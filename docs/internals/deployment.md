# Deploying noxlang.com and the registry

This page documents how the project's own web presence is run: the **noxlang.com** site and the **noxpkg** package registry. Both are Nox programs, they run as containers on one machine, and one Cloudflare Tunnel exposes them. Nothing here
is needed to *use* Nox; it is for maintainers.

## Topology

| Hostname | Service | What it is |
|---|---|---|
| `noxlang.com` | `noxlang-site` | A [Nyx](https://github.com/mburakmmm/nyx) application (`services/noxlang-site/`) that serves the generated site |
| `www.noxlang.com` | `noxlang-site` | Redirects (301) to `noxlang.com` |
| `noxpkg.noxlang.com` | `noxpkg` | The package index and admin panel (`services/noxpkg/`) |
| `noxpkg.2mtechnology.org` | `noxpkg` | The registry's **previous** name, kept so older `noxc` releases keep working |

The stack is described by one Compose file, `deploy/web/docker-compose.yml`, with four services: `noxlang-site`, `noxpkg`, `noxpkg-backup` and `cloudflared`. Containers publish only to `127.0.0.1`; the tunnel is the only way in, and
the host has no open ports 80 or 443.

## How the site is built

The documentation is plain Markdown in `docs/`, ordered by `docs/_toc.yml`. `scripts/build_site.py` turns it into a static tree:

```sh
python3 scripts/build_site.py            # writes services/noxlang-site/public/
python3 scripts/build_site.py --verify   # also compiles and runs the landing-page examples with noxc
python3 scripts/check_docs.py            # checks every link, page, and ```nox block in docs/
```

The builder highlights code with a Nox lexer, rewrites links between pages, writes a client-side search index, and emits `manifest.tsv`, the list of files the server will serve. The Nyx app reads that manifest at start-up and keeps every
file in memory (about 7 MB), so a request is a dictionary lookup. Nyx supplies the configuration, router, security headers, content-security policy, request ids, rate limiting and `/healthz`.

Two properties of Nox's module-level state shape the app. Each scheduler worker has its own copy of module variables, so the content is loaded by *initialiser expressions* (not by assignments in the entry file), and the Nyx application is
opened lazily, once per worker, on the first request ([Concurrency](../language/concurrency.md#the-scheduler)).

## Configuration

Copy `deploy/web/.env.example` to `deploy/web/.env` and fill it in. Docker Compose treats `$` in values as a variable reference, so every `$` in the Argon2 hash must be written `$$`.

| Variable | Meaning |
|---|---|
| `NYX_SECRET_KEY` | secret for the site's Nyx app, at least 32 characters |
| `NOXPKG_ADMIN_PASSWORD_HASH` | Argon2id hash of the registry admin password (`noxc run services/noxpkg/scripts/gen_admin_hash.nox -- '<password>'`) |
| `NOXPKG_SESSION_SECRET` | secret for the registry's session cookie |
| `NOXPKG_DATA_DIR` | directory with the registry's JSON files (default `services/noxpkg/data`) |
| `BACKUP_DIR` | where local snapshots are kept (default `services/noxpkg/backups`) |
| `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | optional off-site backup to an S3-compatible bucket such as Cloudflare R2 |

## DNS and the tunnel

`deploy/web/cloudflared.yml` routes the four hostnames above through the existing tunnel. In the Cloudflare dashboard, create these proxied (orange-cloud) `CNAME` records pointing at `<tunnel-id>.cfargotunnel.com`:

```text
noxlang.com   CNAME  <tunnel-id>.cfargotunnel.com    (apex; Cloudflare flattens it)
www           CNAME  <tunnel-id>.cfargotunnel.com
noxpkg        CNAME  <tunnel-id>.cfargotunnel.com
```

## Deploying

From the repository root on the host:

```sh
docker compose -f deploy/web/docker-compose.yml --env-file deploy/web/.env up -d --build
docker compose -f deploy/web/docker-compose.yml ps
```

The first build compiles Zig, QBE and `noxc` inside the image and takes several minutes; later builds reuse the cache. Check `https://noxlang.com/healthz` and `https://noxpkg.noxlang.com/index.json` afterwards. To roll back, check out the previous
commit and run the same command again.

## Backups

The registry's state is a few small JSON files (`index.json`, `inbox.json`, `ratelimit.txt`). The server writes each one atomically (a temporary file, then a rename), so a file read at any moment is complete. There is no database to
snapshot.

`scripts/backup_noxpkg.sh` runs in the `noxpkg-backup` container:

1. **Every hour** it validates the JSON and writes `noxpkg-<UTC timestamp>.tar.gz` with a `.sha256` next to it. Corrupt data is refused rather than backed up over a good snapshot.
2. **Rotation** keeps the newest 48 snapshots, the newest one per day for 30 days, and the newest one per week for 12 weeks (`KEEP_HOURLY`, `KEEP_DAILY`, `KEEP_WEEKLY`).
3. **Off-site (optional):** when the four `RESTIC_*`/`AWS_*` variables are set, each run also pushes the data to a [restic](https://restic.net) repository. restic encrypts and de-duplicates it, so the bucket holds only ciphertext.

Restoring never overwrites: the target directory must be empty or absent, and the archive's checksum is verified first.

```sh
# list what exists
ls services/noxpkg/backups

# restore the newest snapshot into a fresh directory, then inspect it
sh scripts/backup_noxpkg.sh restore latest /tmp/noxpkg-restored

# prove the newest snapshot can be restored (the container's health check also watches freshness)
docker compose -f deploy/web/docker-compose.yml exec noxpkg-backup /usr/local/bin/backup_noxpkg.sh verify
```

To recover production, stop `noxpkg`, restore into an empty directory, replace the data directory with it, and start `noxpkg` again. For an off-site restore, use `restic restore latest --target <dir>` with the same environment variables.

`scripts/test_backup.sh` tests the script (snapshot, rejection of corrupt data, rotation, restore, checksum failure) and runs on both busybox and GNU/BSD shells.

## Security notes

- The site container runs as an unprivileged user with a read-only root file system; it needs no writable storage.
- The content-security policy allows only same-origin resources; the site loads no third-party scripts, fonts or analytics.
- The registry approves *metadata*, not code. See [Security model](../reference/security.md).
