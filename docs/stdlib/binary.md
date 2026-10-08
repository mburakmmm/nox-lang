# nox.binary

Cursor-based readers and writers for binary formats — file headers, network packets, on-disk structures — without raw pointers. Every integer width
and both byte orders are supported, with exact types (`u16`, `i32`, …).

```text
from nox.binary import BinaryReader, BinaryWriter, span_reader, span_writer
```

**Capability:** none.

## `BinaryWriter`

Writes into a `Buffer` ([`nox.buffer`](buffer.md)) starting at position 0 and advances after every write. Writing past the end raises `IndexError`.

| Member | Description |
|---|---|
| `BinaryWriter(buf)` | a writer over `buf` |
| `position()` | the current offset |
| `seek(pos)` | moves the cursor |
| `write_u8(v)`, `write_i8(v)` | one byte |
| `write_u16_le(v)`, `write_u16_be(v)`, `write_i16_le(v)`, `write_i16_be(v)` | 16-bit, little / big endian |
| `write_u32_le(v)`, `write_u32_be(v)`, `write_i32_le(v)`, `write_i32_be(v)` | 32-bit |
| `write_u64_le(v)`, `write_u64_be(v)`, `write_i64_le(v)`, `write_i64_be(v)` | 64-bit |

## `BinaryReader`

Reads from a `Buffer` and advances after every read. Reading past the end raises `IndexError`.

| Member | Description |
|---|---|
| `BinaryReader(buf)` | a reader over `buf` |
| `position()` | the current offset |
| `remaining()` | bytes left to read |
| `seek(pos)` | moves the cursor |
| `read_u8()`, `read_i8()` | one byte |
| `read_u16_le()`, `read_u16_be()`, `read_i16_le()`, `read_i16_be()` | 16-bit |
| `read_u32_le()`, `read_u32_be()`, `read_i32_le()`, `read_i32_be()` | 32-bit |
| `read_u64_le()`, `read_u64_be()`, `read_i64_le()`, `read_i64_be()` | 64-bit |

## Spans

`span_reader(sp)` and `span_writer(sp)` create a reader or writer that is confined to a [`Span`](buffer.md#span): its `position()` and
`remaining()` are relative to the window, and it cannot touch bytes outside it.

```nox
from nox.buffer import Buffer, Span
from nox.binary import BinaryReader, BinaryWriter, span_reader

b: Buffer = Buffer(8)
w: BinaryWriter = BinaryWriter(b)
w.write_u8(u8(1))
w.write_u16_be(u16(0x0203))
w.write_u32_le(u32(0x04050607))
print(w.position())

r: BinaryReader = BinaryReader(b)
print(r.read_u8(), r.read_u16_be(), r.read_u32_le(), r.position(), r.remaining())
r.seek(0)
print(r.read_i8(), r.position())

sp: Span = b.span(0, 4)
rs: BinaryReader = span_reader(sp)
print(rs.read_u8(), rs.remaining())
```

```output
7
1 515 67438087 7 1
1 1
1 3
```

## Notes

- Values are assembled byte by byte, so the module is independent of the host's byte order and alignment.
- Signed reads reinterpret the bits: `read_i8()` of byte `255` is `-1`.
- Strings are not part of this module; encode them to bytes explicitly with `nox.strings.byte_at` / `char_from_byte`.
