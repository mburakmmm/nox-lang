# nox.thread

Explicit worker threads and thread-to-thread channels. The language's `spawn` / `await` already runs tasks in parallel under the default scheduler ([Concurrency](../language/concurrency.md));
`nox.thread` is for when you want a named unit of work with a joinable handle, or a channel that is safe to hand to such a unit.

```text
import nox.thread
```

**Capability:** `threads` (unavailable in freestanding profiles).

## `start` and `ThreadHandle[T]`

```text
h: ThreadHandle[T] = nox.thread.start(fn, arg)
result: T = await h.join()
```

| Item | Description |
|---|---|
| `nox.thread.start(fn, arg)` | starts `fn(arg)` on another thread and returns a `ThreadHandle[T]` where `T` is the result type of `fn`. `fn` must be an `async def` taking one argument |
| `await h.join()` | waits for the thread and returns (or re-raises) its result |

## `ThreadChannel[T]`

A bounded channel designed to be shared with a started thread: `ThreadChannel[T](capacity)` with `await tc.send(v)` and `await tc.recv()`, like [`Channel[T]`](../language/concurrency.md#channels), but
the channel itself may be passed as the `arg` of `start`. `capacity` must be at least 1 (rendezvous channels are not supported across threads).

```nox
import nox.thread

async def worker(x: int) -> int:
    return x * 2

async def producer(tc: ThreadChannel[int]) -> None:
    i: int = 0
    while i < 3:
        await tc.send(i * 10)
        i = i + 1

async def run() -> None:
    h: ThreadHandle[int] = nox.thread.start(worker, 21)
    print(await h.join())

    tc: ThreadChannel[int] = ThreadChannel[int](2)
    p: ThreadHandle[None] = nox.thread.start(producer, tc)
    total: int = 0
    j: int = 0
    while j < 3:
        total += await tc.recv()
        j = j + 1
    await p.join()
    print(total)

t: Task[None] = spawn run()
await t
```

```output
42
30
```

## `pool_run`

`nox.thread.pool_run(num_workers, entry)` runs `entry` — an `async def entry() -> None` with no parameters — and waits until it and everything it spawns has finished. On the default backend the program
already runs on a shared worker pool, so `pool_run` simply groups work under one waiting call; the `num_workers` argument is honoured only when it has to create the pool itself, and the pool size is
otherwise set at program start (see below).

## Argument types

| Backend | `start` / `spawn` arguments and results |
|---|---|
| LLVM (default) | `int`, `float`, `bool`, `str`, `None`, `ptr`, `ThreadChannel[T]`, plus `list[T]`, classes, `dict[K, V]`, `Task[T]`, `Channel[T]`, `TaskLocal[T]` (retained for the worker) |
| QBE | `int`, `float`, `bool`, `str`, `None`, `ptr`, `ThreadChannel[T]` |

## Pool size

Under the LLVM backend, programs that only use `spawn`/`start` get a small default pool (2 workers); programs that call `nox.http.serve_multicore*` or `nox.thread.pool_run` get one worker per CPU core.
Set the environment variable **`NOX_POOL_WORKERS=N`** to choose the size explicitly at run time.

## Notes

- Threads share nothing implicitly: module-level variables are per worker, so communicate through channels, [`nox.atomic`](atomic.md) cells or [`nox.sharedmem`](sharedmem.md).
- `start` needs `async def` entry functions even though they run on their own thread.
