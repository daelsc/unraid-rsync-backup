#!/bin/bash
set -e

# Ensure SSH key permissions are correct (skip if read-only mount)
if [ -d /root/.ssh ] && [ -w /root/.ssh ]; then
  chmod 700 /root/.ssh 2>/dev/null || true
  chmod 600 /root/.ssh/id_* 2>/dev/null || true
  chmod 644 /root/.ssh/*.pub 2>/dev/null || true
  chmod 644 /root/.ssh/known_hosts 2>/dev/null || true
fi

# Generate crontab from environment variable
CRON_SCHEDULE="${CRON_SCHEDULE:-0 0 * * *}"
echo "${CRON_SCHEDULE} /usr/local/bin/sync.sh >> /var/log/rsync-backup/cron.log 2>&1" > /etc/crontabs/root

echo "=========================================="
echo "Unraid Rsync Backup container started"
echo "=========================================="
echo "Time:          $(date -Is)"
echo "Cron schedule: ${CRON_SCHEDULE}"
echo "Source:        ${SRC_BASE:-/mnt/user}"
echo "Destination:   ${DST_HOST:-NOT SET}:${DST_BASE:-/mnt/user/backup}"
echo "Excludes:      ${EXCLUDE_SHARES:-none}"
echo "Exclude paths: ${EXCLUDE_PATHS:-none}"
echo "Logs:          /var/log/rsync-backup/"
echo "=========================================="

# Run now if RUN_ON_START is set
if [ "${RUN_ON_START:-0}" = "1" ]; then
  echo "RUN_ON_START=1, running sync now..."
  /usr/local/bin/sync.sh || true
fi

# Run crond in foreground
exec crond -f -l 2
