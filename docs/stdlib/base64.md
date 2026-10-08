# nox.base64

Base64 encoding and decoding of text, in the standard and the URL-safe alphabets.

```text
import nox.base64
from nox.base64 import Base64Error
```

**Capability:** none registered; the module is pure Nox and works wherever the compiler's hosted profile does (it is not on the freestanding allow-list).

## Functions

| Function | Description |
|---|---|
| `encode(data)` | standard Base64 (`+`, `/`) with `=` padding |
| `encode_url(data)` | URL-safe Base64 (`-`, `_`) **without** padding, as used in JWTs |
| `decode(s)` | decodes either alphabet, with or without padding; raises `Base64Error` for invalid input |

Input and output are `str`. The data is processed as the UTF-8 bytes of the string.

```nox
import nox.base64

print(nox.base64.encode("hello"), nox.base64.decode("aGVsbG8="))
print(nox.base64.encode_url("??>>"), nox.base64.decode("Pz8-Pg"))
```

```output
aGVsbG8= hello
Pz8-Pg ??>>
```

For binary data, convert bytes to a string with `nox.strings.char_from_byte` first, or use [`nox.gzip`](gzip.md)'s `list[int]` byte API for compression.
