# nox.console

Levelled message printing **without** timestamps or any operating-system dependency — safe in every profile, including freestanding kernels.

```text
import nox.console
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `format(level, message)` | builds `"[LEVEL] message"` without printing |
| `debug(message)`, `info(message)`, `warn(message)`, `error(message)` | prints `[DEBUG]`/`[INFO]`/`[WARN]`/`[ERROR]` followed by the message to standard output |

```nox
import nox.console

nox.console.info("server started")
nox.console.warn("disk almost full")
nox.console.error("boom")
print(nox.console.format("INFO", "x"))
```

```output
[INFO] server started
[WARN] disk almost full
[ERROR] boom
[INFO] x
```

Use [`nox.log`](log.md) when you want a timestamp on every line.
