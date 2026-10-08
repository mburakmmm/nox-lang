# Numbers

Nox has three numeric families: the 64-bit signed integer `int`, the IEEE-754 double `float`, and the ten fixed-width integer
types. `bool` is a separate type and never behaves as a number.

## `int`

`int` is a signed 64-bit two's-complement integer. Arithmetic on plain `int` **wraps around** on overflow, identically on both
backends:

```nox
big: int = 9223372036854775807
print(big + 1)
print(3 ** 40)
```

```output
-9223372036854775808
-6289078614652622815
```

To wrap deliberately at another width, compute in `int` and mask: `(x * 31 + c) & 0xFFFFFFFF`.

### Arithmetic operators

| Operator | Meaning | Result type |
|---|---|---|
| `a + b`, `a - b`, `a * b` | addition, subtraction, multiplication | `int` (or `float` if either side is `float`) |
| `a / b` | true division | **always `float`** |
| `a // b` | floor division (rounds toward −∞) | `int` / `float` |
| `a % b` | remainder with the **sign of the divisor** | `int` / `float` |
| `a ** b` | exponentiation | `int` for two `int`s, otherwise `float` |
| `-a`, `+a` | negation, identity | same as operand |

```nox
print(7 // 2, -7 // 2, 7 % 3, -7 % 3, 7 % -3, 7 / 2)
print(5.0 // 2.0, -5.0 // 2.0, 5.5 % 2.0, -5.5 % 2.0)
```

```output
3 -4 1 2 -2 3.5
2.0 -3.0 1.5 0.5
```

**Integer power** `int ** int` is exact integer arithmetic (square-and-multiply with the same wrap-around as `*`), not a
floating-point `pow`. A negative exponent yields the truncated reciprocal, which is `0` unless the base is `1` or `-1`;
`0 ** negative` raises `ZeroDivisionError`. Use floats for fractional results: `2.0 ** -1` is `0.5`.

```nox
print(2 ** 10, (-2) ** 3, 2 ** -1, 2.0 ** -1, 2 ** 0.5)
```

```output
1024 -8 0 0.5 1.4142135623730951
```

### Division by zero

Integer `//` and `%` with a zero divisor raise `ZeroDivisionError` (catchable like any exception). Floating-point `/`, `//`
and `%` follow IEEE-754 and never raise: they produce `inf`, `-inf` or `nan`.

```nox
x: float = 1.0 / 0.0
print(x, -x, x - x)
try:
    print(1 // 0)
except ZeroDivisionError as e:
    print("caught:", e.message)
```

```output
inf -inf nan
caught: sifira bolme
```

### Bitwise operators

`&`, `|`, `^`, `~`, `<<`, `>>` work on `int` and on fixed-width integers. `>>` is an arithmetic shift for signed values. A shift count
outside `[0, width)` raises `ValueError`.

```nox
print(1 << 4, 256 >> 2, 6 & 3, 6 | 3, 6 ^ 3, ~5)
```

```output
16 64 2 7 5 -6
```

## `float`

`float` is an IEEE-754 binary64. Mixed `int`/`float` arithmetic promotes the integer to `float`; `int → float` is also implicit on
assignment (`x: float = 3`). Comparisons between `int` and `float` compare mathematically.

### Printing floats

Printing follows Python's `repr`: the **shortest digit string that round-trips**, always with a `.0` for whole values, switching
to scientific notation outside `1e-4 <= |x| < 1e16`, and `inf`, `-inf`, `nan` for the special values. `print`, `str(x)`,
f-strings and the printing of containers all agree.

```nox
print(0.1 + 0.2, 1e16, 1.5e-7, 100.0, 1 / 3, 2.5, -0.0)
```

```output
0.30000000000000004 1e+16 1.5e-07 100.0 0.3333333333333333 2.5 -0.0
```

## Conversions

Everything except `int → float` is explicit. The conversion functions are spelled like the types:

| Call | From | Behaviour |
|---|---|---|
| `int(x)` | `float` | truncates toward zero (`int(-3.9) == -3`) |
| `int(x)` | `str` | parses a decimal integer; a bad string raises `ValueError` |
| `int(x)` | `bool` | `0` or `1` |
| `int(x)` | fixed-width integer | widens; a `u64`/`usize` above `9223372036854775807` terminates the program |
| `float(x)` | `int`, `bool`, fixed-width, `str` | exact where representable; a bad `str` raises `ValueError` |
| `str(x)` | `int`, `float`, `bool`, `str`, containers, classes | the same text `print` shows |
| `bool(x)` | `bool`, `int`, `float`, `str`, `list`, `dict`, classes | truthiness (zero, empty, `__bool__`) |
| `u8(x)`, `i32(x)`, … | `int`, `float`, other fixed-width | range-checked narrowing/widening |

```nox
print(int(3.9), int(-3.9), int("42"), float("2.5"), float(3), str(3.0), int(True))
```

```output
3 -3 42 2.5 3.0 3.0 1
```

## Rounding and the numeric built-ins

`round(x)` rounds half to even and returns an `int` (`round(2.5) == 2`, `round(3.5) == 4`). `round(x, n)` returns a `float`
and rounds the *exact binary value* like Python, so `round(2.675, 2)` is `2.67`. `abs`, `min`, `max`, `sum` and `divmod` are
described in [Built-in functions](builtins.md); `nox.math` ([stdlib](../stdlib/math.md)) has the transcendental functions.

```nox
print(round(2.5), round(3.5), round(-2.5), round(2.675, 2), round(3.14159, 3))
print(abs(-3), abs(-2.5), min(1, 2), max(1.5, 2.0), divmod(17, 5))
```

```output
2 4 -2 2.67 3.142
3 2.5 1 2.0 (3, 2)
```

## Fixed-width integers

`i8 i16 i32 i64 isize` and `u8 u16 u32 u64 usize` exist for byte-level code, binary formats and `lowlevel`. Their rules differ
deliberately from `int`:

- They **never mix implicitly** — with each other, with `int`, or with `float`. `u8 + i32` and `u8 + int` are compile errors.
- A literal fits implicitly where the value is in range: `b: u8 = 200` is fine, `b: u8 = 300` is a compile error.
- Conversion is explicit and **range-checked on every backend**: `u8(300)` terminates the program, `u8(-1)` too.
- **Overflow of `+`, `-` and `*` terminates the program** with a message (`'u8' integer overflow`), on both backends. Plain `int`
  wraps; fixed-width does not.
- `usize`/`isize` are as wide as the pointer (64 bits on all supported targets).
- `%`, `//` and `**` are not defined on fixed-width values; convert with `int(x)` first. Unary `-` on an unsigned type is a
  compile error.
- Comparisons use the signedness of the type.
- `list[u8]` and the other fixed-width list types are stored byte-packed.

```nox
a: u8 = 200
b: u8 = 55
total: u8 = a + b
print(total, int(total) // 7, u8(int(total) % 2))
```

```output
255 36 1
```

`sizeof(T)`, `alignof(T)` and `offsetof(T, "field")` query sizes; `@repr("C")` and `@packed` choose class layouts (see
[Foreign functions](ffi.md)).

## Booleans

`bool` has the two values `True` and `False`. It does not participate in arithmetic (`True + 1` is a compile error) — convert with
`int(b)` when a number is needed. `and`, `or` and `not` operate on `bool` and short-circuit; conditions in `if`, `while`, `assert` and
the ternary must be `bool` (there is no implicit truthiness except through `bool(x)`).
