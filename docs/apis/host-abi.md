# Host ABI (`nox_host.h`) — experimental

The Host ABI lets a **C or Python host** call Nox code: it is the reverse direction of [NNI](nni.md) (where Nox calls native plugins). A Nox library marked with
`@export` is compiled with `--host-abi`; the host then talks to it through a small, versioned C header, `include/nox_host.h`.

> **Experimental v1.** `abi_version`/`struct_size` carry versioning, but the interface may change incompatibly until it has been validated by real hosts
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
| `None` | — | no `out` parameter |

Every export has the shape `NoxHostStatus nox_host_export_<module>_<name>(NoxHostContext *ctx, <params>, [<ret> *out,] NoxHostError **err)`.
`err` may be `NULL`. A Nox exception is **contained**: the call returns `NOX_HOST_ERR_EXCEPTION` and `*err` can be inspected with `nox_host_error_class_name`,
`nox_host_error_message` and `nox_host_error_line`, then freed with `nox_host_error_release`. Release errors before destroying their context.

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
- `async def` exports, generics, lists/dicts/`Optional` parameters and host-provided allocators are not part of v1.
- The static archive form cannot hide the runtime's symbols.
