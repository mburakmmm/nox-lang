# Environment variables

## Compiler and tools

| Variable | Used by | Meaning |
|---|---|---|
| `NOX_HOME` | `noxc` | data directory for the package cache, global installs and `installed.json` (default `~/.nox`) |
| `NOX_RESOURCE_DIR` | `noxc` | use this directory instead of the one next to the executable to find the runtime object and standard library |
| `NOX_INDEX_URL` | `search`, `add` | the package index to query: an `https://…/index.json` URL or a local file (default `https://noxpkg.noxlang.com/index.json`) |
| `NOX_PUBLISH_API_BASE` | `publish` | base URL of the registry's publish API (default `https://noxpkg.noxlang.com`) |
| `NOX_UPGRADE_API_BASE`, `NOX_UPGRADE_DOWNLOAD_BASE` | `upgrade` | override where releases are looked up and downloaded (for mirrors and tests) |
| `NOX_ALLOW_INSECURE_TRANSPORT` | package/upgrade fetches | permit non-TLS transports (testing only; never in production) |
| `LC_ALL`, `LC_MESSAGES`, `LANG` | `noxc` | a value starting with `tr` selects Turkish for `noxc --help`; anything else English |

## Installer

| Variable | Meaning |
|---|---|
| `NOX_INSTALL_DIR` | where `install.sh` / `install.ps1` unpack Nox (default `~/.nox-lang`) |
| `NOX_VERSION` | install a specific release tag instead of the latest |

## Programs you compile

| Variable | Meaning |
|---|---|
| `NOX_POOL_WORKERS` | number of scheduler worker threads under the LLVM back end (overrides the compile-time default) |
| `NOX_STACK_PAINT` | when set, measures fiber stack use and prints `NOX_STACK_HWM_BYTES=<n>` at exit |
| `NOX_OPENSSL_LIB` | full path of the OpenSSL library to load for `serve_tls` |
| `NOX_STRESS_ROUNDS` | number of rounds for the opt-in stress test |

Programs read their own environment with [`nox.os.getenv`](../stdlib/os.md); nothing else in the standard library depends on environment variables.

## Services (noxpkg)

`NOXPKG_ADMIN_PASSWORD_HASH` (an Argon2id hash for the admin login) and `NOXPKG_SESSION_SECRET` (the session-cookie secret) configure the registry ([noxpkg](../tools/noxpkg.md)).
