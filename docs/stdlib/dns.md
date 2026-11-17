# nox.dns

Explicit DNS resolution. `nox.http` resolves a host name by itself while connecting, so a program that validates the address first (SSRF protection) would otherwise resolve twice and could be
fooled by DNS rebinding. `nox.dns.resolve` makes the lookup a separate step; together with `nox.http.request(..., connect_ip=...)` the flow is **resolve → validate → connect to the validated address**.

```text
import nox.dns
import nox.http
import nox.ip

ips: list[str] = nox.dns.resolve("api.example.com", 3000)
for ip in ips:
    if nox.ip.is_global_text(ip):           # see nox.ip
        resp = nox.http.request("GET", "https://api.example.com/", "", {}, 5000, ip)
        break
```

**Capability:** `network`.

| Function | Description |
|---|---|
| `resolve(host: str, timeout_ms: int = 0, doh_url: str = "") -> list[str]` | the A/AAAA addresses of `host` as text (at most 16, in the operating system's RFC 6724 order); `doh_url` is only used on WASM (see below) |

- IP literals (`203.0.113.7`, `[2001:db8::1]`) and `localhost` / `*.localhost` come back without touching the network.
- `timeout_ms > 0` bounds the lookup (`DnsTimeoutError`); with `0` it is bounded by a 2-minute cap. An unresolvable name raises `DnsError` (the function never returns an empty list, so a caller cannot treat "failure" as "allowed").
- Inside a fiber only the calling fiber waits. The lookup shares the bounded, single-flight resolver that `nox.http` uses.
- `DnsCapabilityError` when the `network` capability is denied; `DnsError` on targets without a resolver (freestanding, and WASM unless a `doh_url` is given).
- Address classification (private/loopback/link-local/metadata ranges) is [`nox.ip`](ip.md); `nox.dns` only resolves.

## DNS on WASM (DNS-over-HTTPS)

A browser or WASI module has no system resolver. On `wasm32-freestanding --asyncify` with the host `fetch` capability, pass the URL of a **DoH JSON** resolver (the `application/dns-json` format) as `doh_url`: the lookup is then two `GET` requests (`?name=<host>&type=A` and `&type=AAAA`) through the host's `fetch`.

```text
ips: list[str] = nox.dns.resolve("api.example.com", 3000, "https://doh.example/dns-query")
```

- There is **no default resolver**: the host names you look up are sent only to the server you choose. Without `doh_url` the call raises `DnsError` ("not supported on this target").
- IP literals and `localhost` still need no network. A name with characters other than letters, digits, `-`, `_` and `.` is rejected without a request.
- `DnsTimeoutError` when the host's `fetch` times out, `DnsCapabilityError` when the host grants no network capability, `DnsError` when neither query returns an address (NXDOMAIN or a malformed answer). One of the two queries returning addresses is a success.
- The host's own network policy (`--net-allow`, `--allow-net`) applies to the DoH server like any other `fetch`. The addresses you get are only as trustworthy as that server: validate them with [`nox.ip`](ip.md) before connecting.
