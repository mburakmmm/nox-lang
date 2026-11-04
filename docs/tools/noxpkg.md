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

## Signing in and publishing

Publishing needs an account. Run `noxc login` once: it shows a short code, opens `github.com/login/device` (or prints the address with `--no-browser`), and waits while you approve. `noxc` never talks to GitHub:
the registry relays the OAuth *device flow*, checks who you are (your public GitHub profile only, no scopes), and hands back its own API token. Your GitHub token is used once on the server and thrown away.
The registry token is saved in `~/.nox/credentials` (`$NOX_HOME/credentials`), readable only by you (mode `0600`); the server keeps only its SHA-256 digest and the token expires after a year.

| Command | |
|---|---|
| `noxc login [--no-browser]` | sign in with GitHub; saves the token |
| `noxc whoami` | which account the saved token belongs to (asks the server) |
| `noxc logout` | deletes the local token and revokes it on the server |

A package **name belongs to whoever submits it first**. Only that account can publish the name again (updates); anyone else gets a `403` that names the owner. A **new package name** or a **change of repository** waits for administrator approval. Publishing again to the same name and the same repository as the account that owns it
(a new version, description or tags) needs **no new approval**: the catalogue entry is updated at once and `noxc publish` says `published` instead of `submitted`. Submitting the same pending
package again does not add rows to the queue; it updates the one that is waiting. The
package page and the administration panel show who published each package (a warning appears when the repository owner differs from the publisher). Packages that were listed before accounts existed belong to the
registry administrator's GitHub account.

## Submitting a package

`noxc publish <repo> [--ref <ref>] [--description <text>] [--tags a,b,c]` (after `noxc login`) sends `POST /api/publish` with the token in an `Authorization: Bearer` header and this JSON:

| Field | Type | Required | |
|---|---|---|---|
| `name` | string | yes | the package name |
| `repo` | string | yes | repository path, e.g. `github.com/you/pkg` |
| `ref` | string | no | the tag or branch you are announcing |
| `description` | string | no | one line |
| `tags` | array of strings | no | search keywords |

Without a valid token the endpoint answers `401`. The reply is `{"ok": true, "status": "pending", "id": ...}` when the submission lands in the inbox (it becomes visible in `index.json` only after an administrator approves it in the web UI) and `"status": "published"` when an owner's update to an approved package went live directly. The endpoint is rate-limited and validates its input.

## Running a registry

The service is a small Nox program (`services/noxpkg/` in the repository): `main.nox` wires the routes, `handlers_public.nox` serves the index and accepts submissions, `handlers_admin.nox` is the moderation UI
(password login with Argon2id, session cookie and CSRF protection), `store.nox` persists the index and inbox as JSON files under `data/`.

| Route | Purpose |
|---|---|
| `GET /` | the public package list |
| `GET /index.json` | the machine-readable index |
| `POST /api/publish` | submit a package (Bearer token required) |
| `POST /api/auth/device/start`, `POST /api/auth/device/poll` | the GitHub device flow that `noxc login` drives |
| `GET /api/auth/whoami`, `POST /api/auth/logout` | token owner; revoke the token |
| `GET/POST /admin/login`, `GET /admin`, `POST /admin/approve/:id`, `POST /admin/reject/:id`, `POST /admin/index/remove`, `POST /admin/logout` | moderation |

Configuration comes from the environment:

| Variable | |
|---|---|
| `NOXPKG_ADMIN_PASSWORD_HASH` | an Argon2id hash of the administrator password — generate one with `noxc run services/noxpkg/scripts/gen_admin_hash.nox -- '<password>'` |
| `NOXPKG_SESSION_SECRET` | secret for the signed session cookies |
| `NOXPKG_GITHUB_CLIENT_ID` | client id of a GitHub OAuth App with *Device Flow* enabled (no client secret is needed). Without it, `noxc login` answers that GitHub login is not configured |
| `NOXPKG_ADMIN_GITHUB` | the administrator's GitHub login; when it signs in, packages that predate accounts are assigned to it |
| `NOXPKG_PORT` | listen port (default `8080`) |
| `NOXPKG_GITHUB_BASE`, `NOXPKG_GITHUB_API` | where GitHub is reached (for tests; defaults `https://github.com` and `https://api.github.com`) |

 A `docker-compose.yml` and a Cloudflare Tunnel sidecar are included; persistent data lives in the `data/` volume, which should be backed up regularly (the production deployment
snapshots it on a schedule and keeps off-site copies).

## Trust

Approval means "the metadata looks legitimate", not "the code is safe". See [Security](../reference/security.md).
