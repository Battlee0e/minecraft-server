#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Run on the VPS. start/stop/restart/logs are thin wrappers over docker
# compose — the part that actually earns a script is `address`, which works
# out what players should type.

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/server.sh <command>

  start      Bring the server up and print the connect address
  stop       Shut down gracefully (waits for the world to finish saving)
  restart    stop + start
  status     Container state, health, and connect address
  address    Just the connect address
  logs       Follow the server log (Ctrl-C to detach, server keeps running)
EOF
  exit 1
}

# Read the published port from docker rather than assuming 25565, so this
# stays correct if the mapping in docker-compose.yml is ever changed.
published_port() {
  local mapping
  mapping="$(docker compose port mc 25565 2>/dev/null || true)"
  if [ -n "$mapping" ]; then
    echo "${mapping##*:}"
  else
    echo "25565"
  fi
}

public_ip() {
  local ip
  for url in https://api.ipify.org https://icanhazip.com https://ifconfig.me; do
    ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  done
  return 1
}

address() {
  local port pub lan
  port="$(published_port)"

  echo "Port: ${port}"
  echo

  if pub="$(public_ip)"; then
    # Minecraft assumes 25565. Anything else has to be typed explicitly.
    if [ "$port" = "25565" ]; then
      echo "  Players connect to:   ${pub}"
      echo "  (no port needed — 25565 is Minecraft's default)"
    else
      echo "  Players connect to:   ${pub}:${port}"
    fi
  else
    echo "  Could not determine the public IP (no outbound network?)."
    echo "  Find it with: curl https://api.ipify.org"
  fi

  lan="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  if [ -n "$lan" ]; then
    echo
    if [ "$port" = "25565" ]; then
      echo "  On the same network:  ${lan}"
    else
      echo "  On the same network:  ${lan}:${port}"
    fi
  fi

  echo
  echo "  Only whitelisted names can join — see data/whitelist-source.txt"
}

# The container runs as MC_UID:MC_GID with no capabilities, so it cannot
# chown anything itself. If data/ belongs to someone else the server dies
# in a wall of "chown: Operation not permitted" — catch it here instead.
# Reads one key from .env. Must not fail when the key is absent: under
# `set -e` with pipefail, a bare `grep | cut` that matches nothing kills the
# whole script silently. sed -n exits 0 either way.
env_get() {
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | head -1
}

# docker-compose.yml passes the whitelist as MC_WHITELIST, a comma-separated
# name list, because the image's file-based option copies rather than parses
# (see the comment there). Compose has no way to read a file itself, so turn
# the one-name-per-line source into that list here. An exported variable wins
# over .env, so nothing needs to be stored there.
#
# Strips comments and whitespace. No source file, or one with nothing but
# comments, yields an empty string — harmless, the image just skips the step.
whitelist_csv() {
  [ -f data/whitelist-source.txt ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' data/whitelist-source.txt |
    paste -sd, -
}

preflight() {
  local uid gid offender
  uid="$(env_get MC_UID)"
  gid="$(env_get MC_GID)"
  # Matches the compose default, so a pre-existing .env behaves the same.
  uid="${uid:-1000}"
  gid="${gid:-1000}"

  if [ "$uid" = "0" ]; then
    cat >&2 <<'EOF'
Error: MC_UID is 0. The container cannot run as root — with cap_drop: ALL
it has no CAP_SETUID, so the image's privilege drop fails and it exits with
"failed switching to 'minecraft:minecraft'".

Set MC_UID/MC_GID in .env to a non-root user (1000 is the usual choice) and
chown data/ to match:

  sed -i 's/^MC_UID=.*/MC_UID=1000/; s/^MC_GID=.*/MC_GID=1000/' .env
  chown -R 1000:1000 data/
EOF
    exit 1
  fi

  [ -d data ] || return 0

  # -quit stops at the first mismatch rather than walking the whole world.
  offender="$(find data ! -uid "$uid" -print -quit 2>/dev/null)"
  [ -n "$offender" ] || return 0

  cat >&2 <<EOF
Error: data/ is not owned by ${uid}:${gid}, and the container cannot fix
that itself (it runs unprivileged with cap_drop: ALL).

  first mismatch: ${offender}
  owned by uid:   $(stat -c %u "$offender")
  expected uid:   ${uid}

Fix it, then start again:

  sudo chown -R ${uid}:${gid} data/

This usually means files arrived as another user — an rsync or scp under a
different account, or a directory Docker created as root.
EOF
  exit 1
}

case "${1:-}" in
  start)
    preflight
    MC_WHITELIST="$(whitelist_csv)"
    export MC_WHITELIST
    if [ -z "$MC_WHITELIST" ]; then
      echo "Warning: data/whitelist-source.txt lists no names. With" >&2
      echo "ENFORCE_WHITELIST=TRUE, only players already in" >&2
      echo "data/whitelist.json will be able to join." >&2
      echo >&2
    fi
    docker compose up -d
    echo
    address
    echo
    echo "The healthcheck has a 2m start_period; the server won't accept"
    echo "connections until it finishes generating/loading the world."
    echo "Watch it come up with: ./scripts/server.sh logs"
    ;;
  stop)
    # stop_grace_period in docker-compose.yml (60s) gives the JVM time to
    # flush the world before Docker escalates to SIGKILL.
    echo "Stopping — waiting for the world to save..."
    docker compose stop
    echo "Stopped."
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    docker compose ps
    echo
    if [ -n "$(docker compose ps -q mc 2>/dev/null)" ]; then
      address
    else
      echo "Not running. Start it with: ./scripts/server.sh start"
    fi
    ;;
  address)
    address
    ;;
  logs)
    docker compose logs -f mc
    ;;
  *)
    usage
    ;;
esac
