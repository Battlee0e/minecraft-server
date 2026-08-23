# mc-server

Dockerised Paper Minecraft server, configured for a small whitelisted group on a
shared VPS. Config is env-driven.

## Setup

```bash
git clone https://github.com/Battlee0e/minecraft-server.git minecraft-server 
cd minecraft-server 
./scripts/bootstrap.sh # creates .env + whitelist from the templates
nano data/whitelist-source.txt
./scripts/server.sh start
```

Firewall, once, as root:

```bash
ufw allow 25565/tcp           # game port — must stay open for players
ufw allow 80,443/tcp          # only if a website shares this VPS
ufw status numbered
```

Rules are per-port and independent: adding the web ports does not affect 25565,
and 25565 stays open for as long as you want people to connect. Note that UFW
does not actually gate the container's port — see Security notes.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Service definition — reads everything from `.env` |
| `.env.example` | .env template |
| `.env` | Real config incl. RCON password — **gitignored** |
| `data/whitelist-source.txt` | Plain usernames, one per line — **gitignored** |
| `data/` | World saves, `ops.json`, logs, plugin configs — **gitignored** |
| `scripts/server.sh` | start/stop/status + connect address — **on the VPS** |
| `scripts/bootstrap.sh` | First-run setup — **on the VPS** |
| `scripts/backup.sh` | Snapshot `data/` with saving paused — **on the VPS** |
| `scripts/pull-backups.sh` | Fetch archives down — **on your local machine** |
| `scripts/push-world.sh` | Upload a world to the VPS — **on your local machine** |
| `backups/` | Retained archives — **gitignored** |

## Whitelist

Edit `data/whitelist-source.txt` (one username per line) and restart. The image
resolves usernames to UUIDs on each start, so no manual UUID lookup.

To change it live instead:

```bash
docker exec mc rcon-cli whitelist add PlayerName
docker exec mc rcon-cli whitelist list
```

`ENFORCE_WHITELIST=TRUE` kicks non-whitelisted players immediately rather than
only blocking new joins.

**"That player does not exist"** means Mojang's profile API couldn't resolve
the name — the server has to turn it into a UUID, because `ONLINE_MODE=TRUE`.
Almost always one of:

- It's an **Xbox gamertag, not a Java profile name.** They differ even on the
  same Microsoft account, and only the Java name resolves.
- It's a **Bedrock** account (phone, console, Windows 10 edition). Those can't
  join a Java server at all without Geyser.
- A typo, or the player renamed recently.

Check a name before blaming the server — this returns the UUID if it's a real
Java account and 404 if it isn't:

```bash
curl -s https://api.mojang.com/users/profiles/minecraft/PlayerName
```

## Ops and gamerules

```bash
docker exec mc rcon-cli op PlayerName          # admin, persists in ops.json
docker exec mc rcon-cli deop PlayerName
```

Ops resolve names through the same Mojang lookup, so the notes above apply.
There's also an `OPS` environment variable, but the image skips it once
`data/ops.json` exists — so on a server that has already run, `rcon-cli op` is
the way.

Gamerules are stored in the world and survive restarts:

```bash
# how many players must sleep to skip the night, as a percentage.
# 0 = any single player; 100 = everyone (the default)
docker exec mc rcon-cli gamerule playersSleepingPercentage 0

# stop phantoms spawning when people go without sleep
docker exec mc rcon-cli gamerule doInsomnia false
```

## Backups

```bash
./scripts/backup.sh
```

Pauses saving while the tar runs, so no region file gets copied half-written,
and turns saving back on afterwards even if the tar fails. Archives land in
`backups/` on the VPS; the newest 7 are kept and older ones pruned. Tune with
`MC_BACKUP_KEEP` / `MC_BACKUP_DIR`.

Each archive is a full copy of `data/`, so keep an eye on disk: `du -sh backups/`.

Run it daily from cron:

```
0 4 * * * /path/to/mc-server/scripts/backup.sh >> /var/log/mc-backup.log 2>&1
```

### Copying backups to your machine

A backup that only exists on the VPS doesn't survive the VPS. `pull-backups.sh`
runs **locally** (the only script here that does) and rsyncs the archives down:

```bash
MC_SSH=you@vps.example.com ./scripts/pull-backups.sh
```

rsync only transfers archives you don't already have, and `--partial` resumes an
interrupted pull rather than restarting it — world tarballs get large. Override
`MC_REMOTE_DIR` if the repo isn't at `~/minecraft-server` on the server, and
`LOCAL_DIR` to put them somewhere other than `./backups`.

For a true offsite copy without a machine in the loop, uncomment the `aws s3 cp`
line in `backup.sh` instead.

## Uploading a world to the server

Replaces the server's world with another one — a singleplayer save, or a backup
you're rolling back to. Two modes, depending on where the world already is.

**World on your machine** — run this on your machine, it uploads over ssh:

