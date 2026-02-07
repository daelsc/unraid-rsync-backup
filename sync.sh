#!/usr/bin/env bash
set -euo pipefail

# Prevent overlapping runs with a lock file
LOCKFILE="/var/run/rsync-backup.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
  echo "$(date -Is) Another sync is already running (lock: $LOCKFILE). Skipping."
  exit 0
fi

# Configuration via environment variables (with defaults)
SRC_BASE="${SRC_BASE:-/mnt/user}"
DST_HOST="${DST_HOST:?ERROR: DST_HOST environment variable is required}"
DST_BASE="${DST_BASE:-/mnt/user/backup}"

# Parse comma-separated env vars into arrays
IFS="," read -ra EXCLUDES <<< "${EXCLUDE_SHARES:-}"
IFS="," read -ra EXCLUDE_PATHS <<< "${EXCLUDE_PATHS:-}"

RSYNC_OPTS=(
  -aHAXx
  --numeric-ids
  --human-readable
  --info=progress2,stats2
  --partial
  --partial-dir=.rsync-partial
  --delete
  --delete-delay
)

DRYRUN="${DRYRUN:-0}"
NODELETE="${NODELETE:-0}"

# CLI overrides (optional)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRYRUN=1; shift ;;
    --no-delete) NODELETE=1; shift ;;
    --exclude) EXCLUDES+=("$2"); shift 2 ;;
    --exclude-path) EXCLUDE_PATHS+=("$2"); shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--no-delete] [--exclude SHARE]... [--exclude-path PATH]..."
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

LOG="/var/log/rsync-backup/sync_$(date +%F_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

# Helper function for elapsed time
format_duration() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))
  if [[ $hours -gt 0 ]]; then
    printf "%dh %dm %ds" $hours $minutes $secs
  elif [[ $minutes -gt 0 ]]; then
    printf "%dm %ds" $minutes $secs
  else
    printf "%ds" $secs
  fi
}

RUN_START=$(date +%s)

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    UNRAID RSYNC BACKUP                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo
echo "Started:      $(date -Is)"
echo "Source:       ${SRC_BASE}/"
echo "Destination:  root@${DST_HOST}:${DST_BASE}/"
echo "Log file:     ${LOG}"
[[ $DRYRUN -eq 1 ]] && echo "Mode:         DRY RUN (no changes will be made)"
[[ $NODELETE -eq 1 ]] && echo "Mode:         NO DELETE (skipping file deletions)"
echo

# Test SSH connection
echo "Testing SSH connection to ${DST_HOST}..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${DST_HOST}" 'true' >/dev/null 2>&1; then
  echo "ERROR: SSH to root@${DST_HOST} failed (keys/ssh config?)"
  exit 1
fi
echo "SSH connection OK"
echo

# Build share list from top-level dirs (BusyBox compatible)
mapfile -t SHARES < <(find "$SRC_BASE" -mindepth 1 -maxdepth 1 -type d | xargs -n1 basename | sort)

