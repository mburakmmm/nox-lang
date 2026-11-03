# nox.web

Production building blocks for a [`nox.http`](http.md) backend, written in Nox: cookies, CORS, a rate limiter, request ids, an access log, security headers and response helpers. They are plain
functions and small classes you call from your `serve` handler (or from [`nox.router`](router.md) middleware) — there is no framework to buy into.

```text
import nox.web
from nox.web import Cors, RateLimiter
```

**Capability:** none for the module itself; `RateLimiter` and `access_log` read the clock (`nox.time`), `request_id` needs entropy (`nox.uuid`).

## Reference

| Name | Description |
|---|---|
| `header(req, name)` | request header looked up **case-insensitively**; `""` when absent |
| `bearer_token(req)` | the token of `Authorization: Bearer <token>`, or `""` |
| `parse_cookies(header_value)` | `Cookie` header → `dict[str, str]` (the first of a repeated name wins) |
| `cookie(name, value, path="/", max_age=-1, http_only=True, secure=False, same_site="Lax")` | a `Set-Cookie` value. `ValueError` if the name, value or path contains `;`, `,`, a space, CR, LF or NUL, or for `SameSite=None` without `secure` |
| `expire_cookie(name, path="/")` | a `Set-Cookie` value that deletes the cookie |
| `Cors(allow_origins, allow_methods, allow_headers, max_age, allow_credentials)` | a cross-origin policy; `preflight(req)` answers an `OPTIONS` preflight (`204`, or `403` for a foreign origin) or returns `None`; `apply(req, resp)` adds the CORS headers to a real response |
| `client_ip(req)` | the client's IP without the port (`203.0.113.7:51234` → `203.0.113.7`, `[::1]:80` → `::1`). **Use this, not `req.peer_addr`, as the rate-limit key** — the port changes on every connection |
| `RateLimiter(limit, window_ms)` | fixed-window counter: `allow(key)` is `False` once `key` has made more than `limit` requests in the window; `too_many()` is the ready-made `429` with `Retry-After` |
| `request_id(req)` | the client's `X-Request-Id` when it is safe (≤ 64 characters of letters, digits, `-`, `_`, `.`), else a fresh UUID |
| `with_request_id(resp, rid)` | adds `X-Request-Id` to a response |
| `access_log(req, resp, started_ms, rid)` | one `nox.log.info` line: `METHOD target status ms id peer` |
| `with_security_headers(resp)` | adds `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` unless already set |
| `text_response(status, body)`, `json_response(status, body_json)`, `redirect(location, status=302)` | small response constructors (`redirect` rejects CR/LF) |

Several cookies in one response: join the `Set-Cookie` values with `nox.http.multi([...])` ([Several headers with the same name](http.md#several-headers-with-the-same-name)).

## Cookies

```nox
import nox.web
import nox.http

print(nox.web.cookie("sid", "abc123"))
print(nox.web.cookie("theme", "dark", "/app", 3600, False, True, "Strict"))
print(nox.web.expire_cookie("sid"))
jar: dict[str, str] = nox.web.parse_cookies("a=1; b=two; a=ignored")
print(jar["a"] + " " + jar["b"])
print(nox.http.multi([nox.web.cookie("a", "1"), nox.web.cookie("b", "2")]).count("\n"))
```

```output
sid=abc123; Path=/; HttpOnly; SameSite=Lax
theme=dark; Path=/app; Max-Age=3600; Secure; SameSite=Strict
sid=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax
1 two
1
```

## Putting it together

The handler passed to `serve` is an ordinary function, so the pieces compose by calling them in order: id → rate limit → CORS preflight → route → CORS headers → id and security headers → log.

```nox
import nox.http
import nox.web
from nox.http import HttpRequest, HttpResponse
from nox.web import Cors, RateLimiter

cors: Cors = Cors(["https://app.example"], "GET, POST", "Content-Type", 600, False)
limiter: RateLimiter = RateLimiter(100, 60000)

def route(req: HttpRequest) -> HttpResponse:
    if req.target == "/hello":
        return nox.web.text_response(200, "hello")
    return nox.web.text_response(404, "not found")

def respond(req: HttpRequest) -> HttpResponse:
    if not limiter.allow(nox.web.client_ip(req)):
        return limiter.too_many()
    pre: HttpResponse | None = cors.preflight(req)
    if pre is not None:
        return pre
    return cors.apply(req, route(req))

def handle(req: HttpRequest) -> HttpResponse:
    rid: str = nox.web.request_id(req)
    resp: HttpResponse = nox.web.with_security_headers(nox.web.with_request_id(respond(req), rid))
    return resp

req: HttpRequest = HttpRequest("GET", "/hello", "", {"Origin": "https://app.example", "X-Request-Id": "r-1"}, "10.0.0.1:5000")
out: HttpResponse = handle(req)
print(out.status)
print(out.headers["Access-Control-Allow-Origin"])
print(out.headers["X-Request-Id"])
print(out.headers["X-Frame-Options"])
```

```output
200
https://app.example
r-1
DENY
```

In a real handler, add `nox.web.access_log(req, resp, started, rid)` before the `return` to write one log line per request (it goes to standard output through [`nox.log`](log.md)); it is left out here so the example's output stays deterministic.

## Reference application

[`examples/todo-backend`](https://github.com/mburakmmm/nox-lang/tree/main/examples/todo-backend) is a complete small backend built from these pieces: registration and login (argon2id + JWT), a per-user todo list in SQLite, a server-sent-events endpoint ([streaming responses](http.md#streaming-responses)), CORS, rate limiting, request ids, access log, security headers and graceful shutdown on `SIGTERM`. `scripts/todo_backend_smoke.py` builds it and drives it end to end (authorisation isolation between two users, CORS, 429, 8 concurrent clients, clean shutdown) on both backends.

## Notes

- **Module state is per worker on the default backend.** With the LLVM backend a `serve` connection may run on any worker thread, and each worker has its own copy of the module's variables. Build everything the handler needs *inside a variable initialiser* (`router: Router = build_router()`, `limiter: RateLimiter = RateLimiter(...)`). Route registrations directly after the router's declaration are replayed per worker too; other statements after the last variable run only on the main worker. Details: [Modules](../language/modules.md#module-level-state-and-the-multi-core-runtime).
- **`serve_multicore`:** module-level state is per worker, so a `RateLimiter`'s counters are per worker (the effective limit is up to `limit` × workers; the same holds for plain `serve` on the LLVM backend). Use a database, [`nox.atomic`](atomic.md) or [`nox.sharedmem`](sharedmem.md) for a strict shared limit.
- **Memory:** a `RateLimiter` forgets all counters at the end of each window and resets early when it has seen 100000 distinct keys, so it cannot grow without bound.
- **CORS:** with `allow_credentials` the policy echoes the request's `Origin` (a `*` would be rejected by browsers). `Vary: Origin` is added whenever the origin is echoed.
- Cookie *values* are not encoded for you: percent-encode arbitrary text with [`nox.url.percent_encode`](url.md) first.
