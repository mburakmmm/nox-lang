# Use the embedded C libraries

Six standard-library modules are backed by well-known C libraries that ship with Nox. They are real wrappers with Nox semantics: errors are Nox exceptions, strings are Nox strings, and nothing leaks.

| Module | Library | What it does |
|---|---|---|
| [`nox.lz4`](../stdlib/lz4.md) | LZ4 | frame compression, very fast |
| [`nox.xxhash`](../stdlib/xxhash.md) | xxHash | fast non-cryptographic hashes |
| [`nox.yyjson`](../stdlib/yyjson.md) | yyjson | JSON read and write, the fastest reader in the standard library |
| [`nox.pcre2`](../stdlib/pcre2.md) | PCRE2 with JIT | Perl-compatible regular expressions |
| [`nox.brotli`](../stdlib/brotli.md) | Brotli | decompression |
| [`nox.zstd`](../stdlib/zstd.md) | Zstandard | compression (the C library); decompression is built in |

They sit **next to** the pure modules (`nox.json`, `nox.regex`, ...), which are unchanged. Reach for the C-backed one when speed matters or when you need its exact semantics (for example Perl-style look-behind).

## How they are linked

The C code lives in one archive, `lib/noxclibs.a` (and `noxclibs-<target>.a` for cross targets). A program links it **only if it imports one of these modules**, so programs that do not use them do not grow. It behaves identically on macOS, Linux and Windows.

Each module except `nox.zstd` has `is_supported()`. It returns `True` in any program that has the library linked, which is every program that can call it, so it is mostly useful as a feature probe in library code that wants one code path for all modules.

```sh
noxc build main.nox -o app          # links lib/noxclibs.a because main.nox imports nox.lz4
```

## Where they are not available

- **Mobile targets (iOS, Android):** the archive is not linked. Importing `nox.lz4`, `nox.xxhash`, `nox.yyjson` or `nox.brotli` is a compile-time error that says so, and `nox.pcre2` is rejected by the mobile capability rules. `nox.zstd.decompress` works; `nox.zstd.compress` needs the archive and cannot be linked there.
- **WebAssembly:** `noxc build --target wasm32-wasi` stops with "this target has no embedded C libraries" for a program that imports one of these modules.
- **Builds that deny `dynamic_code`:** `nox.pcre2` is rejected (the JIT generates machine code); use `nox.regex` instead.

## Installing

Release archives and installers from 2.1.176 include `lib/noxclibs.a`. If you installed an earlier release, `noxc upgrade` brings it. When you build the compiler from source, `zig build` produces `zig-out/lib/noxclibs.a`.