# Apply share excludes
if [[ ${#EXCLUDES[@]} -gt 0 && -n "${EXCLUDES[0]}" ]]; then
  NEW=()
  for s in "${SHARES[@]}"; do
    skip=0
    for e in "${EXCLUDES[@]}"; do [[ "$s" == "$e" ]] && skip=1; done
    [[ $skip -eq 0 ]] && NEW+=("$s")
  done
  SHARES=("${NEW[@]}")
fi

TOTAL_SHARES=${#SHARES[@]}
echo "Shares to sync: ${TOTAL_SHARES}"
printf '  • %s\n' "${SHARES[@]}"
echo
if [[ ${#EXCLUDES[@]} -gt 0 && -n "${EXCLUDES[0]}" ]]; then
  echo "Excluded shares:"
  printf '  ✗ %s\n' "${EXCLUDES[@]}"
  echo
fi
if [[ ${#EXCLUDE_PATHS[@]} -gt 0 && -n "${EXCLUDE_PATHS[0]}" ]]; then
  echo "Excluded path patterns:"
  printf '  ✗ %s\n' "${EXCLUDE_PATHS[@]}"
  echo
fi

# Per-run options
if [[ $DRYRUN -eq 1 ]]; then RSYNC_OPTS+=(--dry-run); fi
if [[ $NODELETE -eq 1 ]]; then
  RSYNC_OPTS=("${RSYNC_OPTS[@]/--delete/}")
  RSYNC_OPTS=("${RSYNC_OPTS[@]/--delete-delay/}")
fi
for p in "${EXCLUDE_PATHS[@]}"; do
  [[ -n "$p" ]] && RSYNC_OPTS+=(--exclude="$p")
done

echo "Ensuring destination base exists..."
ssh "root@${DST_HOST}" "mkdir -p '$DST_BASE'"
echo

# Track results
declare -A SHARE_STATUS
declare -A SHARE_DURATION
declare -A SHARE_TRANSFERRED
CURRENT=0
FAILED=0
SUCCESS=0

for s in "${SHARES[@]}"; do
  CURRENT=$((CURRENT + 1))
  SHARE_START=$(date +%s)

  echo "┌──────────────────────────────────────────────────────────────────┐"
  echo "│ [$CURRENT/$TOTAL_SHARES] Syncing: $s"
  echo "├──────────────────────────────────────────────────────────────────┤"
  echo "│ Started: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "└──────────────────────────────────────────────────────────────────┘"

  ssh "root@${DST_HOST}" "mkdir -p '$DST_BASE/$s'"

  # Capture rsync output to parse stats
  RSYNC_OUTPUT=$(mktemp)
  if rsync "${RSYNC_OPTS[@]}" \
    -e "ssh -o Compression=no -o ServerAliveInterval=30 -o ServerAliveCountMax=4" \
    "${SRC_BASE}/${s}/" "root@${DST_HOST}:${DST_BASE}/${s}/" 2>&1 | tee "$RSYNC_OUTPUT"; then
    SHARE_STATUS[$s]="OK"
    SUCCESS=$((SUCCESS + 1))
  else
    SHARE_STATUS[$s]="FAILED"
    FAILED=$((FAILED + 1))
  fi

  SHARE_END=$(date +%s)
  SHARE_DURATION[$s]=$((SHARE_END - SHARE_START))

  # Extract transferred size from rsync output
  TRANSFERRED=$(grep -E "^Total transferred file size:" "$RSYNC_OUTPUT" | awk '{print $5, $6}' || echo "0 bytes")
  SHARE_TRANSFERRED[$s]="${TRANSFERRED:-0 bytes}"
  rm -f "$RSYNC_OUTPUT"

  echo
  echo "Completed: $s in $(format_duration ${SHARE_DURATION[$s]}) [${SHARE_STATUS[$s]}]"
  echo
done

RUN_END=$(date +%s)
RUN_DURATION=$((RUN_END - RUN_START))

echo
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                         RUN SUMMARY                              ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo
echo "Finished:     $(date -Is)"
echo "Duration:     $(format_duration $RUN_DURATION)"
echo "Shares:       $SUCCESS succeeded, $FAILED failed (of $TOTAL_SHARES total)"
echo
echo "Per-share results:"
echo "────────────────────────────────────────────────────────────────────"
printf "%-25s %-10s %-15s %s\n" "SHARE" "STATUS" "DURATION" "TRANSFERRED"
echo "────────────────────────────────────────────────────────────────────"
for s in "${SHARES[@]}"; do
  printf "%-25s %-10s %-15s %s\n" "$s" "${SHARE_STATUS[$s]}" "$(format_duration ${SHARE_DURATION[$s]})" "${SHARE_TRANSFERRED[$s]}"
done
echo "────────────────────────────────────────────────────────────────────"
echo

if [[ $FAILED -gt 0 ]]; then
  echo "WARNING: $FAILED share(s) failed to sync completely"
  exit 1
fi

echo "All shares synced successfully!"
