# nox.signal

Subscribe to process signals: `SIGINT`, `SIGTERM`, `SIGHUP`, `SIGUSR1`, `SIGUSR2`.

```text
import nox.signal
```

**Capability:** `process`.

The handler does exactly one async-signal-safe thing: it sets a flag. Your code reads the flag from its own task, so a signal never interrupts Nox code in the
middle of a statement. A typical graceful-shutdown loop:

```text
nox.signal.install(nox.signal.sigterm())
while not nox.signal.take(nox.signal.sigterm()):
    ...do work...
    nox.time.sleep_ms(50)     # inside a task this suspends only that task
...drain active work and exit...
```

| Function | Description |
|---|---|
| `sigint()`, `sigterm()`, `sighup()`, `sigusr1()`, `sigusr2()` | the platform's signal number (`0` where signals do not exist) |
| `install(sig)` | routes the signal to the flag-setting handler; `True` on success |
| `pending(sig)` | is the flag set? (does not clear it) |
| `take(sig)` | reads **and clears** the flag: `True` once per delivered signal |
| `wait(sig, timeout_ms)` | cooperatively waits until the signal arrives or the timeout expires; `True` if it arrived (and clears the flag) |
| `send_self(sig)` | sends the signal to this process (tests, self-shutdown) |

```nox
import nox.signal

s: int = nox.signal.sigusr1()
print(nox.signal.install(s))
print(nox.signal.send_self(s))
print(nox.signal.take(s), nox.signal.take(s))
```

```output
True
True
True False
```

## Notes

- **Windows** has no POSIX signals but has console events, and `nox.signal` maps them: `sigint()` (2) is Ctrl+C, `sigterm()` (15) is Ctrl+Break, closing the console, logging off and shutting down. `install`, `pending`, `take`, `wait` and `send_self` work as on POSIX, so a `while not take(sigterm())` loop is portable. Windows ends the process about 5 seconds after the handler returns for close/logoff/shutdown events: finish draining within that time. `sigusr1()`/`sigusr2()` do not exist there (0), a process without a console receives no events, and stopping a Windows *service* (SCM) is not covered. `nox.http.serve*` shuts down gracefully on the same events.
- WebAssembly and freestanding targets have no signals: `install` returns `False`, `take`/`pending` always `False`.
- `nox.http.serve*` installs its own `SIGTERM`/`SIGINT` handler when it starts; the last installer wins, so do not combine the two on the same signal. Use
  `nox.http.shutdown()` to stop a server from code.
- Signal numbers differ between platforms (`SIGUSR1` is 10 on Linux and 30 on macOS), which is why they come from functions rather than constants.
