# Compilation backends

Nox compiles the typed program to one of two back ends, which are tested against the same corpus and must produce **identical program output**.

| | **LLVM** (default) | **QBE** |
|---|---|---|
| Pipeline | typed IR → LLVM IR (`.ll`) → `clang -O2` (or `zig cc -O2`) → native | typed IR → QBE IL (`.ssa`) → `qbe` → assembly → `cc` → native |
| Code speed | faster (roughly 1.5× C on a mixed benchmark suite) | good (roughly 1.7× C) |
| Compile speed | fast | fast |
| Scheduler | **multi-core M:N work-stealing** with atomic reference counts | the same M:N scheduler (since 2.1.111); atomic reference counts only in programs that use tasks or threads |
| Needs | `clang` or `zig` on `PATH` | the bundled `qbe`, and a C compiler for linking |
| Debug info (`-g`) | no | yes (DWARF line tables) |
| `--target` cross-compile (desktop) | yes, needs `zig` (`zig cc -O2 -target`) | yes |
| `--emit-asm`, freestanding | no | yes |

## How the backend is chosen

`--backend llvm` and `--backend qbe` always win. Otherwise (`auto`):

1. **freestanding** builds, `--emit-asm` and `-g` → QBE. A desktop `--target` (`macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`, `linux-riscv64`, `windows-x64`) goes to LLVM when `zig` is on `PATH` (the `.ll` file is cross-linked with `zig cc -O2 -target <triple>`, so cross-built programs run at `-O2` speed and a Windows `.exe` does not depend on QBE's `amd64_win` back end), otherwise to QBE. Mobile names (`ios-arm64`, `ios-simulator-arm64`, `android-arm64`, `android-x64`) and `wasm32-wasi`/`wasm32-freestanding` stay on LLVM; `--backend qbe` is an error;
2. on **Windows**, LLVM when `zig` is installed (it links with `zig cc -target x86_64-windows-gnu`), otherwise QBE with MinGW `cc`;
3. on macOS and Linux, LLVM when `clang` or `zig` is on `PATH`; with neither, QBE and a one-line note;
4. otherwise LLVM.

Asking for LLVM together with `-g`, `--emit-asm` or freestanding is an explicit error rather than a silent switch.

### The C driver

The LLVM path needs a C toolchain driver to optimise and link the `.ll` file. `noxc` tries `clang` first, then `zig cc` (Zig's bundled clang and LLD), so a machine with only Zig installed
works. The QBE path links with the system `cc` (or `zig cc` for cross targets).

## What is the same

Both back ends implement exactly the language in the [reference](../language/index.md):

- integer overflow: plain `int` wraps, fixed-width integers trap, on **both**;
- argument evaluation order, exception semantics, `with`/`defer`/`finally` cleanup order;
- program output, including float formatting.

## What differs (and how code should treat it)

| Difference | Guidance |
|---|---|
| Parallelism: tasks run on a worker pool (LLVM) or interleave on one thread (QBE) | write tasks that are correct under both; communicate with channels |
| `spawn`/`nox.thread.start` argument types are wider on LLVM | stay within the QBE set for portable code ([Concurrency](../language/concurrency.md#the-scheduler)) |
| `-g`, `--emit-asm`, freestanding exist only on QBE | choose `--backend qbe` for those. Desktop `--target` works on both. Mobile targets and `wasm32-*` are LLVM |
| speed | LLVM is faster; neither is a semantic choice |

Both back ends are run over the entire golden corpus on every change, and a differential test compares their output.

## Intermediate files

`noxc build` leaves `file.ll` (LLVM) or `file.ssa` and `file.s` (QBE) next to the executable; they are useful for inspecting the generated code and are safe to delete.

## Platforms

See [Platforms](../reference/platforms.md) for which combinations are tested.
