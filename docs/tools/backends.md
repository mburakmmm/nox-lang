# Compilation backends

Nox compiles the typed program to one of two back ends, which are tested against the same corpus and must produce **identical program output**.

| | **LLVM** (default) | **QBE** |
|---|---|---|
| Pipeline | typed IR → LLVM IR (`.ll`) → `clang -O2` (or `zig cc -O2`) → native | typed IR → QBE IL (`.ssa`) → `qbe` → assembly → `cc` → native |
| Code speed | faster (roughly 1.5× C on a mixed benchmark suite) | good (roughly 1.7× C) |
| Compile speed | fast | fast |
| Scheduler | **multi-core M:N work-stealing** with atomic reference counts | single-threaded cooperative |
| Needs | `clang` or `zig` on `PATH` | the bundled `qbe`, and a C compiler for linking |
| Debug info (`-g`) | no | yes (DWARF line tables) |
| `--target` cross-compile, `--emit-asm`, freestanding | no | yes |

## How the backend is chosen

`--backend llvm` and `--backend qbe` always win. Otherwise (`auto`):

1. **freestanding** builds, `--target`, `--emit-asm` and `-g` → QBE;
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
| `-g`, `--target`, `--emit-asm`, freestanding exist only on QBE | choose `--backend qbe` for those |
| speed | LLVM is faster; neither is a semantic choice |

Both back ends are run over the entire golden corpus on every change, and a differential test compares their output.

## Intermediate files

`noxc build` leaves `file.ll` (LLVM) or `file.ssa` and `file.s` (QBE) next to the executable; they are useful for inspecting the generated code and are safe to delete.

## Platforms

See [Platforms](../reference/platforms.md) for which combinations are tested.
