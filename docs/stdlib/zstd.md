# nox.zstd

Zstandard **compression and decompression**.

```text
import nox.zstd
from nox.zstd import ZstdError, compress, decompress
```

**Capability:** none, but the module is not available on freestanding (bare-metal) targets, whose memory budget cannot hold the 8 MiB decoder window.

`decompress(data)` decodes one or more concatenated Zstandard frames from a `str` of raw bytes and returns the original bytes as a `str`; it raises `ZstdError` for corrupt or unsupported input. Limits: the decoder window is 8 MiB (streams that need a larger window fail), the output is capped at 1 GiB, dictionaries are not supported, and checksums are not verified.

`compress(data, level=3)` compresses a `str` of raw bytes into one Zstandard frame (level 1 to 19, negative levels are faster; out-of-range values are clamped). It uses the embedded C zstd library (BSD-3, `third_party/zstd`), shipped as a separate archive that is linked **only into programs that use `compress`**, so the feature is identical on macOS, Linux and Windows and costs nothing otherwise. Frames carry the content size and a checksum and use a window of at most 8 MiB, so they always decode with `decompress`. (`compress` does not exist on WebAssembly, mobile and bare-metal targets; programs there that only call `decompress` are unaffected.) On iOS and Android a call to `compress` is a compile-time error (the C library is not linked there); `decompress` works.

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
