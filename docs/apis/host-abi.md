# Host ABI (`nox_host.h`) — experimental

The Host ABI lets a **C or Python host** call Nox code: it is the reverse direction of [NNI](nni.md) (where Nox calls native plugins). A Nox library marked with
`@export` is compiled with `--host-abi`; the host then talks to it through a small, versioned C header, `include/nox_host.h`.

> **Experimental (ABI v2 → v3, being frozen).** v2 only *adds* the value-tree API and v3 (UR-009 … UR-014) only *adds* classes, callbacks, tasks, buffers and capabilities; hosts built against v1/v2 (`abi_version = 1` or `2`) keep working. `abi_version`/`struct_size` carry versioning, but the interface may change incompatibly until it has been validated by real hosts
> (for example NoxPy). It is **not** covered by the NNI binary-compatibility promise. Native code called this way runs with full native authority — the host is
> outside Nox's type and ownership guarantees ([trust boundary](../language/ffi.md)).

## Building

```text
noxc build --emit-obj --host-abi --module-name fastmath src/lib.nox          # relocatable PIC object
noxc build --emit-shared-lib --host-abi --module-name fastmath src/lib.nox   # .so / .dylib exporting only nox_host_* symbols
```

Top-level `def`s and `class`es decorated with `@export` are exported (the same set `noxc expand --json` reports). `--host-abi` needs the LLVM backend and a desktop target.
In the shared-library form every symbol except `nox_host_*` is made local (macOS `-exported_symbols_list`, ELF `--version-script`), so two independently built Nox
extensions can live in one process without symbol clashes. Link an object or static archive yourself with the same export policy.

## Type mapping

| Nox | C parameter | C return (`out` pointer) |
|---|---|---|
| `int` | `int64_t` | `int64_t *` |
| `float` | `double` | `double *` |
| `bool` | `uint8_t` (0/1) | `uint8_t *` |
| `str` | `const uint8_t *data, size_t len` (UTF-8, validated) | `NoxHostBuffer *` (host frees) |
| `bytes` | `const uint8_t *data, size_t len` (raw, embedded zeros kept) | `NoxHostBuffer *` |
| class instance | `NoxHostHandle` | `NoxHostHandle *` |
| `nox.host.HostObject` (v3) | `NoxHostExternalRef` | `NoxHostExternalRef *` (a new host-owned reference) |
| `Class \| None`, `list[Class]`, … (v3) | `NoxHostValue` (`NOX_HOST_VALUE_HANDLE` items) | `NoxHostValue *` |
| `T \| None`, `list[T]`, `dict[K, V]`, `tuple[...]` | `NoxHostValue` (v2) | `NoxHostValue *` (v2; host releases) |
| `None` | — | no `out` parameter |

Every export has the shape `NoxHostStatus nox_host_export_<module>_<name>(NoxHostContext *ctx, <params>, [<ret> *out,] NoxHostError **err)`.
`err` may be `NULL`. A Nox exception is **contained**: the call returns `NOX_HOST_ERR_EXCEPTION` and `*err` can be inspected with `nox_host_error_class_name`,
`nox_host_error_message` and `nox_host_error_line`, then freed with `nox_host_error_release`. Release errors before destroying their context.

## Containers, `Optional` and tuples (`NoxHostValue`, ABI v2)

Containers cross the boundary as **opaque, generation-checked value trees** owned by the context — never as Nox objects, so no internal list/dict/Optional layout is visible.
Build arguments with `nox_host_value_int/float/bool/str/none/container` + `nox_host_value_append` / `nox_host_value_dict_set`, read results with `nox_host_value_kind/len/item/dict_entry/get_*`,
and release **every** handle you hold with `nox_host_value_release` (parameter handles are only borrowed for the call; a returned handle is yours). Appending does not invalidate the
appended handle; appending a value into itself (a cycle) is `NOX_HOST_ERR_INVAL`. `T | None` is simply the `none` kind or a `T` value; `dict` keeps insertion order and a repeated key
replaces the value; `tuple` uses `NOX_HOST_VALUE_TUPLE` with one item per element.

