# nox.buffer

Fixed-size byte buffers for systems and protocol code: network packets, file blocks, device buffers. A `Buffer` owns its bytes; a `Span` is a bounded
window onto a part of one.

```text
from nox.buffer import Buffer, Span
```

**Capability:** none. A `Buffer` is a thin wrapper over `list[u8]` with a fixed length — it does not grow or shrink — and uses no raw pointers.

## `Buffer`

| Member | Description |
|---|---|
| `Buffer(n)` | a new buffer of `n` zero bytes |
| `len()` | its length in bytes |
| `get(i)` | the byte at index `i` (`u8`); `IndexError` out of range |
| `set(i, v)` | stores the byte `v` (`u8`) at index `i` |
| `fill(v)` | sets every byte to `v` |
| `copy_from(other)` | copies the bytes of another `Buffer` (the lengths must match) |
| `span(start, end)` | a `Span` viewing bytes `[start, end)` |

## `Span`

A `Span` borrows part of a `Buffer`; writes through the span are visible in the buffer. `Span(buf, start, end)` constructs one directly.

| Member | Description |
|---|---|
| `len()` | number of bytes in the window |
| `get(i)`, `set(i, v)` | access relative to the window's start; bounds are those of the window |

```nox
from nox.buffer import Buffer, Span

b: Buffer = Buffer(8)
b.fill(u8(7))
b.set(0, u8(255))
print(b.len(), b.get(0), b.get(1))

c: Buffer = Buffer(8)
c.copy_from(b)
sp: Span = c.span(0, 4)
print(sp.len(), sp.get(0))
sp.set(1, u8(9))
print(c.get(1))
```

```output
8 255 7
4 255
9
```

## Notes

- Elements are `u8`; use `int(x)` to compute with them ([Numbers](../language/numbers.md#fixed-width-integers)).
- Byte-oriented parsing and generation of structured data (integers of every width, both endiannesses) lives in [`nox.binary`](binary.md), built on top of `Buffer`.
- A `Span` does not extend the lifetime guarantees of C pointers: it is an ordinary reference to its buffer, kept alive automatically.
