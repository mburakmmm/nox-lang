# nox.gzip

Compress and decompress gzip data (RFC 1952).

```text
import nox.gzip
from nox.gzip import GzipError
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `compress(text)` | gzips the UTF-8 bytes of `text`; returns the compressed bytes as a `list[int]` (values 0–255) |
| `decompress(data)` | gunzips to a `str`; raises `GzipError` for corrupt or non-gzip input |
| `compress_bytes(data)` | gzips a `list[int]` of byte values |
| `decompress_bytes(data)` | gunzips to a `list[int]` |

Bytes are represented as `list[int]` here. For fixed-size binary work see [`nox.buffer`](buffer.md).

```nox
import nox.gzip
from nox.gzip import GzipError

c: list[int] = nox.gzip.compress("hello hello hello hello")
print(len(c) > 0, nox.gzip.decompress(c))
print(nox.gzip.decompress_bytes(nox.gzip.compress_bytes([1, 2, 3, 4])))
try:
    nox.gzip.decompress([1, 2, 3])
except GzipError as e:
    print("not gzip")
```

```output
True hello hello hello hello
[1, 2, 3, 4]
not gzip
```

## Notes

- `nox.http` decompresses gzip and deflate response bodies automatically; use this module for your own data.
- Whole inputs are processed in memory.
