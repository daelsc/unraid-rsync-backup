# Unraid Rsync Backup

A lightweight Docker container for backing up Unraid shares to a remote server via rsync over SSH. Designed for the Unraid Community Applications ecosystem with full UI configuration support.

## Features

- **Scheduled backups** via configurable cron schedule
- **Share-level excludes** - skip specific shares entirely
- **Path pattern excludes** - skip paths within shares (e.g., `cache/`, `*.tmp`)
- **Unraid UI integration** - configure everything through the Docker template
- **Minimal footprint** - Alpine-based, ~16MB image
- **SSH key authentication** - secure, passwordless backups

## Quick Start

### Prerequisites

1. **SSH keys** configured on your Unraid server:
   ```bash
   ssh-keygen -t ed25519
   ```

2. **Copy public key** to the destination server:
   ```bash
   ssh-copy-id root@destination-server
   ```

3. **Test SSH connection**:
   ```bash
   ssh root@destination-server
   ```

### Installation

#### Option 1: Community Applications (Recommended)

Search for "unraid-rsync-backup" in Community Applications and install.

#### Option 2: Manual Template

1. Copy `unraid-template.xml` to `/boot/config/plugins/dockerMan/templates-user/`
2. Go to Docker → Add Container → Select template

#### Option 3: Docker Compose

```yaml
services:
  rsync-backup:
    image: ghcr.io/daelsc/unraid-rsync-backup:latest
    container_name: rsync-backup
    restart: unless-stopped
    network_mode: host
    volumes:
      - /mnt/user:/mnt/user:ro
      - /root/.ssh:/root/.ssh:ro
      - /mnt/user/appdata/rsync-backup/logs:/var/log/rsync-backup
    environment:
      - TZ=America/New_York
      - DST_HOST=192.168.1.100
      - DST_BASE=/mnt/user/backup
      - CRON_SCHEDULE=0 0 * * *
      - EXCLUDE_SHARES=appdata,isos
      - EXCLUDE_PATHS=cache/,*.tmp
```

## Configuration

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DST_HOST` | Yes | - | Destination server IP or hostname |
| `DST_BASE` | No | `/mnt/user/backup` | Remote path for backups |
| `CRON_SCHEDULE` | No | `0 0 * * *` | Cron schedule (default: midnight daily) |
| `EXCLUDE_SHARES` | No | - | Comma-separated shares to skip |
| `EXCLUDE_PATHS` | No | - | Comma-separated rsync exclude patterns |
| `RUN_ON_START` | No | `0` | Set to `1` to sync on container start |
| `TZ` | No | `America/New_York` | Timezone for logs |

### Cron Schedule Examples

| Schedule | Description |
|----------|-------------|
| `0 0 * * *` | Daily at midnight |
| `0 */6 * * *` | Every 6 hours |
| `0 2 * * 0` | Sundays at 2am |
| `0 3 * * 1-5` | Weekdays at 3am |

## Volume Mounts

| Container Path | Host Path | Mode | Description |
|----------------|-----------|------|-------------|
| `/mnt/user` | `/mnt/user` | ro | Source shares to backup |
| `/root/.ssh` | `/root/.ssh` | ro | SSH keys for authentication |
| `/var/log/rsync-backup` | `/mnt/user/appdata/rsync-backup/logs` | rw | Persistent logs |

## Manual Sync

To trigger a sync manually:

```bash
docker exec rsync-backup /usr/local/bin/sync.sh
```

Dry run (no changes):

```bash
docker exec rsync-backup /usr/local/bin/sync.sh --dry-run
```

## Logs

Logs are stored in the configured logs volume:

```bash
# View latest log
ls -lt /mnt/user/appdata/rsync-backup/logs/*.log | head -1 | xargs cat

# Follow cron log
tail -f /mnt/user/appdata/rsync-backup/logs/cron.log
```

## Building Locally

```bash
docker build -t unraid-rsync-backup .
```

## License

MIT
