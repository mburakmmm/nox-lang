# noxpkg — the central package index

**noxpkg** is the registry service behind `noxc search`, `noxc add` and `noxc publish`. It is deliberately simple: a JSON *index* of package metadata (name, repository, description, tags) and a
moderated *submission* queue. It does **not** host code — packages live in their own Git repositories.

The public instance is at **<https://noxpkg.noxlang.com>**.

## The index

`GET /index.json` returns the approved packages:

```json
{
  "packages": [
    {
      "name": "nyx",
      "repo": "github.com/mburakmmm/nyx",
      "description": "Rails-scoped web framework for Nox",
      "tags": ["web", "framework"]
    }
  ]
}
```

The index deliberately carries no `ref`: it is a *discovery* catalogue. Version pinning is the job of your `nox.json` and `nox.lock` ([Packages](packages.md)).

`noxc search` and `noxc add` read the index from `NOX_INDEX_URL` (default `https://noxpkg.noxlang.com/index.json`); you can search any other index with `noxc search <file|url> <query>`, and run your own
registry by serving a file of the same shape.

## Submitting a package

`noxc publish <repo> [--ref <ref>] [--description <text>] [--tags a,b,c]` sends `POST /api/publish` with JSON:

| Field | Type | Required | |
|---|---|---|---|
| `name` | string | yes | the package name |
| `repo` | string | yes | repository path, e.g. `github.com/you/pkg` |
| `ref` | string | no | the tag or branch you are announcing |
| `description` | string | no | one line |
| `tags` | array of strings | no | search keywords |

The submission lands in an inbox; it becomes visible in `index.json` only after an administrator approves it in the web UI. The endpoint is rate-limited and validates its input.

## Running a registry

The service is a small Nox program (`services/noxpkg/` in the repository): `main.nox` wires the routes, `handlers_public.nox` serves the index and accepts submissions, `handlers_admin.nox` is the moderation UI
(password login with Argon2id, session cookie and CSRF protection), `store.nox` persists the index and inbox as JSON files under `data/`.

| Route | Purpose |
|---|---|
| `GET /` | the public package list |
| `GET /index.json` | the machine-readable index |
| `POST /api/publish` | submit a package |
| `GET/POST /admin/login`, `GET /admin`, `POST /admin/approve/:id`, `POST /admin/reject/:id`, `POST /admin/index/remove`, `POST /admin/logout` | moderation |

Configuration comes from the environment: `NOXPKG_ADMIN_PASSWORD_HASH` (an Argon2id hash — generate one with `noxc run services/noxpkg/scripts/gen_admin_hash.nox -- '<password>'`) and
`NOXPKG_SESSION_SECRET`. A `docker-compose.yml` and a Cloudflare Tunnel sidecar are included; persistent data lives in the `data/` volume, which should be backed up regularly (the production deployment
snapshots it on a schedule and keeps off-site copies).

## Trust

Approval means "the metadata looks legitimate", not "the code is safe". See [Security](../reference/security.md).
