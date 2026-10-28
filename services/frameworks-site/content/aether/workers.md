# Workers and shutdown

`AETHER_WORKERS` defaults to 1. That one worker is `nox.http.serve`. A value greater than 1 is `serve_multicore`.

## What is shared

The listening socket is shared. The database file is shared. Everything you closed over in `build` — rate-limit counters, metrics, websocket hubs, service objects — is **worker-local**. `build` runs once per worker. It must be idempotent.

On LLVM (`noxc build --release`) the heap is a shared M:N pool and connection fibers can be stolen, but the `Application` for a slot is still that slot’s. Export `NOX_POOL_WORKERS` equal to `AETHER_WORKERS` before the process starts. `run.sh` from `aether new` does this.

QBE (`noxc run`) stays shared-nothing. `serve_multicore` there is `SO_REUSEPORT`, not a shared heap.

In-memory rate limiting is not a process-wide limit under more than one worker. If the limit must hold for the whole machine, put it in the database or run one worker.

## IPv6

`AETHER_IPV6=1` listens with `listen_v6` and `serve_fd`. That mode is single-worker. `serve_multicore` stays IPv4, and asking for both is an error. `AETHER_IPV6_ONLY=1` disables dual-stack. `client_ip()` strips the port from `peer_addr`, including `[ipv6]:port`.

## Drain

`aether.lifecycle` coordinates shutdown:

- A process-wide stopping flag.
- A per-worker registry.
- In-flight requests finish; new ones get 503.
- `on_shutdown` runs per slot.

`POST /__aether/shutdown` exists only when `AETHER_SHUTDOWN_ROUTE=1`. Leave it off on a public listener. `begin_shutdown` and `clear_shutdown` publish on the calling worker immediately. Other workers notice via the stopping file, polled every `AETHER_STOP_POLL_MS` (default 200). The check caches that file between polls.

`boot_for_serve` / `finalize_serve` are the entry and exit. `finalize_serve` belongs in `finally`, as the quick start shows, so a failed bind still releases what boot acquired.

## Client address

`client_ip()` uses `peer_addr` unless you set `AETHER_TRUST_X_FORWARDED_FOR`. Turn that on only when the peer is your proxy. The noxlang.com tunnel is that situation for the sites themselves; an API you expose on the same tunnel should make the same explicit choice, not inherit it by default.
