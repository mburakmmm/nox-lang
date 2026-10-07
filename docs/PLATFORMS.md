# Platform support and known constraints (as of v1.165)

This page states what is supported, what is tested in CI, and the known gaps. It is the platform half of the
[2.0 readiness roadmap](v2-hazirlik-yol-haritasi.md) (section 3).

## Backends

| Situation | Backend used |
|---|---|
| macOS / Linux, hosted, `clang` on `PATH` | **LLVM** (`.ll` → `clang -O2`), the default |
| `--backend qbe` | QBE (`.ssa` → `qbe` → `cc`) |
| freestanding profile, `--target`, `--emit-asm` | QBE (automatic) |
| Windows | QBE (automatic: the LLVM path has no MinGW link arguments yet) |
| `clang` not installed | QBE (automatic, a note is printed) |

Both backends run the entire golden corpus and must agree on program output, including fixed-width integer overflow
(`u8`, `i32`, … trap with a message on both since v1.169.0). Plain `int` (64-bit) wraps on both.

## Tier table

| Platform | Compiler front end | Hosted programs | CI |
|---|---|---|---|
| macOS arm64 | yes | yes (LLVM or QBE) | full test suite |
| Linux x86-64 | yes | yes (LLVM or QBE) | full test suite |
| Linux aarch64 | yes | yes | full test suite (see "aarch64 watch" below) |
| Windows x86-64 | yes | via QBE only, **not** exercised end to end | front-end tests only |
| riscv64 | — | **not supported** | none (freestanding `--emit-asm` only) |

Freestanding (bare-metal) builds exist for x86-64 and aarch64 (`--profile freestanding --target …`): an ELF with the Zig
runtime and a kernel-provided allocator. The x86-64 path is proven by booting a real kernel image in QEMU
(`zig build kernel-boot-test`, `zig build freestanding-dogfood-test`).

## Toolchain requirements

- Building the compiler: Zig 0.16.
- Compiling a hosted Nox program: a C toolchain for linking (`cc`/`clang`); `qbe` for the QBE backend (the release archive
  bundles `qbe`); `clang` for the default LLVM backend (**not bundled**; its absence silently selects QBE).
- WASM is a library-import mechanism, never a compile target.

## Known constraints

1. **Windows:** LLVM backend not wired for MinGW linking; CI exercises only the compiler front end. Treat Windows as
   "compiles Nox code to QBE IR and links with the platform C toolchain, best effort".
2. **`clang` is not bundled.** A permanent fix (a bundled clang or `zig cc` as the linker driver) is still open.
3. **aarch64 watch:** a stack-smash seen occasionally on aarch64 in the HTTP server tests has an unverified root cause (the
   x86-64 twin was a dangling pointer, fixed in v1.142.3). The `continue-on-error` workaround was removed in v1.142.21; if it
   reappears, investigate the root cause rather than re-adding an allow-failure.
4. **riscv64** has no hosted runtime; only freestanding assembly output.
5. `extern def` and `lowlevel` are an unsandboxed trust boundary (see [`ARCHITECTURE.en.md`](ARCHITECTURE.en.md)).

## Reporting

A platform bug report should include `noxc --version`, the platform triple, whether `--backend qbe` reproduces it, and the
smallest `.nox` program that shows it.
