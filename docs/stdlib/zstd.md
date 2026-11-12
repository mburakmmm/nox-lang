# nox.zstd

Zstandard **decompression**.

```text
import nox.zstd
from nox.zstd import ZstdError, decompress
```

**Capability:** none, but the module is not available on freestanding (bare-metal) targets, whose memory budget cannot hold the 8 MiB decoder window.

`decompress(data)` decodes one or more concatenated Zstandard frames from a `str` of raw bytes and returns the original bytes as a `str`; it raises `ZstdError` for corrupt or unsupported input. Limits: the decoder window is 8 MiB (streams that need a larger window fail), the output is capped at 1 GiB, dictionaries are not supported, and checksums are not verified.

There is **no compression** function: Zig's standard library only decodes Zstandard. Use [`nox.gzip`](gzip.md) when you need to compress.

```nox
import nox.base64
import nox.zstd

# "hello hello hello hello" compressed by zstd
packed: str = nox.base64.decode("KLUv/SAXZQAAMGhlbGxvIAEAmUsR")
print(nox.zstd.decompress(packed))
```

```output
hello hello hello hello
```
