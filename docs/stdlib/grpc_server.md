# nox.grpc_server

A gRPC **server** written in Nox on top of [`nox.http`](http.md) (HTTP/2: cleartext with prior knowledge, or TLS with ALPN `h2` through the `serve_tls*` functions). Messages are protobuf bytes; encode and decode them with [`nox.protobuf`](protobuf.md).

```text
import nox.http
import nox.grpc_server
from nox.http import HttpRequest, HttpResponse
from nox.grpc import GrpcStatusError
from nox.grpc_server import Method, StreamMethod, CtxMethod, Call
```

**Capability:** `network`.

```nox-fragment
def say_hello(requests: list[str]) -> list[str]:
    return ["hello " + requests[0]]

def not_found(requests: list[str]) -> list[str]:
    raise GrpcStatusError(5, "no such user")

def table() -> list[Method]:
    return [Method("/helloworld.Greeter/SayHello", say_hello), Method("/helloworld.Greeter/Find", not_found)]

def handle(req: HttpRequest) -> HttpResponse:
    return nox.grpc_server.dispatch(table(), req)

nox.http.serve(50051, handle)
```

| Member | Description |
|---|---|
| `Method(path, handler)` | a method: `path` is `/package.Service/Method`; `handler` is `(list[str]) -> list[str]` |
| `StreamMethod(path, handler)` | a **true streaming** method: `handler` is `(Call) -> None` |
| `Call.recv() -> str \| None`, `Call.send(message) -> bool` | the next request message (`None` when the client has finished sending); send a reply message **immediately** |
| `CtxMethod(path, handler)` | a batch method whose handler also gets the `Call`: `(Call, list[str]) -> list[str]` |
| `dispatch_all(methods, streams, req) -> HttpResponse` | like `dispatch` with both tables |
| `dispatch_full(methods, streams, ctxs, req, compress_replies=False) -> HttpResponse` | all three tables; `compress_replies=True` gzips replies for clients that accept it |
| `dispatch(methods, req) -> HttpResponse` | runs the call for a `nox.http` handler: finds the method, calls the handler with the request messages, sends the reply messages and the `grpc-status` trailer |
| `parse_messages(body) -> list[str]`, `frame(message) -> str` | the length-prefixed message framing, for tests and custom handlers |

A handler receives **all request messages** (one for a unary or server-streaming method, several for client streaming) and returns **all reply messages** (one for unary or client streaming, several for server streaming). Raise `GrpcStatusError(code, "message")` to
return a status other than `OK`; the message is percent-encoded for you. A method that is not in the table answers `UNIMPLEMENTED` (12). A gzip-compressed request message is decompressed; replies are compressed only when you ask (see below).

## Bidirectional streaming

A `StreamMethod` handler runs as soon as the request headers arrive and reads the request body piece by piece, so requests and replies interleave: a chat-like RPC can answer each message before the next one is sent.

```text
def chat(call: Call) -> None:
    m: str | None = call.recv()
    while m is not None:
        call.send("echo:" + m)
        m = call.recv()

def streams() -> list[StreamMethod]:
    return [StreamMethod("/chat.Room/Talk", chat)]

def handle(req: HttpRequest) -> HttpResponse:
    return nox.grpc_server.dispatch_all(table(), streams(), req)
```

Raise `GrpcStatusError` from the handler to finish the call with that status (replies already sent stay delivered). When the handler returns, the call ends with `OK`. Under the hood the HTTP/2 server gives a request with `content-type: application/grpc` to the handler before its body ends, and `req.read_chunk(n)` (see [`nox.http`](http.md)) delivers the body as it arrives; flow control keeps at most 1 MiB buffered per call.

## Metadata, deadlines, headers, trailers and compression

`Call` (the argument of a `StreamMethod` handler and of a `CtxMethod` handler) exposes the call's context:

| Member | Description |
|---|---|
| `call.header(name) -> str` | request metadata (case-insensitive name; `""` if absent), e.g. `call.header("authorization")` |
| `call.timeout_ms() -> int`, `call.remaining_ms() -> int`, `call.expired() -> bool` | the client's `grpc-timeout` in ms (0 if none), time left (-1 if none, 0 once passed), and whether it has passed |
| `call.set_header(name, value)`, `call.set_trailer(name, value)` | response metadata: headers go out with the first reply (or `call.send_headers()`), trailers next to `grpc-status` |
| `call.use_compression(True)` | gzip the replies (effective only when the client sent `grpc-accept-encoding: gzip`; call it before the first reply). `call.compressing()` tells whether it is on |
| `call.send_headers()` | send the response headers now |

The deadline is enforced for you: `recv()` and `send()` raise `GrpcStatusError(4, "deadline exceeded")` (`DEADLINE_EXCEEDED`) once the client's `grpc-timeout` has passed, and a batch method whose handler returns late answers `DEADLINE_EXCEEDED` instead of its replies. A handler stuck in a loop that never calls `recv`/`send` is not interrupted; poll `call.expired()` there.

```text
def whoami(call: Call, requests: list[str]) -> list[str]:
    if call.header("x-token") != "s3cret":
        raise GrpcStatusError(16, "bad token")
    call.set_trailer("x-served-by", "nox")
    return ["ok"]

def ctxs() -> list[CtxMethod]:
    return [CtxMethod("/svc.Auth/WhoAmI", whoami)]

def handle(req: HttpRequest) -> HttpResponse:
    return nox.grpc_server.dispatch_full(table(), streams(), ctxs(), req, True)
```

## Limits

- A plain `Method` handler runs after the whole request body has been read (it is the simple unary / client-streaming / server-streaming form). Use `StreamMethod` when a reply must go out before the request ends.
- Plain `Method` handlers do not see metadata or the deadline; use `CtxMethod` for that.
- For `Method`/`CtxMethod`, reply messages are sent after the handler returns, not while it runs (use `StreamMethod` + `call.send` to stream).
- Flow control, large messages and many sequential calls on one connection are tested against `grpcio` (a 300 KB request and a 2 MB reply).
