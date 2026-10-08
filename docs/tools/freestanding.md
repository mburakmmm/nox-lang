# Freestanding builds

Nox can compile programs that run with **no operating system** — kernels, firmware, bootloaders — by linking a freestanding runtime and importing only modules that need no OS services. This page describes the
profile, the target model and the allocator interface.

> Freestanding builds use the QBE backend. A complete worked example — a bootable x86-64 kernel written in Nox with a physical-memory manager, virtual memory, PCI enumeration, timer interrupts and a shell — is the
> separate `nox-kernel-demo` project.

## Building

```sh
noxc build --profile freestanding --target x86_64 -o kernel.elf kernel.nox
noxc build --profile freestanding --target aarch64 -o kernel.elf kernel.nox
noxc build --profile freestanding --target riscv64 --emit-asm kernel.nox   # assembly only
```

- `--profile freestanding` restricts imports to modules that need no capability, checked at compile time ([capabilities](../stdlib/index.md#capabilities)). `nox.mem`, `nox.bits`, `nox.buffer`, `nox.binary`, `nox.mathx`,
  `nox.collections`, `nox.strings`, `nox.console`, `nox.json`, `nox.csv` and the other pure modules are allowed; `nox.fs`, `nox.http`, `nox.thread`, `nox.time`'s clock functions and similar are rejected.
- `--target` selects the architecture (`x86_64`, `aarch64`; `riscv64` can only emit assembly because its runtime context-switch is not implemented). The result is linked with `zig cc` against the freestanding runtime
  object (`noxrt-freestanding-generic-<arch>.o`).

## The allocator interface

The managed heap — lists, dictionaries, strings, class instances, reference counts, everything — needs memory. A freestanding program provides it by registering a pair of functions **before** `main` runs:

```text
nox_allocator_install(kernel_alloc, kernel_free)
```

The runtime then satisfies *every* memory request from them. The functions must return memory that is at least 8-byte aligned (the runtime's headers assume it) and must really own it. Because these functions back the
whole managed heap, they sit inside the same [trust boundary](../language/ffi.md#the-trust-boundary) as `extern def`: a wrong allocator corrupts the whole program.

`nox_freestanding_early_init` is the one-time bootstrap step that runs, unconditionally and exactly once, before control reaches the program's top-level code.

## Hardware access

`ptr[T]`, `ptr_read`/`ptr_write`, `ptr_*_volatile` and `memory_fence()`/`compiler_fence()` (inside `lowlevel`) give typed memory-mapped I/O; [`nox.mem`](../stdlib/mem.md) wraps the common patterns. Fixed-width integers
(`u8`…`u64`) and `@repr("C")` / `@packed` classes model hardware registers and descriptor tables; `sizeof`, `alignof` and `offsetof` check layouts. Native entry stubs (boot code, interrupt trampolines) are small
assembly or Zig objects linked in with `extern def`.

## Limits

No threads, no scheduler pool (single-threaded cooperative `spawn` only if the runtime's fiber support is built for the target), no file system, networking or clock. Unhandled errors halt the machine rather than exiting a
process.
