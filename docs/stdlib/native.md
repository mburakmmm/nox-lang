# nox.native

The Nox side of the [Nox Native Interface](../apis/nni.md): load a native plugin (a shared library exporting `nox_plugin_init_v1`), call the functions it registered, and receive events from its threads.
This is the **raw** interface; for manifests, typed signatures and capability consent use [`nox.plugin`](plugin.md), which is built on it.

```text
from nox.native import open_plugin, Plugin, Event, NativeError
```

**Capability:** none registered (hosted programs only).

## Functions and methods

| Member | Description |
|---|---|
| `open_plugin(path)` | loads the library at `path`, runs `nox_plugin_init_v1`, returns a `Plugin`; raises `NativeError` if it cannot be loaded or initialisation fails |
| `Plugin.arg_int(v)`, `arg_float(v)`, `arg_bool(v)`, `arg_str(v)` | pushes the next argument for the next call |
| `Plugin.clear_args()` | discards pushed arguments |
| `Plugin.call(name)` | calls the native function `name` with the pushed arguments, ignoring the result |
| `Plugin.call_int(name)`, `call_float(name)`, `call_bool(name)`, `call_str(name)` | calls and returns the result as that type |
| `Plugin.result_kind()` | the kind of the last result (`VALUE_NONE`=0, `VALUE_INT`=1, `VALUE_FLOAT`=2, `VALUE_BOOL`=3, `VALUE_STRING`=4, `VALUE_BYTES`=5) |
| `Plugin.poll_event()` | the next queued event from a native thread, or `None` |
| `Plugin.wait_event(timeout_ms)` | waits up to `timeout_ms` for an event; `None` on timeout |
| `Plugin.close()` | calls `nox_plugin_shutdown_v1` (if exported) and unloads the library |

An `Event` carries `kind` (the number the plugin chose), `value_kind`, `int_value`, `float_value` and `str_value`.

A native function that reports failure raises `NativeError` with the plugin's message; calling an unregistered name raises `NativeError`. Arguments are not type-checked here — the plugin must validate them (the manifest-based
[`nox.plugin`](plugin.md) checks them for you).

```nox
from nox.native import open_plugin, Plugin, NativeError

def try_load(path: str) -> str:
    try:
        p: Plugin = open_plugin(path)
        p.close()
        return "loaded"
    except NativeError as e:
        return "not loaded"

print(try_load("/definitely/not/a/plugin.so"))
```

```output
not loaded
```

See the [NNI guide](../apis/nni-guide.md) for complete plugins in C, Zig and Rust.

## Trust

A plugin runs with full native authority ([Security](../reference/security.md)).
