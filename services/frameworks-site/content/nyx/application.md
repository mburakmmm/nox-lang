# Boot and dispatch

`nyx.app` is the lifecycle. `nyx.config` is the environment. `nyx.ctx` is the per-request handle. `nyx.runtime` keeps request state in a place that works both on the root task and on connection fibers.

## Boot

```nox
cfg: Config = nyx.config.load()
application: Application = nyx.app.boot(cfg, setup)
```

`boot` calls your `setup` exactly once for that worker and returns the `Application`. Register routes inside `setup`. Opening the database, loading translations and installing middleware happen here, before the first request is served.

Call `boot` at module scope in the entry file. Nox 2.0.0-rc.4 fixed the stale-local crash that older compilers hit on `application = nyx.app.boot(...)`. Nyx @@VERSION@@ requires a compiler that includes that fix (Nox 2.0.7 or newer).

## Dispatch

```nox
def handle(req: HttpRequest) -> HttpResponse:
    return nyx.app.dispatch(application, req)

nox.http.serve(cfg.port, handle)
```

`dispatch` is the whole middleware chain: request id, security headers, session, CSRF, the router, then the handler. Your function returns an `HttpResponse`. Nyx does not throw across the HTTP server to report a missing route; a miss becomes a response.

The router stores the path with the query stripped. `Context.query` holds the query string. Nyx still cuts the path before dispatch so logs stay path-only, and `nyx.params` keeps the form rule that `+` means a space. `nox.url.query_decode` leaves `+` as a literal plus, so form bodies should go through Nyx, not the raw URL helper.

## One worker or many

| `NYX_WORKERS` | Server |
|---|---|
| `1` (default) | `nox.http.serve` |
| greater than 1 | `serve_multicore` |

Under `--release`, set `NOX_POOL_WORKERS` to the same number before the process starts. The LLVM pool size is fixed at startup. A mismatch is an error, not a silent clamp.

Each worker has its own copy of module globals. An in-memory cache built as a module `dict` is therefore per worker, not process-wide. Use `NYX_RATE_LIMIT_STORE=db` (the automatic choice when workers are greater than 1 and the variable is unset) when a limit must be shared.

## IPv6

`NYX_IPV6=1` binds with `listen_v6` and serves that file descriptor. `NYX_IPV6_ONLY=1` turns dual-stack off. `NYX_WORKERS` greater than 1 together with IPv6 raises `ServerError`, because `serve_multicore` listens on IPv4.

## Request context

```nox
ac: AppContext = nyx.ctx.wrap(application, ctx)
title: str = ac.param("title", "")
env: str = ac.config().env
```

`wrap` is the supported way to see the application from a handler. `param` reads the form or query field and returns the default when it is absent. Database access is `ac.db()`.

## Errors

Nyx `*Error` types do not override `__init__`, so a caught exception still carries `Exception.line`. A development 500 page includes that line. Production responses stay generic.
