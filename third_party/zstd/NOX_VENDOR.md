# zstd (vendored)

- Upstream: https://github.com/facebook/zstd, tag **v1.5.7**
- Archive SHA-256 (zstd-1.5.7.tar.gz, release asset): `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`
- License: BSD-3-Clause (see `LICENSE`; zstd is dual BSD/GPLv2, Nox uses it under BSD)
- Used by: `nox.zstd.compress` on hosted macOS/Linux (`runtime/stdlib_shims/zstd_c.zig`, glue `runtime/c_glue/zstd_glue.c`). Decompression still uses Zig's `std.compress.zstd` (`nox.zstd.decompress`, 8 MiB window); compressed frames are capped at windowLog 23 so both agree.
- Included: `lib/zstd.h`, `lib/zstd_errors.h`, `lib/common`, `lib/compress`, `lib/decompress` (no `huf_decompress_amd64.S`: built with `ZSTD_DISABLE_ASM`; no dictBuilder/legacy/threading: `ZSTD_MULTITHREAD` is off). Unmodified.
- Update: replace the tree from a new upstream tag, update this file, run `zig build test` (round-trip tests cross-check against `std.compress.zstd`).
