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

## errno helpers

| Function | Meaning |
|---|---|
| `errno()` | the current C `errno` (0 on Windows) |
| `errno_text()` | its `strerror` text (`"errno N"` when 0 or unsupported) |
| `is_null(p)` | `True` when the `ptr` is NULL |

[`@ffi.errors(errno=True)`](../language/ffi.md#errors) uses `errno_text()` for you (it needs `import nox.ffi`); call them directly when you wrap an API yourself.
