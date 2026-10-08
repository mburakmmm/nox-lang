# The runtime

The runtime is written in Zig and statically linked into every program (`noxrt.o`; `noxrt-freestanding*.o` for kernels). It follows the Zig rule the project adopts: **allocators are explicit parameters, never
globals**. Generated code receives a pointer to a per-program (or per-worker) `RuntimeState` as a hidden first parameter and passes it to every runtime call.

## Memory

| Module | Responsibility |
|---|---|
| `alloc/asap.zig` | `RuntimeState`, ASAP/stack support, leak reporting in debug runs |
| `alloc/arc.zig` | reference-counted allocation, retain/release, small-object pools, the depth-limited release worklist |
| `alloc/cycle_detector.zig` | the trial-deletion cycle collector, its root table and stop-the-world participation |
| `alloc/lowlevel.zig` | arenas for `lowlevel` blocks |
| `alloc/dispatch_registry.zig` | class tables for dynamic release/trace |
| `alloc/defer_stack.zig` | `defer` bookkeeping |

In debug builds the allocator is Zig's `DebugAllocator`: every leaked allocation is reported with a stack trace at exit, which is how most memory bugs in this project were found. Tests must pass with leak and double-free
detection on.

## Values

- `str.zig` — the packed header (61-bit length and a 2-bit ASCII state), UTF-8 handling, O(1) ASCII indexing, float formatting (`formatFloatRepr`, the shortest round-trip digits) and conversions.
- `format.zig` — the Python format mini-language with exact big-integer rounding for `f` and `%`.
- `collections/dict.zig`, `list_ops.zig`, `list_sort.zig` — insertion-ordered dictionaries, list operations and a stable sort.

## Errors

`errors/handle.zig` defines exception handles (a class tag plus the parent-chain reference used by `except` matching), the unhandled-exception report, `nox_int_overflow_trap` for fixed-width overflow, and
`nox_int_pow`. `errors/diag_sink.zig` routes diagnostics so freestanding builds can supply their own sink.

## Concurrency

`async_rt/` — fibers (`fiber.zig` and the per-architecture context switches `swap_*.S`), the single-threaded scheduler, channels, thread bridges, the I/O reactor (kqueue/epoll/`WSAPoll`), and the multi-core
worker pool. See [The scheduler](scheduler.md).

## Standard-library shims

`stdlib_shims/` contains the native half of each `nox.*` module that touches the OS: files, processes, time, sockets, TLS (client and server), HTTP client and server, WebSocket client and server, SQLite/PostgreSQL/MySQL
(loaded with `dlopen` on first use), crypto, gzip, JSON (parsing via Zig's `std.json`, building Nox values by calling back into a Nox factory), regex, shared memory, atomics and the NNI host (`native.zig`).

A shim function is exported with `export fn nox_<module>_<name>_raw(...)`; the Nox module wraps it. Every export that must survive linking is referenced from `lib.zig` (and `lib_freestanding.zig` for kernels).

## Platform notes

Linux and macOS use `epoll`/`kqueue`; Windows uses `WSAPoll` and links `ntdll`, `ws2_32` and `crypt32`; the fiber context switch is hand-written assembly per architecture (x86-64, aarch64). Fiber stacks are 192 KiB with a guard page.

## Freestanding

`lib_freestanding.zig` omits everything that needs an OS; memory comes from the kernel-supplied allocator registered with `nox_allocator_install`. The only mutable global state in the runtime is this one-time bootstrap
state, documented as the single exception to "no hidden global state".
