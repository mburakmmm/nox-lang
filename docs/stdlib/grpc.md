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
| `connect_tls(host, port, ca_file="", cert_file="", key_file="") -> Client` | the same over TLS with ALPN `h2`. The server name is checked against the certificate. An empty `ca_file` uses the system CA store; a PEM path trusts only the CAs in that file (a private CA, a self-signed server). `cert_file` + `key_file` (PEM) present a client certificate when the server asks for one (mTLS); the key must be ECDSA P-256, ECDSA P-384 or Ed25519 (RSA keys are not supported: the standard library cannot sign with RSA) |
| `Client.unary(path, request, timeout_ms=0) -> str` | one request, one reply message; a status other than `OK` raises `GrpcStatusError` (`code`, `detail`) |
| `Client.call(path, requests, timeout_ms=0) -> Response` | any RPC shape: one or more request messages (client streaming), all reply messages collected (server streaming). The status is in the `Response`, not raised |
| `Client.call_with(path, requests, metadata, timeout_ms) -> Response` | the same with request metadata (`dict[str, str]`) |
| `Client.open_stream(path, metadata, timeout_ms=0) -> Stream` | a bidirectional stream: requests and replies interleave (see below) |
| `Client.close()`, `Client.is_ok()` | close; whether the connection is still usable |
| `Response.status`, `.message`, `.messages`, `.ok()`, `.header(name)` | gRPC status code, status message, reply messages, response header or trailer value (case-insensitive, `""` if absent) |

`path` is `/package.Service/Method`. Status constants (`nox.grpc.NOT_FOUND`, `UNAVAILABLE`, ...) follow the gRPC status codes. `timeout_ms > 0` is sent as `grpc-timeout`; the server
answers `DEADLINE_EXCEEDED` when it runs out.

## Bidirectional streams

`open_stream` returns a `Stream` for calls where requests and replies interleave (chat-like RPCs, or a server that answers each request before the next is sent):

```text
st: Stream = c.open_stream("/chat.Room/Talk", metadata)
st.send(first)
reply: str | None = st.recv()     # blocks (cooperatively) until a reply or the end of the stream
st.close_send()                   # no more requests; the server may finish
while st.recv() is not None:
    pass
print(st.status(), st.message(), st.header("x-trailer"))
```

`recv()` returns `None` once the server has finished the call; then `status()`, `message()` and `header(name)` hold the result. `finish()` reads and discards the rest and returns the status.
Only one stream (or `call`) can be open on a connection at a time. Letting a `Stream` go out of scope before it ends cancels the call (`RST_STREAM`) and frees the connection for the next one;
release or finish streams **before** `Client.close()`.

## Errors

- A transport or protocol failure (connection lost, malformed frame, `GOAWAY`, a stream reset) raises `GrpcError` and closes the connection; open a new one with `connect`.
- A server status is data: `Response.status`, or `GrpcStatusError` from `unary`. The status message is percent-decoded.

## Limits

- **TLS needs TLS 1.3 ALPN support from the server** (the usual case for gRPC servers); a server that does not select `h2` makes `connect_tls` fail. Client certificates: ECDSA P-256/P-384 and Ed25519 keys only (TLS 1.3). Not available when compiled to WebAssembly.
- **One call or stream at a time** per connection (open several connections for parallel calls). `call` sends all requests and then collects the replies; use `open_stream` to interleave.
- **Compression:** gzip only. Requests announce `grpc-accept-encoding: gzip,identity` and gzip replies are decoded automatically; `Client.use_compression(True)` gzips the request messages too. Any other `grpc-encoding` is an error.
- **No client-side read timeout** (the same limit as [`nox.redis`](redis.md)); use `timeout_ms` so the server enforces the deadline.
- Flow control is handled in both directions (a 300 KB request and a 2 MB reply are tested).
