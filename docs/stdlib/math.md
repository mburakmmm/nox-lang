# nox.math

Floating-point mathematics backed by the C library's `libm`.

```text
import nox.math
from nox.math import sqrt, pi
```

**Capability:** `libc_math` — hosted programs only. For code that must run in a freestanding profile use [`nox.mathx`](mathx.md), the same functions
with no libc dependency.

## Calling convention — read this first

The `libm` functions are bound with `extern def`, which is never name-mangled, so they are called **unqualified** after the import:

```nox
import nox.math

print(sqrt(16.0), pow(2.0, 10.0), floor(2.7), ceil(2.1))
```

```output
4.0 1024.0 2.0 3.0
```

The pure-Nox helpers (`ln`, `pi`, `e`, `min`, `max`, `abs`) are ordinary functions and are called **qualified**: `nox.math.pi()`,
`nox.math.ln(x)`. `from nox.math import sqrt, pi` imports both kinds by name.

## Functions

| Function | Description | Call as |
|---|---|---|
| `sqrt(x)` | square root | `sqrt(x)` |
| `pow(x, y)` | `x` raised to `y` | `pow(x, y)` |
| `floor(x)`, `ceil(x)` | round down / up to a whole number (still a `float`) | `floor(x)` |
| `sin(x)`, `cos(x)`, `tan(x)` | trigonometric functions (radians) | `sin(x)` |
| `atan2(y, x)` | the angle of the point `(x, y)` | `atan2(y, x)` |
| `exp(x)` | *e* to the power `x` | `exp(x)` |
| `log(x)` | natural logarithm (the libm name) | `log(x)` |
| `ln(x)` | natural logarithm (alias of `log`) | `nox.math.ln(x)` |
| `pi()` | π | `nox.math.pi()` |
| `e()` | Euler's number | `nox.math.e()` |
| `min(a, b)`, `max(a, b)`, `abs(x)` | `float` versions of the built-ins | `nox.math.min(a, b)` |

All arguments and results are `float`. Domain errors follow IEEE-754 (`sqrt(-1.0)` is `nan`; `log(0.0)` is `-inf`) — nothing raises.

```nox
import nox.math

print(nox.math.pi() > 3.14159, nox.math.e() > 2.71828, nox.math.ln(1.0), nox.math.min(2.0, 3.0), nox.math.abs(-2.5))
print(sin(0.0), cos(0.0), atan2(1.0, 1.0) > 0.78, exp(0.0), log(1.0))
```

```output
True True 0.0 2.0 2.5
0.0 1.0 True 1.0 0.0
```

## Choosing `nox.math` or `nox.mathx`

| | `nox.math` | `nox.mathx` |
|---|---|---|
| Backed by | the platform `libm` | Zig's own math (no libc) |
| Freestanding | no | yes |
| Call style | `sqrt(x)` (unqualified externs) | `nox.mathx.sqrt(x)` (always qualified) |

Use `nox.mathx` for new code, and for anything that may run without a C library. Results may differ in the last bit between the two for some inputs.
