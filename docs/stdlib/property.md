# nox.property

Seeded property-based testing: generate many random inputs, check a property, and get a reproducible, size-reduced failure.

```text
import nox.property
from nox.property import Rng, PropertyFailed
```

**Capability:** none.

A property is a function `(Rng) -> bool` that draws its inputs from the `Rng` and returns whether the property holds. `check` runs it many times; each run has its own
seed (`seed + run`) and a **size** that grows from 1 to `max_size`, which bounds list lengths, string lengths and integer magnitudes. When a run fails, `check` re-runs the same
seed with smaller and smaller sizes, keeps the smallest size that still fails, and raises `PropertyFailed` with a replay hint. An exception raised by the property also counts as a failure.

| Member | Description |
|---|---|
| `check(name, prop, runs=100, seed=12345, max_size=100)` | runs the property; raises `PropertyFailed(message, seed, size, run)` on the first failure |
| `replay(prop, seed, size)` | one run with an exact seed and size; returns whether the property held (an exception counts as `False`) — use it to reproduce a CI failure locally |
| `Rng(seed, size)` | the generator; `size` is a public field |
| `r.int_range(lo, hi)` | an integer in `[lo, hi]`, with the upper bound capped at `lo + size` |
| `r.boolean()` | a random `bool` |
| `r.int_list(max_len, lo, hi)` | a list of 0..`max_len` integers (length also bounded by `size`) |
| `r.ascii_str(max_len)` | a lowercase ASCII string of 0..`max_len` characters |
| `r.choice_str(items)` | a random item of a non-empty `list[str]` |
| `r.next_raw()` | the next raw value in `[0, 2147483646)` |

The generator is a Park–Miller linear congruential generator: not cryptographic, free of overflow, and identical on every platform, so a seed always reproduces the same values.

```nox
import nox.property
from nox.property import Rng, PropertyFailed

def reverse_twice(r: Rng) -> bool:
    xs: list[int] = r.int_list(r.size, -100, 100)
    ys: list[int] = xs.copy()
    ys.reverse()
    ys.reverse()
    return xs == ys

def too_big(r: Rng) -> bool:
    return r.int_range(0, 1000) < 50

nox.property.check("reverse twice", reverse_twice)
try:
    nox.property.check("too big", too_big, 50, 1)
except PropertyFailed as e:
    print("failed, replay still fails:", not nox.property.replay(too_big, e.seed, e.size))
```

```output
failed, replay still fails: True
```

## Notes

- Shrinking reduces the **size**, not individual values: generators draw smaller structures at a smaller size, so the reported counterexample comes from the smallest size that still fails.
- Print `e.seed` and `e.size` (they are in the message) in CI so a failure can be replayed with `replay`.
