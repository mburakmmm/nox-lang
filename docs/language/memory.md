# Memory

There is no ownership syntax anywhere in Nox: no `&`, no `move`, no lifetimes, no `Annotated[...]`, no `read`/`mut`/`owned`. You never
free memory and never think about aliasing rules. The compiler chooses the cheapest safe strategy for every value, automatically,
and falls back to a more general one — silently, never with an error — whenever it cannot prove the cheaper one correct.

## The ownership pyramid

| Layer | Mechanism | When it applies |
|---|---|---|
| 1 | **Stack / ASAP destructors** | ownership and lifetime are statically provable. Small fixed-size values live on the stack; others are freed at the exact point of last use, with no reference count at all |
| 2 | **ARC** (automatic reference counting) | the compiler cannot prove ownership. Retain/release are O(1); values are never deep-copied |
| 3 | **Cycle collector** | reference cycles among ARC-managed class instances (a background trial-deletion scan in the spirit of Nim's ORC), triggered by allocation pressure and at program exit |
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

`noxc explain file.nox` prints, for every local variable, where it will be allocated and why. The output labels are currently Turkish
(`tahsis` = allocation, `gerekce` = reason):

```text
mm1.nox:13  xs
  tahsis: stack (40 bayt)
  gerekce:
    - sabit-boyutlu literal liste (40 bayt)
    - kaçmıyor, boyut/bütçe İçinde -> stack
  çerçeve bütçesi: 40 / 24576 bayt (önce: 0)
mm1.nox:19  h
  tahsis: ARC (heap, referans-sayımlı)
  gerekce:
    - bilinmeyen çağrı hedefi (sınıf kurucusu DEĞİL) -> ARC
```

A small literal list that does not escape is kept on the stack; a class instance returned from a function, stored in a field or captured
by a closure is reference counted. You do not need to act on this — it is a tool for understanding performance, never a requirement.
`noxc explain --release` shows the decisions for the LLVM backend.

## Reference counting and concurrency

On the LLVM backend reference counts are **atomic**, so a value can be shared by tasks running on different worker threads
([Concurrency](concurrency.md)). On the QBE backend the single-threaded scheduler needs no atomics. Either way, the cycle collector
coordinates with the scheduler (all workers pause at a safe point while it runs).

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

There is no `del x` that frees an object (`del` removes list elements and dictionary entries), no destructor/`__del__` method, no weak
references and no way to ask for an object's address from ordinary code. Resource cleanup is expressed with `with` (context managers),
`defer` and `finally` ([Exceptions](exceptions.md)), which share one scope-exit mechanism with automatic memory release.
