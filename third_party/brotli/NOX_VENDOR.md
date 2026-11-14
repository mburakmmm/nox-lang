# brotli (vendored, decoder only)

- Upstream: https://github.com/google/brotli, tag **v1.2.1**
- Archive SHA-256 (GitHub tag archive `v1.2.1.tar.gz`): `98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f`
- License: MIT (`LICENSE`)
- Used by: `nox.brotli` (glue `runtime/c_glue/brotli_glue.c`, archive `noxclibs-<target>.a`). Only the decoder is vendored: `c/dec/*`, `c/common/*` (including the built-in 122 KB dictionary) and the public headers `c/include/brotli/{decode,port,types,shared_dictionary}.h`. Unmodified. The encoder (`c/enc`) is not included.