```bash
MC_SSH=you@vps.example.com ./scripts/push-world.sh "/media/you/DRIVE/My World"
```

**World already on the VPS** — run it *there* with `--local`. No ssh, no
transfer, so there's no reason to re-upload gigabytes you've already sent:

```bash
./scripts/push-world.sh --local ~/uploads/MyWorld
```

Use `--local` for anything that arrived on the server some other way: an
earlier `scp`, a zip you unpacked there, a world pulled straight down on the
VPS. It refuses if the source is the live world folder or sits inside it.

Quote paths with spaces in either mode.

**26.1 unified the save format**, which makes this much simpler than the advice
you'll find in older guides. Singleplayer and Paper now use the same layout, so
a modern world uploads verbatim — no conversion, no separate `world_nether`:

| | pre-26.1 | 26.1+ |
|---|---|---|
| Overworld | `world/region/` | `dimensions/minecraft/overworld/` |
| Nether | `DIM-1/` (or server `world_nether/`) | `dimensions/minecraft/the_nether/` |
| End | `DIM1/` (or server `world_the_end/`) | `dimensions/minecraft/the_end/` |
| Player data | `playerdata/`, `stats/`, `advancements/` | `players/` |

The script detects which format it's looking at and prints the dimensions it
found with their sizes, so you can confirm the nether and end are actually
there before uploading. **Older guides tell you to split `DIM-1` into a
separate `world_nether/` folder — don't; that's pre-26.1 advice** and it will
produce a layout the current server doesn't expect.

A pre-26.1 world is migrated by the server on first load. That conversion is
one-way (see Updates), which the script warns about before it starts.

Preview without uploading:

```bash
./scripts/push-world.sh --dry-run "/media/you/DRIVE/My World"
```

The upload stops the server first (the JVM holds region files open and would
overwrite whatever you copy in), takes a backup of the world being replaced,
transfers, and starts it again. It asks you to type the world name first;
`--yes` skips that.

`--delete` is scoped to the world folder, never to `data/` — stale region files
from the old world can't linger, but `ops.json`, `whitelist-source.txt`, plugin
configs and logs are left alone. `session.lock` is excluded, since the server
writes its own and a stale one from an open client is the last thing you want
to copy up.

It compares by checksum rather than rsync's default size-and-timestamp check.
Two different worlds can hold a same-size file with a matching timestamp —
`level.dat` is a realistic candidate — and skipping it would leave a world
that's part old and part new. That silent half-swap is worth more I/O to
avoid on an operation you run this rarely.

## Security notes

- RCON is enabled but its port is **never published** — `backup.sh` reaches it
  through `docker exec`. An exposed RCON port with a weak password is a real RCE
  path; keep it off the host network.
- **UFW does not filter Docker-published ports.** Docker writes DNAT rules into
  iptables' `nat`/`PREROUTING`, which runs *before* the `filter`/`INPUT` chain
  where UFW rules live. So `25565` is reachable from the internet whether or not
  UFW allows it, and a `ufw deny 25565` would not close it. The `ufw allow` below
  is documentation, not enforcement. What actually keeps RCON safe is that
  `docker-compose.yml` never publishes 25575 — not the firewall. To genuinely
  restrict a container port, bind it (`127.0.0.1:PORT:PORT`) or use the
  `DOCKER-USER` chain.
- Container runs with `cap_drop: ALL`, `no-new-privileges`, and as `1000:1000`
  rather than root. Check with `docker exec mc id`.
- **Running as non-root is required here, not just preferred.** The image's
  entrypoint chowns `/data` and drops privileges only when it starts as uid 0
  — and with no capabilities it can do neither (`chown` needs `CAP_CHOWN`, the
  user switch needs `CAP_SETUID`). Started as root it dies with `failed
  switching to 'minecraft:minecraft'`, preceded by a long wall of `chown:
  Operation not permitted`. Starting as 1000 skips that branch entirely.
- The consequence: **`data/` on the host must be owned by uid 1000**, because
  nothing inside the container can fix it. `bootstrap.sh` sets that, and
  `push-world.sh` restores it after installing a world. `server.sh start`
  checks before starting and tells you the `chown` to run rather than letting
  the container fail. If you ever hit it by hand:

  ```bash
  chown -R 1000:1000 data/
  ```
- Own bridge network (`mc-net`) so it can't reach other containers on the host.
- `mem_limit` / `cpus` cap it so it can't starve co-located services.
- Minecraft servers have a real RCE history (Log4Shell was exploited via chat).
  Patch monthly — but deliberately, see Updates below.

## Updates

Both pins in `.env` are set and should stay set:

```bash
MC_IMAGE=itzg/minecraft-server:2026.8.1   # container tooling, tag YYYY.M.P
MC_VERSION=26.2                            # the game
```

They move independently, and only one of them is risky.

