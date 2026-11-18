# Memory

There is no ownership syntax anywhere in Nox: no `&`, no `move`, no lifetimes, no `Annotated[...]`, no `read`/`mut`/`owned`. You never
free memory and never think about aliasing rules. The compiler chooses the cheapest safe strategy for every value, automatically,
and falls back to a more general one — silently, never with an error — whenever it cannot prove the cheaper one correct.

## The ownership pyramid

| Layer | Mechanism | When it applies |
|---|---|---|
| 1 | **Stack / ASAP destructors** | ownership and lifetime are statically provable. Small fixed-size values live on the stack; others are freed at the exact point of last use, with no reference count at all |
| 2 | **ARC** (automatic reference counting) | the compiler cannot prove ownership. Retain/release are O(1); values are never deep-copied |
| 3 | **Cycle collector** | reference cycles among ARC-managed class instances (a stop-the-world trial-deletion scan in the spirit of Nim's ORC; large scans use several threads, see below), triggered by allocation pressure and at program exit |
| 4 | **`lowlevel` blocks** | you opt in to arena allocation (below) |

Promotion from layer 1 to layer 2 is silent and is an internal compiler decision, not part of the language semantics: the observable
behaviour of a program is the same whichever layer a value ends up in. The analysis is **conservative** — it never decides a value is safe
unless it can prove it.

What this means for you in practice:

- Values are released **deterministically**, at scope exit or earlier — not at some later collection pause. (Operating-system resources
  such as files and sockets are closed explicitly or with `with`; memory release does not run user code.)
- Reference cycles are reclaimed, but only by the cycle collector; a cyclic structure lives until a collection runs or the program
  ends.
- Assignment of a class instance copies the **reference**, never the object. `list`, `dict` and `set` are reference values as well.
- Strings are immutable; sharing them is always safe.

## Seeing the compiler's decisions: `noxc explain`

`noxc explain file.nox` prints, for every local variable, where it will be allocated and why:

```text
mm1.nox:13  xs
  allocation: stack (40 bytes)
  reasons:
    - fixed-size literal list (40 bytes)
    - does not escape, within size/budget -> stack
  frame budget: 40 / 24576 bytes (before: 0)
mm1.nox:19  h
  allocation: ARC (heap, reference-counted)
  reasons:
    - unknown call target (not a class constructor) -> ARC
```

A small literal list that does not escape is kept on the stack; a class instance returned from a function, stored in a field or captured
by a closure is reference counted. You do not need to act on this — it is a tool for understanding performance, never a requirement.
`noxc explain --release` shows the decisions for the LLVM backend.

## Reference counting and concurrency

On the LLVM backend reference counts are **atomic**, so a value can be shared by tasks running on different worker threads
([Concurrency](concurrency.md)). On the QBE backend the single-threaded scheduler needs no atomics. Either way, the cycle collector
coordinates with the scheduler (all workers pause at a safe point while it runs).

### Measuring reference-count traffic

`nox.mem.stats()` counts allocations. To see how many **retain/release operations** a program actually executes, build and run it with `NOX_RC_STATS=1` (a diagnostic; nothing changes when the variable is not set):

```bash
NOX_RC_STATS=1 noxc build app.nox -o app
NOX_RC_STATS=1 ./app          # prints NOXRC lines on stderr when the program exits
```

The output lists inline retain and release counts per heap kind (`str`, `list`, `class`, `dict`, ...) and the totals together with allocation and free counts. Counts are best effort (not atomic), cover the code the compiler emits inline (not retains done inside the runtime), and the build-time variable only affects the hosted backends (not WebAssembly or freestanding). Sampling profilers (`sample`, `perf`) show where the time goes; combining the two tells you whether reference counting or allocation dominates.

With `NOX_RC_STATS=1` the exit report also contains `NOXGC` lines: how many cycle collections ran, their total/longest pause and a log2 histogram of pause lengths (`parallel=` counts the collections that ran multi-threaded).

### Pauses with several workers

With `serve_multicore` or a thread pool, a cycle collection stops all workers at a **safe point between fibers**. A worker that is inside one long CPU-bound stretch with no I/O, `await` or `yield` cannot reach it, so every other worker waits until that stretch ends. Measured with four workers (`benchmarks/stw_latency`): ordinary requests have a p99 of 1.5 ms and a collection adds nothing visible (max 5.7 ms); with a 300 ms non-yielding handler running and a collection requested at the same time, the p99 of *all* workers becomes about 300 ms. The stall is bounded by the longest non-yielding stretch, not by the size of the heap. If a handler does long pure computation, split it with an `await` between chunks, or keep cyclic data out of that service so no collection is requested.

### Large cyclic garbage

The collector also reacts to **bytes**, not only to the number of candidate objects: when the live memory held in large blocks (64 KiB and up — big lists and strings) has grown by 64 MiB since the last collection and cyclic candidates are waiting, the next candidate registration starts a collection. A collection that frees little backs the trigger off (the step doubles, up to 4 GiB), so a large live cyclic structure is not rescanned over and over. Nothing is added to the allocation of small objects or to reference counting; only allocating and freeing a block of 64 KiB or more updates one counter. wasm and freestanding builds do not use it.

### Cycle collector threads

The cycle collector stops the world while it runs. When the previous collection visited at least 32 768 objects, the next one splits its mark/scan/collect phases over a few threads (default `min(CPU count, 4)`). Set `NOX_GC_THREADS=1` to force the single-threaded collector, or `NOX_GC_THREADS=<n>` to choose the thread count; `NOX_GC_PAR_MIN=<objects>` changes the switch-over threshold. Programs without cyclic data (most servers) never run the collector in steady state, so nothing changes for them. wasm and freestanding builds always use the single-threaded collector.

## `lowlevel` blocks

`lowlevel:` gives a block **arena allocation** and, together with `ptr[T]`, raw memory access. It is Nox's analogue of `unsafe`, with one
absolute difference: **static typing stays fully mandatory inside `lowlevel`**. The block relaxes only the allocation *strategy*, never
the type system.

```nox
def compute() -> int:
    total: int = 0
    lowlevel:
        nums: list[int] = [1, 2, 3, 4, 5]
        i: int = 0
        while i < 5:
            total = total + nums[i]
            i = i + 1
    return total

print(compute())
```

```output
15
```

Rules:

- Heap values created inside the block are allocated from a per-block arena that is torn down in one step when the block exits —
  by falling off the end, `return`, `break`, `continue` or an exception.
- A heap-typed value that belongs to the block may not **escape** it: it cannot be stored in a variable declared outside, returned,
  or passed to a function. The compiler rejects such a program at code generation. Copy the data you need into scalars (or construct a new
  value outside the block) before leaving it.
- `extern def` calls inside `lowlevel` run with full native authority exactly as outside — `lowlevel` does not weaken or strengthen the
  [trust boundary](ffi.md#the-trust-boundary).

For manual, typed access to memory (kernels, device registers, FFI buffers) see `ptr[T]`, `ptr_read`/`ptr_write`/`ptr_offset`,
`adopt`, and the `nox.mem` module ([Foreign functions](ffi.md), [stdlib](../stdlib/mem.md)); freestanding builds with a
kernel-provided allocator are described in [Freestanding](../tools/freestanding.md).

## What is not exposed

There is no `del x` that frees an object (`del` removes list elements and dictionary entries), no weak references and no way to ask for an object's address from ordinary code. A class may define `__del__`; it runs when the object's last reference goes away (not for objects reclaimed by the cycle collector). Resource cleanup is expressed with `with` (context managers),
`defer` and `finally` ([Exceptions](exceptions.md)), which share one scope-exit mechanism with automatic memory release.
