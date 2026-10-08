# nox.os

Process-level information and control: command-line arguments, environment variables, the working directory and exit.

```text
import nox.os
from nox.os import OsError
```

**Capability:** `process`.

## Functions

| Function | Description |
|---|---|
| `arg_count()` | the number of command-line arguments, **including** the program name at index 0 |
| `arg(i)` | argument `i` as a `str` |
| `getenv(name)` | the value of an environment variable; raises `OsError` if it is not set |
| `set_var(name, value)` | sets an environment variable for this process and its children |
| `current_dir()` | the current working directory |
| `exit(code)` | terminates the program immediately with exit status `code` |

Arguments given to `noxc run file.nox -- a b c` (or to a compiled program) appear as `arg(1)`, `arg(2)`, `arg(3)`.

```nox
import nox.os
from nox.os import OsError

print(nox.os.arg_count() >= 1, nox.os.getenv("HOME") != "")
try:
    nox.os.getenv("NOX_SURELY_UNSET_VAR")
except OsError as e:
    print("not set")
nox.os.set_var("NOX_DEMO", "42")
print(nox.os.getenv("NOX_DEMO"), nox.os.current_dir() != "")
```

```output
True True
not set
42 True
```

## Notes

- `exit` ends the process without running `finally` blocks or `defer`s that are still pending — flush and close what you need first. A normal return
  from the top level exits with status 0, an uncaught exception with status 1.
- `getenv` has no default-value form; test for absence with `try`/`except OsError`.
- Environment changes made with `set_var` are visible to child processes started with [`nox.process`](process.md).
