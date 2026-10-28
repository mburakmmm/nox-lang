# nox.bytes

The bridge between a `str` and a raw byte buffer.

```text
import nox.bytes
from nox.buffer import Buffer
```

**Capability:** none. Hosted targets only: the module uses `nox.strings`, which freestanding profiles do not link.

A `str` holds UTF-8, and it keeps its length in its header, so it also stores embedded `\x00` bytes and bytes that are not valid UTF-8 exactly as they arrived (a binary HTTP body, the
contents of a file). `from_str` copies those bytes into a [`Buffer`](buffer.md).

| Function | Description |
|---|---|
| `from_str(s)` | a new `Buffer` holding the bytes of `s` |

```nox
import nox.bytes
from nox.buffer import Buffer

b: Buffer = nox.bytes.from_str("a\x00b")
print(b.len())
print(b.get(0))
print(b.get(1))
print(b.get(2))
```

```output
3
97
0
98
```
