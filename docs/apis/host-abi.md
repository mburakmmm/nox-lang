# Host ABI (`nox_host.h`) — experimental

The Host ABI lets a **C or Python host** call Nox code: it is the reverse direction of [NNI](nni.md) (where Nox calls native plugins). A Nox library marked with
`@export` is compiled with `--host-abi`; the host then talks to it through a small, versioned C header, `include/nox_host.h`.

> **Experimental (ABI v2).** v2 only *adds* the value-tree API; hosts built against v1 (`abi_version = 1`) keep working. `abi_version`/`struct_size` carry versioning, but the interface may change incompatibly until it has been validated by real hosts
> (for example NoxPy). It is **not** covered by the NNI binary-compatibility promise. Native code called this way runs with full native authority — the host is
> outside Nox's type and ownership guarantees ([trust boundary](../language/ffi.md)).

## Building

```text
noxc build --emit-obj --host-abi --module-name fastmath src/lib.nox          # relocatable PIC object
noxc build --emit-shared-lib --host-abi --module-name fastmath src/lib.nox   # .so / .dylib exporting only nox_host_* symbols
```

Only top-level `def`s decorated with `@export` are exported (the same set `noxc expand --json` reports). `--host-abi` needs the LLVM backend and a desktop target.
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

Supported element types: `int`, `float`, `bool`, `str`, `bytes`, nested `list`/`dict` (scalar keys)/`tuple`, and `T | None`. Not supported inside containers: class instances, and
`int | None` / `float | None` / `bool | None` (the Nox compiler itself cannot build such lists yet; `str | None` and container `| None` elements work). `noxc expand --json` reports
the transfer form of every parameter and return value as `marshal`/`return_marshal` (`scalar`, `span`, `handle`, `value`, `none`).

## Lifecycle

1. `nox_host_context_create` — a context owns one isolated Nox runtime.
2. `nox_host_module_init_<module>(ctx, &err)` — runs the module's top-level code and allocates its globals *for this context*.
3. Calls to `nox_host_export_<module>_<name>`.
4. `nox_host_module_fini_<module>(ctx)`, then `nox_host_context_destroy(ctx)` (open handles are released).

## Threads

A context is guarded by a lock: **any OS thread may use a context, one call at a time**. Contexts are completely independent, so the parallel pattern is **one
context per thread**. There is no fixed table of thread slots, so threads may come and go without limit. Callbacks into the host are not part of v1.

## Handles

A class instance crosses the boundary as an opaque `NoxHostHandle` (generation-checked, owned by the context that produced it). A released, forged or foreign
handle is rejected with `NOX_HOST_ERR_INVALID_HANDLE`; the raw object layout is never visible. `nox_host_handle_retain` makes a second handle to the same object.

## Export metadata (`noxc expand --json`)

Types are spelled canonically as written in Nox source: `tuple[int, str]`, `list[int | None]`, `dict[str, tuple[int, float]]`, `int | None` (never the compiler-internal
`tuple__int_str`). Each parameter carries `has_default` and, since v2.2.85, `default`: `null` when there is none, otherwise `{"type": "int|float|bool|str|None|bytes", "value": ...}`
(`bytes` uses `"hex"`). Defaults are always constant literals (the checker rejects anything else), so a host can apply them without running Nox code.

## Known limits

- Out-of-memory and fixed-width integer overflow traps terminate the process; they cannot be turned into a recoverable error (Nox has no unwind tables).
- `async def` exports, generics and host-provided allocators are not supported. Containers hold scalars, `str`/`bytes` and nested containers only (no class instances).
- The static archive form cannot hide the runtime's symbols.
