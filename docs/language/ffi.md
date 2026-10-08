# Foreign functions

Nox calls native code through **`extern def`**: a declaration of a function implemented outside Nox — in C, Zig, Rust (with a C ABI), or
the system libraries — callable from Nox with normal static typing at the boundary. This page covers `extern def`, raw pointers, callbacks
and the trust boundary. For richer integrations see [the three APIs](../apis/index.md): the **Nox Native Interface** for plugins that keep
the runtime's data structures private, and the HPy/WASM bridges in [Internals](../internals/hpy-wasm.md).

## `extern def`

```nox
extern def malloc(n: int) -> ptr from "c"
extern def free(p: ptr) -> None from "c"
extern def sqrt(x: float) -> float from "m"
```

```text
extern def NAME(PARAMS) -> RETURN from "LIBRARY" [retains(p1, p2)]
```

(`with_rt`, which passes the hidden runtime-state pointer as the first argument, exists for the standard library's own runtime shims and is
not meant for user code.)

`from "LIBRARY"` says where the symbol lives:

- a **file path** (it contains `/` or ends in `.o` / `.a`) — an object or archive that is passed to the linker: `from "./add.o"`,
  `from "build/libfoo.a"`;
- otherwise a **system library name**, linked as `-l<name>`: `"m"` (libm), `"c"`, `"sqlite3"`.

