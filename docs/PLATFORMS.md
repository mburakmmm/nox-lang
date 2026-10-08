# Platform support and known constraints (as of v1.165)

This page states what is supported, what is tested in CI, and the known gaps. It is the platform half of the
[2.0 readiness roadmap](v2-hazirlik-yol-haritasi.md) (section 3).

## Backends

| Situation | Backend used |
|---|---|
| macOS / Linux, hosted, `clang` **or `zig`** on `PATH` | **LLVM** (`.ll` → `clang -O2`, or `zig cc -O2` when `clang` is absent), the default |
| `--backend qbe` | QBE (`.ssa` → `qbe` → `cc`) |
| freestanding profile, `--target`, `--emit-asm` | QBE (automatic) |
| Windows | **LLVM** via `zig cc -target x86_64-windows-gnu` when `zig` is on `PATH` (default); QBE + MinGW `cc` otherwise |
| neither `clang` nor `zig` installed | QBE (automatic, a note is printed) |

Both backends run the entire golden corpus and must agree on program output, including fixed-width integer overflow
(`u8`, `i32`, … trap with a message on both since v1.169.0). Plain `int` (64-bit) wraps on both.

## Tier table

| Platform | Compiler front end | Hosted programs | CI |
|---|---|---|---|
| macOS arm64 | yes | yes (LLVM or QBE) | full test suite |
| Linux x86-64 | yes | yes (LLVM or QBE) | full test suite |
| Linux aarch64 | yes | yes | full test suite (see "aarch64 watch" below) |
| Windows x86-64 | yes | yes — LLVM (`zig cc`) and QBE both smoke-tested end to end (classes, lists, dicts, spawn, f-strings, exceptions) | front-end tests + end-to-end smoke + TLS/WebSocket checks (no full test suite) |
| riscv64 | — | **not supported** | none (freestanding `--emit-asm` only) |

Freestanding (bare-metal) builds exist for x86-64 and aarch64 (`--profile freestanding --target …`): an ELF with the Zig
runtime and a kernel-provided allocator. The x86-64 path is proven by booting a real kernel image in QEMU
(`zig build kernel-boot-test`, `zig build freestanding-dogfood-test`).

## Toolchain requirements

- Building the compiler: Zig 0.16.
- Compiling a hosted Nox program: a C toolchain for linking (`cc`/`clang`); `qbe` for the QBE backend (the release archive
  bundles `qbe`); `clang` or `zig` for the default LLVM backend (**not bundled**; with neither on `PATH` QBE is selected and a note is printed).
- WASM is a library-import mechanism, never a compile target.

## Known constraints

1. **Windows:** the LLVM backend links through `zig cc` (MinGW target) and is smoke-tested in CI; the full unit/golden suite does
   not run on Windows yet. Without `zig` the QBE + MinGW `cc` path is used (also smoke-tested).
2. **`clang` is not bundled.** Mitigated in 2.0: the driver falls back to `zig cc` (Zig's clang + LLD) when `clang` is missing, and to QBE when neither exists; `tests/cli/zig_cc_fallback_test.zig` covers it. A fully bundled toolchain is still open.
3. **aarch64 watch:** a stack-smash seen occasionally on aarch64 in the HTTP server tests had the same root cause as its x86-64 twin (a dangling stack pointer, fixed in v1.142.3/v1.142.21); the
   `continue-on-error` workaround was removed and 40+ consecutive CI runs have been clean. If it
   reappears, investigate the root cause rather than re-adding an allow-failure.
4. **riscv64** has no hosted runtime; only freestanding assembly output.
5. `extern def` and `lowlevel` are an unsandboxed trust boundary (see [`ARCHITECTURE.en.md`](ARCHITECTURE.en.md)).

## Reporting

A platform bug report should include `noxc --version`, the platform triple, whether `--backend qbe` reproduces it, and the
smallest `.nox` program that shows it.
