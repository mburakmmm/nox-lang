# Platforms

What is supported, what is tested, and the known gaps.

## Back ends by situation

| Situation | Back end |
|---|---|
| macOS or Linux, hosted, `clang` **or `zig`** on `PATH` | **LLVM** (`.ll` → `clang -O2`, or `zig cc -O2`), the default |
| `--backend qbe` | QBE (`.ssa` → `qbe` → `cc`) |
| freestanding profile, `--target`, `--emit-asm`, `-g` | QBE (automatic) |
| Windows | **LLVM** through `zig cc -target x86_64-windows-gnu` when `zig` is on `PATH` (default); QBE with MinGW `cc` otherwise |
| neither `clang` nor `zig` installed | QBE (automatic, with a note) |

Both back ends run the whole golden corpus and must agree on program output, including fixed-width overflow (a trap on both) and plain `int` wrap-around ([Backends](../tools/backends.md)).

## Support tiers

| Platform | Hosted programs | CI |
|---|---|---|
| macOS arm64 | yes (LLVM or QBE) | full test suite |
| Linux x86-64 | yes (LLVM or QBE) | full test suite |
| Linux aarch64 | yes | full test suite |
| Windows x86-64 | yes — LLVM (`zig cc`) and QBE are smoke-tested end to end (classes, lists, dictionaries, tasks, f-strings, exceptions, TLS and WebSocket) | front-end tests and end-to-end smoke tests (the full suite does not run on Windows) |
| riscv64 | **not supported** | none (freestanding assembly output only) |

macOS x86-64 is expected to work (`macos-x64`) but is not part of CI or the release matrix.

**Freestanding** (bare-metal) builds exist for x86-64 and aarch64: an ELF with the Zig runtime and a kernel-provided allocator. The x86-64 path is proven by booting a real kernel image in QEMU as part of the test suite ([Freestanding](../tools/freestanding.md)).

## Toolchain requirements

| To… | You need |
|---|---|
| compile and run Nox programs | a C toolchain for linking (`cc`); `clang` or `zig` for the LLVM back end; `qbe` is bundled for macOS/Linux |
| build the compiler from source | Zig 0.16 |
| use SQLite / PostgreSQL / MySQL | `libsqlite3` / `libpq` / `libmysqlclient` installed at run time (loaded on first use) |
| use `serve_tls` | an OpenSSL (`libssl`, `libcrypto`) at run time; set `NOX_OPENSSL_LIB` to a specific library path if needed |

## Known constraints

1. **No bundled C compiler.** `clang` is not shipped; the driver falls back to `zig cc` and then to QBE.
2. **Windows** lacks a full-suite CI run; the smoke tests cover the language end to end.
3. **riscv64** has no hosted runtime.
4. **Multi-core parallelism** is a property of the LLVM back end; QBE programs run tasks on one thread.
5. `extern def`, `lowlevel`, NNI plugins and dependencies with native code run with full authority ([Security](security.md)).

## Reporting a platform problem

Include `noxc --version`, the platform, whether `--backend qbe` reproduces it, and the smallest `.nox` program that shows it.
