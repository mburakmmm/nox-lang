# nox.decimal

Exact decimal numbers for money and measurements, built on [`nox.bigint`](bigint.md).

```text
import nox.decimal
from nox.decimal import Decimal, DecimalError, parse, from_int, from_bigint
```

**Capability:** none (pure Nox on top of `nox.bigint`).

A `Decimal` is `coefficient × 10^exponent` with a `BigInt` coefficient. Addition, subtraction and multiplication are **exact** (no rounding, no precision limit). Division and rounding take an explicit number of decimal places and a rounding mode; there is deliberately no global context, so a calculation never depends on hidden state.

**Rounding modes** (same meaning as Python's `decimal`): `"half_even"` (default), `"half_up"` (ties away from zero), `"half_down"` (ties toward zero), `"down"` (toward zero), `"up"` (away from zero), `"floor"`, `"ceiling"`.

| Function / method | Description |
|---|---|
| `parse(s)` | from `"12.345"`, `"-0.5"`, `"1e3"`, `"2.5E-4"`; `ValueError` for invalid text |
| `from_int(x)`, `from_bigint(x)` | from integers |
| `a + b`, `a - b`, `a * b`, `-a` | exact arithmetic |
| `a == b`, `<`, `<=`, `>`, `>=`, `a.compare(b)` | numeric comparison (`1.0 == 1.00`); `compare` returns -1, 0 or 1 |
| `a.quantize(places, mode="half_even")` | round to `places` decimal places (negative `places` rounds to tens, hundreds, ...); the result has exponent `-places` |
| `a.div(b, places, mode="half_even")` | `a / b` rounded to `places` decimal places; `ZeroDivisionError` if `b` is zero |
| `a.normalize()` | remove trailing zeros (`1.500` becomes `1.5`) |
| `a.abs()`, `a.sign()`, `a.is_zero()`, `a.scale()` | basic queries (`scale()` is the number of decimal places) |
| `a.to_bigint()` | integer part, truncated toward zero |
| `a.to_float()` | nearest `float` |
| `str(a)` | plain notation, never an exponent: `12.345`, `-0.001`, `1200` |

An unknown rounding mode raises `DecimalError`.

Zero has no sign (`-0.00` prints as `0.00`).

```nox
import nox.decimal
from nox.decimal import Decimal, parse

price: Decimal = parse("19.99")
qty: Decimal = parse("3")
total: Decimal = price * qty
print(total)
print(total.div(parse("7"), 4))
print(parse("2.675").quantize(2), parse("2.675").quantize(2, "half_up"), parse("-2.5").quantize(0, "floor"))
print(parse("0.1") + parse("0.2") == parse("0.3"), parse("1.500").normalize())
```

```output
59.97
8.5671
2.68 2.68 -3
True 1.5
```
