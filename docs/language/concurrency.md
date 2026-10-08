# Concurrency

Nox's concurrency model is **tasks and channels**: lightweight fibers started with `spawn`, joined with `await`, and connected by typed
channels. Tasks are cheap (a small fixed stack each) and are scheduled by a runtime scheduler; whether they run on one thread or many is
a property of the backend and is invisible to the source ([The scheduler](#the-scheduler)).

## Async functions, `spawn` and `await`

`async def` declares a function that can run as a task. `spawn f(args)` starts it and immediately returns a `Task[T]`, where `T` is the
function's return type. `await task` suspends the caller until the task finishes and yields its result. `await` may be used inside an
`async def` and at the top level of a program.

```nox
async def square(n: int) -> int:
    return n * n

a: Task[int] = spawn square(6)
b: Task[int] = spawn square(7)
print(await a + await b)
```

```output
85
```

A call to an async function without `spawn` is a compile error: starting a task is always explicit.

### Failures propagate through `await`

If a task raises, the exception is delivered to whoever awaits it — `await` re-raises it, so ordinary `try`/`except` works across tasks:

```nox
async def fail() -> int:
    raise ValueError("task failed")

async def run() -> None:
    f: Task[int] = spawn fail()
    try:
        r: int = await f
        print(r)
    except ValueError as e:
        print("caught:", e.message)

t: Task[None] = spawn run()
await t
```

```output
caught: task failed
```

### Fire and forget

`spawn f(x)` written as a statement starts a task and drops the handle; the task keeps running until it finishes. An exception in a task
nobody awaits is not reported, so use this only for work that handles its own errors.

### Cancellation

`task.cancel()` requests cancellation. It is **cooperative**: it sets a flag, and the cancelled task gets a `CancelledError` the next time
*it* awaits another task. A task that never awaits (pure computation) is not interrupted. The `CancelledError` can be caught inside the
task; if it is not, it reaches whoever awaits the task.

```nox
async def step() -> int:
    return 1

async def worker() -> int:
    total: int = 0
    while True:
        s: Task[int] = spawn step()
        total += await s
    return total

async def run() -> None:
    w: Task[int] = spawn worker()
    w.cancel()
    try:
        await w
    except CancelledError as e:
        print("worker cancelled")

t0: Task[None] = spawn run()
await t0
```

```output
worker cancelled
```

## Channels

`Channel[T](capacity)` is a typed queue connecting tasks. `await ch.send(v)` suspends while the channel is full; `await ch.recv()` suspends
while it is empty. A capacity of `0` is a rendezvous channel: a send completes only when a receiver takes the value. Channels are values
you pass to tasks as arguments.

```nox
async def producer(ch: Channel[int], n: int) -> None:
    for i in range(n):
        await ch.send(i)

async def consumer(ch: Channel[int], n: int) -> int:
    total: int = 0
    for i in range(n):
        total += await ch.recv()
    return total

async def run() -> None:
    ch: Channel[int] = Channel[int](2)
    p: Task[None] = spawn producer(ch, 5)
    c: Task[int] = spawn consumer(ch, 5)
    await p
    print(await c)

t: Task[None] = spawn run()
await t
```

```output
10
```

### Fan-out and fan-in

There is no `list[Task[T]]` in 2.0 (tasks and channels cannot be stored in collections). The idiom for "start N workers and gather the
results" is a channel the workers write to:

```nox
async def worker(ch: Channel[int], n: int) -> None:
    await ch.send(n * n)

async def run() -> None:
    ch: Channel[int] = Channel[int](4)
    for i in range(4):
        spawn worker(ch, i)
    total: int = 0
    for i in range(4):
        total += await ch.recv()
    print("total", total)

t: Task[None] = spawn run()
await t
```

```output
total 14
```

Results arrive in completion order, not spawn order; send an index with the result if order matters.

## Task-local values

`TaskLocal[T]` holds one value per running task (`T` must be a `str`, `list`, `dict` or class). `get()` returns `T | None`; `set(v)` and
`clear()` change it. It is useful for per-request context in servers.

```nox
async def run() -> None:
    who: TaskLocal[str] = TaskLocal[str]()
    print(who.get())
    who.set("ada")
    name: str | None = who.get()
    if name is not None:
        print(name)
    who.clear()
    print(who.get())

t: Task[None] = spawn run()
await t
```

```output
None
ada
None
```

## Threads

For explicit worker threads, `nox.thread` offers `nox.thread.start(fn, arg)` returning a `ThreadHandle[T]` (`await h.join()` yields the
result) and `ThreadChannel[T](capacity)` for communicating with it. The module is described in the [standard library](../stdlib/thread.md).

```nox
import nox.thread

async def worker(x: int) -> int:
    return x * 2

async def run() -> None:
    h: ThreadHandle[int] = nox.thread.start(worker, 21)
    print(await h.join())
    tc: ThreadChannel[int] = ThreadChannel[int](4)
    await tc.send(7)
    print(await tc.recv())

t: Task[None] = spawn run()
await t
```

```output
42
7
```

## The scheduler

All tasks run on fibers scheduled by the runtime:

- **LLVM backend (default):** an automatic **M:N work-stealing scheduler** — the program's tasks run in parallel on a pool of worker
  threads. The pool size is fixed at compile time (a small default for programs that only use plain `spawn`, the CPU count for programs
  using `nox.http.serve_multicore*` or `nox.thread.pool_run`) and can be overridden at run time with the `NOX_POOL_WORKERS` environment
  variable. Reference counting is atomic on this backend, so values may safely be shared between tasks on different workers.
- **QBE backend:** a **single-threaded cooperative scheduler**. Tasks interleave only at `await` points (and at blocking I/O, which is
  non-blocking at the fiber level); `time.sleep_ms` blocks the one thread.

Consequences for portable code:

- Do not rely on tasks running in parallel *or* strictly interleaved — write them to be correct under both.
- Data shared between tasks should flow through channels. Module-level variables are not a safe way to communicate between tasks that may run on different
  workers (each worker keeps its own copy of the module state); use channels, `nox.atomic` counters, or `nox.sharedmem`.
- `time.sleep_ms` blocks its worker; with the M:N pool other tasks continue on other workers, with QBE everything waits.
- The argument and result types of `spawn`/`nox.thread.start` are restricted on QBE to scalars, `str`, `None`, `ptr` and thread
  channels; on LLVM lists, dictionaries, class instances, tasks and channels are accepted too.

### Fiber stacks

Each task runs on a fixed-size fiber stack (192 KiB) with a guard page below it; overflowing it terminates the program instead of
corrupting memory. The runtime's own recursive algorithms (class release, cycle collection, JSON) are iterative or depth-limited so they
fit comfortably; user code that recurses very deeply should run outside fibers.

## Concurrency and the type system

- Ownership stays invisible: values handed to a task are retained for it; a value can be used by several tasks safely under the M:N
  runtime (atomic reference counts).
- The compiler rejects, at compile time, obvious data races in `spawn` arguments (for example mutating a list after handing it to a task
  that still reads it).
- Network and file operations in the standard library are non-blocking at the fiber level: a task waiting on a socket does not block the
  worker.
