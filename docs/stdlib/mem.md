# nox.mem

Bulk typed-pointer memory operations and volatile access — a friendly facade over `lowlevel` and `ptr[T]`, so ordinary code (device drivers, kernels, FFI buffers) does not need to write its own
`lowlevel` loops. Pure Nox with no operating-system or libc dependency, so it works in freestanding programs.

```text
import nox.mem
```

**Capability:** none. Callers still need `lowlevel` to *obtain* pointers ([Foreign functions](../language/ffi.md#raw-pointers)).

## Functions

| Function | Description |
|---|---|
| `copy(dst, src, count)` | copies `count` elements of type `T` from `src` to `dst`; the regions must **not overlap** |
| `move(dst, src, count)` | like `copy`, but correct for overlapping regions (copies backwards when `dst` is after `src`) |
| `set(dst, value, count)` | stores `value` into `count` consecutive elements |
| `read_volatile(p)` | loads from `p` in a way the optimiser may not remove or reorder (memory-mapped registers) |
| `write_volatile(p, value)` | stores through `p` likewise |

All are generic over the element type: `ptr[i32]`, `ptr[u8]`, … Counts are element counts, not bytes. There is **no bounds checking**: you are responsible for the regions.

```nox
import nox.mem

extern def malloc(n: int) -> ptr from "c"
extern def free(p: ptr) -> None from "c"

def demo() -> int:
    total: int = 0
    lowlevel:
        raw: ptr = malloc(64)
        a: ptr[i32] = ptr[i32](ptr_to_int(raw))
        b: ptr[i32] = ptr[i32](ptr_to_int(raw) + 32)
        nox.mem.set(a, i32(7), 4)
        nox.mem.copy(b, a, 4)
        nox.mem.write_volatile(b, i32(9))
        total = int(nox.mem.read_volatile(a)) + int(nox.mem.read_volatile(b)) + int(ptr_read(ptr_offset(b, 3)))
        free(raw)
    return total

print(demo())
```

```output
23
```

## Allocation counters

`nox.mem.stats() -> MemStats` reports how many ARC-managed heap blocks (`str`, `list`, `dict`, class instances) were allocated and freed. The counters cost
one boolean check on the allocation path while off; the **first** `stats()` call starts counting and returns zeros, later calls return what was counted
since. Call it once before the code you want to measure, then again and read the difference:

```nox
import nox.mem

nox.mem.stats()                      # starts counting
# ... code under measurement ...
s: nox.mem.MemStats = nox.mem.stats()
print(s.allocations, s.frees, s.live)
```

| Field | Meaning |
|---|---|
| `allocations` | blocks allocated since counting started (blocks reused from the internal pool count too) |
| `frees` | blocks freed since counting started |
| `live` | `allocations - frees`; can be negative if a block allocated before counting started is freed during measurement |
| `bytes_allocated` | total payload bytes of those allocations |

Objects the compiler promotes to the stack or an arena never reach the heap and are not counted.

## Notes

- `detach(x)` of a `list[T]` yields a pointer to the list **header**; the elements start 16 bytes after it. [`nox.buffer`](buffer.md) hides that detail for byte buffers.
- This module is part of the same [trust boundary](../language/ffi.md#the-trust-boundary) as `lowlevel`: a wrong pointer is a crash or corruption.
