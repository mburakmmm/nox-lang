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
- **Linked into the freestanding runtime today:** the pure modules above plus `nox.strings`, `nox.json`, `nox.regex`, `nox.base64`, `nox.path` (lexical only; `canonicalize` always fails without a file system) and `nox.random` (seeded from the time-stamp counter on x86_64; call `seed(n)` for reproducible output). **Every module the profile admits links.** Bare-kernel notes: `nox.gzip` runs on a dedicated 768 KiB stack (single core, not re-entrant); `nox.crypto` offers the digests, HMAC and constant-time comparison, but no password hashing that needs entropy or MiB of memory (`argon2`, `scrypt`, `*_hash` return empty; `bcrypt_verify` works); `nox.os` has an in-memory environment, `arg(0)` is `"nox"` and `exit` halts the machine. The same checks run in `scripts/freestanding_survey.py`.
- `--target` selects the architecture (`x86_64`, `aarch64`, `riscv64`). All three have a boot chain proven in QEMU (see *Reference boot chains* below); on riscv64 the link step of `noxc build` is not wired yet, so use `--emit-asm` and link it yourself as the reference chain does. Hosted riscv64 is a separate target, `linux-riscv64`. The result is linked with `zig cc` against the freestanding runtime
  object (`noxrt-freestanding-generic-<arch>.o`).

## Reference boot chains (QEMU)

| Architecture | Machine | Files | Output / exit |
|---|---|---|---|
| x86_64 | `q35`, Multiboot1 | `runtime/freestanding/x86_64/` (`boot.S`, `kernel.ld`, `kernel.zig`, `kernel_demo.nox`) | COM1; `isa-debug-exit` |
| aarch64 | `virt`, `cortex-a57`, `-kernel` ELF | `runtime/freestanding/aarch64/` | PL011 at `0x09000000`; ARM semihosting `SYS_EXIT_EXTENDED` (`-semihosting`) |
| riscv64 | `virt`, `-bios none`, `-kernel` ELF | `runtime/freestanding/riscv64/` | NS16550 at `0x10000000`; SiFive test finisher at `0x100000` |

Each directory is a complete, small example: `boot.S` (entry, FPU enable, stack, `.bss` clear), `kernel.ld`, `kernel.zig` (UART sink, halt provider, fiber stack pool, exit) and a demo program whose checkpoints (`Hello Nox`, list/dict/string/class/float/recursion/exception, integer and float `print`) the test `tests/golden/kernel_boot_qemu_test.zig` checks on a real QEMU run (`zig build kernel-boot-qemu-test`; skipped when `qbe` or `qemu-system-<arch>` is missing).

Notes that cost real debugging time and are worth knowing for your own kernel:

- **aarch64 needs the MMU on.** With the MMU off every data access is Device memory and an unaligned access faults, which the generated code does (string copies). `boot.S` builds a one-level identity map (1 GiB device block, 1 GiB normal block) and enables MMU + caches; keep the page table outside the `.bss` range you zero.
- **riscv64 RAM starts at `0x80000000`.** QBE's riscv64 output materializes addresses with `lui %hi` / `addi %lo`, which only reaches the first 2 GiB, so `noxc build --target riscv64 --profile freestanding --emit-asm` rewrites each pair into the PC-relative `lla sym`. The runtime object is built with the `medium` code model.
- `print` of integers and floats on aarch64 and riscv64 works through a register-based `printf` (no `va_list`): at most 7 integer and, on aarch64, 8 floating-point arguments per call, which `print` never exceeds.

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

**Exit codes under QEMU.** The reference boot chain writes to the `isa-debug-exit` device: a program that finishes normally exits with QEMU status `33`; an unrecoverable error (unhandled exception, out of memory, integer overflow trap) prints its message on the serial port and exits with status `35`. On real hardware the port is inert and the machine halts.

**Numerics.** There is no libm. Float `**` uses Zig's `std.math.pow`, and `nox.mathx.exp` uses a correctly rounded `f128` implementation (it agrees with a hosted libm to the last digit); the other `mathx` functions may differ from a hosted libm in the last digit.

