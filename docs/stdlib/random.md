# nox.random

A fast general-purpose pseudo-random number generator (xoshiro256). Suitable for simulations, games, shuffling and tests.

> **Not for security.** Use [`nox.crypto`](crypto.md) for tokens, salts, keys and anything an attacker must not be able to guess.

```text
import nox.random
```

**Capability:** none. The generator is seeded from the system at start-up; call `seed` for a reproducible sequence.

## Functions

| Function | Description |
|---|---|
| `seed(s)` | seeds the generator; the same seed gives the same sequence |
| `randint(lo, hi)` | a uniform integer in `[lo, hi]` — **both ends inclusive** |
| `random()` | a uniform `float` in `[0.0, 1.0)` |
| `normal()` | a standard normal (Gaussian) variate: mean 0, standard deviation 1 |
| `exponential(rate)` | an exponentially distributed variate with the given `rate` (mean `1 / rate`) |
| `shuffle(xs)` | shuffles a `list[T]` in place (Fisher–Yates) |

```nox
import nox.random

nox.random.seed(42)
a: int = nox.random.randint(1, 6)
nox.random.seed(42)
b: int = nox.random.randint(1, 6)
print(a == b, a >= 1 and a <= 6)

x: float = nox.random.random()
print(x >= 0.0 and x < 1.0)

xs: list[int] = [1, 2, 3, 4, 5]
nox.random.shuffle(xs)
print(len(xs), sum(xs))
print(nox.random.exponential(2.0) >= 0.0)
```

```output
True True
True
5 15
True
```

## Notes

- The generator state is per program (per worker under the multi-core scheduler); seeding in one worker does not affect another.
- `randint` requires `lo <= hi`.
- `shuffle` works for any element type, including classes and nested lists.
