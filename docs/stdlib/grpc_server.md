# nox.grpc_server

A gRPC **server** written in Nox on top of [`nox.http`](http.md) (HTTP/2: cleartext with prior knowledge, or TLS with ALPN `h2` through the `serve_tls*` functions). Messages are protobuf bytes; encode and decode them with [`nox.protobuf`](protobuf.md).

```text
import nox.http
import nox.grpc_server
from nox.http import HttpRequest, HttpResponse
from nox.grpc import GrpcStatusError
from nox.grpc_server import Method, StreamMethod, Call
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
| `dispatch_all(methods, streams, req) -> HttpResponse` | like `dispatch` with both tables |
| `dispatch(methods, req) -> HttpResponse` | runs the call for a `nox.http` handler: finds the method, calls the handler with the request messages, sends the reply messages and the `grpc-status` trailer |
| `parse_messages(body) -> list[str]`, `frame(message) -> str` | the length-prefixed message framing, for tests and custom handlers |

A handler receives **all request messages** (one for a unary or server-streaming method, several for client streaming) and returns **all reply messages** (one for unary or client streaming, several for server streaming). Raise `GrpcStatusError(code, "message")` to
return a status other than `OK`; the message is percent-encoded for you. A method that is not in the table answers `UNIMPLEMENTED` (12). A gzip-compressed request message is decompressed; replies are not compressed.

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

## Limits

- A plain `Method` handler runs after the whole request body has been read (it is the simple unary / client-streaming / server-streaming form). Use `StreamMethod` when a reply must go out before the request ends.
- `grpc-timeout` and request metadata are not exposed to the handler (the `HttpRequest.headers` of the call are not passed through `dispatch`; write your own handler around `parse_messages` and `frame` if you need them).
- Reply messages are sent after the handler returns, not while it runs.
- Flow control, large messages and many sequential calls on one connection are tested against `grpcio` (a 300 KB request and a 2 MB reply).
