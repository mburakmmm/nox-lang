# nox.websocket

WebSocket (RFC 6455) for both directions: a **client** that connects to `ws://` and `wss://` URLs, and the **server-side connection** object handed to a WebSocket handler by
`nox.http.serve_ws*`. Messages are text.

```text
from nox.websocket import connect, WebSocketClient, WebSocketServerConn, WebSocketError
```

**Capability:** `network`.

## Client

| Function / method | Description |
|---|---|
| `connect(url)` | opens a connection (performing the handshake) and returns a `WebSocketClient`; `wss://` uses TLS. Raises `WebSocketError` if it cannot connect |
| `send_text(data)` | sends one text message; returns the number of bytes sent; raises `WebSocketError` on failure |
| `recv()` | blocks until the next message and returns it; pings and pongs are handled internally; returns the **empty string** when the connection has closed |
| `is_open()` | whether the connection is still open |
| `close()` | closes it (idempotent) |

Using a client after `close()` raises `WebSocketError`.

```nox
from nox.websocket import connect, WebSocketClient, WebSocketError

def ask(url: str, question: str) -> str:
    try:
        ws: WebSocketClient = connect(url)
        ws.send_text(question)
        answer: str = ws.recv()
        ws.close()
        return answer
    except WebSocketError as e:
        return "no connection"

print(ask("ws://127.0.0.1:1/", "hello"))
```

```output
no connection
```

## Server side

Pass a handler of type `(WebSocketServerConn) -> None` to `nox.http.serve_ws` (or the `_tls`, `_fd` and `_multicore` variants — see [`nox.http`](http.md#server)). It runs once per upgraded
connection, on its own task, until it returns.

`WebSocketServerConn` has the same four methods as the client: `send_text(data)`, `recv()`, `is_open()` and `close()`.

```nox
import nox.http
from nox.http import HttpRequest, HttpResponse
from nox.websocket import WebSocketServerConn

def page(req: HttpRequest) -> HttpResponse:
    return HttpResponse(200, "use a WebSocket client", {"Content-Type": "text/plain"})

def echo(conn: WebSocketServerConn) -> None:
    while conn.is_open():
        msg: str = conn.recv()
        if msg == "":
            return
        conn.send_text("echo: " + msg)

nox.http.serve_ws(8080, page, echo)
```

## Notes

- Operations block the calling task; the runtime keeps other tasks running while one waits.
- Only text messages are exposed; binary frames are delivered as text bytes.
- An empty message from the peer is indistinguishable from a close in `recv()`; use `is_open()` after an empty result if you need to tell them apart.
