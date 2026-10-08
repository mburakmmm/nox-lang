# The scheduler

Tasks are fibers: small stacks and a hand-written context switch. Two schedulers exist; the language semantics are identical.

## Single-threaded (QBE)

One cooperative scheduler on one thread. A task runs until it awaits (a task, a channel operation, or non-blocking I/O); the reactor (`io_reactor.zig`) wakes tasks when sockets become ready. Because nothing runs in
parallel, reference counts are non-atomic and module-level state is trivially safe.

## Multi-core M:N (LLVM)

A pool of OS worker threads shares a work-stealing scheduler:

- **Deques.** Each worker owns a Chase–Lev deque of runnable fibers; idle workers steal from others.
- **Atomic reference counts.** Objects may be touched by any worker.
- **Fiber-affine globals.** Module-level variables are kept in per-worker blocks.
- **Wake-ups.** Completion pipes and self-pipes wake blocked workers; channels use spin-locked buffers that are safe across workers.
- **Deadlock detection.** The pool detects the case where every worker is idle and no task can become runnable and reports it instead of hanging.
- **Stop-the-world barrier.** The cycle collector needs a consistent view: it requests a barrier, every worker parks at a safe point, the collector runs, workers resume. The barrier is a sense-reversing design that was the source of two real
  livelocks during development; its tests run repeatedly.
- **Pool size.** Chosen at compile time (a small default for programs that merely `spawn`, one worker per core for programs using `serve_multicore*`/`pool_run`) and overridable with `NOX_POOL_WORKERS`.

`spawn` argument packing is retain/release-aware: values captured for a task are retained for it so they outlive the spawning scope; the data-race pre-checks in the type checker catch the obvious cases
(mutating a collection that a spawned task still reads).

## `nox.thread`

`nox.thread.start` and `ThreadChannel[T]` have two implementations behind one source API: independent runtimes per OS thread on QBE (so only scalar-like values cross), and ordinary tasks on the shared pool under LLVM (so lists,
classes and dictionaries can be passed).

## Cancellation

`task.cancel()` sets a flag; the cancelled task observes it at its next `await` of another task and raises `CancelledError`. Channel operations do not check the flag.

## Blocking calls

`time.sleep_ms` and synchronous file operations block their worker. Network operations are non-blocking at the fiber level. A multi-core server therefore keeps serving on other workers while one blocks.

## Testing

`worker-pool-test`, `async-rt-test` (a standalone target that also builds on Windows), the stress test, the two concurrency torture suites and the HTTP soak test are opt-in because they are slow; see [Testing internals](testing.md).
