# nox.bigint

Arbitrary-precision integers with Python semantics.

```text
import nox.bigint
from nox.bigint import BigInt, BigIntError, big, from_int, parse, factorial
```

**Capability:** none. The arithmetic is done by the runtime (Zig's `std.math.big`), so the module also works on freestanding, wasm and mobile targets.

A `BigInt` is an immutable value; operators return new values. `//` and `%` round towards negative infinity like Python (the remainder takes the divisor's sign), `>>` is an arithmetic shift, and `&`, `|`, `^` behave as on infinitely sign-extended two's complement.

## Creating values

| Function | Description |
|---|---|
| `big(x)` / `from_int(x)` | from an `int` |
| `parse(s, base=10)` | from text with an optional `+`/`-` sign and `_` separators, base 2–36; `ValueError` for invalid text |
| `factorial(n)` | `n!` |

## Operators and methods

| Syntax | Meaning |
|---|---|
| `a + b`, `a - b`, `a * b`, `-a` | arithmetic |
| `a // b`, `a % b` | floor division and modulo; `ZeroDivisionError` when `b` is zero |
| `a ** e` | power with an `int` exponent `0 <= e < 2**32`; `BigIntError` otherwise |
| `a << n`, `a >> n` | shifts by an `int` (`BigIntError` when negative or too large) |
| `a & b`, `a \| b`, `a ^ b` | bitwise operations |
| `a == b`, `<`, `<=`, `>`, `>=` | comparisons |
| `a.divmod(b)` | `(a // b, a % b)` |
| `a.abs()`, `a.sign()`, `a.is_zero()`, `a.is_odd()`, `a.is_even()` | basic queries (`sign()` is -1, 0 or 1) |
| `a.bit_length()` | bits needed for `abs(a)` (0 for zero) |
| `a.gcd(b)` | greatest common divisor (non-negative) |
| `a.pow_mod(e, m)` | `a ** e mod m` for `e >= 0` and `m > 0`, result in `[0, m)` |
| `a.isqrt()` | integer square root of a non-negative value |
| `a.is_probable_prime(rounds=8)` | Miller–Rabin with the first twelve primes as bases (exact below 3.3e24) plus `rounds` more |
| `a.to_str(base=10)` | text in base 2–36 (lower case) |
| `a.fits_int()`, `a.to_int()` | conversion to a 64-bit `int`; `to_int()` raises `BigIntError` when it does not fit |

```nox
import nox.bigint
from nox.bigint import BigInt, big, parse, factorial

a: BigInt = parse("123456789012345678901234567890")
b: BigInt = parse("-987654321098765432109876543210")
print(a + b)
print(a * b)
print(big(-7) // big(2), big(-7) % big(2), big(7) // big(-2), big(7) % big(-2))
print(factorial(30))
print(big(2) ** 100)
print(big(3).pow_mod(big(200), big(1000000007)))
print(big(255).to_str(16), parse("ff", 16))
print(big(97).is_probable_prime(), big(91).is_probable_prime())
```

```output
-864197532086419753208641975320
-121932631137021795226185032733622923332237463801111263526900
-4 1 -4 -1
265252859812191058636308480000000
1267650600228229401496703205376
136318165
ff 255
True False
```

## Notes

- The internal representation is a `str` (a sign byte followed by the little-endian magnitude), so copying a `BigInt` is cheap and there is nothing to release.
- Multiplication and division are schoolbook/Knuth algorithms: fine for thousands of digits, not tuned for millions.
- The type is strict about operands: `a + 5` is a type error; write `a + big(5)`.
