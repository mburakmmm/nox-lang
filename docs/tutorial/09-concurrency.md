# 9. Concurrency

Nox runs work in lightweight **tasks**. You start one with `spawn`, wait for its result with `await`, and let tasks talk through typed
**channels**.

## Tasks

```nox
import nox.time

async def fetch_square(n: int) -> int:
    nox.time.sleep_ms(10)
    return n * n

a: Task[int] = spawn fetch_square(6)
b: Task[int] = spawn fetch_square(7)
print(await a + await b)
```

```output
85
```

`async def` declares a function that can run as a task. `spawn f(x)` starts it and returns immediately with a `Task[int]` (the type is the function's
return type); `await task` waits for the result. Both tasks above run at the same time — on the default backend, on different threads of a worker
pool.

## Errors travel through `await`

```nox
async def risky(n: int) -> int:
    if n < 0:
        raise ValueError("negative")
    return n

async def run() -> None:
    t: Task[int] = spawn risky(-1)
    try:
        print(await t)
    except ValueError as e:
        print("task failed:", e.message)

main_task: Task[None] = spawn run()
await main_task
```

```output
task failed: negative
```

## Channels

A `Channel[T](capacity)` is a typed queue between tasks. `await ch.send(v)` waits while the queue is full; `await ch.recv()` waits while it is empty:

```nox
async def producer(ch: Channel[int], n: int) -> None:
    for i in range(n):
        await ch.send(i * 10)

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
    print("sum:", await c)

t: Task[None] = spawn run()
await t
```

```output
sum: 100
```

## Fan-out, fan-in

To start many workers and gather their results, hand every worker the same channel:

```nox
async def worker(results: Channel[int], n: int) -> None:
    await results.send(n * n)

async def run() -> None:
    results: Channel[int] = Channel[int](8)
    for i in range(8):
        spawn worker(results, i)
    total: int = 0
    for i in range(8):
        total += await results.recv()
    print("total:", total)

t: Task[None] = spawn run()
await t
```

```output
total: 140
```

`spawn f(x)` on its own line starts a task and discards the handle ("fire and forget"). Results arrive in the order workers finish, not the order they
started.

## Cancelling

`task.cancel()` asks a task to stop; the task receives `CancelledError` the next time it awaits another task. It is cooperative — a task stuck in
pure computation is not interrupted.

## What to remember

- Tasks cost very little; start as many as you have concurrent jobs.
- Share data between tasks by sending it through channels, not through global variables.
- The same program behaves correctly whether tasks run on one thread or many: the default (LLVM) backend runs them in parallel, the QBE backend
  interleaves them on one thread. Details: [Concurrency](../language/concurrency.md).
