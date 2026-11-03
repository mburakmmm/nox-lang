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

`HttpRequest(method, target, body, headers, peer_addr="", conn=0)` can be constructed directly, which is how handlers are unit-tested (`conn` is the server's internal connection handle; leave it `0`). Constructor parameters are frozen; new ones are only
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

**Concurrency.** Inside a task (`spawn`) or a `serve` handler, a request does not occupy an operating-system thread: the task is suspended while it waits for the network and the worker runs other tasks, so thousands of requests can be in flight at once on a few threads (about 110 KB of memory per request in flight). Outside a task (plain top-level code), on Windows and for `stream`/`stream_upload`, each request still uses a helper thread.

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

### Connection pooling

Outgoing requests share a process-wide pool of idle connections. When a request finishes, its connection goes back to the pool and the next request to the same scheme, host and port
(from any task or worker) reuses it, so repeated calls to one API skip the TCP connect and, for `https`, the TLS handshake. Against a real HTTPS API this made back-to-back requests about
4× faster (336 ms → 82 ms each). Nothing changes in how you call the client.

| Call | Meaning |
|---|---|
| `nox.http.client_pool(max_idle, idle_timeout_ms=...)` | the most idle connections kept (default `32`, at most `1024`); `0` turns pooling off: idle connections close at once and every request opens and closes its own. `idle_timeout_ms` is how long a connection may sit idle in the pool (default `90000`; `0` = no limit; leave it out to keep the current value) |
| `nox.http.client_idle_connections()` | how many idle connections the pool holds right now |

```nox
import nox.http

print(nox.http.client_idle_connections())
nox.http.client_pool(0)
nox.http.client_pool(32)
print(nox.http.client_idle_connections())
```

```output
0
0
```

How stale connections are handled — a server may close an idle connection at any time:

- Before a request, the pool checks the idle connection it is about to reuse; one the server has already closed is discarded and a fresh connection is opened. You never see an error for this.
- If the connection dies in the instant between that check and the request, an **idempotent** request (`GET`, `HEAD`, `OPTIONS`, `PUT`, `DELETE`, `TRACE`) that failed before any response arrived is retried **once** on a fresh connection. `POST` and `PATCH` are never retried automatically, because the server may already have acted on them; such a request fails with `HttpError` and your code decides.
- Only responses that were read completely return their connection to the pool; a timeout, a truncated body or a `Connection: close` response closes it. A request with `timeout_ms` is cancelled by closing its connection, which is never reused.
- Idle connections are closed after `idle_timeout_ms` (90 s by default, measured from when the pool first sees them idle, to within a fraction of a second), when the server closes them, when the pool is full (the oldest go first) or when `client_pool` shrinks the pool. A small background thread does the sweeping and exits on its own once the pool has been empty for a few seconds. Streaming calls (`nox.http.stream`, `stream_upload`) open their own connections and do not use the pool.
- HTTPS certificate checks use the current time, refreshed every ten minutes.

### Proxies

The client honours `HTTP_PROXY`, `HTTPS_PROXY` and `ALL_PROXY` (and the lower-case spellings), plus `NO_PROXY`. They are read when the first request is made; changing them later has no effect.

- **`http://` targets** go through the proxy in the standard forward-proxy form (`GET http://host/path`).
- **`https://` targets** are tunnelled with `CONNECT host:443`; TLS to the *target* (server name, certificate check) then runs inside the tunnel, so the proxy sees only encrypted bytes. If the proxy refuses the tunnel the request **fails**; it is never retried as a plain-text request to the proxy. Tunnelled connections are pooled like direct ones. The proxy URL itself must be `http://` (a TLS connection to the proxy is not supported; such a request fails rather than bypassing the proxy).
- **`NO_PROXY`** is a comma-separated list: `*` for everything, `example.com` for the host and its subdomains, `.example.com` for subdomains only; a `:port` suffix is ignored and IP ranges (CIDR) are not understood (an exact IP matches). Matching hosts connect directly.
- `user:password@` in the proxy URL is sent as `Proxy-Authorization: Basic`. Environment variables are not read on Windows.

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

### Several headers with the same name

`HttpResponse.headers` is a `dict[str, str]`, so a name appears once. To send several lines with the same name (`Set-Cookie`, `Link`, `Vary`), join the values with `nox.http.multi`; the server writes each one as its own header line:

```text
h: dict[str, str] = {}
h["Set-Cookie"] = nox.http.multi(["session=abc; Path=/; HttpOnly", "theme=dark; Path=/"])
```

On the request side, a header the client sent more than once arrives in `req.headers` as one entry with the values joined by `, ` (by `; ` for `Cookie`), as RFC 9110 describes.

### Streaming responses

A handler normally returns one `HttpResponse`. To send a body over time — server-sent events, a long export, a progress feed — start a stream from the request. The status line and
headers go out **immediately**, then every `send` reaches the client at once (chunked transfer encoding). The handler keeps its signature and ends with `return stream.end()`.

| Call | Meaning |
|---|---|
| `req.stream(status, headers)` | start a streaming response; raises `HttpError` if it cannot (already started, status outside 200–599 or 204/304, invalid header) |
| `req.sse()` | `stream(200, ...)` with `Content-Type: text/event-stream`, `Cache-Control: no-cache` and `X-Accel-Buffering: no` (stops reverse proxies from buffering) |
| `stream.send(chunk)` | write a raw chunk; `False` once the client has gone or the stream has ended |
| `stream.event(data, event="", id="")` | one SSE event; a multi-line `data` becomes one `data:` field per line; `event` and `id` have newlines removed |
| `stream.comment(text="")` | an SSE comment line (`: text`): invisible to the client, keeps the connection alive and detects a broken one |
| `stream.retry(ms)` | suggest the client's reconnect delay |
| `stream.is_open()` | `False` after a write failed, after `end()`, or while the server is shutting down |
| `stream.sleep_ms(ms)` | wait; cooperative (other connections keep running, also on the QBE backend) and returns early when the server shuts down. Use it instead of `nox.time.sleep_ms` in stream loops |
| `stream.trailers(headers)` | set the response trailers (`grpc-status`, a checksum, ...): sent after the body, before `end()`; returns `False` if the stream already ended or the client speaks HTTP/1.0 |
| `stream.end()` | finish the body and return the placeholder response the handler must return (its contents are ignored) |

```nox
from nox.http import HttpRequest, HttpResponse, ResponseStream

def handle(req: HttpRequest) -> HttpResponse:
    s: ResponseStream = req.sse()
    n: int = 0
    while s.is_open() and n < 3:
        if not s.event("tick " + str(n), "tick", str(n)):
            break
        n = n + 1
        s.sleep_ms(1000)
    return s.end()

# A request built by hand has no connection: the stream collects what was sent, which is how handlers are unit-tested.
test_req: HttpRequest = HttpRequest("GET", "/events", "", {})
s2: ResponseStream = test_req.sse()
s2.event("hello", "greeting")
s2.comment("ping")
print(len(s2.sent))
print(s2.sent[0] == "event: greeting\ndata: hello\n\n")
print(s2.sent[1] == ": ping\n\n")
```

```output
2
True
True
```

### Trailers

Trailing headers travel after the body: as a final `HEADERS` frame in HTTP/2, after the last chunk in chunked HTTP/1.1. Set them with `stream.trailers({...})` before `stream.end()`. For requests, `req.trailer(name)` returns a trailer sent after the body (chunked HTTP/1.1 or HTTP/2), or `""`; repeated values are joined with `, `. Trailers are only known once the request body has been read, which is when your handler runs.

```nox
from nox.http import HttpRequest, ResponseStream

req: HttpRequest = HttpRequest("GET", "/", "", {})
s: ResponseStream = req.stream(200, {})
s.send("body")
print(s.trailers({"X-Checksum": "abc"}))
print(s.sent_trailers["X-Checksum"])
s.end()
print(s.trailers({"late": "x"}))
print(req.trailer("X-Sum") == "")
```

```output
True
abc
False
True
```

Things to know:

- On HTTP/1.1 the connection **closes** after a stream (`Connection: close`); the next request opens a new one. The handler's return value is ignored, and an exception after the stream has started just ends it (the status line is already sent, so no `500` is possible).
- A client that disconnects is noticed at the **next write**: `send`/`event`/`comment` return `False`. In a quiet stream send a `comment` every few seconds; it doubles as a heartbeat for proxies.
- On `SIGTERM`/`SIGINT` or `nox.http.shutdown()`, `is_open()` turns `False` and `sleep_ms` returns, so a loop written as above ends by itself and the graceful shutdown completes; otherwise the server waits `drain_timeout_ms` and then closes the stream.
- Each open stream holds one connection and one fiber. On the default backend streams are spread over the worker threads like any other connection ([Choosing a `serve` form](#choosing-a-serve-form)); the QBE backend serves all of them from one thread, so wait with `stream.sleep_ms`, never with a blocking call.
- Behind a reverse proxy, keep `X-Accel-Buffering: no` (set by `sse()`) and make sure the proxy does not enforce a short read timeout shorter than your heartbeat interval.

### Configuration and graceful shutdown

```text
nox.http.configure(max_body_bytes=0, max_header_bytes=0, read_timeout_ms=0, max_connections=0, drain_timeout_ms=0)
nox.http.shutdown()
```

`configure` sets process-wide server limits and must be called **before** `serve*` (an argument of `0` keeps the default). It applies to every worker.

| Argument | Default | Effect |
|---|---|---|
| `max_body_bytes` | 10 MiB | a larger request body is answered with `413` |
| `max_header_bytes` | 16 KiB (4 KiB – 1 MiB) | the request line plus all headers must fit; otherwise `431`. Browsers' cookies are the usual reason to raise it |
| `read_timeout_ms` | 30000 | longest silence while waiting for a request or its body; the connection is then closed |
| `max_connections` | 4096 | connections open at once; further ones get a `503 Service Unavailable` (`Retry-After: 1`) and are closed until some close |
| `drain_timeout_ms` | 10000 | how long a graceful shutdown waits for requests that are still being handled |

**Graceful shutdown.** `SIGTERM` or `SIGINT` (and `nox.http.shutdown()`, which you may call from a handler) stops the server cleanly: new connections are no longer accepted, requests that are already being handled finish and are answered with `Connection: close`, idle keep-alive connections are closed, and **`serve*` returns** — so the code after it (closing a database, flushing logs) runs and the program exits normally. A second signal exits immediately. After `drain_timeout_ms` the server stops waiting and also returns. On Windows only `nox.http.shutdown()` is available (there is no signal handler). A WebSocket connection already upgraded is not closed by a shutdown: close it from its handler, or rely on `drain_timeout_ms`.

Malformed or hostile requests no longer drop the connection silently: `400` (bad request line or header, conflicting `Content-Length`/`Transfer-Encoding`, `Host` missing in HTTP/1.1), `413`, `431`, `501` (a `Transfer-Encoding` other than `chunked`). A handler that raises an uncaught exception is answered with `500`, the exception class and line are written to standard error, and the server keeps serving.

### Choosing a `serve` form

- **`serve`** — one listening socket; simplest. On the QBE backend one thread handles every request and module-level state is shared. On the default LLVM backend the connection fibers can be picked up by any worker thread, and **each worker has its own copy of the module's variables** — build everything the handler needs in a variable initialiser (`router: Router = build_router()`, `db: Connection = open_db()`); `router.get(...)` calls directly after the router's declaration also run per worker, other statements placed after the last variable do not ([Modules](../language/modules.md#module-level-state-and-the-multi-core-runtime)). Keep data that must be shared in a database, `nox.atomic` or `nox.sharedmem`.
- **`serve_multicore`** — scales across CPU cores. Each worker has its own copy of module-level state, so keep shared state in a database or in `nox.atomic` / `nox.sharedmem`.
- **`_tls`** — pass paths to a PEM certificate chain and private key; clients that offer `h2` get [HTTP/2](#http2). Behind a reverse proxy that terminates TLS, plain `serve` is usually what you want.
- **`_ws`** — use when the same port serves normal requests and WebSockets; see [`nox.websocket`](websocket.md).

### HTTP/2

The server speaks HTTP/2 as well as HTTP/1.1, with no change to your handler: the same `HttpRequest` goes in and the same `HttpResponse` comes out.

- **Over TLS** (`serve_tls`, `serve_ws_tls`, ...) the protocol is negotiated with ALPN: a client that offers `h2` gets HTTP/2, every other client gets HTTP/1.1.
- **Over plain TCP** a client that starts with the HTTP/2 connection preface ("prior knowledge", `curl --http2-prior-knowledge`, or a reverse proxy speaking cleartext HTTP/2 to its upstream) gets HTTP/2; ordinary HTTP/1.1 clients are unaffected.
- **Multiplexing:** every request on a connection runs your handler on its own task, so one browser connection can have up to 100 requests in flight, slow ones do not hold up fast ones, and a long-lived `req.sse()` stream shares the connection with ordinary requests. Streaming responses ([Streaming responses](#streaming-responses)) work unchanged; unlike HTTP/1.1, only the stream ends, not the connection.
- **Flow control** is handled for you: uploads and downloads are paced by the peer's windows (1 MiB per request and 4 MiB per connection on the receiving side), so a slow client cannot make the server buffer a whole response.

What differs from HTTP/1.1, as your handler sees it:

| | |
|---|---|
| Request header names | normalised to `Title-Case` (`content-type` arrives as `Content-Type`), so `req.headers["Content-Type"]` works for every client; `Host` is filled from `:authority` |
| Response header names | sent in lower case, as the protocol requires; `Connection`, `Keep-Alive`, `Transfer-Encoding` and `Upgrade` response headers are dropped (they do not exist in HTTP/2) |
| `Content-Length` | added for you when the handler does not set one |
| WebSocket | works over HTTP/2 too ([RFC 8441](https://www.rfc-editor.org/rfc/rfc8441)) on `serve_ws*` servers: the server announces `SETTINGS_ENABLE_CONNECT_PROTOCOL`, and an extended `CONNECT` with `:protocol: websocket` runs your `ws_handle` on the stream; clients that use an HTTP/1.1 upgrade are served as before |
| Trailers, `Expect: 100-continue` | supported: see [trailers](#trailers) below; the `100` interim response is sent for you |
| Not supported (by design) | server push and the RFC 7540 priority tree: both are deprecated by RFC 9113 and gone from browsers; priority signals are accepted and ignored, which the protocol allows |

Limits and protection: 100 concurrent requests per connection (further ones are refused and retried by the client), `max_body_bytes` and `max_header_bytes` apply as in HTTP/1.1, an incomplete request is cut after `read_timeout_ms`, an idle connection is closed after two minutes, and floods of control frames (`SETTINGS`, `PING`, resets — the "rapid reset" attack) end the connection with `ENHANCE_YOUR_CALM`. A request that was reset by the client keeps its slot until your handler returns, so resets cannot be used to start unbounded work.

On `SIGTERM` or `nox.http.shutdown()` each HTTP/2 connection is sent `GOAWAY`, requests already running finish, and the connection closes ([Configuration and graceful shutdown](#configuration-and-graceful-shutdown)); a stream loop that checks `stream.is_open()` ends by itself.

`nox.http.set_http2(False)` turns HTTP/2 off (TLS then offers only `http/1.1` and cleartext HTTP/2 is not detected); `True` turns it back on. It applies to connections accepted afterwards. HTTP/2 is not available on Windows yet; connections there stay on HTTP/1.1.

```nox
import nox.http

nox.http.set_http2(False)
nox.http.set_http2(True)
print("http2 configurable")
```

```output
http2 configurable
```

Try it with `curl --http2 -k https://localhost:8443/` (TLS) or `curl --http2-prior-knowledge http://localhost:8080/` (cleartext); `curl -w '%{http_version}'` prints `2`.

### Behaviour

- Request bodies and headers are limited to sane sizes; a client that stalls on reading or writing is cut off by a write timeout (2.0 closes the slow-reader denial-of-service hole).
- `HEAD`, `Connection: close` and keep-alive are handled by the runtime. A connection serves at most 1000 requests; the 1000th response carries `Connection: close` so clients reconnect cleanly instead of seeing an unexpected reset.
- A client that disconnects while the server writes does not stop the process: `SIGPIPE` is ignored by the `serve*` functions and the write simply fails.
- Routing is not part of the server: use [`nox.router`](router.md).

## Notes

- Only the `serve*` functions listed above are intrinsics; everything else in the module (`get`, `post`, `listen`, `listen_v6`, `HttpRequest`, `HttpResponse`, `HttpError`) is ordinary Nox code.
- For TLS client connections beyond HTTP see [`nox.tls`](tls.md).
