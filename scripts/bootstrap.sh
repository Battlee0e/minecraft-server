#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Bootstrapping Minecraft server config"

# The container runs as this uid, matching docker-compose.yml. Never root:
# with cap_drop: ALL the image can't drop privileges, so it must start
# unprivileged. 1000 is the image's own default user.
RUN_UID=1000
RUN_GID=1000

if [ -f .env ]; then
  echo "    .env already exists — leaving it alone."
else
  cp .env.example .env
  RCON_PW="$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
  # BSD/macOS sed needs an explicit empty suffix for -i; GNU does not.
  if sed --version >/dev/null 2>&1; then
    sed -i "s|^MC_RCON_PASSWORD=.*|MC_RCON_PASSWORD=${RCON_PW}|" .env
  else
    sed -i '' "s|^MC_RCON_PASSWORD=.*|MC_RCON_PASSWORD=${RCON_PW}|" .env
  fi
  chmod 600 .env
  echo "    Created .env (chmod 600) with a generated RCON password."
fi

if [ -f data/whitelist-source.txt ]; then
  echo "    data/whitelist-source.txt already exists — leaving it alone."
else
  cp data/whitelist-source.txt.example data/whitelist-source.txt
  echo "    Created data/whitelist-source.txt — edit it with real usernames."
fi

# The container can't chown data/ itself (cap_drop: ALL), so do it here
# while we still might have the privileges for it.
if [ -n "$(find data ! -uid "$RUN_UID" -print -quit 2>/dev/null)" ]; then
  if chown -R "${RUN_UID}:${RUN_GID}" data/ 2>/dev/null; then
    echo "    Set ownership of data/ to ${RUN_UID}:${RUN_GID}."
  else
    echo "    WARNING: data/ is not owned by ${RUN_UID}:${RUN_GID} and this"
    echo "             user can't change it. The server will not start until:"
    echo "               sudo chown -R ${RUN_UID}:${RUN_GID} data/"
  fi
fi

cat <<'EOF'

==> Done.

  1. Edit data/whitelist-source.txt   (real usernames)
  2. Review .env                      (memory, players, MOTD)
  3. docker compose up -d
  4. docker compose logs -f mc

Firewall (once, as root):
     ufw allow 25565/tcp
     ufw status numbered      # confirm 25575 is NOT listed

Verify after first boot:
     docker exec mc id        # should not be uid=0
     docker compose ps        # healthcheck should read "healthy"

EOF