```c
NoxHostValue xs, out; int64_t sum;
nox_host_value_container(ctx, NOX_HOST_VALUE_LIST, &xs);
for (int i = 1; i <= 4; i++) { NoxHostValue v; nox_host_value_int(ctx, i, &v); nox_host_value_append(ctx, xs, v); nox_host_value_release(ctx, v); }
nox_host_export_lib_sum_list(ctx, xs, &sum, &err);          // @export def sum_list(xs: list[int]) -> int
nox_host_value_release(ctx, xs);
```

How it works: for each `@export` whose signature contains a container/`Optional`, `noxc --host-abi` appends a small Nox *adapter* to the module (`nox_host_adapt_<name>`) that converts the
handles to Nox values with Nox's own code generator, calls your function and converts the result back; the exported C symbol is still `nox_host_export_<module>_<name>`. A value of the wrong
kind (a `str` where a `list` is expected, a wrong tuple length, a stale handle) surfaces as a `ValueError` (`NOX_HOST_ERR_EXCEPTION`).

Supported element types: `int`, `float`, `bool`, `str`, `bytes`, **user classes (v3)**, nested `list`/`dict` (scalar keys)/`tuple`, and `T | None`. Not supported inside containers:
`int | None` / `float | None` / `bool | None` (the Nox compiler itself cannot build such lists yet; `str | None` and container `| None` elements work). `noxc expand --json` reports
the transfer form of every parameter and return value as `marshal`/`return_marshal` (`scalar`, `span`, `handle`, `value`, `none`).

## Exported classes (ABI v3, UR-009)

```python
@export("instance_locked")          # optional thread policy, reported in `expand --json`
class Counter:
    def __init__(self, start: int) -> None: ...
    def inc(self, by: int) -> int: ...
    @property
    def value(self) -> int: ...
    @value.setter
    def value(self, v: int) -> None: ...
    @staticmethod
    def zero() -> int: ...
    @classmethod
    def make(cls, start: int) -> Counter: ...
    def __repr__(self) -> str: ...

@export
class CounterError(ValueError): ...   # metadata only: errors surface as NoxHostError with this class name
```

Each exported class produces C functions named `nox_host_export_<module>_<Class>_<member>`:

| Member | C symbol suffix | C shape (after `ctx`) |
|---|---|---|
| constructor (`__init__` params; none → no params) | `<Class>___new__` | `<params>, NoxHostHandle *out, err` |
| instance method / `__repr__ __str__ __eq__ __len__ __iter__ __next__ __enter__ __exit__` | `<Class>_<name>` (`<Class>___repr__`) | `NoxHostHandle self, <params>, [ret *out,] err` |
| `@property` getter / setter | `<Class>_get_<name>` / `<Class>_set_<name>` | `NoxHostHandle self, [value]` |
| `@staticmethod` / `@classmethod` | `<Class>_<name>` | `<params>, [ret *out,] err` (no `self`; `cls` is the class) |

Methods starting with `_` (other than the dunders above), generic/enum/`@dataclass` classes and `async` methods are not exported (`--host-abi` rejects the unsupported ones with a clear message).
`noxc expand --json` reports `"kind": "class"` (with `constructor` and `methods[]`: `method_kind` = `instance | staticmethod | classmethod | property_get | property_set | dunder`, `has_self`,
`c_symbol`, `params` without `self`, `return_type`, `return_marshal`, `thread_policy`, `is_async`) and `"kind": "exception"` (with `base`). Since the checker strips `@property`/`@staticmethod`
from class bodies, the metadata is taken from the source tree *before* checking.

Handles are type-unchecked on the way in (a handle of another class is undefined behaviour), so a host verifies a handle with `nox_host_handle_type_name(ctx, h, &span)` (the Nox class name, e.g. `"Counter"`).
Class instances inside containers travel as `NOX_HOST_VALUE_HANDLE` values: `nox_host_value_handle(ctx, h, &v)` wraps a handle's object (the host keeps and releases its own handle) and
`nox_host_value_get_handle(ctx, v, &h)` gives a **new** handle (release it with `nox_host_handle_release`). `Class | None` uses `nox_host_value_none` for `None`. Inside containers only the *exact* class
is accepted (a subclass instance or another class raises `ValueError`); top-level `NoxHostHandle` parameters have no such restriction.

## Host objects and callbacks (ABI v3, UR-010)

