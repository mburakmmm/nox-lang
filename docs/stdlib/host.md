# nox.host

Host callbacks for [Host ABI](../apis/host-abi.md) extensions (experimental Nox surface; the C ABI it rests on is `nox_host.h` v3).

```text
import nox.host
from nox.host import HostObject, HostArgs, HostResult, HostError
```

**Capability:** none. It only does something inside a library built with `--host-abi` whose host installed `NoxHostCallbackOps`; otherwise `call` raises `RuntimeError`.

A `HostObject` wraps an opaque host-managed object (for example a Python callable) identified by a `NoxHostExternalRef`. Nox never dereferences it. Use it as a parameter or return type of an
`@export` function (`noxc expand --json` reports it as `"marshal": "external_ref"`) or inside containers (`list[HostObject]`, `HostObject | None`).

| Member | Description |
|---|---|
| `HostObject(ref)` | wraps a reference; the host gets `retain` now and `release` when the object is destroyed (ARC) |
| `o.call(args)` / `o.call0()` | invokes the host object with a `HostArgs` tuple (or none); returns a `HostResult` |
| `HostArgs()` | argument tuple: `add_none`, `add_int`, `add_float`, `add_bool`, `add_str`, `add_bytes`, `add_object` |
| `HostResult` | `kind()`, `is_none()`, `as_int()`, `as_bool()`, `as_float()`, `as_str()`, `len()`, `item(i)`, `as_object()`; a wrong kind raises `ValueError` |
| `HostError` | raised when the host callback raised; `message` is the host's text. Uncaught, the export returns `NOX_HOST_ERR_HOST_EXCEPTION` and `nox_host_error_host_token` gives the host's exception token |

The context lock is **released** while the host callback runs, so the callback may call back into Nox (`nox_host_export_*`) on the same context without deadlocking. Values built by the callback
(`nox_host_value_*`) are owned by Nox once returned in `*out_result`.

```nox
from nox.host import HostObject, HostArgs

@export
def apply_twice(cb: HostObject, x: int) -> int:
    a: HostArgs = HostArgs()
    a.add_int(x)
    b: HostArgs = HostArgs()
    b.add_int(cb.call(a).as_int())
    return cb.call(b).as_int()
```
