# The Plugin API

The Plugin API turns an [NNI](nni.md) library into a **product**: something with a name, a version, a declared set of functions with types, and a
declared set of capabilities that the host program must consent to before it loads. It is a thin, fully specified layer written in Nox
([`nox.plugin`](../stdlib/plugin.md)) on top of NNI — it adds no new binary interface, so every NNI plugin can be given a manifest.

What it adds over raw NNI:

- a **manifest** (`nox-plugin.json`) that describes the plugin and selects the right library for the current platform;
- **API version negotiation** (`plugin_api`);
- **typed signatures**: every call is checked against the declared argument and return types *before* native code runs;
- **registration cross-check**: the functions the library registered must be exactly the ones the manifest declares;
- **capability consent**: the host lists the capabilities it grants and a plugin that needs more is refused;
- a **lifecycle**: `load_plugin` … `shutdown`, with the optional `nox_plugin_shutdown_v1` hook.

## The manifest

`nox-plugin.json`, next to the library:

```json
{
  "name": "acme.image",
  "version": "1.2.0",
  "plugin_api": 1,
  "library": {
    "macos-arm64": "libimage.dylib",
    "linux-x64": "libimage.so",
    "linux-arm64": "libimage.so",
    "windows-x64": "image.dll"
  },
  "capabilities": ["fs.read"],
  "functions": [
    { "name": "resize", "args": ["int", "int", "str"], "returns": "str" },
    { "name": "version", "returns": "str" },
    { "name": "sum", "args": ["int", "..."], "returns": "int" }
  ]
}
```

### Fields

| Field | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | the plugin's identifier; reverse-DNS style (`acme.image`) is recommended |
| `version` | string | yes | the plugin's own version (semantic versioning recommended); informational |
| `plugin_api` | number | yes | the Plugin API version the manifest follows; **must equal** the host's (`1`) |
| `library` | object | yes | maps a **platform key** to the library file; paths are relative to the manifest's directory (absolute paths are used as given) |
| `capabilities` | array of strings | no | capabilities the plugin needs; default none |
| `functions` | array | yes | the functions the library registers, with signatures |

**Platform keys:** `macos-arm64`, `linux-x64`, `linux-arm64`, `windows-x64`. A manifest with no entry for the host platform is refused. Use
`nox.plugin.host_platform()` to see the key of the current machine.

### Function signatures

Each entry of `functions` has:

| Field | Meaning |
|---|---|
| `name` | the name the library passes to `register_function` |
| `args` | array of argument types, in order; omit or `[]` for none |
| `returns` | the return type |

Types: `"int"` (NNI `NOX_V_INT`), `"float"`, `"bool"`, `"str"` (a validated-UTF-8 string handle) and, for `returns` only, `"none"`. A trailing `"..."` in
`args` makes the **previous** type repeat zero or more times (`["int", "..."]` is one required integer followed by any number of integers; `"..."`
cannot be first).

## Loading and calling

```nox-fragment
from nox.plugin import load_plugin, LoadedPlugin, PluginError

p: LoadedPlugin = load_plugin("plugins/image/nox-plugin.json", ["fs.read"])
p.arg_int(640)
p.arg_int(480)
p.arg_str("photo.png")
out: str = p.call_str("resize")
p.shutdown()
```

`load_plugin(manifest_path, allowed)` performs these steps in order, raising `PluginError` at the first failure:

