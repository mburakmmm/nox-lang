# nox.uuid

Random (version 4) UUIDs.

```text
import nox.uuid
```

**Capability:** none. UUIDs are generated from the operating system's secure random source.

## Functions

| Function | Description |
|---|---|
| `uuid4()` | a new random UUID as a 36-character lowercase string (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`) |
| `is_valid(s)` | whether `s` is a well-formed UUID string (any version) |

```nox
import nox.uuid

x: str = nox.uuid.uuid4()
print(len(x), nox.uuid.is_valid(x), nox.uuid.is_valid("nope"))
```

```output
36 True False
```
