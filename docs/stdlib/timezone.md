# nox.timezone

IANA time zones (`Europe/Istanbul`, `America/New_York`, …): UTC offset, abbreviation, daylight-saving flag, and conversion between UTC timestamps and local wall-clock time.

```text
import nox.timezone
```

**Capability:** `filesystem` (the module reads the system's `tzdata` files).

The zone data is read from the machine's own time-zone database (TZif v2+): `$TZDIR`, `/usr/share/zoneinfo`, macOS `/var/db/timezone/zoneinfo`, Android `/system/usr/share/zoneinfo`.
For instants after a zone's last recorded transition the file footer's POSIX rule (for example `EST5EDT,M3.2.0,M11.1.0`) is evaluated, so dates far in the future are correct too.
Nothing is cached: each call reads and parses one small file, so keep a `ZoneInfo` or an offset if you convert in a tight loop.

```text
import nox.time
import nox.timezone

off: int = nox.timezone.utc_offset("Europe/Istanbul", 1721044800)        # 10800
local: nox.time.DateTime = nox.timezone.to_local("America/New_York", 1721044800 * 1000)
ms: int = nox.timezone.from_local("Europe/Berlin", local)                # wall clock -> UTC epoch ms
print(nox.timezone.format_iso("Asia/Tokyo", ms))                         # 2024-07-15T...+09:00
```

| Function | Description |
|---|---|
| `utc_offset(zone, unix_s)` | seconds east of UTC at that instant |
| `is_dst(zone, unix_s)` | is daylight-saving time in effect? |
| `abbreviation(zone, unix_s)` | `CET`, `EDT`, `+03`, … |
| `zone_info(zone, unix_s)` | a `ZoneInfo` with `zone`, `offset_s`, `abbreviation`, `is_dst` |
| `to_local(zone, epoch_ms)` | a `nox.time.DateTime` showing the zone's wall clock |
| `from_local(zone, datetime)` | the UTC epoch milliseconds of a wall-clock time in the zone |
| `format_iso(zone, epoch_ms)` | `2024-07-15T21:00:00+09:00` (the offset is always written) |
| `is_supported()` | can the zone database be read on this machine? |

`unix_s` is a UTC Unix timestamp in seconds, `epoch_ms` in milliseconds.

## Ambiguous and missing local times

A wall-clock time can occur twice (clocks go back) or not at all (clocks go forward). `from_local` follows Python's `fold=0` rule:

- **ambiguous** (Berlin 2024-10-27 02:30): the *first* occurrence, the daylight-saving one (`+02:00`);
- **missing** (Berlin 2024-03-31 02:30): resolved with the offset *before* the gap, so the result is `03:30+02:00`.

## Errors and platforms

- An unknown zone name raises `TimezoneError` (its `zone` field holds the name). Names are validated before use (no leading `/` or `.`, no `..`), so passing untrusted input is safe.
- `UTC`, `Etc/UTC` and `GMT` never need the database.
- On Windows, in WebAssembly, on iOS and in containers without `tzdata`, `is_supported()` is `False` and every zone except UTC raises `TimezoneError`.
