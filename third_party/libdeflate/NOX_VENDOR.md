# libdeflate (vendored)

- Upstream: https://github.com/ebiggers/libdeflate, tag **v1.23**
- Archive SHA-256 (v1.23.tar.gz): `1ab18349b9fb0ce8a0ca4116bded725be7dcbfa709e19f6f983d99df1fb8b25f`
- License: MIT (see `COPYING`)
- Used by: `nox.gzip` on hosted desktop targets (macOS and Linux; Windows COFF cannot embed several C objects into the runtime object, so it keeps Zig flate) — `runtime/stdlib_shims/gzip.zig`. WebAssembly, mobile and freestanding builds keep Zig's `std.compress.flate`.
- Included: `libdeflate.h`, `common_defs.h`, `lib/` without the zlib wrapper files (`zlib_*`). Unmodified.
- Update: replace the tree from a new upstream tag, update this file, run `zig build test` (the gzip tests cross-check against `std.compress.flate`).
