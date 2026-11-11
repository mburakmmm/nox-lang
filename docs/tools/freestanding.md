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
- `--target` selects the architecture (`x86_64`, `aarch64`; `riscv64` can only emit assembly — there is no freestanding boot chain). Hosted riscv64 is a separate target, `linux-riscv64`. The result is linked with `zig cc` against the freestanding runtime
  object (`noxrt-freestanding-generic-<arch>.o`).

## The allocator interface

The managed heap — lists, dictionaries, strings, class instances, reference counts, everything — needs memory. A freestanding program provides it by registering a pair of functions **before** `main` runs:

```text
nox_allocator_install(kernel_alloc, kernel_free)
```

The runtime then satisfies *every* memory request from them. The functions must return memory that is at least 8-byte aligned (the runtime's headers assume it) and must really own it. Because these functions back the
whole managed heap, they sit inside the same [trust boundary](../language/ffi.md#the-trust-boundary) as `extern def`: a wrong allocator corrupts the whole program.

**Default heap.** The reference x86_64 boot chain (`kernel.zig`) installs a built-in allocator: a size-class free-list heap over a contiguous 16 MiB region at the top of the 32 MiB identity-mapped memory (the page pool for `nox_alloc_page` lives below it). Requests are rounded up to a power-of-two class (16 B and up), blocks are reused after `free`, and there is no coalescing. If the heap (or a kernel-installed allocator) cannot satisfy a request, the program stops with `nox: out of memory — terminating the program` instead of continuing with a null pointer. Earlier releases rejected any request above 4096 bytes and never reclaimed memory, which silently corrupted lists above 128 elements.

The boot chain runs the program on a 1 MiB boot stack (64 KiB in earlier releases overflowed in formatted printing such as `{x:8.3f}`).

`nox_freestanding_early_init` is the one-time bootstrap step that runs, unconditionally and exactly once, before control reaches the program's top-level code.

## Hardware access

`ptr[T]`, `ptr_read`/`ptr_write`, `ptr_*_volatile` and `memory_fence()`/`compiler_fence()` (inside `lowlevel`) give typed memory-mapped I/O; [`nox.mem`](../stdlib/mem.md) wraps the common patterns. Fixed-width integers
(`u8`…`u64`) and `@repr("C")` / `@packed` classes model hardware registers and descriptor tables; `sizeof`, `alignof` and `offsetof` check layouts. Native entry stubs (boot code, interrupt trampolines) are small
assembly or Zig objects linked in with `extern def`.

## Limits

No threads, no scheduler pool (single-threaded cooperative `spawn` only if the runtime's fiber support is built for the target), no file system, networking or clock. Unhandled errors halt the machine rather than exiting a
process.
