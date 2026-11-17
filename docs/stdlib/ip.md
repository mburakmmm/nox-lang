# nox.ip

IPv4/IPv6 address parsing and classification — the "validate" step of a resolve → validate → connect defence against SSRF and DNS rebinding. Pure Nox: no network, no capability.

```nox
import nox.ip
import nox.dns
import nox.http

def safe_get(host: str) -> int:
    for ip in nox.dns.resolve(host, 3000):
        if nox.ip.is_global_text(ip):
            resp: nox_http_HttpResponse = nox.http.request("GET", "https://" + host + "/", "", {}, 5000, ip)
            return resp.status
    return 0
```

| Function / method | Description |
|---|---|
| `parse(text) -> IpAddress` | parses an IPv4 or IPv6 literal (`[::1]` URL form accepted); raises `IpError` otherwise |
| `is_valid(text) -> bool` | `parse` succeeds |
| `is_global_text(text) -> bool` | valid **and** `is_global()`; an invalid literal is `False` (fail closed) |
| `a.version`, `a.octets` | `4` or `6`; 4 or 16 values 0–255 |
| `a.text()` | canonical text (IPv6 per RFC 5952, IPv4-mapped as `::ffff:a.b.c.d`) |
| `a.is_global()` | publicly routable unicast: none of the categories below |
| `a.is_loopback()`, `a.is_private()`, `a.is_link_local()`, `a.is_cgnat()`, `a.is_multicast()`, `a.is_unspecified()` | `127/8` and `::1`; RFC 1918 and `fc00::/7`; `169.254/16` and `fe80::/10`; `100.64/10`; `224/4` and `ff00::/8`; `0.0.0.0` and `::` |
| `a.is_metadata()` | well-known cloud metadata endpoints (`169.254.169.254`, `169.254.170.2`, `100.100.100.200`, `192.0.0.192`, `fd00:ec2::254`) |
| `a.is_reserved()` | documentation, benchmarking, IETF protocol assignments, `240/4` (including broadcast), `0/8`, `100::/64`, `2001::/23`, `2001:db8::/32`, `2002::/16`, `3fff::/20`, `64:ff9b:1::/48` |
| `a.is_ipv4_mapped()`, `a.is_nat64()`, `a.unmap()` | `::ffff:a.b.c.d`; `64:ff9b::/96`; the embedded IPv4 address (or the address itself) |

Notes:

- `parse` **rejects** ambiguous forms: a leading zero (`010.0.0.1`, octal in some parsers), `0x7f.1` and short forms such as `127.1`, IPv6 zone ids (`fe80::1%eth0`), and a second `::`.
- IPv4-mapped (`::ffff:127.0.0.1`) and NAT64 addresses are classified by the IPv4 address they carry, so the common mapped-loopback bypass is `False` for `is_global()`.
- `is_global()` treats multicast as not global, which is stricter than Python's `ipaddress`; everything else agrees with it (the golden `ip_classify` is checked against Python on 72 valid and 22 invalid inputs).
- Classification is address-based only. It cannot know about your own private networks; combine it with an allow-list of hosts you trust.
