# nox.zlib

zlib (RFC 1950) and raw deflate (RFC 1951) containers, plus the `crc32` (IEEE 802.3) and `adler32` (RFC 1950) checksums. Use [`nox.gzip`](gzip.md) for gzip (RFC 1952).

```text
import nox.zlib
from nox.zlib import ZlibError
```

**Capability:** none. Works on every target, including WebAssembly and `freestanding`.

## Functions

| Function | Description |
|---|---|
| `compress(data)` | `list[int]` of byte values → zlib stream (2-byte header + deflate + Adler-32) |
| `decompress(data)` | zlib stream → `list[int]`; raises `ZlibError` for corrupt, truncated or non-zlib input |
| `deflate(data)` | raw deflate stream, no header or checksum (ZIP entries, PNG `IDAT` payloads) |
| `inflate(data)` | raw deflate stream → `list[int]` |
| `crc32(data, prev=0)` | CRC-32 as an unsigned 32-bit value in an `int`; pass the previous result as `prev` to continue |
| `crc32_str(text, prev=0)` | CRC-32 of the UTF-8 bytes of `text` |
| `adler32(data, prev=1)` | Adler-32; pass the previous result as `prev` to continue (the start value is `1`) |
| `adler32_str(text, prev=1)` | Adler-32 of the UTF-8 bytes of `text` |

Bytes are `list[int]` (values 0–255), exactly as in `nox.gzip`; a value outside that range raises `ZlibError`.

```nox
import nox.zlib

z: list[int] = nox.zlib.compress([1, 2, 3, 4, 5, 6, 7, 8])
print(nox.zlib.decompress(z))
print(nox.zlib.crc32_str("123456789"))
print(nox.zlib.adler32_str("123456789"))
part: int = nox.zlib.crc32_str("1234")
print(nox.zlib.crc32_str("56789", part))
```

```output
[1, 2, 3, 4, 5, 6, 7, 8]
3421780262
152961502
3421780262
```

## Notes

- Whole inputs are processed in memory. Unlike `nox.gzip` there is no libdeflate fast path: every target uses Zig's `std.compress.flate`.
- The decompressed size is not capped; bound untrusted input before calling it.
