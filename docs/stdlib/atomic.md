# nox.atomic

Process-wide atomic cells for sharing a counter or flag between workers. A cell lives in memory shared by every worker, so — unlike module-level variables, which are per worker — updates are
visible everywhere.

```text
import nox.atomic
from nox.atomic import AtomicInt, AtomicBool
```

**Capability:** `threads` (unavailable in freestanding profiles).

This is intentionally narrow: a single 64-bit integer or boolean, not a shared object graph. For separate **processes** use [`nox.sharedmem`](sharedmem.md).

## `AtomicInt`

| Member | Description |
|---|---|
| `new_int(initial)` | creates a cell holding `initial` |
| `load()` | reads the value |
| `store(value)` | writes a value |
| `add(delta)` | atomically adds `delta` and returns the **new** value |
| `increment()`, `decrement()` | `add(1)` / `add(-1)`, returning the new value |
| `compare_and_swap(expected, desired)` | if the value equals `expected`, replaces it with `desired`; returns whether it did |
| `handle` | the cell's address as an `int`, to pass to another worker |
| `from_int_handle(h)` | wraps the same cell from a handle |
| `free()` | releases the cell |

`AtomicError` is the exception class of the module; the operations above do not raise in normal use.

## `AtomicBool`

`new_bool(initial)`, `load()`, `store(value)`, `compare_and_swap(expected, desired)`, `handle`, `from_bool_handle(h)`, `free()` — the same operations for a flag.

```nox
import nox.atomic
from nox.atomic import AtomicInt, AtomicBool

c: AtomicInt = nox.atomic.new_int(5)
print(c.load(), c.add(3), c.increment(), c.decrement(), c.compare_and_swap(8, 100), c.compare_and_swap(8, 1), c.load())
c.store(42)
print(c.load())

b: AtomicBool = nox.atomic.new_bool(False)
print(b.load(), b.compare_and_swap(False, True), b.load())

same: AtomicInt = nox.atomic.from_int_handle(c.handle)
print(same.load())
c.free()
b.free()
```

```output
5 8 9 8 True False 100
42
False True True
42
```

## Sharing a cell with workers

Create the cell once, pass `cell.handle` (an `int`) to each worker as an argument, and rebuild a wrapper there with `from_int_handle`. Free the cell **once**, after every worker has finished — there is no
automatic release, and using a handle after `free()` is invalid.

```nox
import nox.atomic
import nox.thread
from nox.atomic import AtomicInt

async def bump(handle: int) -> int:
    cell: AtomicInt = nox.atomic.from_int_handle(handle)
    i: int = 0
    while i < 100:
        cell.increment()
        i = i + 1
    return 0

async def run() -> None:
    counter: AtomicInt = nox.atomic.new_int(0)
    a: ThreadHandle[int] = nox.thread.start(bump, counter.handle)
    b: ThreadHandle[int] = nox.thread.start(bump, counter.handle)
    await a.join()
    await b.join()
    print(counter.load())
    counter.free()

t: Task[None] = spawn run()
await t
```

```output
200
```
