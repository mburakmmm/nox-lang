# xxHash (vendored)

- Upstream: https://github.com/Cyan4973/xxHash, tag **v0.8.3**
- Archive SHA-256 (v0.8.3 source tarball, GitHub tag archive): `aae608dfe8213dfd05d909a57718ef82f30722c392344583d3f39050c7f29a80`
- License: BSD-2-Clause (library; see `LICENSE`)
- Used by: `nox.xxhash` (`xxh32`, `xxh64`, `xxh3_64`, `xxh3_128`) on hosted macOS/Linux (`runtime/stdlib_shims/hash_c.zig`, glue `runtime/c_glue/xxh_glue.c`). Not cryptographic.
- Included: `xxhash.c`, `xxhash.h`, `xxh3.h`. Unmodified.
