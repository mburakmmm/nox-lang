# nox.udp

UDP datagram sockets, for telemetry (statsd, syslog), discovery and simple request/response protocols.

```text
import nox.udp
```

**Capability:** `network`. POSIX only (macOS, Linux, Android, iOS): on Windows and in WebAssembly `is_supported()` is `False`.

```text
import nox.udp
from nox.udp import UdpSocket, Datagram, UdpError

rx: UdpSocket = nox.udp.bind("127.0.0.1", 0)        # port 0: the OS picks one
tx: UdpSocket = nox.udp.open()                      # a send-only socket
tx.send_to("127.0.0.1", rx.local_port(), "ping")
d: Datagram = rx.recv(2048, 1000)                   # at most 2048 bytes, 1 s timeout
print(d.data, d.host, d.port)
rx.send_to(d.host, d.port, "pong")                  # reply to the sender
```

| Function | Description |
|---|---|
| `bind(host, port, ipv6=False, reuse=False, broadcast=False)` | a socket bound to `host:port` (`""` = all interfaces, `0` = OS-chosen port) |
| `open(ipv6=False, broadcast=False)` | a send-only socket on an OS-chosen port |
| `is_supported()` | can UDP be used on this target? |

`UdpSocket`:

| Member | Description |
|---|---|
| `local_port()` | the bound port (useful after `bind(…, 0)`) |
| `send_to(host, port, data)` | sends `data` (a `str`) as one datagram; returns the byte count |
| `send_bytes_to(host, port, data)` | the same for a `list[int]` of byte values |
| `recv(max_len=65507, timeout_ms=-1)` | receives one datagram as a `Datagram`; longer datagrams are truncated to `max_len` |
| `close()` | closes the socket; calling it twice is harmless |

`Datagram` has `data` (`str`), `host` (the sender's numeric address), `port` (the sender's port) and `to_bytes()` (`list[int]`).

## Behaviour

- **Fibers.** `recv` inside a task suspends only that task; other tasks keep running. Outside a task it waits with `poll`. `timeout_ms < 0` waits forever, `0` polls.
- **Bytes are exact.** A `str` carries every byte, NUL included, so binary payloads (protobuf, gzip output via `nox.bytes.str_from_list`) round-trip unchanged. The limit is 65507 bytes per datagram.
- **Errors.** Everything raises `UdpError`; its `kind` is `"timeout"` (see `is_timeout()`), `"closed"` or `"io"`.
- **Address family.** It is chosen when the socket is opened (IPv4 by default, `ipv6=True` for a dual-stack IPv6 socket). Sending to a name resolves it with a *blocking* `getaddrinfo`; IP literals and `localhost` resolve immediately.
- **UDP is unreliable.** Loss, reordering and duplication are yours to handle.
