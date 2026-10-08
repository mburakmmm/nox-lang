# nox.sharedmem

Named shared-memory segments for communicating between **separate operating-system processes** (two `noxc run` invocations, a server and a helper). Within one program, use channels or
[`nox.atomic`](atomic.md) instead.

```text
import nox.sharedmem
from nox.sharedmem import SharedBuffer, SharedMemError
```

**Capability:** `shared_memory` (macOS and Linux; unavailable in freestanding profiles).

## Functions and methods

| Member | Description |
|---|---|
| `open(name, size)` | opens the segment called `name` (creating it with `size` bytes if it does not exist) and maps it; names look like `"/myapp-state"`; raises `SharedMemError` on failure |
| `unlink(name)` | permanently removes the segment's name (segments live until unlinked) |
| `SharedBuffer.lock()`, `unlock()` | a spin lock stored in the segment: take it around any read-modify-write; pair it with `defer buf.unlock()` |
| `SharedBuffer.read_int(offset)`, `write_int(offset, value)` | a 64-bit integer at a byte offset |
| `SharedBuffer.read_str(offset, length)`, `write_str(offset, value)` | `length` bytes as text / write the bytes of a string |
| `SharedBuffer.close()` | unmaps it **in this process only**; other processes keep their mapping |

The segment is plain bytes: you decide the layout. Keep offsets inside `size` and, when two processes interpret the layout, agree on it. `lock` protects the segment as a whole; it is not re-entrant.

```nox
import nox.sharedmem
from nox.sharedmem import SharedBuffer

nox.sharedmem.unlink("/noxdocdemo")
b: SharedBuffer = nox.sharedmem.open("/noxdocdemo", 4096)
b.lock()
b.write_int(0, 12345)
b.write_str(16, "hello")
b.unlock()

c: SharedBuffer = nox.sharedmem.open("/noxdocdemo", 4096)
c.lock()
print(c.read_int(0), c.read_str(16, 5))
c.unlock()
c.close()
b.close()
nox.sharedmem.unlink("/noxdocdemo")
```

```output
12345 hello
```

## Notes

- Always `unlink` a segment you created when it is no longer needed, otherwise it persists after the program exits.
- The segment's name is global to the machine: use a distinctive prefix and treat the segment as untrusted input from other local processes.
