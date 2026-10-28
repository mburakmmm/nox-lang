# Configuration

`aether.config.load()` reads the environment once per worker. Invalid `AETHER_ENV` (anything other than `development`, `test` or `production`) raises `ConfigError` at boot.

| Variable | Meaning |
|---|---|
| `AETHER_ENV` | `development`, `test`, or `production` |
| `AETHER_HOST` | bind address |
| `AETHER_PORT` | bind port |
| `AETHER_WORKERS` | `1` or the `serve_multicore` count. Default 1 |
| `AETHER_LOG_REQUESTS` | request log |
| `AETHER_OPENAPI` | build and serve the OpenAPI document |
| `AETHER_OPENAPI_TITLE`, `AETHER_OPENAPI_VERSION` | info block |
| `AETHER_JOBS_DB` | SQLite file for the queue |
| `AETHER_TLS_CERT`, `AETHER_TLS_KEY` | PEM paths for TLS |
| `AETHER_TRUST_X_FORWARDED_FOR` | use the forwarded client only behind a proxy you control |
| `AETHER_WS` | WebSocket gateways |
| `AETHER_MAX_BODY_BYTES` | request body limit |
| `AETHER_RATE_LIMIT` | enable the limiter |
| `AETHER_RATE_LIMIT_MAX`, `AETHER_RATE_LIMIT_WINDOW_MS` | budget and window |
| `AETHER_CORS_ORIGINS` | allowed browser origins. Empty means no reflection |
| `AETHER_JOB_STALE_MS` | when a leased job may be reclaimed |
| `AETHER_METRICS`, `AETHER_METRICS_ROUTES` | `/metrics` and per-route counters |
| `AETHER_REQUEST_ID` | `0` skips request ids. Used by ping benchmarks |
| `AETHER_REQUEST_HEADERS` | `0` takes the header-skip path |
| `AETHER_IPV6`, `AETHER_IPV6_ONLY` | IPv6 listen. Single worker |
| `AETHER_SHUTDOWN_ROUTE` | `1` mounts `POST /__aether/shutdown` |
| `AETHER_STOP_POLL_MS` | how often other workers re-read the stopping file. Default 200 |

`NOX_POOL_WORKERS` is a Nox variable, not an Aether one, and it must be set in the environment before the binary starts whenever `AETHER_WORKERS` is greater than 1 on the LLVM backend.

Header-skip (`AETHER_REQUEST_HEADERS=0`) and `AETHER_REQUEST_ID=0` exist so a microbenchmark is not measuring UUID allocation. Leave them on for a real service.
