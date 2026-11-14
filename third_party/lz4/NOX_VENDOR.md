# lz4 (vendored)

- Upstream: https://github.com/lz4/lz4, tag **v1.10.0**
- Archive SHA-256 (v1.10.0 source tarball, GitHub tag archive): `537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b`
- License: BSD-2-Clause for the library (`lib/LICENSE` copied as `LICENSE`)
- Used by: `nox.lz4` on hosted macOS/Linux (`runtime/stdlib_shims/lz4_c.zig`, glue `runtime/c_glue/lz4_glue.c`) via the LZ4 *frame* API (interoperable with the `lz4` CLI).
- Included: `lz4.[ch]`, `lz4hc.[ch]`, `lz4frame.[ch]`, `lz4frame_static.h`, and lz4's own bundled `xxhash.[ch]` (its symbols are namespaced `LZ4F_`). Unmodified.
