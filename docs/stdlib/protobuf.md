# nox.protobuf

The Protocol Buffers **wire format**: a writer and a reader for the byte encoding, in pure Nox. There is no schema compiler: you give the field numbers, which is all that OTLP, gRPC payloads or your own messages need.

```text
import nox.protobuf
from nox.protobuf import Writer, Reader, ProtobufError
```

**Capability:** none (works on every target, including mobile and WebAssembly).

```text
w: Writer = nox.protobuf.writer()
w.varint(1, 150)                  # int32 / int64 / uint32 / uint64 / enum
w.string(2, "testing")
inner: Writer = nox.protobuf.writer()
inner.sint(1, -5)                 # sint32 / sint64 (zigzag)
w.message(3, inner)               # nested message
body: str = w.to_str()            # byte-exact str, e.g. an HTTP request body
data: list[int] = w.to_bytes()

r: Reader = nox.protobuf.reader(data)
while r.next_field():
    if r.field == 1:
        print(r.read_varint())
    elif r.field == 2:
        print(r.read_string())
    else:
        r.skip()                  # unknown fields are skipped (forward compatible)
```

## Writer

| Method | Proto type | Wire type |
|---|---|---|
| `varint(field, v)` | `int32`, `int64`, `uint32`, `uint64`, `enum` | 0 |
| `boolean(field, v)` | `bool` | 0 |
| `sint(field, v)` | `sint32`, `sint64` (zigzag) | 0 |
| `fixed64(field, v)` / `fixed32(field, v)` | `fixed64`, `sfixed64` / `fixed32`, `sfixed32` | 1 / 5 |
| `double(field, v)` / `float32(field, v)` | `double` / `float` | 1 / 5 |
| `string(field, s)` | `string` (UTF-8) | 2 |
| `bytes_field(field, data)` | `bytes` (`list[int]`) | 2 |
| `message(field, inner)` | nested message (`inner` is another `Writer`) | 2 |
| `packed_varints(field, values)` | packed `repeated` varint field | 2 |

`to_bytes()` returns the encoding as `list[int]`, `to_str()` as a byte-exact `str`, `size()` the length. Negative `int32`/`int64` values are written as 10-byte varints, as the specification requires.

## Reader

`nox.protobuf.reader(data)` (or `reader_from_str(s)`) reads a message. `next_field()` reads the next tag and returns `False` at the end; `field` and `wire_type` describe it. Then call the matching reader for the field, or `skip()`:

`read_varint`, `read_bool`, `read_sint`, `read_fixed64`, `read_fixed32` (zero-extended), `read_sfixed32` (sign-extended), `read_double`, `read_float32`, `read_string`, `read_bytes`, `read_message` (a `Reader` over the nested bytes), `read_packed_varints`.

## Notes

- Numbers are Nox `int` (64-bit signed): the upper half of `uint64` appears negative, with the bit pattern preserved.
- A wire-type mismatch, a truncated value, a varint longer than 10 bytes or field number 0 raises `ProtobufError`. Groups (wire types 3 and 4) are not supported.
- Together with [`nox.gzip`](gzip.md) and [`nox.bytes`](bytes.md) this is enough for OTLP/HTTP: encode the request, compress it, send it as the body.
