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
  --info=stats2,name,progress2
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

echo "=== Unraid Rsync Backup ==="
echo "Time:     $(date -Is)"
echo "Source:   ${SRC_BASE}/"
echo "Dest:     root@${DST_HOST}:${DST_BASE}/"
echo "Log:      ${LOG}"
echo

if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${DST_HOST}" 'true' >/dev/null 2>&1; then
  echo "ERROR: SSH to root@${DST_HOST} failed (keys/ssh config?)"
  exit 1
fi

# Build share list from top-level dirs
mapfile -t SHARES < <(find "$SRC_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

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

echo "Shares to sync:"
printf '  - %s\n' "${SHARES[@]}"
if [[ ${#EXCLUDE_PATHS[@]} -gt 0 && -n "${EXCLUDE_PATHS[0]}" ]]; then
  echo "Exclude-path patterns:"
  printf '  - %s\n' "${EXCLUDE_PATHS[@]}"
fi
echo

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

for s in "${SHARES[@]}"; do
  echo
  echo "=== Sync: $s ==="
  ssh "root@${DST_HOST}" "mkdir -p '$DST_BASE/$s'"
  rsync "${RSYNC_OPTS[@]}" \
    -e "ssh -o Compression=no -o ServerAliveInterval=30 -o ServerAliveCountMax=4" \
    "${SRC_BASE}/${s}/" "root@${DST_HOST}:${DST_BASE}/${s}/"
done

echo
echo "Done: $(date -Is)"
