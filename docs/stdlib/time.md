# nox.time

Wall-clock time, sleeping, calendar date-times and monotonic interval measurement.

```text
import nox.time
```

**Capability:** none for the module; the functions that actually read the clock — `now_ms`, `sleep_ms`, `now`, `instant_now` and the `Instant`
methods — require the `clock` capability and are unavailable in freestanding profiles. The calendar arithmetic (`DateTime`, `from_epoch_ms`) is pure and
available everywhere.

## Functions

| Function | Description |
|---|---|
| `now_ms()` | milliseconds since the Unix epoch (wall clock; can jump if the system clock is changed) |
| `sleep_ms(ms)` | blocks the **current thread** for `ms` milliseconds |
| `now()` | the current time as a `DateTime` (UTC) |
| `from_epoch_ms(ms)` | converts epoch milliseconds to a `DateTime` (UTC) |
| `instant_now()` | a monotonic `Instant` for measuring intervals |
| `pad2(n)` | formats `n` with at least two digits (`7` → `"07"`) |

## `DateTime`

A calendar date and time (UTC): fields `year`, `month`, `day`, `hour`, `minute`, `second`.

| Member | Description |
|---|---|
| `DateTime(year, month, day, hour, minute, second)` | constructor |
| `to_str()` | `"YYYY-MM-DD HH:MM:SS"` |
| `to_epoch_ms()` | back to epoch milliseconds (a proleptic-Gregorian civil-date algorithm, exact for all dates) |

```nox
import nox.time

dt: nox.time.DateTime = nox.time.from_epoch_ms(1700000000000)
print(dt.to_str(), dt.year, dt.month, dt.day, dt.to_epoch_ms())
made: nox.time.DateTime = nox.time.DateTime(2024, 2, 29, 12, 30, 5)
print(made.to_str(), made.to_epoch_ms() > 0, nox.time.pad2(7))
```

```output
2023-11-14 22:13:20 2023 11 14 1700000000000
2024-02-29 12:30:05 True 07
```

## `Instant` and `Duration`

`Instant` reads a **monotonic** clock — it never goes backwards — and is the right tool for measuring how long something took (prefer it to
subtracting two `now_ms()` values).

| Member | Description |
|---|---|
| `instant_now()` | captures the current monotonic time |
| `Instant.elapsed_ms()` | milliseconds since the instant was captured |
| `Instant.elapsed()` | the same as a `Duration` |
| `Duration(ms)`, `Duration.as_ms()` | a length of time in milliseconds |

```nox
import nox.time

start: nox.time.Instant = nox.time.instant_now()
nox.time.sleep_ms(30)
took: nox.time.Duration = start.elapsed()
print(took.as_ms() >= 25, nox.time.now_ms() > 1700000000000)
```

```output
True True
```

## Notes

- `sleep_ms` blocks its thread. Under the default multi-core scheduler other tasks keep running on other workers; under QBE's single-threaded scheduler the
  whole program waits ([Concurrency](../language/concurrency.md#the-scheduler)).
- There is no time-zone support: `DateTime` is UTC. Format with `nox.time.pad2` or [f-string](../language/strings.md#f-strings) format specs.
