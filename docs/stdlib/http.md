# nox.http

An HTTP/1.1 client and server. The server is part of the language runtime: connections run on lightweight tasks, the I/O reactor never blocks a worker, and a pool of
workers serves many cores. TLS and WebSocket upgrade are built in.

```text
import nox.http
from nox.http import HttpRequest, HttpResponse, HttpError
```

**Capability:** `network` (unavailable in freestanding profiles).

## Messages

### `HttpRequest`

What a server handler receives.

| Field | Type | Description |
|---|---|---|
| `method` | `str` | `"GET"`, `"POST"`, … |
| `target` | `str` | the request target exactly as sent, **including the query string** (`/todos?x=1`) |
| `body` | `str` | the request body (empty if none) |
| `headers` | `dict[str, str]` | request headers, with the **names as the client wrote them** (`Content-Type`, `User-Agent`, …) — look up with the exact spelling, or loop |
| `peer_addr` | `str` | the client's `ip:port` (IPv4 `a.b.c.d:port`; IPv6 clients appear as `[::1]:port`) |

`HttpRequest(method, target, body, headers, peer_addr="")` can be constructed directly, which is how handlers are unit-tested. Constructor parameters are frozen; new ones are only
ever added with defaults ([Stability](../apis/stability.md)).

### `HttpResponse`

What a handler returns and what the client functions return.

| Field | Type | Description |
|---|---|---|
| `status` | `int` | the HTTP status code |
| `body` | `str` | the body |
| `headers` | `dict[str, str]` | response headers |

`HttpResponse(status, body, headers)`. The server adds `content-length` itself; set `Content-Type` and any other headers you need.

## Client

| Function | Description |
|---|---|
| `get(url, headers)` | issues a GET and returns the `HttpResponse`; `http://` and `https://` are supported |
| `post(url, body, headers)` | issues a POST with `body` |

`headers` are *added* to the request (the client also sends its own `Host`, `User-Agent`, `Accept-Encoding` …). Redirects are followed, gzip/deflate response bodies are decoded
automatically. A non-2xx status is **not** an error: inspect `status`. `HttpError` is raised when the request could not be made at all (connection refused, DNS failure, TLS failure).

```nox
import nox.http
from nox.http import HttpResponse, HttpError

def fetch(url: str) -> str:
    try:
        r: HttpResponse = nox.http.get(url, {"Accept": "text/plain"})
        if r.status == 200:
            return r.body
        return "status " + str(r.status)
    except HttpError as e:
        return "unreachable"

print(fetch("http://127.0.0.1:1/"))
```

```output
unreachable
```

## Server

The `serve` family are language-level entry points: the handler must be a plain function name (or, for `serve` and `serve_fd`, a closure of type `(HttpRequest) -> HttpResponse`) and
**cannot be `async`** — each connection already runs on its own task. They block forever (or until `max_connections` have been served, when that optional argument is given).

| Call | Description |
|---|---|
| `serve(port, handle[, max_connections])` | one listener, runs on the calling worker; handler may be a name or a closure |
| `serve_fd(fd, handle[, max_connections])` | serve on an already-listening socket from `listen(port)` |
| `serve_multicore(port, handle, num_threads[, max_connections])` | `num_threads` workers share the listening socket; handler must be a function **name**; `max_connections` must be an integer literal |
| `serve_tls(port, handle, cert_path, key_path[, max_connections])` | HTTPS using PEM certificate and key files |
| `serve_ws(port, handle, ws_handle[, max_connections])` | HTTP plus WebSocket upgrade; `ws_handle(conn: WebSocketServerConn) -> None` runs for upgraded connections |
| `serve_ws_tls(port, handle, ws_handle, cert_path, key_path[, max_connections])` | WebSocket over TLS |
| `serve_fd_tls`, `serve_fd_ws`, `serve_fd_ws_tls` | the `_fd` forms of the above |
| `serve_multicore_tls`, `serve_multicore_ws`, `serve_multicore_ws_tls` | the multi-worker forms (`num_threads` follows `handle`) |
| `listen(port)` | opens a listening socket and returns its descriptor; raises `HttpError` on failure |
| `listen_v6(port, v6_only)` | an IPv6 (dual-stack unless `v6_only`) listening socket; not available on Windows |

```nox
import nox.http
from nox.http import HttpRequest, HttpResponse

def handle(req: HttpRequest) -> HttpResponse:
    return HttpResponse(200, req.method + " " + req.target + "\n", {"Content-Type": "text/plain"})

nox.http.serve(8080, handle)
```

A handler is an ordinary function: test it by calling it with a hand-built request.

```nox
from nox.http import HttpRequest, HttpResponse

def handle(req: HttpRequest) -> HttpResponse:
    return HttpResponse(200, req.method + " " + req.target, {"Content-Type": "text/plain"})

resp: HttpResponse = handle(HttpRequest("GET", "/hi?x=1", "", {}, "10.0.0.1:5555"))
print(resp.status, resp.body)
```

```output
200 GET /hi?x=1
```

### Choosing a `serve` form

- **`serve`** — one worker; simplest; module-level state is shared by every request. Fine for small services and the whole development workflow.
- **`serve_multicore`** — scales across CPU cores. Each worker has its own copy of module-level state, so keep shared state in a database or in `nox.atomic` / `nox.sharedmem`.
- **`_tls`** — pass paths to a PEM certificate chain and private key. Behind a reverse proxy that terminates TLS, plain `serve` is usually what you want.
- **`_ws`** — use when the same port serves normal requests and WebSockets; see [`nox.websocket`](websocket.md).

### Behaviour

- Request bodies and headers are limited to sane sizes; a client that stalls on reading or writing is cut off by a write timeout (2.0 closes the slow-reader denial-of-service hole).
- `HEAD`, `Connection: close` and keep-alive are handled by the runtime.
- Routing is not part of the server: use [`nox.router`](router.md).

## Notes

- Only the `serve*` functions listed above are intrinsics; everything else in the module (`get`, `post`, `listen`, `listen_v6`, `HttpRequest`, `HttpResponse`, `HttpError`) is ordinary Nox code.
- For TLS client connections beyond HTTP see [`nox.tls`](tls.md).
