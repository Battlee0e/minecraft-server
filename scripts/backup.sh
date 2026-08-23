#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP="$(date +%Y%m%d-%H%M)"

# Kept on the VPS so there is always a local copy to restore from and for
# scripts/pull-backups.sh to fetch. Override with MC_BACKUP_DIR.
BACKUP_DIR="${MC_BACKUP_DIR:-backups}"
# How many to retain. Each is a full copy of data/, so watch disk on a
# small VPS — check with: du -sh backups/
KEEP="${MC_BACKUP_KEEP:-7}"

mkdir -p "$BACKUP_DIR"
ARCHIVE="${BACKUP_DIR}/mc-backup-${STAMP}.tar.gz"

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

# Saving can resume now — the rest doesn't touch the world. (The EXIT trap
# would also handle it, but holding save-off during an upload is needless.)
restore_saving
trap - EXIT

# Optional offsite copy to R2 (uncomment and set R2_ENDPOINT / bucket):
# aws s3 cp "$ARCHIVE" s3://your-r2-bucket/minecraft/ --endpoint-url="$R2_ENDPOINT"

# Retain the newest $KEEP archives, delete the rest.
ls -1t "${BACKUP_DIR}"/mc-backup-*.tar.gz 2>/dev/null \
  | tail -n +$((KEEP + 1)) \
  | xargs -r rm -f

echo "Backup complete: ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1))"
echo "Retained $(ls -1 "${BACKUP_DIR}"/mc-backup-*.tar.gz 2>/dev/null | wc -l) of $KEEP."
