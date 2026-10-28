# Overview

Nyx is the full-stack web framework for [Nox](https://noxlang.com). Its scope matches the problem domains of Rails: application lifecycle, HTTP, models, security, mail and background jobs. The ergonomics are the typed Nox APIs below, not a line-by-line Rails port.

**Version @@VERSION@@.** License MIT. Requires Nox 2.0.7 or newer. The package name is `nyx`.

Nyx is a library you import. It is not a second compiler and not a separate runtime. `noxc` still builds the program. Nyx boots an `Application`, dispatches each request through a router, and gives you sessions, CSRF, models and jobs on top of the Nox standard library.

Use Nyx when the product is a site of HTML pages plus a database. Use [Aether](https://aether.noxlang.com) when the product is a JSON API. The two packages do not depend on each other.

## What a Nyx app is

A Nyx app is an ordinary Nox program:

1. `nyx.config.load()` reads `NYX_*` from the environment.
2. `nyx.app.boot(cfg, setup)` builds the router, middleware and database handle once.
3. Handlers are defined **inside** `setup` so they close over that `Application`.
4. `nyx.app.dispatch` turns one `HttpRequest` into one `HttpResponse`.
5. `nox.http.serve` (or `serve_multicore` when `NYX_WORKERS` is greater than 1) accepts connections.

Module-level `boot` is the supported shape since Nox 2.0.0-rc.4. Defining the handler at the top level and reaching for a global `application` from another function is the pattern that used to crash; keep the closure.

## Areas

| Area | Modules |
|---|---|
| Lifecycle | `nyx.app`, `nyx.config`, `nyx.runtime`, `nyx.ctx` |
| HTTP | `nyx.ctrl`, `nyx.view`, `nyx.params`, `nyx.routes`, `nyx.form` |
| Data | `nyx.db`, `nyx.model`, `nyx.assoc` |
| Security | `nyx.session`, `nyx.csrf`, `nyx.auth`, `nyx.jwt`, `nyx.password`, `nyx.security`, `nyx.cors` |
| Extras | `nyx.mailer`, `nyx.job`, `nyx.storage`, `nyx.cache`, `nyx.i18n`, `nyx.cable`, `nyx.flash`, `nyx.testing` |

Postgres and MySQL have their own model and session engines (`nyx.pg_model`, `nyx.mysql_model`, and the matching session and auth engines). The default ORM path is SQLite.

## What Nyx does not pretend to be

- It does not sandbox `extern` code. A Nyx app has the same trust boundary as any other Nox program.
- Templates have no `{% for %}`. Lists are rendered with `render_records` or `render_each`.
- `nox.jwt` is HS256 only and does not check `exp`, `nbf` or `iat`. `nyx.jwt` does.
- Production should migrate with the CLI. `NYX_AUTO_MIGRATE` defaults off in production.