**Version numbering changed in 2026.** Mojang dropped the `1.x` scheme for
`year.drop[.hotfix]`, so the sequence runs `1.21.x` → `26.1` → `26.2`. A
"26.2" is *newer* than a "1.21.4", which sorts wrong in every tool that
assumes semver. Expect stale guides to still say `1.21`.

**Why `LATEST` is not an option here.** Loading a world on a newer game
version upgrades its chunk format in place, and that is not reversible.
There is no downgrade path — only restoring a backup. With `MC_VERSION=LATEST`
an unattended `docker compose pull` will happily walk your world across a
drop boundary while you're asleep.

Because both are pinned, `docker compose pull` is now a no-op — bumping the
value in `.env` is what triggers an upgrade.

### Image updates (low risk, do monthly)

Only the container tooling changes; the game and world are untouched. Check
[Docker Hub tags](https://hub.docker.com/r/itzg/minecraft-server/tags), bump
`MC_IMAGE`, then:

```bash
docker compose up -d
```

### Game updates (one-way, do deliberately)

```bash
./scripts/backup.sh                       # non-negotiable — this is the only rollback
```

1. Confirm Paper has builds for the target version at
   [papermc.io/downloads/paper](https://papermc.io/downloads/paper). Paper
   trails a fresh Mojang drop by days to weeks; pinning `MC_VERSION` to a
   version Paper hasn't shipped yet just fails to boot.
2. Check every plugin you run supports it. Drops break plugin APIs.
3. Bump `MC_VERSION` in `.env`, then `docker compose up -d`.
4. Watch it come up: `docker compose logs -f mc`, then `docker compose ps`
   should read "healthy".

To roll back, restore the backup tarball — changing `MC_VERSION` back on its
own will not work, because the world has already been converted.

## Performance

Already applied: Aikar's G1GC flags, and view/simulation distance at 8/8.

The two distances do different jobs — they were one setting before 1.18, and
most tuning advice online still conflates them:

- **View distance** is how far players *see*. Costs bandwidth and memory, not
  tick time. Raise or lower it freely; farms are unaffected.
- **Simulation distance** is how far the world *ticks*, and it's the real tick
  cost — ticking chunks scale as `(2n+1)²`, so 8 is ~3.5× the work of 4.

**Simulation distance 8 is a floor here, not a preference.** Mob spawning uses
a 128-block sphere around each player, which is exactly 8 chunks; below that
the spawn sphere is clipped and mob farms starve. Hoppers, redstone, crops and
minecarts also freeze once they're outside it. Going above 8 buys farms
nothing — the sphere doesn't grow — so 8 is both the floor and the ceiling
worth paying for.

Beyond that, **don't tune preemptively**. Run `/tps` in-game with real players
on; anything ≥ 19.5 means there's nothing to fix. If it does drop, add cores
before you touch game rules.

If you go looking in `data/config/paper-world-defaults.yml` (written after
first boot), note that the usual suggestions there are farm-hostile:

| Setting | Farm impact |
|---|---|
| `entity-activation-range` | **Breaks farms.** Mobs outside the range stop ticking, so they never move to the collection point. Leave at 32. |
| `despawn-ranges` | **Breaks farms.** Lowering the hard range (128) despawns mobs before they're processed. Leave alone. |
| `alt-item-despawn-rate` | **Breaks item farms** — fast-despawns cobblestone/netherrack before hoppers collect them. |
| `max-auto-save-chunks-per-tick` | Safe. Spreads the autosave spike over more ticks; no gameplay effect. |

Only the last one is worth touching on a farm server.

## Running it

```bash
./scripts/server.sh start     # up + prints the connect address
./scripts/server.sh status    # state, health, connect address
./scripts/server.sh address   # just the address, for pasting to players
./scripts/server.sh stop      # graceful — waits for the world to save
./scripts/server.sh logs      # follow; Ctrl-C detaches, server keeps running
```

`start`/`stop`/`logs` are thin wrappers over `docker compose` — use either. The
one that earns its keep is `address`, which reads the *actually published* port
out of Docker rather than assuming 25565, looks up the public IP, and prints
what players should type:

```
Port: 25565

  Players connect to:   203.0.113.42
  (no port needed — 25565 is Minecraft's default)

  On the same network:  192.168.0.73
```

The port is only shown in the address when it isn't 25565 — the client assumes
that one, so appending it is noise, and getting this backwards is a common
source of "it won't connect".

`stop` is worth preferring over `docker compose down`: it leans on
`stop_grace_period: 60s`, since Docker's 10s default can SIGKILL the JVM
mid-save and write torn chunks.

## Health

```bash
./scripts/server.sh status    # should read "healthy"
docker exec mc rcon-cli tps
```

The healthcheck matters: without it, `restart: unless-stopped` will happily keep
a hung JVM running because the container process is technically alive.
