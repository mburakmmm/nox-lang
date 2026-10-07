# Nox API layers, the Framework Author Contract and the Native Interface (NNI v1)

Nox separates *what library and framework authors may rely on* from *what the compiler and runtime may freely change*.
There are four layers:

```
Nox 2.x
├── Language / Source API          normal .nox packages (source compatibility)
├── Framework Author Contract      what Aether / Nyx / Aura-style frameworks may rely on (this page, §1)
├── Nox Native Interface (NNI) v1  C ABI + opaque handles for native extensions (§2, include/nox_nni.h)
└── Internal Runtime ABI           compiler ↔ runtime ↔ stdlib shims: PRIVATE, unstable (§3)
```

The one hard rule: **the public Native Interface and the Internal Runtime ABI are different things and must never be
confused.** ARC header layout, `RuntimeState`, string/list/class memory layouts and `nox_*` runtime symbols are internal.

## 1. Framework Author Contract

### Stable (source compatibility within a major version)

| Area | What is promised |
|---|---|
| Language semantics | Everything documented in [`LANGUAGE.md`](LANGUAGE.md): typing rules, evaluation order (arguments with side effects evaluate left to right), integer overflow (fixed-width traps on every backend, `int` wraps), operator/dunder protocol, `Exception` hierarchy, `break/continue/defer/with/finally` cleanup |
| Public stdlib | The signatures and documented behaviour of `nox.*` modules in [`STDLIB.md`](STDLIB.md). Names beginning with `__nox_`, and anything marked deprecated or experimental, are excluded |
| Reflection | The `nox.reflect` metadata API for decorators (function/method/class metadata queries) |
| Concurrency | `async def`/`spawn`/`await` semantics, `Task`/`Channel` semantics, cancellation behaviour (`CancelledError`), `nox.thread` transfer rules |
| HTTP | `nox.http` client/server abstractions (`HttpRequest`/`HttpResponse` fields and constructors), `nox.router` |
| FFI | `extern def` C-ABI mapping of Nox types; `@ffi.callback` trailing-userdata convention |
| Packages | `nox.json` manifest and `nox.lock` format, `requires[]` resolution |
| Native extensions | NNI v1 (§2) |

### Not stable (may change in any release)

AST and compiler internals · QBE IR and LLVM IR output · ARC header layout · object, list, dict, string layouts ·
`RuntimeState` · cycle collector implementation · generated symbol names (`Class_method`, `tuple__int_str`, `__nox_*`) ·
every `nox_*` runtime symbol that is not part of NNI · the contents of the prelude (`stdlib/nox/core.nox`) beyond its documented
names · **binary compatibility between separately compiled Nox object files** (there is no promise that a `.o` built by one
Nox version links with code built by another).

### Source-level guidance for frameworks

Aether-, Nyx- and Aura-style frameworks written in Nox depend on *source-level* features, not on a binary ABI: generics
(including higher-order generics), callbacks, `nox.reflect`, allocator-independent collections, the task scheduler, and
`extern def` / NNI for native engines. Prefer the narrow `nox.mem`, `nox.atomic`, `nox.thread`, `nox.fs`, `nox.os`, `nox.reflect`
modules over reaching into runtime symbols.

## 2. Nox Native Interface (NNI) v1

A native extension is a shared library (`.so` / `.dylib` / `.dll`) written in C, C++, Rust or Zig against
[`include/nox_nni.h`](../include/nox_nni.h). It exports one symbol:

```c
NOX_EXPORT NoxStatus nox_plugin_init_v1(const NoxApiV1* api, NoxRuntime* rt);
```

The host calls it with a **versioned function table**; the plugin checks `api->abi_version` / `api->struct_size` and registers its
functions with `api->register_function`. From Nox:

```nox
from nox.native import open_plugin, Plugin, Event, NativeError

p: Plugin = open_plugin("./libmyext.so")
p.arg_int(20)
p.arg_str("hello")
n: int = p.call_int("add_len")         # also call_float / call_bool / call_str / call
```

### What crosses the boundary

* **`NoxValue`** — a tagged 16-byte value: `none`, `int` (i64), `float` (f64), `bool`, `string`, `bytes`.
* **Opaque handles** (`NoxHandle`, generation-counted indexes; `0` is never valid) for strings and byte buffers. A released or
  stale handle is detected (`NOX_BAD_HANDLE`), never dereferenced. A plugin never sees a pointer into Nox's heap.
* **Strings** are validated UTF-8 (`string_new` returns `0` on invalid input); `string_view` gives a read-only view valid while the
  handle lives.
* **Allocator** — `alloc` / `free` forward to the host allocator.
* **Errors** — a native function returns `NOX_OK`, `NOX_ERROR` (after `error_set`, becomes a Nox `NativeError` carrying the
  message), or `NOX_PANIC`. No exception, `longjmp` or unwinding ever crosses the boundary in either direction.
* **Versioning** — new API members are only appended to `NoxApiV1`; old plugins keep working because they gate on `struct_size`.

### Threading contract

1. Native functions run **synchronously on the thread that called them from Nox**.
2. `retain` / `release` / `string_new` / `string_view` / `bytes_*` are internally locked and safe from any thread.
3. A native thread never enters the Nox object graph. To send work or results back it calls the thread-safe
   `post_event(rt, kind, payload)`; payloads (strings/bytes) are **copied** into the host queue. Nox code drains events with
   `Plugin.poll_event()` / `Plugin.wait_event(timeout_ms)` on its own scheduler (this is the "native → Nox callback" model:
   *native thread → `post_event` → Nox scheduler → Nox code*).
4. `register_function` is valid only during `nox_plugin_init_v1`.

### Deliberately out of NNI v1

Direct list/dict/object memory access, class layouts, reflection ABI, GC hooks, Nox closures as C function pointers, precompiled
Nox-to-Nox binary linking. These keep the runtime free to change (different RC schemes, arenas, a nursery…) without ever
breaking a plugin. A versioned *Plugin* contract (lifecycle, capabilities, dependency declaration) can be layered on top later.

### Trust boundary

A plugin runs with full native authority, exactly like `extern def` (see `AGENTS.md` §9.5). NNI does not sandbox it.

## 3. Internal Runtime ABI

Everything the compiler emits calls into the runtime through `nox_*` symbols (`nox_rc_alloc`, `nox_list_grow`, `nox_dict_set`,
`nox_cycle_*`, …). These are the *fast* primitives and are **private and unstable**: their names, signatures and the memory
layouts they imply may change in any release. Only the symbols declared in `include/nox_nni.h` (and the documented `extern def`
C ABI) are public. Native code must not link against, or hard-code the layout behind, any other `nox_*` symbol.

## 4. Roadmap

* NNI v1.x: `NoxValue` list/dict builders, richer event payloads, an optional `invoke_callback` for registered Nox functions.
* A dedicated Plugin ABI (manifest, capabilities, dependency declaration) on top of NNI.
* Making the internal-symbol boundary mechanical (a `__nox_internal_` prefix applied across runtime, compiler and stdlib shims) — a
  large mechanical rename that is intentionally not bundled with the first NNI release.
