# nox.grpc

A gRPC client (HTTP/2 over plain TCP `h2c`, or over TLS with ALPN `h2`) written in Zig: no `grpc` library needed. Messages are protobuf bytes (encode and decode them with [`nox.protobuf`](protobuf.md)); a `str`
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
| `connect(host, port) -> Client` | opens a plain TCP (`h2c`) connection and sends the HTTP/2 preface; failure raises `GrpcError` |
| `connect_tls(host, port, ca_file="") -> Client` | the same over TLS with ALPN `h2`. The server name is checked against the certificate. An empty `ca_file` uses the system CA store; a PEM path trusts only the CAs in that file (a private CA, a self-signed server) |
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

- **TLS needs TLS 1.3 ALPN support from the server** (the usual case for gRPC servers); a server that does not select `h2` makes `connect_tls` fail. No client certificates (mTLS) yet. Not available when compiled to WebAssembly.
- **Sequential calls** on one connection; the client does not interleave a bidirectional stream (requests are sent, then replies are collected).
- **No compression:** requests announce `grpc-accept-encoding: identity`; a compressed reply is an error.
- **No client-side read timeout** (the same limit as [`nox.redis`](redis.md)); use `timeout_ms` so the server enforces the deadline.
- Flow control is handled in both directions (a 300 KB request and a 2 MB reply are tested).
