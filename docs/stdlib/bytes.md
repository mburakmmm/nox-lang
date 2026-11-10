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
| `str_from_list(data)` | a byte-exact `str` from a `list[int]` of values 0-255 (e.g. the output of [`nox.gzip`](gzip.md)); `BytesError` for a value outside 0..255. Usable as a binary HTTP body or protobuf payload |
| `list_from_str(s)` | the bytes of `s` as a `list[int]` |
| `to_list(buf)`, `from_list(data)` | `Buffer` ↔ `list[int]` |
| `to_str(buf)` | a byte-exact `str` from a `Buffer` |

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
