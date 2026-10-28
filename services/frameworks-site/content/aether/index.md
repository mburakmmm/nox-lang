# Overview

Aether is the HTTP API framework for [Nox](https://noxlang.com). The shape is Nest-inspired: modules, a pipeline of guards, pipes and interceptors, typed DTO validation, OpenAPI, WebSocket gateways and a SQLite job queue. The dependency injection that Nox can actually express is a closure, not a subclass of an imported base.

**Version @@VERSION@@.** License MIT. Requires Nox 2.0.7 or newer. The package name is `aether`.

Aether does not depend on [Nyx](https://nyx.noxlang.com). Use Aether for JSON APIs. Use Nyx for a monolith of HTML pages, sessions and server-rendered views.

## Design

- **Modules.** `class UsersModule` with `configure(self, m: ModuleBuilder)` owns a group of routes.
- **Closures.** `m.provide("Name")` is a name registry. The instance lives in a field of the module and is captured when you register the handler.
- **One pipeline.** Guard, then pipe, then interceptor, then the handler, then the interceptor’s after step, then an exception filter.
- **Boot-time work.** Routes are bound and the OpenAPI document is built once. A request does not rebuild them.

## Package

| Concern | Modules |
|---|---|
| Boot and dispatch | `aether.application`, `aether.server`, `aether.lifecycle` |
| Modules and routes | `aether.module`, `aether.container` |
| Request | `aether.context`, `aether.response`, `aether.body` |
| Pipeline | `aether.guard`, `aether.pipe`, `aether.interceptor`, `aether.pipeline` |
| Contracts | `aether.dto`, `aether.openapi`, `aether.swagger` |
| Auth helpers | `aether.jwt` |
| Edge | `aether.cors`, `aether.rate_limit`, `aether.metrics`, `aether.logx` |
| Realtime and jobs | `aether.gateway`, `aether.queue` |
| Tests and CLI | `aether.testing`, `cli.nox` |

Flat modules, imported as `import aether.application`. Shared route and hook state lives in `RouteTable` and `HookState`. Assigning a list does not share the storage across holders in Nox, so those tables are the objects you mutate.

## A request, end to end

1. The bare `handle` reads `method`, `target`, `body`, `headers` and `peer_addr`, then calls `dispatch_from_parts`. Do not pass the `HttpRequest` object through; the server reuses it.
2. The path is normalized. Body limit, CORS preflight and 405 are decided here.
3. Global guards, then route guards.
4. Pipes and DTO validation.
5. Interceptors. A before-step may return a response and skip the handler.
6. The handler.
7. Interceptor after-steps, then exception filters.
8. Metrics and the request log.

`HttpError` becomes a JSON body. An unexpected failure becomes the fallback JSON error. In development that JSON includes `Exception.line`. Production stays generic.