A Nox extension can hold and call opaque host objects (a Python callable, say) through `nox.host.HostObject` (see [nox.host](../stdlib/host.md)). The host identifies such an object by a
`NoxHostExternalRef` (`uint64_t`, 0 invalid) and installs one `NoxHostCallbackOps` table per context with `nox_host_context_set_callbacks` (`struct_size` must be at least `sizeof`; a table without
`invoke` is `NOX_HOST_ERR_INVAL`; `NULL` removes the table; clear it only after the Nox objects holding refs are gone):

```c
typedef struct NoxHostCallbackOps {
    uint32_t struct_size; void *user_data;
    NoxHostStatus (*invoke)(void *user_data, NoxHostContext *ctx, NoxHostExternalRef target, NoxHostValue args_tuple,
                            NoxHostValue *out_result, uint64_t *out_err_token, NoxHostBuffer *out_err_msg);
    void (*retain)(void *user_data, NoxHostExternalRef ref);
    void (*release)(void *user_data, NoxHostExternalRef ref);
} NoxHostCallbackOps;
```

- **Reentrancy.** `invoke`, `retain` and `release` run with the context lock **released**; the callback may call `nox_host_value_*` or any `nox_host_export_*` on the same context. After it returns the lock is re-taken.
- **Arguments/result.** `args_tuple` is a borrowed `NOX_HOST_VALUE_TUPLE`. The callback builds `*out_result` with `nox_host_value_*` (leave it `0` for `None`); Nox owns and releases it.
- **Exceptions.** Return `NOX_HOST_ERR_HOST_EXCEPTION` and set `*out_err_token` (a host reference; one `+1` passes to Nox) and optionally `*out_err_msg` (UTF-8, *borrowed*: copied before `invoke`
  returns, no `nox_host_buffer_release`). Nox raises `nox.host.HostError`. If it is not caught, the export returns `NOX_HOST_ERR_HOST_EXCEPTION` and `nox_host_error_host_token(err)` yields the token so the host
  can restore its original exception; the token's `release` callback fires when the error is released (read the token first). Any other non-OK status becomes a `RuntimeError`.
- **Values.** `NOX_HOST_VALUE_EXTERNAL_REF` (`nox_host_value_external_ref` / `nox_host_value_get_external_ref`) carries a ref inside containers (`retain` on creation, `release` when the value is released).
- A `HostObject` returned from an `@export` function gives the host a **new** reference (the host releases it itself).

## Lifecycle

1. `nox_host_context_create` — a context owns one isolated Nox runtime.
2. `nox_host_module_init_<module>(ctx, &err)` — runs the module's top-level code and allocates its globals *for this context*.
3. Calls to `nox_host_export_<module>_<name>`.
4. `nox_host_module_fini_<module>(ctx)`, then `nox_host_context_destroy(ctx)` (open handles are released).

## Threads

A context is guarded by a lock: **any OS thread may use a context, one call at a time**. Contexts are completely independent, so the parallel pattern is **one
context per thread**. There is no fixed table of thread slots, so threads may come and go without limit. Callbacks into the host (v3) run with the lock released (see above).

## Handles

A class instance crosses the boundary as an opaque `NoxHostHandle` (generation-checked, owned by the context that produced it). A released, forged or foreign
handle is rejected with `NOX_HOST_ERR_INVALID_HANDLE`; the raw object layout is never visible. `nox_host_handle_retain` makes a second handle to the same object.

## Export metadata (`noxc expand --json`)

Types are spelled canonically as written in Nox source: `tuple[int, str]`, `list[int | None]`, `dict[str, tuple[int, float]]`, `int | None` (never the compiler-internal
`tuple__int_str`). Each parameter carries `has_default` and, since v2.2.85, `default`: `null` when there is none, otherwise `{"type": "int|float|bool|str|None|bytes", "value": ...}`
(`bytes` uses `"hex"`). Defaults are always constant literals (the checker rejects anything else), so a host can apply them without running Nox code.

## Known limits

- Out-of-memory and fixed-width integer overflow traps terminate the process; they cannot be turned into a recoverable error (Nox has no unwind tables).
- `async def` exports, generics and host-provided allocators are not supported yet (v3 work in progress: UR-011 … UR-013).
- The static archive form cannot hide the runtime's symbols.
