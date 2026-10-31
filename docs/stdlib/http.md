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
| `put(url, body, headers)`, `patch(url, body, headers)` | PUT / PATCH with `body` |
| `delete(url, headers)`, `head(url, headers)`, `options(url, headers)` | bodyless requests |
| `request(method, url, body, headers, timeout_ms=0)` | any of GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS; optional timeout |

`headers` are *added* to the request (the client also sends its own `Host`, `User-Agent`, `Accept-Encoding` …). Redirects are **not** followed: a 3xx response is returned as it is, so you decide whether to follow `Location` (and whether to forward `Authorization`). gzip/deflate response bodies are decoded
automatically. A non-2xx status is **not** an error: inspect `status`. `HttpError` is raised when the request could not be made at all (connection refused, DNS failure, TLS failure) or when the body arrives incomplete (the connection closed before the announced `Content-Length`).

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

### Methods, timeouts and binary bodies

`request` accepts exactly `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD` and `OPTIONS` (upper case). Any other name raises `HttpError`; it is never turned into a GET. A request body
can only be sent with `POST`, `PUT` and `PATCH`.

`timeout_ms > 0` limits the DNS lookup, the TCP connect, and then the time spent sending the request and reading the response: when it runs out the connection is aborted and
`HttpTimeoutError` (a subclass of `HttpError`) is raised. An unresolvable name or an address that never answers therefore fails after `timeout_ms` instead of waiting for the operating
system's own limit (30 s for DNS and 75 s for a TCP connect on macOS, similar on Android). With `timeout_ms = 0` the lookup and the connect are not bounded.

Names resolve with the system resolver for both IPv4 and IPv6 (the system's address order is tried in turn, so a dead IPv6 route falls back to IPv4), and IPv6 literals such as
`http://[::1]:8080/` work on every platform. `nox.tls.connect`, `nox.websocket.connect` and `nox.smtp.connect` bound DNS and connect at 30 seconds.

A response body may be binary. `resp.body` keeps every byte (including `\x00` and bytes that are not valid UTF-8); `nox.bytes.from_str(resp.body)` copies them into a `Buffer`.

```text
r: HttpResponse = nox.http.request("PUT", "http://127.0.0.1:8080/items/1", "{\"n\": 2}", {"Content-Type": "application/json"}, 5000)
png: Buffer = nox.bytes.from_str(nox.http.get("http://127.0.0.1:8080/logo.png", {}).body)
```

### Streaming large bodies

`get`, `post` and `request` keep the whole response body in memory. For large downloads and uploads use a stream: the body moves in chunks, memory use is bounded by the chunk size,
and reading is pull-based (the network is read only when you ask for the next chunk, so a slow consumer applies back-pressure to the server).

| Function / method | Description |
|---|---|
| `stream(method, url, headers, body="", timeout_ms=0)` | sends the request, waits for the response head and returns an `HttpStream` whose `status` and `headers` are set; `body` (optional, POST/PUT/PATCH only) is sent from memory |
| `stream_upload(method, url, headers, content_length=-1, timeout_ms=0)` | opens a streamed **request** body (POST/PUT/PATCH): `content_length >= 0` sends a fixed `Content-Length` (you must write exactly that many bytes), `-1` uses chunked transfer encoding |
| `s.read_chunk(n)` | up to `n` bytes of the response body as a `str`; returns as soon as at least one byte is available, `""` at the end of the body |
| `s.write(chunk)` | sends one piece of an uploaded body |
| `s.finish()` | ends the upload and reads the response head; afterwards `s.status`/`s.headers` are set and the response body is read with `read_chunk` |
| `s.close()` | closes the connection (calling it twice is harmless) |

```text
from nox.http import HttpStream

with nox.http.stream("GET", "https://example.com/big.iso", {}) as s:
    if s.status == 200:
        while True:
            chunk: str = s.read_chunk(65536)
            if len(chunk) == 0:        # end of the body
                break
            ...                        # write it somewhere, hash it, …

up: HttpStream = nox.http.stream_upload("PUT", "https://example.com/data", {}, 11)
up.write("hello ")
up.write("world")
up.finish()
print(up.status, up.read_chunk(100))
up.close()
```

To move a body straight to or from a file, see [`nox.transfer`](transfer.md) (`download_to_file`, `upload_file`).

Details:

- A chunk is a `str` carrying **raw bytes** (binary data, `\x00` and invalid UTF-8 included; see [`nox.bytes`](bytes.md)); it can end in the middle of a multi-byte UTF-8 character and `len(chunk)` counts code points, so use `nox.strings.byte_len`.
- The body is decoded according to `Content-Encoding` (gzip/deflate) as it is read.
- A server that closes the connection before sending the whole `Content-Length` / chunked body makes `read_chunk` raise `HttpError`; a truncated body is never reported as a complete one. (`get`/`post`/`request` apply the same check.)
- `timeout_ms > 0` is an **idle** timeout per operation (waiting for the response head, each `read_chunk`, each `write`), not a limit on the whole transfer; when it runs out the connection is aborted and `HttpTimeoutError` is raised. After any failure the stream is closed and further calls raise `HttpError`.
- An `HttpStream` owns a network connection and a helper thread and is **not** closed automatically: use `with` or call `close()`.
- Redirects are not followed, as for `request`. Streams can be read from lightweight tasks: waiting suspends only the calling task.

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
