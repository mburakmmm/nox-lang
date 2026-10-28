# Quick start

A module registers routes by returning closures. `boot_for_serve` validates the config once. When `AETHER_WORKERS` is greater than 1 it does not leave an idle parent `Application` around; each worker boots on its first request.

```nox
import nox.http
from nox.http import HttpRequest, HttpResponse
import aether.application
import aether.server
import aether.config
from aether.application import Application
from aether.config import Config
from aether.module import ModuleBuilder
from aether.context import HttpContext
from aether.response import json_ok

class HealthModule:
    def configure(self: HealthModule, m: ModuleBuilder) -> None:
        m.get("/healthz", self._health())

    def _health(self: HealthModule) -> (HttpContext) -> HttpResponse:
        def health(ctx: HttpContext) -> HttpResponse:
            return json_ok("{\"status\":\"ok\"}")
        return health

def build(app: Application) -> None:
    HealthModule().configure(app.module())

cfg: Config = aether.config.load()
aether.application.boot_for_serve(cfg, build)

def handle(req: HttpRequest) -> HttpResponse:
    return aether.application.dispatch_from_parts(
        req.method, req.target, req.body, req.headers, req.peer_addr, cfg, build
    )

aether.server.print_listen(cfg, aether.server.serve_mode(cfg, False))
try:
    workers: int = aether.server.effective_workers(cfg)
    if aether.server.use_os_workers(cfg):
        nox.http.serve_multicore(cfg.port, handle, workers)
    else:
        nox.http.serve(cfg.port, handle)
finally:
    aether.application.finalize_serve(cfg)
```

Pass `""` as `peer_addr` only when the handler must not retain the peer string. Otherwise pass `req.peer_addr` so `client_ip()` and the rate limiter can see it.

`build` must be safe to call again. Multicore boots it on every worker. Registering a route twice, or allocating a process-wide resource as a side effect, will not do what a single call suggested.

Bound methods work as handlers: `m.get("/ping", ctl.show)`.

Decorator routes (`@get`, `@post`, then `mount_decorators`) are optional. They still go through the same `dispatch` pipeline.
