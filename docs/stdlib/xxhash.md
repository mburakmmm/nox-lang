# nox.xxhash

[xxHash](https://xxhash.com): extremely fast **non-cryptographic** hashes (cache keys, deduplication, sharding). For anything security-sensitive use `nox.crypto`.

```text
import nox.xxhash
from nox.xxhash import xxh32, xxh64, xxh3_64, xxh64_hex, xxh3_64_hex, xxh3_128_hex, is_supported
```

**Capability:** none. The embedded C xxHash (BSD-2, `third_party/xxhash`) is shipped as a separate archive linked only into programs that import this module; identical on **macOS, Linux and Windows** (not available on WebAssembly, mobile and bare-metal targets). The 64-bit results are returned as a signed `int` with the same bit pattern (the top bit set shows as negative); the `*_hex` functions show the unsigned value as 16 lower-case hex digits (`xxh3_128_hex`: 32 digits, canonical big-endian order). All functions take an optional `seed`.

```nox
import nox.xxhash

print(nox.xxhash.xxh64_hex(""), nox.xxhash.xxh3_64_hex(""))
```

```output
ef46db3751d8e999 2d06800538d394c2
```
