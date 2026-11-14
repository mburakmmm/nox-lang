# nox.lz4

LZ4 **frame** compression: very fast, modest ratio (the same format as the `lz4` command-line tool).

```text
import nox.lz4
from nox.lz4 import Lz4Error, compress, decompress, is_supported
```

**Capability:** none. The embedded C library (BSD-2, `third_party/lz4`) is shipped as a separate archive linked only into programs that import this module; it behaves identically on **macOS, Linux and Windows**. The module is not available on WebAssembly, mobile and bare-metal targets (the link fails with a clear message).

- `compress(data, level=0)` returns an LZ4 frame for a `str` of raw bytes. `level` 0 is the fast default; 1 to 12 select the slower high-compression (HC) encoder. The frame stores the content size and a content checksum.
- `decompress(data)` returns the original bytes; it raises `Lz4Error` for corrupt, truncated or trailing-garbage input and caps the output at 1 GiB.

```nox
import nox.lz4

packed: str = nox.lz4.compress("hello hello hello hello")
print(nox.lz4.decompress(packed))
```

```output
hello hello hello hello
```
