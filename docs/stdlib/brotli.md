# nox.brotli

Brotli **decompression** (HTTP `Content-Encoding: br`, `.br` files, WOFF2 payloads). It uses the reference C decoder (MIT, `third_party/brotli`, including the built-in 122 KB dictionary).

```text
import nox.brotli
from nox.brotli import BrotliError, decompress, is_supported
```

**Capability:** none. The C library is shipped as a separate archive linked only into programs that import this module; it behaves identically on **macOS, Linux and Windows**. It is not available on WebAssembly, mobile and bare-metal targets. There is no compressor: use `nox.zstd.compress`, `nox.lz4.compress` or `nox.gzip` to produce data.

- `decompress(data, max_output=0)` returns the original bytes of a brotli stream held in a `str`. It raises `BrotliError` for corrupt or truncated input, for bytes after the end of the stream, and when the output would exceed `max_output` bytes (0 means the 1 GiB default; a guard against decompression bombs).

Speed: 4 MB of text from a 0.75 MB stream decodes in about 5.7 ms (the C decoder alone: 4.8 ms).

```nox
import nox.brotli
import nox.base64

data: str = nox.base64.decode("Hy4A+I2Ubt5EVYaWbCBvYU8cYOIA")
print(nox.brotli.decompress(data))
```

```output
hello hello hello hello hello hello hello hello
```
