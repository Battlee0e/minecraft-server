#!/usr/bin/env bash
set -euo pipefail

# Upload a local world to the VPS, replacing the one that's there.
#
# Runs LOCALLY (like pull-backups.sh, unlike the rest).
#
#   MC_SSH=you@vps ./scripts/push-world.sh ~/.minecraft/saves/MyWorld
#
# This is destructive on the server side, so it: refuses to run against a
# live server, takes a remote backup first, and asks before overwriting.
#
# Options:
#   --yes           skip the confirmation prompt
#   --dry-run       show what would transfer, change nothing
#   --stage-only    just convert to the Paper layout locally and print where,
#                   so you can inspect it before pushing. No network.
#
# Env:
#   MC_SSH          user@host  (required)
#   MC_REMOTE_REPO  repo path on the VPS (default: minecraft-server)
#   MC_LEVEL_NAME   server world name (default: world — matches LEVEL default)

MC_SSH="${MC_SSH:-}"
MC_REMOTE_REPO="${MC_REMOTE_REPO:-minecraft-server}"
MC_LEVEL_NAME="${MC_LEVEL_NAME:-world}"

ASSUME_YES=0
DRY_RUN=0
STAGE_ONLY=0
SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)     ASSUME_YES=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --stage-only) STAGE_ONLY=1 ;;
    -*)           echo "Unknown option: $1" >&2; exit 1 ;;
    *)            SRC="$1" ;;
  esac
  shift
done

die() { echo "Error: $*" >&2; exit 1; }

# --stage-only never touches the network, so it doesn't need a target host.
[ -n "$MC_SSH" ] || [ "$STAGE_ONLY" = 1 ] \
  || die "Set MC_SSH to user@host, e.g. MC_SSH=me@vps $0 <world-dir>"
[ -n "$SRC" ]    || die "Give the local world directory, e.g. ~/.minecraft/saves/MyWorld"
[ -d "$SRC" ]    || die "Not a directory: $SRC"

# level.dat is what makes a directory a world. Without it we'd happily
# upload some unrelated folder over the live save.
[ -f "$SRC/level.dat" ] || die "No level.dat in $SRC — that isn't a Minecraft world."

SRC="${SRC%/}"
echo "Source: $SRC"

# --- work out the layout -------------------------------------------------
# Singleplayer keeps all three dimensions in one folder (DIM-1 = nether,
# DIM1 = end). Paper wants them as separate sibling world folders. Copying
# a singleplayer save verbatim silently regenerates the nether and end.
HAS_NETHER=0; [ -d "$SRC/DIM-1" ] && HAS_NETHER=1
HAS_END=0;    [ -d "$SRC/DIM1"  ] && HAS_END=1

if [ "$HAS_NETHER" = 1 ] || [ "$HAS_END" = 1 ]; then
  echo "Layout: singleplayer (dimensions nested) — will split for Paper:"
  [ "$HAS_NETHER" = 1 ] && echo "  DIM-1  ->  ${MC_LEVEL_NAME}_nether/DIM-1"
  [ "$HAS_END"    = 1 ] && echo "  DIM1   ->  ${MC_LEVEL_NAME}_the_end/DIM1"
else
  echo "Layout: no DIM-1/DIM1 present — uploading the overworld only."
  echo "        If this world HAS a nether/end you care about, stop: they"
  echo "        aren't in this folder and will regenerate empty."
fi

# --- stage the converted layout locally ----------------------------------
STAGE="$(mktemp -d)"
# --stage-only is asking to keep the result, so only clean up otherwise.
[ "$STAGE_ONLY" = 1 ] || trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/${MC_LEVEL_NAME}"
# Everything except the nested dimensions becomes the overworld.
rsync -a --exclude='DIM-1' --exclude='DIM1' "$SRC/" "$STAGE/${MC_LEVEL_NAME}/"

if [ "$HAS_NETHER" = 1 ]; then
  mkdir -p "$STAGE/${MC_LEVEL_NAME}_nether/DIM-1"
  rsync -a "$SRC/DIM-1/" "$STAGE/${MC_LEVEL_NAME}_nether/DIM-1/"
  # Each world folder needs its own level.dat; the overworld's works.
  cp "$SRC/level.dat" "$STAGE/${MC_LEVEL_NAME}_nether/level.dat"
fi

if [ "$HAS_END" = 1 ]; then
  mkdir -p "$STAGE/${MC_LEVEL_NAME}_the_end/DIM1"
  rsync -a "$SRC/DIM1/" "$STAGE/${MC_LEVEL_NAME}_the_end/DIM1/"
  cp "$SRC/level.dat" "$STAGE/${MC_LEVEL_NAME}_the_end/level.dat"
fi

echo
echo "Staged $(du -sh "$STAGE" | cut -f1) in the Paper layout:"
ls -1 "$STAGE" | sed 's/^/  /'

if [ "$STAGE_ONLY" = 1 ]; then
  echo
  echo "--stage-only: converted, nothing uploaded. Inspect it at:"
  echo "  $STAGE"
  echo "Remove it yourself when you're done."
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "--dry-run: would rsync the above into ${MC_SSH}:${MC_REMOTE_REPO}/data/"
  for dir in "$STAGE"/*/; do
    name="$(basename "$dir")"
    echo "  --- ${name} ---"
    rsync -an --delete --itemize-changes \
      "$dir" "${MC_SSH}:${MC_REMOTE_REPO}/data/${name}/" | head -10
  done
  exit 0
fi

# --- confirm -------------------------------------------------------------
echo
echo "This REPLACES the world at ${MC_SSH}:${MC_REMOTE_REPO}/data/"
echo "A backup is taken on the server first, but the running world is lost."
if [ "$ASSUME_YES" != 1 ]; then
  printf "Type the world name (%s) to continue: " "$MC_LEVEL_NAME"
  read -r reply
  [ "$reply" = "$MC_LEVEL_NAME" ] || die "Aborted."
fi

# --- stop, back up, upload, start ----------------------------------------
# The server must be down. Region files are held open by the JVM, and it
# will write its in-memory state over whatever we copy in.
echo
echo "==> Stopping the server"
ssh "$MC_SSH" "cd ${MC_REMOTE_REPO} && ./scripts/server.sh stop"

echo "==> Backing up the world that's there now"
ssh "$MC_SSH" "cd ${MC_REMOTE_REPO} && ./scripts/backup.sh"

echo "==> Uploading"
# One rsync per world folder, NOT one for data/. --delete is needed so
# leftover region files from the old world can't survive and mix into the
# new one — but pointed at data/ it would also wipe ops.json,
# whitelist-source.txt, plugin configs and logs. Keep it scoped.
for dir in "$STAGE"/*/; do
  name="$(basename "$dir")"
  echo "  --- ${name} ---"
  rsync -a --delete --info=progress2 \
    "$dir" "${MC_SSH}:${MC_REMOTE_REPO}/data/${name}/"
done

echo "==> Starting the server"
ssh "$MC_SSH" "cd ${MC_REMOTE_REPO} && ./scripts/server.sh start"

echo
echo "Done. Watch it load — a converted world logs upgrade work on first boot:"
echo "  ssh ${MC_SSH} 'cd ${MC_REMOTE_REPO} && ./scripts/server.sh logs'"
