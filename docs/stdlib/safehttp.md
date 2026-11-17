# nox.safehttp

An HTTP client that is safe to point at **untrusted URLs** (webhooks, link previews, "fetch this image" features). It refuses to talk to internal addresses and cannot be tricked by DNS rebinding or by a redirect into your network.
Pure Nox, built on [`nox.dns`](dns.md), [`nox.ip`](ip.md) and `nox.http.request(..., connect_ip=...)`.

**Capability:** `network`.

```nox
import nox.http
import nox.safehttp

try:
    r: nox_http_HttpResponse = nox.safehttp.request("GET", "https://example.com/preview", "", {}, 5000)
    print(r.status)
except nox.safehttp.SafeHttpBlockedError as e:
    print("refused:", e.message)
```

For every request **and every redirect hop** it:

1. accepts only `http`/`https` URLs without embedded credentials;
2. resolves the host name once (`nox.dns`) — an IP literal is used as is;
3. requires **every** resolved address to be globally routable (`nox.ip` `is_global()`): loopback, private (RFC 1918, `fc00::/7`), link-local, CGNAT, multicast, reserved and cloud-metadata addresses (`169.254.169.254` and friends) block the request, including IPv4-mapped forms such as `::ffff:127.0.0.1`;
4. connects to the **validated address** (`connect_ip`), so the name is never resolved a second time; TLS still verifies the certificate against the original host name.

| Call | Description |
|---|---|
| `request(method, url, body, headers, timeout_ms=10000, max_redirects=5, allow_private=False, allow_hosts="") -> HttpResponse` | the safe request; raises `SafeHttpBlockedError` (a `SafeHttpError`) when an address is not allowed, `SafeHttpError` for a bad URL, an unresolvable host, too many redirects or no reachable address, `HttpTimeoutError` on a timeout |

- Redirects (`301/302/303/307/308`) are followed by hand and each new location is checked like the first request. `303` (and `301`/`302` after a `POST`) become `GET` without a body. When the host changes, `Authorization`, `Cookie` and `Proxy-Authorization` headers are dropped.
- `allow_hosts` is a comma-separated list of host names or IP literals you **do** want to reach even though they are internal (`"db.internal,127.0.0.1"`); the address check is skipped for those names only, on every hop.
- `allow_private=True` switches the address check off (local development and tests only).
- It does not use the connection pool, HTTP/3 or `HTTP_PROXY`/`HTTPS_PROXY` (a proxy would resolve the name for you), and it does not read the response body before the headers have been checked — but it does not limit the body size either; set limits in your own code when fetching untrusted content.
