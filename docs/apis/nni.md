# NNI — the Nox Native Interface (v1)

NNI is a **C ABI** that lets native code — C, C++, Rust, Zig — extend Nox programs without ever depending on how the runtime represents data. A
native extension is a shared library (`.so`, `.dylib`, `.dll`) that exports one entry point. The host hands it a **versioned table of functions**;
everything that crosses the boundary is a plain C value or an **opaque handle**. A plugin never sees a pointer into Nox's heap, the reference-count
header, a string layout or a generated symbol name — so the runtime stays free to change all of them without breaking a single plugin.

The header is [`include/nox_nni.h`](https://github.com/mburakmmm/nox-lang/blob/main/include/nox_nni.h). Plugins are loaded from Nox with
[`nox.native`](../stdlib/native.md) (raw) or, with manifests and consent, [`nox.plugin`](plugin-api.md).

## The entry point

Every plugin exports exactly one required symbol:

```c
NOX_EXPORT NoxStatus nox_plugin_init_v1(const NoxApiV1* api, NoxRuntime* rt);
```

The host calls it once, on load, with the API table and an opaque per-plugin runtime context `rt`. The plugin must:

1. check `api->abi_version` and `api->struct_size` and return `NOX_ABI_UNSUPPORTED` if the host is too old for what it needs;
2. register its functions with `api->register_function(rt, "name", fn)`;
3. return `NOX_OK`.

An optional second symbol is called when the plugin is closed:

```c
NOX_EXPORT void nox_plugin_shutdown_v1(const NoxApiV1* api, NoxRuntime* rt);
```

If exported, the host calls it exactly once, on the thread that closes the plugin, just before the library is unloaded. Stop native threads and
release resources there.

## Status codes

```c
typedef int32_t NoxStatus;
enum {
    NOX_OK = 0,
    NOX_ERROR = 1,           /* recoverable error: becomes a Nox exception (message from error_set) */
    NOX_PANIC = 2,           /* unrecoverable plugin failure: terminates the call with an error */
    NOX_ABI_UNSUPPORTED = 3, /* returned by init when the host ABI is too old */
    NOX_BAD_HANDLE = 4,
    NOX_OUT_OF_MEMORY = 5,
    NOX_NOT_FOUND = 6
};
```

## Values

```c
enum { NOX_V_NONE = 0, NOX_V_INT = 1, NOX_V_FLOAT = 2, NOX_V_BOOL = 3, NOX_V_STRING = 4, NOX_V_BYTES = 5 };

typedef struct NoxValue {
    int32_t kind;      /* NOX_V_* */
    int32_t reserved;  /* set to 0 */
    union { int64_t i; double f; NoxHandle h; } u;
} NoxValue;
```

A `NoxValue` is 16 bytes. `NOX_V_INT` and `NOX_V_BOOL` use `u.i` (`0`/`1` for bool), `NOX_V_FLOAT` uses `u.f`, and `NOX_V_STRING` / `NOX_V_BYTES` carry a
**handle** in `u.h`.

### Handles

`NoxHandle` is a 64-bit **generation-counted index**. `0` is never valid. A handle that was released — or reused after release — is *detected*
(`NOX_BAD_HANDLE`), never dereferenced. Strings and byte buffers are only ever reachable through handles:

- `string_new(rt, data, len)` creates a string from **validated UTF-8**; it returns `0` on invalid UTF-8 or out of memory.
- `string_view(rt, h, &data, &len)` gives a read-only view valid **while the handle lives**.
- `bytes_new` / `bytes_view` are the same for raw byte buffers.
- `retain` / `release` adjust a handle's reference count.

Handles in the `args` of a call are owned by the host. A handle you store in `*out` transfers ownership to the host.

## The API table

```c
struct NoxApiV1 {
    uint32_t abi_version;   /* NOX_NNI_ABI_VERSION the host implements */
    uint32_t struct_size;   /* sizeof(NoxApiV1) of the host; never read members past this */

    void      (*retain)(NoxRuntime* rt, NoxHandle h);
    void      (*release)(NoxRuntime* rt, NoxHandle h);

    NoxHandle (*string_new)(NoxRuntime* rt, const uint8_t* data, size_t len);
    NoxStatus (*string_view)(NoxRuntime* rt, NoxHandle h, const uint8_t** data, size_t* len);
    NoxHandle (*bytes_new)(NoxRuntime* rt, const uint8_t* data, size_t len);
    NoxStatus (*bytes_view)(NoxRuntime* rt, NoxHandle h, const uint8_t** data, size_t* len);

    void*     (*alloc)(NoxRuntime* rt, size_t size, size_t alignment);
    void      (*free)(NoxRuntime* rt, void* p, size_t size, size_t alignment);

    NoxStatus (*error_set)(NoxRuntime* rt, int32_t code, const uint8_t* msg, size_t len);
    NoxStatus (*register_function)(NoxRuntime* rt, const char* name, NoxNativeFn fn);
    NoxStatus (*post_event)(NoxRuntime* rt, int64_t kind, const NoxValue* payload);
};
```

| Member | Contract |
|---|---|
| `retain`, `release` | thread-safe; adjust the reference count of any valid handle |
| `string_new`, `string_view`, `bytes_new`, `bytes_view` | thread-safe; see *Handles* |
| `alloc`, `free` | the host allocator (the one Nox uses for the plugin's context); `free` must receive the same size and alignment |
| `error_set` | records a message for the *current call* and returns `NOX_ERROR`; use as `return api->error_set(rt, code, msg, len);` |
| `register_function` | valid **only during** `nox_plugin_init_v1`; registers a callable by name |
| `post_event` | thread-safe, callable from **any** thread; copies string/bytes payloads; `kind` must be `>= 0` |

## Native functions

```c
typedef NoxStatus (*NoxNativeFn)(const NoxApiV1* api, NoxRuntime* rt,
                                 const NoxValue* args, size_t argc, NoxValue* out);
```

A native function receives the argument array and writes its result into `*out` (leave it as `NOX_V_NONE` for "no value"). It returns `NOX_OK`,
`NOX_ERROR` (after `error_set`, which becomes a Nox [`NativeError`](../stdlib/native.md) carrying the message) or `NOX_PANIC`. **No exception,
`longjmp` or unwinding may cross the boundary in either direction.**

Always validate: check `argc` and each `args[i].kind` before use, as the host does not know your function's signature (a [manifest](plugin-api.md)
lets it check for you).

## Threading contract

1. Native functions run **synchronously on the thread that called them** from Nox.
2. `retain`, `release`, `string_new`, `string_view` and `bytes_*` are internally locked and safe from any thread.
3. A native thread never enters the Nox object graph. To send work or results back it calls the thread-safe `post_event(rt, kind, payload)`;
   payloads are **copied** into a host queue. Nox code drains events with `Plugin.poll_event()` / `Plugin.wait_event(timeout_ms)` on its own
   scheduler. This is the "native → Nox callback" model: *native thread → `post_event` → Nox scheduler → Nox code*.
4. `register_function` is valid only during `nox_plugin_init_v1`.
5. A plugin that starts threads must stop them in `nox_plugin_shutdown_v1`.

## Versioning

New members are **only ever appended** to the end of `NoxApiV1`. A plugin built against an older header stays valid because it gates on
`struct_size` before touching any later member. Incompatible changes would be a new `NoxApiV2` with a new entry symbol
(`nox_plugin_init_v2`), which a host can implement alongside v1.

## Deliberately out of NNI v1

Direct list/dictionary/object memory access, class layouts, reflection ABI, GC hooks, Nox closures as C function pointers and
precompiled Nox-to-Nox binary linking. Keeping these out is what lets the runtime change its reference-counting scheme, arenas or object layout
without ever breaking a plugin. A richer data-structure API (list/dictionary builders, an optional `invoke_callback`) is planned as appended
members for NNI v1.x.

## Platform notes

| Platform | Library | Notes |
|---|---|---|
| macOS | `lib<name>.dylib` | built with `-dynamiclib` |
| Linux | `lib<name>.so` | built with `-shared -fPIC` |
| Windows | `<name>.dll` | export with `__declspec(dllexport)` (`NOX_EXPORT`) |

The host loads libraries with `dlopen`/`LoadLibrary`; the plugin's own dependencies are resolved by the platform loader as usual.

## Trust boundary

A plugin runs with **full native authority**, exactly like `extern def` ([Security](../reference/security.md)). NNI does not sandbox it; its
handle checks protect the *host's data*, not the system from a malicious plugin.

See the [NNI guide](nni-guide.md) for complete working plugins in C, Zig and Rust.
