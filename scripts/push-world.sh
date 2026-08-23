#!/usr/bin/env bash
set -euo pipefail

# Install a world into the server, replacing the one that's there.
#
# Two modes:
#
#   Remote — run on YOUR machine, uploads over ssh:
#     MC_SSH=you@vps ./scripts/push-world.sh ~/.minecraft/saves/MyWorld
#
#   Local — run ON THE VPS, for a world already sitting there. No transfer,
#   no ssh, no re-uploading gigabytes you already sent:
#     ./scripts/push-world.sh --local ~/uploads/MyWorld
#
# Paths with spaces are fine — quote them.
#
# Destructive either way, so it stops the server first, takes a backup, and
# asks before overwriting.
#
# Options:
#   --local     source is on this machine and so is the server
#   --yes       skip the confirmation prompt
#   --dry-run   list what would change, change nothing
#
# Env:
#   MC_SSH          user@host  (required unless --local)
#   MC_REMOTE_REPO  repo path on the VPS (default: minecraft-server)
#   MC_LEVEL_NAME   server world folder (default: world — matches LEVEL)

MC_SSH="${MC_SSH:-}"
MC_REMOTE_REPO="${MC_REMOTE_REPO:-minecraft-server}"
MC_LEVEL_NAME="${MC_LEVEL_NAME:-world}"

LOCAL=0
ASSUME_YES=0
DRY_RUN=0
SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --local)    LOCAL=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          SRC="$1" ;;
  esac
  shift
done

die() { echo "Error: $*" >&2; exit 1; }

if [ "$LOCAL" != 1 ]; then
  [ -n "$MC_SSH" ] || die "Set MC_SSH to user@host, or pass --local if the world is already on the server."
fi
[ -n "$SRC" ] || die "Give the world directory, e.g. ~/.minecraft/saves/MyWorld"
[ -d "$SRC" ] || die "Not a directory: $SRC"

# level.dat is what makes a directory a world. Without it we'd happily
# install some unrelated folder over the live save.
[ -f "$SRC/level.dat" ] || die "No level.dat in $SRC — that isn't a Minecraft world."

SRC="$(cd "$SRC" && pwd)"

# --- where it's going ----------------------------------------------------
if [ "$LOCAL" = 1 ]; then
  REPO="$(cd "$(dirname "$0")/.." && pwd)"
  DEST_PATH="${REPO}/data/${MC_LEVEL_NAME}"
  RSYNC_DEST="${DEST_PATH}/"
  DEST_LABEL="$DEST_PATH"

  # Installing a directory onto itself would have rsync --delete eat the
  # world while reading it.
  [ "$SRC" != "$DEST_PATH" ] \
    || die "Source and destination are the same directory ($SRC). Nothing to do."
  # Source under the destination is the same hazard one level down.
  case "$SRC/" in
    "$DEST_PATH"/*) die "Source is inside the destination world folder. Move it out first." ;;
  esac
else
  RSYNC_DEST="${MC_SSH}:${MC_REMOTE_REPO}/data/${MC_LEVEL_NAME}/"
  DEST_LABEL="${MC_SSH}:${MC_REMOTE_REPO}/data/${MC_LEVEL_NAME}"
fi

# Run a command in the server's repo — here or over ssh, same call sites.
run_on_server() {
  if [ "$LOCAL" = 1 ]; then
    ( cd "$REPO" && sh -c "$1" )
  else
    ssh "$MC_SSH" "cd ${MC_REMOTE_REPO} && $1"
  fi
}

echo "Source: $SRC"
echo "Size:   $(du -sh "$SRC" | cut -f1)"
echo "Mode:   $([ "$LOCAL" = 1 ] && echo 'local (no transfer)' || echo 'remote (upload over ssh)')"

# --- which save format is this? -----------------------------------------
# 26.1 unified the layout: dimensions live under dimensions/<ns>/<dim>/ and
# both singleplayer and Paper use it, so a modern world installs verbatim.
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

echo
echo "Destination: ${DEST_LABEL}/"

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "--dry-run: changes that would happen (first 30 lines)"
  rsync -an --checksum --delete --itemize-changes \
    --exclude='session.lock' \
    "$SRC/" "$RSYNC_DEST" | head -30
  exit 0
fi

# --- confirm -------------------------------------------------------------
echo "This REPLACES the world there. A backup is taken first, but the"
echo "world currently running is gone."
if [ "$ASSUME_YES" != 1 ]; then
  printf "Type the world name (%s) to continue: " "$MC_LEVEL_NAME"
  read -r reply
  [ "$reply" = "$MC_LEVEL_NAME" ] || die "Aborted."
fi

# --- stop, back up, install, start --------------------------------------
# The server must be down. The JVM holds region files open and would write
# its in-memory state over whatever we copy in.
echo
echo "==> Stopping the server"
run_on_server "./scripts/server.sh stop"

echo "==> Backing up the world that's there now"
run_on_server "./scripts/backup.sh"

echo "==> Installing"
# --delete so stale region files from the old world can't linger and mix
# into the new one. Scoped to the world folder, never to data/, which also
# holds ops.json, whitelist-source.txt, plugin configs and logs.
#
# --checksum, not rsync's default size+mtime quick check. Two different
# worlds can hold a same-size file with a matching timestamp — level.dat is
# a realistic candidate — and the quick check would skip it, leaving a world
# that is part old and part new. That silent half-swap is far worse than the
# I/O this costs, and installing a world is a rare operation.
#
# session.lock is excluded: the server writes its own, and a stale one from
# a still-open client is exactly the kind of thing to leave behind.
# No -z; region files are already compressed, and in local mode there's no
# network to compress for anyway.
rsync -a --checksum --delete --partial --info=progress2 \
  --exclude='session.lock' \
  "$SRC/" "$RSYNC_DEST"

echo "==> Starting the server"
run_on_server "./scripts/server.sh start"

echo
if [ "$LEGACY" = 1 ]; then
  echo "Watch the first boot — the format migration is logged, and a large"
  echo "world takes a while:"
else
  echo "Watch it load:"
fi
if [ "$LOCAL" = 1 ]; then
  echo "  ./scripts/server.sh logs"
else
  echo "  ssh ${MC_SSH} 'cd ${MC_REMOTE_REPO} && ./scripts/server.sh logs'"
fi
