# Packages and dependencies

A Nox *package* is an ordinary project in a Git repository. A project lists the packages it needs in `nox.json`; `noxc` fetches them, pins exact commits in `nox.lock`, and compiles them into your
program together with your own code.

## `nox.json`

```json
{
  "name": "myapp",
  "version": "0.1.0",
  "entry": "main.nox",
  "bin": { "name": "myapp", "path": "main.nox" },
  "requires": [
    { "alias": "nyx", "repo": "github.com/mburakmmm/nyx", "ref": "v0.21.0" },
    { "alias": "local", "repo": "/abs/path/to/pkg", "ref": "main", "require_signed_commit": false }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | the project's name |
| `version` | the project's version (informational) |
| `entry` | the entry file (default `main.nox`) |
| `bin` | optional `{name, path}`: makes the package installable as a global command ([below](#global-installs)) |
| `requires[]` | the dependencies |

Each dependency has:

| Field | Meaning |
|---|---|
| `alias` | the name you import it by (`import nyx.app` loads module `app` of the package). Aliases must be unique, and `nox` is reserved for the standard library |
| `repo` | where to get it: `github.com/owner/repo`, another Git host path, or an absolute local directory (for development) |
| `ref` | the branch, tag or commit to follow |
| `require_signed_commit` | optional; when `true` the resolved commit must carry a valid signature (`git verify-commit`) or the fetch fails |

## `nox.lock`

`nox.lock` records, for every dependency, the exact commit its `ref` resolved to:

```json
{
  "packages": [
    { "alias": "nyx", "repo": "github.com/mburakmmm/nyx", "ref": "v0.21.0", "resolved": "1e7388a908aa2ca0fcfc2810f78ad88fbff82d77" }
  ]
}
```

`build`, `run` and `test` always use the locked commit, never re-resolving a branch silently — builds are reproducible. **Commit `nox.lock`** to version control.

## Commands

```sh
noxc init myapp            # scaffold nox.json + main.nox
noxc search http           # query the central index
noxc add nyx               # look "nyx" up in the index and add it (ref defaults to `master`; pass --ref to pin a tag)
noxc add nyx github.com/mburakmmm/nyx --ref v0.21.0
noxc fetch                 # download dependencies, write nox.lock
noxc update                # move every dependency to the latest commit of its ref
noxc delete nyx            # remove it from nox.json and nox.lock
noxc cache prune --dry-run # show stale cached checkouts that would be deleted
```

Downloaded checkouts live in `$NOX_HOME/pkg/mod/<repo>/<commit>/` (default `~/.nox`); the cache is content-addressed by commit, so several projects share one copy. `cache prune` deletes
checkouts no lock file refers to (install, refresh and upgrade also prune automatically).

## Using a dependency

```nox-fragment
import nyx.app                       # module "app" of the package aliased "nyx"
from nyx.config import Config
```

All modules of all packages compile together into one program. Packages may depend on packages; the whole graph is resolved and locked.

## Global installs

A package that declares a `bin` entry can be installed as a command:

```sh
noxc install nyx           # build and install into ~/.nox/bin
noxc list                  # list installed commands
noxc uninstall nyx         # remove the command
```

Add `~/.nox/bin` to your `PATH`. `install` accepts a package name from the index or a repository.

## Publishing a package

1. Put your project in a public Git repository with a `nox.json` and a tag for each release.
2. Submit its metadata to the central index:

   ```sh
   noxc publish github.com/you/yourpkg --ref v1.0.0 --description "What it does" --tags web,http
   ```

3. A registry administrator reviews and approves the submission; once approved, `noxc search` and `noxc add` find it.

`publish` sends **metadata only** (name, repository, ref, description, tags); no code is uploaded — consumers fetch from your repository. See [noxpkg](noxpkg.md) for the service.

## Security

A package can contain `extern def` declarations (native code) and build steps run on your machine, so **adding a dependency means trusting it** — and everything it depends on. The lock file protects against a
moved tag; `require_signed_commit` adds signature verification; neither audits behaviour. There is no sandbox. Read the code of what you depend on and see [Security](../reference/security.md).
