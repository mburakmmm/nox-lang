# nox.grpc

A gRPC client (HTTP/2 over plain TCP, `h2c`) written in Zig: no `grpc` library needed. Messages are protobuf bytes (encode and decode them with [`nox.protobuf`](protobuf.md)); a `str`
holds bytes safely, including NUL.

```text
import nox.grpc
from nox.grpc import Client, Response, GrpcError, GrpcStatusError
```

**Capability:** `network`.

## Connecting and calling

```text
c: Client = nox.grpc.connect("127.0.0.1", 50051)
reply: str = c.unary("/helloworld.Greeter/SayHello", request_bytes)
r: Response = c.call("/pkg.Svc/Stream", [m1, m2])
print(r.status, r.message, len(r.messages), r.header("x-request-id"))
c.close()
```

| Member | Description |
|---|---|
| `connect(host, port) -> Client` | opens the connection and sends the HTTP/2 preface; failure raises `GrpcError` |
| `Client.unary(path, request, timeout_ms=0) -> str` | one request, one reply message; a status other than `OK` raises `GrpcStatusError` (`code`, `detail`) |
| `Client.call(path, requests, timeout_ms=0) -> Response` | any RPC shape: one or more request messages (client streaming), all reply messages collected (server streaming). The status is in the `Response`, not raised |
| `Client.call_with(path, requests, metadata, timeout_ms) -> Response` | the same with request metadata (`dict[str, str]`) |
| `Client.close()`, `Client.is_ok()` | close; whether the connection is still usable |
| `Response.status`, `.message`, `.messages`, `.ok()`, `.header(name)` | gRPC status code, status message, reply messages, response header or trailer value (case-insensitive, `""` if absent) |

`path` is `/package.Service/Method`. Status constants (`nox.grpc.NOT_FOUND`, `UNAVAILABLE`, ...) follow the gRPC status codes. `timeout_ms > 0` is sent as `grpc-timeout`; the server
answers `DEADLINE_EXCEEDED` when it runs out.

## Errors

- A transport or protocol failure (connection lost, malformed frame, `GOAWAY`, a stream reset) raises `GrpcError` and closes the connection; open a new one with `connect`.
- A server status is data: `Response.status`, or `GrpcStatusError` from `unary`. The status message is percent-decoded.

## Limits

- **No TLS yet.** The built-in TLS client cannot announce ALPN `h2`; put a TLS terminator (or a local proxy) in front of a TLS-only service.
- **Sequential calls** on one connection; the client does not interleave a bidirectional stream (requests are sent, then replies are collected).
- **No compression:** requests announce `grpc-accept-encoding: identity`; a compressed reply is an error.
- **No client-side read timeout** (the same limit as [`nox.redis`](redis.md)); use `timeout_ms` so the server enforces the deadline.
- Flow control is handled in both directions (a 300 KB request and a 2 MB reply are tested).
