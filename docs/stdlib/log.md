# nox.log

Levelled logging with a millisecond timestamp on every line.

```text
import nox.log
```

**Capability:** `clock` (reads the system clock).

## Functions

| Function | Description |
|---|---|
| `format(level, message)` | builds `"[LEVEL] [timestamp_ms] message"` without printing; the timestamp is milliseconds since the Unix epoch |
| `debug(message)`, `info(message)`, `warn(message)`, `error(message)` | prints the formatted line to standard output |

Output looks like:

```text
[INFO] [1791446397900] server started
[WARN] [1791446397902] careful
```

There is no level filtering and no file or network sink: the functions are thin wrappers around `print`. If you need to route logs elsewhere, wrap `format` in your
own function; for timestamp-free output use [`nox.console`](console.md).

```nox
import nox.log

line: str = nox.log.format("INFO", "ready")
print(line.startswith("[INFO] ["), line.endswith("] ready"))
```

```output
True True
```
