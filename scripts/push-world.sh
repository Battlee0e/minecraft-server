#!/usr/bin/env bash
set -euo pipefail

# Upload a local world to the VPS, replacing the one that's there.
#
# Runs LOCALLY (like pull-backups.sh, unlike the rest).
#
#   MC_SSH=you@vps ./scripts/push-world.sh ~/.minecraft/saves/MyWorld
#
# Paths with spaces are fine — quote them.
#
# This is destructive on the server side, so it stops the server first,
# takes a remote backup, and asks before overwriting.
#
# Options:
#   --yes       skip the confirmation prompt
#   --dry-run   list what would transfer, change nothing
#
# Env:
#   MC_SSH          user@host  (required)
#   MC_REMOTE_REPO  repo path on the VPS (default: minecraft-server)
#   MC_LEVEL_NAME   server world folder (default: world — matches LEVEL)

MC_SSH="${MC_SSH:-}"
MC_REMOTE_REPO="${MC_REMOTE_REPO:-minecraft-server}"
MC_LEVEL_NAME="${MC_LEVEL_NAME:-world}"

ASSUME_YES=0
DRY_RUN=0
SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          SRC="$1" ;;
  esac
  shift
done

die() { echo "Error: $*" >&2; exit 1; }

[ -n "$MC_SSH" ] || die "Set MC_SSH to user@host, e.g. MC_SSH=me@vps $0 <world-dir>"
[ -n "$SRC" ]    || die "Give the local world directory, e.g. ~/.minecraft/saves/MyWorld"
[ -d "$SRC" ]    || die "Not a directory: $SRC"
# Empty would make the destination data/ itself, and --delete would then
# eat ops.json, the whitelist and every plugin config.
[ -n "$MC_LEVEL_NAME" ] || die "MC_LEVEL_NAME must not be empty."

# level.dat is what makes a directory a world. Without it we'd happily
# upload some unrelated folder over the live save.
[ -f "$SRC/level.dat" ] || die "No level.dat in $SRC — that isn't a Minecraft world."

SRC="${SRC%/}"
DEST="${MC_REMOTE_REPO}/data/${MC_LEVEL_NAME}"

echo "Source: $SRC"
echo "Size:   $(du -sh "$SRC" | cut -f1)"

# --- which save format is this? -----------------------------------------
# 26.1 unified the layout: dimensions live under dimensions/<ns>/<dim>/ and
# both singleplayer and Paper use it, so a modern world uploads verbatim.
# Older worlds keep the nether/end as DIM-1/DIM1 inside the world folder;
# the server migrates those on first load, which is a one-way conversion.
LEGACY=0
if [ -d "$SRC/dimensions" ]; then
  echo "Format: 26.1+ (dimensions/<namespace>/<dimension>)"
  for dim in overworld the_nether the_end; do
    if [ -d "$SRC/dimensions/minecraft/$dim" ]; then
      echo "        $(printf '%-11s' "$dim") $(du -sh "$SRC/dimensions/minecraft/$dim" | cut -f1)"
    else
      echo "        $(printf '%-11s' "$dim") absent"
    fi
  done
elif [ -d "$SRC/DIM-1" ] || [ -d "$SRC/DIM1" ] || [ -d "$SRC/region" ]; then
  LEGACY=1
  echo "Format: pre-26.1 (region/ + DIM-1/ + DIM1/)"
  echo
  echo "  The server will migrate this to the 26.1+ layout on first load."
  echo "  That conversion is ONE-WAY — the world won't open in an older"
  echo "  client afterwards. The backup taken below is your way back."
else
  die "$SRC has level.dat but neither dimensions/ nor region/ — unrecognised layout."
fi

# --- confirm -------------------------------------------------------------
echo
echo "Destination: ${MC_SSH}:${DEST}/"

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "--dry-run: transfer that would happen (first 30 lines)"
  rsync -an --delete --itemize-changes \
    --exclude='session.lock' \
    "$SRC/" "${MC_SSH}:${DEST}/" | head -30
  exit 0
fi

echo "This REPLACES the world there. A backup is taken first, but the"
echo "world currently running is gone."
if [ "$ASSUME_YES" != 1 ]; then
  printf "Type the world name (%s) to continue: " "$MC_LEVEL_NAME"
  read -r reply
  [ "$reply" = "$MC_LEVEL_NAME" ] || die "Aborted."
fi

# --- stop, back up, upload, start ---------------------------------------
# The server must be down. The JVM holds region files open and would write
# its in-memory state over whatever we copy in.
echo
echo "==> Stopping the server"
ssh "$MC_SSH" "cd ${MC_REMOTE_REPO} && ./scripts/server.sh stop"

echo "==> Backing up the world that's there now"
ssh "$MC_SSH" "cd ${MC_REMOTE_REPO} && ./scripts/backup.sh"

echo "==> Uploading"
# --delete so stale region files from the old world can't linger and mix
# into the new one. Scoped to the world folder, never to data/, which also
# holds ops.json, whitelist-source.txt, plugin configs and logs.
# session.lock is excluded: the server writes its own, and a stale one from
# a still-open client is exactly the kind of thing to leave behind.
# No -z; region files are already compressed.
rsync -a --delete --partial --info=progress2 \
  --exclude='session.lock' \
  "$SRC/" "${MC_SSH}:${DEST}/"

echo "==> Starting the server"
ssh "$MC_SSH" "cd ${MC_REMOTE_REPO} && ./scripts/server.sh start"

echo
if [ "$LEGACY" = 1 ]; then
  echo "Watch the first boot — the format migration is logged, and a large"
  echo "world takes a while:"
else
  echo "Watch it load:"
fi
echo "  ssh ${MC_SSH} 'cd ${MC_REMOTE_REPO} && ./scripts/server.sh logs'"
