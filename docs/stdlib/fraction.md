# nox.fraction

Exact rational numbers, built on [`nox.bigint`](bigint.md).

```text
import nox.fraction
from nox.fraction import Fraction, make, from_ints, parse_fraction
```

**Capability:** none (pure Nox on top of `nox.bigint`).

A `Fraction` is always in lowest terms with a positive denominator, so `==` compares numerators and denominators directly.

| Function / method | Description |
|---|---|
| `from_ints(p, q=1)` | `p/q` from two `int`s; `ZeroDivisionError` when `q` is zero |
| `make(p, q)` | the same from two `BigInt`s |
| `parse_fraction(s)` | from `"3/4"`, `"-7"`, `"0.125"`, `"1e-3"`; `ValueError` for invalid text |
| `a + b`, `a - b`, `a * b`, `a / b`, `-a`, `a ** e` | exact arithmetic (`e` is an `int`, may be negative) |
| `a == b`, `<`, `<=`, `>`, `>=` | comparisons |
| `a.numerator()`, `a.denominator()` | the parts, as `BigInt` |
| `a.floor()`, `a.ceil()`, `a.trunc()`, `a.round()` | to a `BigInt`; `round` ties to even like Python |
| `a.abs()`, `a.sign()`, `a.is_integer()`, `a.reciprocal()` | basic operations |
| `a.to_float()` | nearest `float` |
| `str(a)` | `"3/4"`, or `"3"` for integers |

```nox
import nox.fraction
from nox.fraction import Fraction, from_ints, parse_fraction

a: Fraction = from_ints(1, 3)
b: Fraction = from_ints(-5, 10)
print(a + b, a * b, a / b)
print(b.floor(), b.ceil(), from_ints(5, 2).round(), from_ints(7, 2).round())
print(parse_fraction("0.125"), from_ints(2, 3) ** -3)
```

```output
-1/6 -1/6 -2/3
-1 0 2 4
1/8 27/8
```
