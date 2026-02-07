FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    rsync \
    openssh-client \
    tzdata \
    util-linux

# Set timezone (configurable via TZ env var)
ENV TZ=America/New_York

# Create log directory
RUN mkdir -p /var/log/rsync-backup

# Copy the sync script
COPY sync.sh /usr/local/bin/sync.sh
RUN chmod 0755 /usr/local/bin/sync.sh

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
