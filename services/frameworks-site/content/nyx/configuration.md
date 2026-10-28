# Configuration

Every switch is an environment variable read by `nyx.config.load()`. There is no second config file format.

| Variable | Meaning |
|---|---|
| `NYX_ENV` | `development`, `test`, or `production` |
| `NYX_SECRET_KEY` | required in production, at least 32 characters |
| `NYX_PORT` | listen port |
| `NYX_DB_PATH` | SQLite file for the app ORM |
| `DATABASE_URL` | `sqlite:///...`, or `postgres://` / `mysql://` for those drivers |
| `NYX_AUTO_MIGRATE` | `1` or `0`. Production default is `0`. Prefer `nyx db migrate` |
| `NYX_WORKERS` | `1` uses `serve`. Greater than 1 uses `serve_multicore` |
| `NYX_SESSION` | `0` skips session middleware. CSRF forces the session back on |
| `NYX_CSRF` | CSRF middleware |
| `NYX_CSRF_API_EXEMPT` | opts `/api/` out of CSRF |
| `NYX_CSP` | Content-Security-Policy value |
| `NYX_SECURITY_HEADERS` | `0` skips the security after-middleware |
| `NYX_LOCALE` | default locale for `nyx.i18n` |
| `NYX_RATE_LIMIT_STORE` | `memory` or `db`. Auto-`db` when workers are greater than 1 and this is unset |
| `NYX_TRUST_X_FORWARDED_FOR` | `1` trusts the edge’s forwarded client |
| `NYX_TRUSTED_PROXIES` | IP allowlist. Forwarded headers count only when the peer is on the list |
| `NYX_TLS_CERT`, `NYX_TLS_KEY` | PEM paths. Nyx then uses `serve_tls` or `serve_multicore_tls` |
| `NYX_REQUEST_ID` | `0` skips the uuid and `X-Request-Id` |
| `NYX_REQUEST_HEADERS` | `0` takes the header-skip path (`handle_bare`) |
| `NYX_IPV6`, `NYX_IPV6_ONLY` | IPv6 listen. See [Boot and dispatch](/docs/application/) |
| `NYX_MAIL_SMTP_PORT` | default `465`, immediate TLS |
| `NYX_MAIL_SMTP_STARTTLS` | `1` opens plain TCP then STARTTLS, typical of port 587 |

## Secrets

`NYX_SECRET_KEY` signs the session and CSRF tokens. Generate it outside the repo and inject it in the process environment. Do not commit it. The noxlang.com stack reads the same variable for its own Nyx process; a framework app in production should have its own value.

## Databases

A `sqlite:///` URL and `NYX_DB_PATH` both select the default model. `postgres://` and `mysql://` boot through `nyx.pg_model` / `nyx.mysql_model` and the matching session and auth engines. SQL dialects stay split: `?` versus `$n`, `RETURNING`, and identifier quotes. `last_insert_rowid` is not part of the shared protocol.

## Behind the tunnel

noxlang.com’s own container sets `NYX_TRUST_X_FORWARDED_FOR` because Cloudflare is the only client that can reach it. Copy that only when you know the peer is the proxy. An empty `NYX_TRUSTED_PROXIES` plus the trust flag is the older “the operator asserts the edge” behaviour. A non-empty allowlist uses `X-Forwarded-For` only when the connecting IP is on the list.

`HttpRequest.peer_addr` (`"ip:port"`) is the rate-limit key when trust is off. An empty peer, which tests and `dispatch_from_parts` can produce, shares the `"direct"` bucket. Rate-limit keys parse `[addr]:port` as the address inside the brackets.
