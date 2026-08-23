#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP="$(date +%Y%m%d-%H%M)"
ARCHIVE="/tmp/mc-backup-${STAMP}.tar.gz"

# Always re-enable saving, even if the tar fails partway.
restore_saving() {
  docker exec mc rcon-cli save-on >/dev/null 2>&1 || true
}
trap restore_saving EXIT

# Flush pending writes, then pause saving so we don't tar a half-written
# region file. Both are no-ops if the container isn't running.
docker exec mc rcon-cli save-all flush >/dev/null 2>&1 || true
docker exec mc rcon-cli save-off      >/dev/null 2>&1 || true

tar czf "$ARCHIVE" data/

# Upload to R2 (uncomment and set R2_ENDPOINT / bucket):
# aws s3 cp "$ARCHIVE" s3://your-r2-bucket/minecraft/ --endpoint-url="$R2_ENDPOINT"

rm -f "$ARCHIVE"
echo "Backup complete: mc-backup-${STAMP}.tar.gz"
