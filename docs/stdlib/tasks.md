# nox.tasks

Task groups: a dynamic number of tasks with a common result type, with waiting, limiting and cancelling.

```text
import nox.tasks
from nox.tasks import TaskGroup, TaskHandle
```

**Capability:** none.

`list[Task[T]]` cannot be written directly. `TaskGroup[T]` keeps each task in a small `TaskHandle[T]` class (field `task`); releasing the group releases the tasks.

| Member | Description |
|---|---|
| `TaskGroup[T]()` | an empty group for tasks that return `T` |
| `add(t)` | adds a task, e.g. `g.add(spawn work(i))` |
| `size()`, `finished()` | how many tasks were added / have finished |
| `wait_all(timeout_ms)` | waits cooperatively until every task has finished; `True` if they all did before the timeout |
| `wait_below(limit, timeout_ms)` | waits until fewer than `limit` tasks are still running (call it before `add` to bound concurrency) |
| `cancel_all()` | requests cancellation of every task (cooperative: a task sees `CancelledError` at its next `await`) |
| `handles()` | the `TaskHandle[T]` list in insertion order; `await h.task` yields the result |

`await` can only be written in an `async def` and only on a `Task` value, so collecting results is a loop in your code. An exception raised by a task is re-raised by the
`await` of that task.

```nox
import nox.tasks
import nox.time
from nox.tasks import TaskGroup, TaskHandle

async def work(i: int) -> int:
    nox.time.sleep_ms(5 * i)
    return i * 2

async def run() -> None:
    g: TaskGroup[int] = TaskGroup[int]()
    for i in range(4):
        g.add(spawn work(i))
    print(g.wait_all(5000))
    out: list[int] = []
    for h in g.handles():
        out.append(await h.task)
    print(out)

t0: Task[None] = spawn run()
await t0
```

```output
True
[0, 2, 4, 6]
```

## Cancelling CPU-bound work

Cancellation is cooperative, so a loop that never awaits needs a checkpoint:

```text
import nox.tasks
import nox.time

async def crunch(n: int) -> int:
    total: int = 0
    for i in range(n):
        total += heavy(i)
        nox.tasks.checkpoint()          # raises CancelledError if cancellation was requested
        if i % 1000 == 0:
            nox.time.sleep_ms(0)        # let other tasks and timers run
    return total
```

| Function | Description |
|---|---|
| `checkpoint()` | raises `CancelledError` if the current task (or the thread's entry task) was cancelled with `Task.cancel()` / `ThreadHandle.cancel()`; otherwise a cheap flag read. Outside a task it does nothing |
| `is_cancelled()` | the same flag without raising, to clean up and return your own way |

Nothing is stopped forcibly, so no resource is leaked and no ARC state is corrupted. A thread started with `nox.thread.start` is cancelled with `h.cancel()`.

## Notes

- Tasks are started with `spawn`; the group does not start them. Cancelling does not interrupt a task that never awaits (see [Concurrency](../language/concurrency.md#cancellation)).
- To wait for a single task with a timeout use `t.wait(ms)` / `t.wait_any(other, ms)` ([Concurrency](../language/concurrency.md#timeouts-and-waiting-for-the-first-of-two-tasks)).
