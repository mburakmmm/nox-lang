# nox.tls

A client TLS stream: connect to a host and port, then read and write text over an encrypted connection. Certificates are verified against the operating system's trust store.

```text
from nox.tls import connect, TlsStream, TlsError
```

**Capability:** `network`.

## Functions

| Function / method | Description |
|---|---|
| `connect(host, port)` | connects and completes the TLS handshake; returns a `TlsStream`; raises `TlsError` on connection or certificate failure |
| `write(data)` | sends `data`; returns the number of bytes written; raises `TlsError` on failure |
| `read(max_len)` | reads **at most** `max_len` bytes; returns the **empty string** when the peer closed cleanly (not an error — it means "no more data") |
| `is_open()` | whether the stream is still usable |
| `close()` | closes it (idempotent) |

Using a stream after `close()` raises `TlsError`.

```nox
from nox.tls import connect, TlsStream, TlsError

def head(host: str) -> str:
    try:
        s: TlsStream = connect(host, 443)
        s.write("HEAD / HTTP/1.0\r\nHost: " + host + "\r\n\r\n")
        first: str = s.read(64)
        s.close()
        return first
    except TlsError as e:
        return "tls failed"

print(head("localhost.invalid"))
```

```output
tls failed
```

## Notes

- Operations are synchronous at the call site; other tasks keep running while one waits.
- Server-side TLS is part of [`nox.http`](http.md) (`serve_tls`), which needs a PEM certificate and key.
- For HTTPS requests use [`nox.http.get`](http.md#client), which uses this machinery internally.
