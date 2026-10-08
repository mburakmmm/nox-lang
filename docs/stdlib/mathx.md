# nox.mathx

The same mathematical functions as [`nox.math`](math.md), implemented without any C library. They are ordinary Nox functions, so they are always called
**qualified**, and the module works in every profile — including freestanding builds where no libc exists.

```text
import nox.mathx
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `sqrt(x)` | square root |
| `pow(x, y)` | `x` raised to `y` |
| `floor(x)`, `ceil(x)` | round down / up (result is a `float`) |
| `sin(x)`, `cos(x)`, `tan(x)` | trigonometry, radians |
| `atan2(y, x)` | the angle of the point `(x, y)` |
| `exp(x)` | *e* to the power `x` |
| `log(x)`, `ln(x)` | natural logarithm (`ln` is an alias) |
| `pi()`, `e()` | the constants π and *e* |
| `min(a, b)`, `max(a, b)`, `abs(x)` | `float` helpers |

```nox
import nox.mathx

print(nox.mathx.sqrt(16.0), nox.mathx.pow(2.0, 10.0), nox.mathx.floor(2.7), nox.mathx.ceil(2.1))
print(nox.mathx.sin(0.0), nox.mathx.cos(0.0), nox.mathx.exp(0.0), nox.mathx.log(1.0), nox.mathx.pi() > 3.14159)
print(nox.mathx.min(2.0, 3.0), nox.mathx.max(2.0, 3.0), nox.mathx.abs(-1.5), nox.mathx.atan2(1.0, 1.0) > 0.78)
```

```output
4.0 1024.0 2.0 3.0
0.0 1.0 1.0 0.0 True
2.0 3.0 1.5 True
```

Edge cases follow IEEE-754: `sqrt` of a negative number is `nan`, `log(0.0)` is `-inf`, and nothing raises.

## Which one?

Prefer `nox.mathx` in new code. `nox.math` remains for existing code that calls the unqualified libm names. See [`nox.math`](math.md#choosing-noxmath-or-noxmathx) for the
comparison.
