# nox.bits

Bit manipulation on fixed-width integers: rotations, byte swaps, endianness conversion, and single-bit helpers. Pure functions with no operating-system
dependency — usable in every profile, including freestanding kernels.

```text
import nox.bits
```

**Capability:** none.

## Rotations

`rotl_uN(x, n)` and `rotr_uN(x, n)` rotate the `N`-bit unsigned value `x` left or right by `n` bits (`n` is reduced modulo `N`). Available for
`N` = 8, 16, 32, 64: `rotl_u8`, `rotr_u8`, `rotl_u16`, `rotr_u16`, `rotl_u32`, `rotr_u32`, `rotl_u64`, `rotr_u64`.

## Byte order

| Function | Description |
|---|---|
| `swap16(x)`, `swap32(x)`, `swap64(x)` | reverse the bytes of a `u16` / `u32` / `u64` |
| `to_le16`, `to_le32`, `to_le64` | convert a host-order value to little-endian |
| `from_le16`, `from_le32`, `from_le64` | convert a little-endian value to host order |
| `to_be16`, `to_be32`, `to_be64` | convert a host-order value to big-endian |
| `from_be16`, `from_be32`, `from_be64` | convert a big-endian value to host order |

The `le`/`be` conversions are no-ops where the host byte order already matches (every supported platform is little-endian today, so `to_be*` swaps and
`to_le*` does nothing).

## Single bits (on `int`)

| Function | Description |
|---|---|
| `mask(n)` | an integer with the low `n` bits set (`mask(5)` is `31`) |
| `test_bit(x, pos)` | whether bit `pos` of `x` is set |
| `set_bit(x, pos)`, `clear_bit(x, pos)`, `toggle_bit(x, pos)` | a copy of `x` with that bit set / cleared / flipped |

```nox
import nox.bits

print(nox.bits.rotl_u8(u8(129), 1), nox.bits.rotr_u8(u8(129), 1), nox.bits.rotl_u32(u32(1), 31))
print(nox.bits.swap16(u16(0x1234)), nox.bits.swap32(u32(0x12345678)), nox.bits.to_be16(u16(0x1234)), nox.bits.to_le16(u16(0x1234)))
print(nox.bits.mask(5), nox.bits.test_bit(5, 0), nox.bits.test_bit(5, 1), nox.bits.set_bit(0, 3), nox.bits.clear_bit(15, 0), nox.bits.toggle_bit(5, 1))
```

```output
3 192 2147483648
13330 2018915346 13330 4660
31 True False 8 14 7
```

(`0x1234` is `4660`; swapped it becomes `0x3412`, `13330`.)

## Related

The operators `& | ^ ~ << >>` ([Expressions](../language/expressions.md)) are built into the language; `nox.bits` supplies the fixed-width rotations and byte-order helpers
that have no operator. For reading and writing whole binary structures see [`nox.binary`](binary.md).
