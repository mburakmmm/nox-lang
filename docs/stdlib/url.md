# nox.url

Parse URLs, percent-encode and decode text, and build or read query strings.

```text
import nox.url
from nox.url import URL, UrlError
```

**Capability:** none.

## `URL` and `parse`

`parse(s)` splits an absolute URL into a `URL` with these fields:

| Field | Type | Example for `https://user:pw@example.com:8443/a/b?x=1&y=two#frag` |
|---|---|---|
| `scheme` | `str` | `https` |
| `userinfo` | `str` | `user:pw` |
| `host` | `str` | `example.com` |
| `port` | `int` | `8443` (0 when absent) |
| `path` | `str` | `/a/b` |
| `query` | `dict[str, str]` | `{'x': '1', 'y': 'two'}` (decoded) |
| `fragment` | `str` | `frag` |

A malformed URL raises `UrlError`.

## Functions

| Function | Description |
|---|---|
| `parse(s)` | see above |
| `percent_encode(s)` | encodes every byte outside the unreserved set (`A–Z a–z 0–9 - _ . ~`) as `%XX`, operating on UTF-8 bytes |
| `percent_decode(s)` | the inverse |
| `query_encode(params)` | `k=v&k2=v2` with both parts percent-encoded |
| `query_decode(s)` | parses a query string into a dictionary (decoded) |
| `query_int(q, key)`, `query_float(q, key)`, `query_bool(q, key)` | typed access to a decoded query dictionary; a missing key or a value of the wrong form raises `ValueError` |
| `join(base, relative)` | resolves a relative reference against a base URL (it replaces the last path segment; `..` segments are kept as written) |

```nox
import nox.url
from nox.url import URL

u: URL = nox.url.parse("https://user:pw@example.com:8443/a/b?x=1&y=two#frag")
print(u.scheme, u.userinfo, u.host, u.port, u.path, u.query["y"], u.fragment)
print(nox.url.percent_encode("a b&c/é"), nox.url.percent_decode("a%20b%26c"))
print(nox.url.query_encode({"q": "a b", "n": "1"}), nox.url.query_decode("a=1&b=x%20y"))
q: dict[str, str] = {"n": "42", "f": "2.5", "b": "true"}
print(nox.url.query_int(q, "n"), nox.url.query_float(q, "f"), nox.url.query_bool(q, "b"))
print(nox.url.join("https://example.com/a/", "d?e=1"))
try:
    nox.url.query_int(q, "missing")
except ValueError as e:
    print("missing or malformed")
```

```output
https user:pw example.com 8443 /a/b two frag
a%20b%26c%2F%C3%A9 a b&c
q=a%20b&n=1 {'a': '1', 'b': 'x y'}
42 2.5 True
https://example.com/a/d?e=1
missing or malformed
```

## Notes

- Percent-encoding works on bytes, so non-ASCII text round-trips exactly.
- Query dictionaries keep one value per key (the last one wins for repeated keys).