The function name is the C symbol and is **never mangled**, so `extern def` functions are called unqualified after an import
([Modules](modules.md#qualified-access-has-two-quirks)). A library used by several declarations is linked once.

### Type mapping

| Nox | C ABI |
|---|---|
| `int` | `int64_t` |
| `float` | `double` |
| `bool` | integer `0`/`1` |
| `str` | `const char*` — NUL-terminated UTF-8, valid for the duration of the call |
| `None` (return) | `void` |
| `u8 … u64`, `i8 … i64`, `usize`, `isize` | the same-width C integer (`uint8_t`, …) |
| `ptr`, `ptr[T]` | `void*` / `T*` |
| `(P…, ptr) -> R` | a C function pointer, see [Callbacks](#callbacks) |
| `dict[str, str]` | an opaque handle (runtime shims only) |

Only these types may cross the boundary; classes, lists, `Optional` values and so on are rejected at compile time. The *return* of a
`str` from native code is reserved for the runtime's own shims (the string must be built with the runtime's allocator); plugins that need
to return text use the [Nox Native Interface](../apis/nni.md).

```nox
extern def malloc(n: int) -> ptr from "c"
extern def free(p: ptr) -> None from "c"

def demo() -> int:
    total: int = 0
    lowlevel:
        raw: ptr = malloc(16)
        p: ptr[i32] = ptr[i32](ptr_to_int(raw))
        ptr_write(ptr_offset(p, 0), i32(7))
        ptr_write(ptr_offset(p, 1), i32(35))
        total = int(ptr_read(ptr_offset(p, 0))) + int(ptr_read(ptr_offset(p, 1)))
        free(raw)
    return total

print(demo())
```

```output
42
```

A call to a native function that returns a fixed-width integer keeps its type (`print(f(u8(41)))` prints `42`).

### Calling your own native code

```text
// add.c  —  cc -c add.c -o add.o
#include <stdint.h>
int64_t c_add(int64_t a, int64_t b) { return a + b; }
```

```nox-fragment
extern def c_add(a: int, b: int) -> int from "add.o"
print(c_add(2, 40))        # 42
```

The same mechanism links a Zig object (`zig build-obj`), a static archive, or a system library — to Nox they are indistinguishable.

### Ownership across the call: `retains` and `@ffi.escape`

By default the compiler assumes native code **does not keep** the pointers and strings it is given beyond the call, so Nox values may be
freed or reused immediately after. If a function stores an argument (a registry, a handle that outlives the call), list the
parameter in `retains(…)` or decorate the declaration with `@ffi.escape("param", …)`; `@ffi.noescape("param")` states the default
explicitly. Contradictory annotations are a compile error.

```nox-fragment
extern def take_list(xs: list[int]) -> None from "libexample.a" retains(xs)

@ffi.escape("xs")
extern def keep_ref(xs: ptr) -> None from "libexample.a"
```

### Errors

An `extern def` call has no exception channel of its own. Where a native API has an error convention (return codes, errno, a thread-local
error object), wrap the call in a Nox function that checks it and raises. The HPy/WASM bridges generate this translation automatically
(trampolines); for plain `extern def` it is your job.

## Callbacks

Native code may call back into Nox through an ordinary top-level function, using the **trailing-userdata convention** that most C libraries
(`qsort_r`, GLib, libuv) follow: the callback's last parameter is a `void*` that the library hands back untouched. Mark the declaration
with `@ffi.callback("cb", "userdata")`, naming the callback parameter and the `userdata` parameter; the compiler fills `userdata` itself
(you do **not** write that argument at the call site) and generates the trampoline.

```nox-fragment
def add_ints(a: int, b: int) -> int:
    return a + b

@ffi.callback("cb", "userdata")
extern def c_apply(cb: (int, int, ptr) -> int, a: int, b: int, userdata: ptr) -> int from "add.o"

print(c_apply(add_ints, 3, 4))
```

Rules: the callback type's last parameter must be `ptr`; every parameter and the result must be `int`, `float`, `bool` or `ptr`; the target must
be a plain top-level, non-`async`, non-`extern` `def`, passed by name (no lambdas, bound methods or closures). The callback runs
**synchronously** inside the native call — registering a callback to be called later (timers, event loops) is not supported. An exception
escaping the callback terminates the program.

## Raw pointers

`ptr` is an opaque address; `ptr[T]` is a typed address. They are only usable in [`lowlevel`](memory.md#lowlevel-blocks) code and exist
for FFI, kernels and device access:

| Operation | Meaning |
|---|---|
| `ptr[T](addr)` | a typed pointer from an `int` address |
| `ptr_to_int(p)`, `ptr_from_int(n)` | address ↔ integer |
| `ptr_offset(p, i)` | `p + i` elements (typed) |
| `ptr_read(p)`, `ptr_write(p, v)` | typed load / store |
| `ptr_read_volatile`, `ptr_write_volatile` | loads/stores the optimiser must not elide (memory-mapped I/O) |
| `memory_fence()`, `compiler_fence()` | ordering barriers |
| `detach(x)`, `adopt(p)` | turn a managed object into a raw pointer, and take a raw pointer back as a managed object of a given class |

Typed reads and writes are type-checked: `ptr_write(p, v)` requires `v` to have the pointee type. The [`nox.mem`](../stdlib/mem.md) module wraps
the common patterns (`copy`, `move`, `set`, volatile access) so ordinary code rarely needs a `lowlevel` block of its own.

## Sizes and layouts

`sizeof(T)`, `alignof(T)` and `offsetof(T, "field")` work for every type; `@repr("C")` and `@packed` give classes a defined layout to share
with C structs ([Classes](classes.md#layout-control-for-foreign-code)).

## The trust boundary

**`extern def` is raw native code execution.** The compiler marshals types and tracks reference counts around the call, but it cannot
constrain what the native function does: it runs with the full authority of the process — memory access, files, network — outside Nox's
type and ownership guarantees. Consequently:

- A bug in native code (bad alignment, an out-of-bounds write, retaining a pointer it was told not to) can corrupt the whole program.
- `lowlevel` blocks are part of the same boundary: they relax the allocation strategy, but `extern def` calls inside them are no safer.
- A **dependency** listed in `nox.json` may declare its own `extern def`s; adding it means trusting its native code
  ([Security](../reference/security.md)).
- The standard library's `nox.fs` and `nox.os` perform no path validation; sanitise untrusted paths yourself.

Nox deliberately has no "safe mode" for `extern def` in 2.0 — a sandbox needs a dedicated security design.

## Other foreign-code mechanisms

- **Nox Native Interface (NNI)** — a stable C ABI with opaque handles for plugins that must not depend on the runtime's layouts
  ([NNI](../apis/nni.md), [Plugin API](../apis/plugin-api.md)).
- **HPy / CPython extensions** — Python C extensions load through an opaque-handle compatibility layer; a raw `PyObject*` never crosses
  ([Internals](../internals/hpy-wasm.md)).
- **WebAssembly** — a WASM module can be imported like a native library; WASM is an *import* mechanism, never a compilation target.
