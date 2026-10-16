# nox.hpy

Load an aHPy Universal package (`nox-hpy-host-v1`). The facade opens the manifest, checks the artifact for this machine, and calls the extension. It never hands out a raw pointer.

```text
from nox.hpy import Module, Object, load_package
```

**Capability:** filesystem. This is a preview profile, not part of the stable 2.x library surface. A package's native code runs with the process's own privileges.

## Functions

| Function | Description |
|---|---|
| `host_profile()` | the profile string `nox-hpy-host-v1` |
| `host_abi()` | the ABI string `universal` |
| `load_package(root)` | reads `root/nox-hpy.json`, verifies the artifact for this target, and returns an open `Module` |

## `Module`

`load_package` returns a `Module`. Close it with `close`, or use `with`, which calls `__enter__` and `__exit__`. A closed module raises `HPyError`. One module is not shared across operating-system threads. Calls run on the caller's fiber.

| Method | Description |
|---|---|
| `call_int(name)` | calls `name` with no arguments and returns an `int` |
| `call_int_arg(name, arg)` | calls `name` with one `int` |
| `call_bool(name)` | returns a `bool` |
| `call_float(name)` | returns a `float` |
| `call_float_arg(name, arg)` | calls `name` with one `float` |
| `call_str(name)` | returns a `str` |
| `call_str_arg(name, arg)` | calls `name` with one `str` |
| `call_bytes(name, arg)` | `arg` and the result are `list[int]` values in `0..255`, including embedded zeros. The manifest must list the `bytes` capability |
| `call_int_keyword(name, key, arg)` | one keyword argument. The manifest must list `call-keywords` |
| `call_object(name)` | returns an `Object` |
| `construct(class_name, arg)` | calls the named constructor with one `int` and returns an `Object` |

## `Object`

An `Object` is an opaque extension value. `close` releases it. `call(name)` and `call_int(name, arg)` invoke a method and return an `int`.

```nox
import nox.hpy

print(nox.hpy.host_profile())
print(nox.hpy.host_abi())
```

```output
nox-hpy-host-v1
universal
```
