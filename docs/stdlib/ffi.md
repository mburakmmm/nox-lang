# nox.ffi

Closures and lambdas as C callbacks, and `errno` helpers for C error conventions.

```text
import nox.ffi
from nox.ffi import Callback
```

**Capability:** none. Not available on `wasm32` targets (a wasm module does not link native code).

[`@ffi.callback`](../language/ffi.md#callbacks) lets a C library call back into a top-level `def`. A top-level `def` has no state of its own; when the
callback needs to **capture variables** (a lambda, a nested function, a bound method), wrap it in a **`Callback[F]`** handle. `F` is the callback's
function type *without* the trailing `userdata` parameter:

```text
@ffi.callback("cb", "userdata")
extern def reg_set(cb: (int, ptr) -> int, userdata: ptr) -> None from "libreg.o"

total: int = 0
cb: Callback[(int) -> int] = Callback[(int) -> int](lambda x: x + total)
reg_set(cb)        # the handle goes where the callback goes; `userdata` is filled in by the compiler
...
cb.close()         # when the library will not call it any more
```

| Member | Meaning |
|---|---|
| `Callback[F](f)` | pins the function value `f` (an ARC reference is held for as long as the handle is open) and prepares what C needs |
| `cb.close()` | releases the pinned function and the handle's block; calling it again does nothing |
| `with cb as h:` | closes the handle when the block ends |
| `cb.live` | `False` after `close()` |

Rules:

- The handle must be a **variable or a field** at the call (`reg_set(cb)`), not a temporary expression: the library may keep the callback after the call, so the
  handle has to outlive it.
- The type of `F` must match the callback type exactly (every parameter and the result are `int`, `float`, `bool`, `ptr` or a fixed-width integer).
- ARC never frees the handle while C still holds it, so **`close()` is explicit**; a handle that is never closed stays alive until the program ends.
- Call the stored callback **only from a thread Nox started** and **never after `close()`** (the pinned function is gone): the library's own OS threads and
  late "shutdown" callbacks are not supported.
- An exception that escapes the callback terminates the program (there is no exception channel through C).

## Callbacks from a library thread

`@ffi.callback` runs your function on the thread that called into C. Some libraries (audio, networking, event loops) call the callback from a thread of their own, where Nox code
cannot run safely. `EventQueue` solves that: the C library is given a tiny C function that only writes the arguments into a locked queue, and your Nox code reads them in an ordinary
task.

```nox-fragment
import nox.ffi

q: nox.ffi.EventQueue = nox.ffi.EventQueue(4096)
lib_on_event(q.callback(1), q.userdata())   # void cb(int level, void *ud, double value): userdata is integer-class argument 1
while q.wait(1000):
    level: int = q.int_arg(0)               # userdata is left out; the integer-class arguments follow in order
    value: float = q.float_arg(0)           # double arguments, in order
q.close()                                   # after unregistering the callback in the library
```

| Member | Meaning |
|---|---|
| `EventQueue(capacity = 1024)` | a queue of `capacity` events |
| `callback(ud_index)` | the C function pointer to give the library; `ud_index` (0 to 5) says which integer-class argument is the userdata |
| `userdata()` | the queue handle to pass as the callback's userdata |
| `poll()` / `wait(timeout_ms)` | fetch the next event (`wait` waits cooperatively in a task); `True` when there is one |
| `int_arg(i)` / `float_arg(i)` / `float32_arg(i)` | argument `i` of the fetched event: integer-class (integers, pointers, `bool`, enums), `double`, or `float` (f32) |
| `set_return(v)` | the value the callback returns to C (ignored by `void` callbacks) |
| `pending()` / `dropped()` | queued events / events discarded because the queue was full (the library's thread is never blocked) |
| `close()` | stop accepting events; unregister the callback in the library first |

`EventQueue(...)` and `callback(...)` raise `FfiError` when the platform does not support queues (Windows), the queue cannot be allocated, or `ud_index` is outside 0 to 5.

Limits: at most 6 integer-class and 4 `double` arguments, no struct arguments by value, macOS and Linux only (the C function relies on the System V / AAPCS64 argument registers).
With `noxc bindgen`, list the function under `event_callbacks` in the config so its callback parameter stays a plain `ptr`.

## errno helpers

| Function | Meaning |
|---|---|
| `errno()` | the current C `errno` (0 on Windows) |
| `errno_text()` | its `strerror` text (`"errno N"` when 0 or unsupported) |
| `is_null(p)` | `True` when the `ptr` is NULL |
| `null()` | the NULL `ptr` |
| `cstr(p)` | copy a NUL-terminated C string (`char *`) into a Nox `str` (NULL gives `""`) |
| `cstr_n(p, n)` | the same for an `n`-byte region |
| `alloc(n)` / `release(p)` | `n` zeroed bytes of C memory (output parameters, structs) / free it |

[`@ffi.errors(errno=True)`](../language/ffi.md#errors) uses `errno_text()` for you (it needs `import nox.ffi`); call them directly when you wrap an API yourself.
