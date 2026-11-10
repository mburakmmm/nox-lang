# nox.uuid

Random (version 4) and time-ordered (version 7) UUIDs.

```text
import nox.uuid
```

**Capability:** none. UUIDs are generated from the operating system's secure random source.

## Functions

| Function | Description |
|---|---|
| `uuid4()` | a new random UUID as a 36-character lowercase string (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`) |
| `uuid7()` | a time-ordered UUID (RFC 9562 version 7): the first 48 bits are the Unix time in milliseconds, so lexicographic order follows creation time (UUIDs created within the same millisecond are not ordered among themselves) |
| `uuid7_at(unix_ms)` | `uuid7` with an explicit timestamp (deterministic tests, importing records) |
| `uuid7_timestamp_ms(s)` | the timestamp embedded in a version 7 UUID; `ValueError` for anything else |
| `is_valid(s)` | whether `s` is a well-formed UUID string (any version) |

```nox
import nox.uuid

x: str = nox.uuid.uuid4()
print(len(x), nox.uuid.is_valid(x), nox.uuid.is_valid("nope"))
```

```output
36 True False
```
