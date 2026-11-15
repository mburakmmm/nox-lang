# Reduce binary size

A Nox program is one native executable with the runtime linked in. The linker drops everything the program does not use, so size follows what you **import**, not what the standard library contains.

## What to expect

Measured on release builds, with a program that only prints a line:

| Target | Size |
|---|---|
| macOS arm64 | 0.21 MB |
| Linux x86-64 (cross-compiled) | 0.34 MB |
| Windows x86-64 (cross-compiled) | 0.78 MB |

These are the numbers for the default LLVM back end at version 2.1.176. A real program grows with the modules it imports: a TLS client, a database driver or a full HTTP server each add their own code, nothing else does.

## What helps

1. **Import only what you use.** An unused module costs nothing, but every module you do import is linked in. Prefer a narrow module (`nox.strings`) over a broad one when both would do.
2. **Do not pass `-g` unless you are debugging.** `-g` selects the QBE back end and keeps DWARF line tables in the executable ([Debugging](../tools/debugging.md)). Without it the linker strips debug information (`--strip-debug` on Linux and Windows) and no `.pdb` file is written.
3. **Keep the default back end.** LLVM, the default, produces the smaller and faster code on macOS, Linux and Windows. QBE is chosen automatically for freestanding builds, `--emit-asm` and `-g` ([Back ends](../tools/backends.md)).
4. **Use the C-backed modules only where you need them.** `nox.lz4`, `nox.yyjson`, `nox.pcre2` and the others link a C library into the program only when imported ([Embedded C libraries](embedded-c-libraries.md)).

## How the linker does it

The runtime is built with one section per function and per data item, and the final link runs with dead-code elimination (`--gc-sections` on Linux and Windows, `-dead_strip` on macOS). Before Nox 2.1.176 cross-built Linux and Windows programs carried the runtime's debug information and could not drop unused code, so a hello-world was 19 MB on Linux; if you see that on an old compiler, `noxc upgrade` fixes it.

## Check what you got

```sh
noxc build main.nox -o app
ls -l app
```

`noxc explain main.nox` shows where each value lives, which is the other half of a program's footprint: memory at run time rather than bytes on disk ([Memory](../language/memory.md)).
