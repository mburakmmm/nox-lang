# nox.plugin

The Nox side of the [Plugin API](../apis/plugin-api.md): load a native plugin through a `nox-plugin.json` manifest, with API-version negotiation, platform library selection, typed call checking, a registration
cross-check and capability consent. It is a thin, pure-Nox layer over [`nox.native`](native.md).

```text
from nox.plugin import load_plugin, LoadedPlugin, PluginManifest, FunctionSpec, PluginError
```

**Capability:** none registered (hosted programs only).

The complete specification — the manifest schema, types, capabilities, errors and lifecycle — is on the [Plugin API](../apis/plugin-api.md) page. This page lists the module's surface.

## Constants and functions

| Item | Description |
|---|---|
| `PLUGIN_API_VERSION` | the Plugin API version this runtime implements (`1`) |
| `load_plugin(manifest_path, allowed)` | reads and validates the manifest, checks every declared capability against `allowed` (`"*"` grants all), loads the library, runs init, cross-checks the registered functions and returns a `LoadedPlugin` |
| `read_manifest(manifest_path)` | parses and validates a manifest and returns a `PluginManifest` without loading anything |
| `host_platform()` | the platform key (`"macos-arm64"`, `"linux-x64"`, `"linux-arm64"`, `"windows-x64"`) |
| `capability_granted(cap, allowed)` | whether `cap` is permitted by the list `allowed` |
| `obj_get(v, key)`, `dir_of(path)`, `kind_ok(kind)`, `require_string(v, key, what)` | internal helpers used by the manifest reader; they are public but not part of the stable API |

## Classes

| Class | Description |
|---|---|
| `PluginManifest` | the validated manifest: `name`, `version`, `plugin_api`, `library` (the resolved path for this platform), `capabilities`, `functions` |
| `FunctionSpec` | one declared function: `name`, `args` (a list of type names, possibly ending in `"..."`), `returns` |
| `LoadedPlugin` | a loaded plugin: `manifest`; `has_function(name)`, `spec_of(name)`; `arg_int/arg_float/arg_bool/arg_str`; `call`, `call_int`, `call_float`, `call_bool`, `call_str`; `poll_event`, `wait_event`; `clear_args`, `reset_args`, `finish`, `check_call`; `shutdown` |
| `PluginError` | raised for manifest, version, capability, registration and call-signature problems |

```nox
from nox.plugin import read_manifest, host_platform, capability_granted, PluginError, PLUGIN_API_VERSION

print(PLUGIN_API_VERSION, host_platform() != "", capability_granted("net", ["fs.read"]), capability_granted("net", ["*"]))
try:
    read_manifest("/no/such/nox-plugin.json")
except PluginError as e:
    print("no manifest")
```

```output
1 True False True
no manifest
```

For the end-to-end flow (building a plugin and loading it) see the [NNI guide](../apis/nni-guide.md).
