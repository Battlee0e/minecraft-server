#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Bootstrapping Minecraft server config"

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
  # The container runs as this uid:gid and can't chown /data itself, so
  # record whoever is setting the server up rather than assuming 1000.
  sed -i.bak "s|^MC_UID=.*|MC_UID=$(id -u)|; s|^MC_GID=.*|MC_GID=$(id -g)|" .env
  rm -f .env.bak
  chmod 600 .env
  echo "    Created .env (chmod 600) with a generated RCON password."
  echo "    Container will run as $(id -u):$(id -g) — matching you."
fi

if [ -f data/whitelist-source.txt ]; then
  echo "    data/whitelist-source.txt already exists — leaving it alone."
else
  cp data/whitelist-source.txt.example data/whitelist-source.txt
  echo "    Created data/whitelist-source.txt — edit it with real usernames."
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
