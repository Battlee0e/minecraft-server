# mc-server

Dockerised Paper Minecraft server, configured for a small whitelisted group on a
shared VPS. Config is env-driven.

## Setup

```bash
git clone https://github.com/Battlee0e/minecraft-server.git minecraft-server 
cd minecraft-server 
./scripts/bootstrap.sh # creates .env + whitelist from the templates
$EDITOR data/whitelist-source.txt
docker compose up -d
docker compose logs -f mc
```

Firewall, once, as root:

```bash
ufw allow 25565/tcp
ufw status numbered           # confirm 25575 (RCON) is NOT listed
```

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | Service definition — reads everything from `.env` |
| `.env.example` | .env template |
| `.env` | Real config incl. RCON password — **gitignored** |
| `data/whitelist-source.txt` | Plain usernames, one per line — **gitignored** |
| `data/` | World saves, `ops.json`, logs, plugin configs — **gitignored** |
| `scripts/bootstrap.sh` | First-run setup |
| `scripts/backup.sh` | Snapshot `data/` with saving paused |

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

## Backups

```bash
./scripts/backup.sh
```

Pauses saving while the tar runs, so no region file gets copied half-written,
and turns saving back on afterwards even if the tar fails. Uncomment the
`aws s3 cp` line to upload to R2. Run it daily from cron:

```
0 4 * * * /path/to/mc-server/scripts/backup.sh >> /var/log/mc-backup.log 2>&1
```

## Security notes

- RCON is enabled but its port is **never published** — `backup.sh` reaches it
  through `docker exec`. An exposed RCON port with a weak password is a real RCE
  path; keep it off the host network.
- Container runs with `cap_drop: ALL` and `no-new-privileges`. Verify it isn't
  running as root after first boot: `docker exec mc id`.
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

## Health

```bash
docker compose ps             # should read "healthy"
docker exec mc rcon-cli tps
```

The healthcheck matters: without it, `restart: unless-stopped` will happily keep
a hung JVM running because the container process is technically alive.
