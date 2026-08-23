#!/usr/bin/env bash
set -euo pipefail

# Pull backup archives from the VPS down to this machine.
#
# NOTE: this is the one script that runs LOCALLY, not on the server.
# bootstrap.sh and backup.sh run on the VPS; this one reaches into it.
#
#   MC_SSH=you@vps.example.com ./scripts/pull-backups.sh
#
# Or put MC_SSH in your shell profile / a local .env.pull and source it.
# Configure once, then it's a single command whenever you want a copy.

MC_SSH="${MC_SSH:-}"
MC_REMOTE_DIR="${MC_REMOTE_DIR:-minecraft-server/backups}"
LOCAL_DIR="${LOCAL_DIR:-backups}"

if [ -z "$MC_SSH" ]; then
  cat >&2 <<'EOF'
Set MC_SSH to the server you're pulling from, e.g.

    MC_SSH=manuel@vps.example.com ./scripts/pull-backups.sh

Optional overrides:
    MC_REMOTE_DIR   path to the backups dir on the VPS
                    (default: minecraft-server/backups, relative to $HOME)
    LOCAL_DIR       where to put them here (default: backups)
EOF
  exit 1
fi

mkdir -p "$LOCAL_DIR"

# -a  preserve times/perms, so we can tell which archive is which
# --partial  an interrupted transfer resumes instead of restarting; world
#            tarballs get big and home connections drop
# No -z: the archives are already gzipped, compressing again is wasted CPU.
# Trailing slash on the source means "contents of", not "the dir itself".
rsync -a --partial --info=progress2 \
  "${MC_SSH}:${MC_REMOTE_DIR}/" "${LOCAL_DIR}/"

echo
echo "Local copies in ${LOCAL_DIR}:"
ls -lht "${LOCAL_DIR}" | tail -n +2 | head -20
