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
*it* awaits another task. A task that never awaits (pure computation) is not interrupted by itself: put `nox.tasks.checkpoint()` inside the CPU loop
(it raises `CancelledError` when cancellation was requested; `nox.tasks.is_cancelled()` asks without raising), and call `nox.time.sleep_ms(0)` now and then so
other tasks and timers can run. `h.cancel()` on a `ThreadHandle` sets the same flag for the thread's entry task. The `CancelledError` can be caught inside the
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

### Timeouts and waiting for the first of two tasks

`t.is_done()` asks, without blocking and without consuming the result, whether the task has finished. `t.wait(ms)` waits cooperatively for it up to `ms`
milliseconds and returns whether it finished; `t.wait_any(other, ms)` waits for whichever of the two tasks finishes first and returns `0` (`t`), `1` (`other`) or
`-1` (timeout). None of them cancels a task or consumes its result: after a `True`, `await t` returns immediately; after a timeout call `t.cancel()` if the work
should stop.

```nox
import nox.time

async def work(ms: int, v: int) -> int:
    nox.time.sleep_ms(ms)
    return v

async def run() -> None:
    slow: Task[int] = spawn work(400, 1)
    if slow.wait(50):
        print(await slow)
    else:
        print("timed out")
        slow.cancel()

t0: Task[None] = spawn run()
await t0
```

```output
timed out
```

### Async generators and `async for`

An `async def` whose body contains `yield` is an **async generator**. Calling it does not start a task (it is not `spawn`ed): it returns a
lazy `AsyncIterator[T]` — the same type as the [`Iterator[T]`](functions.md#generators-yield) of an ordinary generator — and its body may
`await`. Consume it with `async for`, which is allowed inside an `async def` and at the top level:

```nox
async def double(n: int) -> int:
    return n * 2

async def numbers(n: int) -> AsyncIterator[int]:
    for i in range(n):
        d: int = await spawn double(i)
        yield d

async def total() -> int:
    t: int = 0
    async for v in numbers(5):
        t += v
    return t

async for x in numbers(3):
    print("got", x)
r: Task[int] = spawn total()
print(await r)
```

```output
got 0
got 2
got 4
20
```

Each value is produced when the loop asks for it, in the loop's own task: the generator's `await`s suspend that task, so a `break` also stops
the producer. `async for` needs an async iterator (a generator), not a list; the other limits of generators apply). Because an async generator is not itself a task, it can be passed around like any value, but a *task* (`spawn`ed `async def`)
still takes only simple parameters on the QBE backend, so consume generators inside the task that creates them.

### `async with`

`async with manager as name:` works like `with`, but calls the methods `__aenter__()` and `__aexit__()` of the manager, which may `await`. Declare them
as `async def` methods; they are called directly by the `async with` statement (not spawned), so they take no arguments other than `self`. It is
allowed inside an `async def`, at the top level and inside async generators.

```nox
async def tick(n: int) -> int:
    return n + 1

class Conn:
    def __init__(self, name: str) -> None:
        self.name: str = name

    async def __aenter__(self) -> str:
        t: int = await spawn tick(0)
        print("open", self.name, t)
        return self.name + "!"

    async def __aexit__(self) -> None:
        print("close", self.name)

async def work() -> None:
    async with Conn("db") as c:
        print("using", c)

t: Task[None] = spawn work()
await t
```

```output
open db 1
using db!
close db
```

`await` also works inside list and dict comprehensions (`[await spawn f(i) for i in range(3)]`); the awaits run one after another.

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

### Waiting with a timeout

`ch.wait(ms)` returns `True` as soon as a `recv` would not block (a value is buffered or a sender is waiting) and `False` if `ms` milliseconds pass first. It does not
consume the value: call `await ch.recv()` afterwards. If several tasks receive from the same channel, another one may take the value between `wait` and `recv`; use one receiver
per channel when that matters.

```text
if ch.wait(500):
    job: int = await ch.recv()
else:
    print("no work for 500 ms")
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

- **Both backends (hosted targets):** an automatic **M:N work-stealing scheduler** — the program's tasks run in parallel on a pool of worker
  threads. The pool size is fixed at compile time (a small default for programs that only use plain `spawn`, the CPU count for programs
  using `nox.http.serve_multicore*` or `nox.thread.pool_run`) and can be overridden at run time with the `NOX_POOL_WORKERS` environment
  variable. Reference counting is atomic whenever a program uses tasks or threads, so values may safely be shared between tasks on different
  workers. On the QBE backend (which has no atomic instructions in its IL) the atomic count updates are calls into the runtime, emitted only
  for programs that use `spawn`, `async`, `nox.thread` or the multi-core pool; other QBE programs keep plain, faster counts.
  Module-level variables: every worker keeps its own copy of them (this is what makes `serve_multicore` handlers independent). A program that
  shares **mutable** module state between tasks — a module-level list, dict, class instance, channel or task, or a module-level number/string that is
  reassigned — and does not use `serve_multicore*` or `nox.thread.pool_run` therefore runs on **one worker** on both backends, so a task never
  reads another worker's copy. Module-level constants (numbers and strings assigned once) do not count. Setting `NOX_POOL_WORKERS` overrides this
  (at your own risk).
- **Freestanding targets:** a single-threaded cooperative scheduler. Tasks interleave only at `await` points (and at blocking I/O, which is
  non-blocking at the fiber level); `time.sleep_ms` inside a task suspends only that task.

Consequences for portable code:

- Do not rely on tasks running in parallel *or* strictly interleaved — write them to be correct under both.
- Data shared between tasks should flow through channels. Module-level variables are not a safe way to communicate between tasks that may run on different
  workers (each worker keeps its own copy of the module state); use channels, `nox.atomic` counters, or `nox.sharedmem`.
- `time.sleep_ms` inside a task (an `async def`, an HTTP handler) suspends only that task on both backends; outside a task (and on Windows) it blocks its thread.
- The argument and result types of `spawn`/`nox.thread.start` may be scalars, `str`, `None`, `ptr`, thread channels, lists, dictionaries,
  class instances, tasks and channels on both backends of hosted targets; freestanding targets are restricted to scalars, `str`, `None`,
  `ptr` and thread channels. `Optional`, function values and `ThreadHandle` are never accepted.
- A listening socket shared by several tasks (for example `serve_fd` called on the same fd from two threads) is closed by whichever task
  finishes first; use `nox.http.serve_multicore*` for multi-worker servers.

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