1. read and **validate the manifest** — all required fields, known types, the `plugin_api` version, a `library` entry for this platform;
2. **check capabilities** — every capability in the manifest must be in `allowed`, or `"*"` must be present in `allowed`;
3. **load the library** and call `nox_plugin_init_v1` (a failure raises `PluginError` with the plugin's message);
4. **cross-check registration** — the set of functions the library registered must equal the manifest's `functions`;
5. return a `LoadedPlugin`.

### `LoadedPlugin`

| Member | Description |
|---|---|
| `manifest` | the parsed `PluginManifest` (`name`, `version`, `plugin_api`, `library` path, `capabilities`, `functions`) |
| `has_function(name)` | whether the manifest declares `name` |
| `arg_int(v)`, `arg_float(v)`, `arg_bool(v)`, `arg_str(v)` | push the next argument |
| `call(name)` | call a function declared `returns: "none"` |
| `call_int(name)`, `call_float(name)`, `call_bool(name)`, `call_str(name)` | call and read the result; the requested kind must match `returns` |
| `poll_event()`, `wait_event(timeout_ms)` | drain events a native thread posted ([NNI](nni.md#threading-contract)) |
| `clear_args()` | discard pushed arguments |
| `shutdown()` | call the plugin's `nox_plugin_shutdown_v1` (if exported), unload it; later calls raise `PluginError` |

Before every call the pushed arguments are compared with the manifest signature — count (honouring `"..."`) and each type — and the requested
`call_*` kind with `returns`. A mismatch raises `PluginError` **without calling native code** and discards the pushed arguments. If the native
function returns `NOX_ERROR`, the call raises `NativeError` with the plugin's `error_set` message. `NOX_PANIC` terminates the call with an error.

### Errors

| Situation | Exception |
|---|---|
| manifest missing, malformed, unknown type, wrong `plugin_api`, no library for this platform | `PluginError` |
| capability not in `allowed` | `PluginError` (`capability not granted: fs.read`) |
| library cannot be loaded / `nox_plugin_init_v1` fails | `PluginError` / `NativeError` |
| registered functions differ from the manifest | `PluginError` |
| wrong argument count/type, wrong `call_*` kind, unknown function, closed plugin | `PluginError` |
| the native function reports an error | `NativeError` |

## Capabilities

A capability is a short name for a kind of authority a plugin uses. The standard names are:

| Capability | Authority |
|---|---|
| `fs.read` | reads files or directories |
| `fs.write` | creates, modifies or deletes files |
| `net` | opens network connections or listens |
| `process` | starts processes or signals them |
| `env` | reads or changes environment variables |
| `threads` | starts native threads |
| `unsafe` | uses raw memory, loads other native code or otherwise bypasses the plugin's own checks |

The host passes the list it is willing to grant: `load_plugin(path, ["fs.read", "threads"])`; the joker `"*"` grants everything. A plugin that
declares `"net"` while the host grants only `["fs.read"]` is **refused at load time**, before any native code runs.

> **Capabilities are consent, not a sandbox.** They make a plugin's needs explicit and let the host (or a framework acting for its users) refuse a
> plugin that wants more than expected. After loading, the plugin runs with the full authority of the process. A malicious or buggy plugin can
> ignore its own declaration. Only load plugins you trust ([Security](../reference/security.md)).

## Lifecycle

```text
load_plugin ─▶ manifest validated ─▶ capabilities checked ─▶ library loaded ─▶ nox_plugin_init_v1
            ─▶ registration cross-checked ─▶ LoadedPlugin
            … calls … events …
shutdown ─▶ nox_plugin_shutdown_v1 (optional) ─▶ library unloaded
```

If a `load_plugin` step fails after the library was opened (for example a registration mismatch), the library is shut down and unloaded before the error
is raised, so a failed load leaves nothing behind.

## Versioning rules

- `plugin_api` is bumped only for incompatible changes to the manifest format or `nox.plugin` semantics. A Nox release that implements Plugin API 1
  loads every `plugin_api: 1` manifest; a manifest with a larger value is refused with a clear message.
- New **optional** manifest fields may be added within `plugin_api: 1`; unknown fields are ignored.
- A plugin's own `version` is independent and informational.
- The binary contract underneath is [NNI](nni.md): one plugin binary works across Nox releases that implement NNI v1.

## Writing a plugin

See the [NNI guide](nni-guide.md) for complete C, Zig and Rust plugins with manifests, event threads, testing and packaging.
