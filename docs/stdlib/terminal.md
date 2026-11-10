# nox.terminal

Terminal control for full-screen and interactive programs: TTY detection, size, raw mode, echo, non-blocking input and raw output.

```text
import nox.terminal
from nox.terminal import TerminalError, TerminalSize, TerminalCapabilities
```

**Capability:** `process`.

| Function | Description |
|---|---|
| `is_tty(fd=1)` | is `fd` (0 stdin, 1 stdout, 2 stderr) attached to a terminal? |
| `get_size()` | a `TerminalSize(cols, rows)`; falls back to `COLUMNS`/`LINES`, then 80x24, when the size cannot be read |
| `get_capabilities()` | a `TerminalCapabilities(is_tty, supports_ansi, supports_truecolor, color_depth)` from `TERM`, `COLORTERM` and `NO_COLOR` (depth 0, 16, 256 or 16777216) |
| `enable_raw_mode()` / `disable_raw_mode()` | puts stdin in raw mode (no line buffering, no echo, no signal keys, output post-processing off, reads never block) and back. Calls are counted: every `enable` needs a matching `disable`. `TerminalError` when stdin is not a terminal |
| `is_raw_mode()` | whether raw mode is on |
| `restore_state()` | restores the original terminal settings regardless of the counter — call it from a `finally` or a recovery path |
| `set_echo(enabled)` | turns input echo off/on (password prompts); `TerminalError` when stdin is not a terminal |
| `poll_input(timeout_ms)` | is input available? Waits at most `timeout_ms` (negative: forever). Inside a task only that task waits |
| `read_raw(max_bytes=256)` | the bytes that are available right now (empty string if none); never waits |
| `write_raw(s)` | writes `s` to stdout without a trailing newline; flushes pending `print` output first so the order is kept |
| `flush()` | flushes buffered `print` output |

`read_raw` returns a `str` that is byte-safe: NUL bytes and incomplete UTF-8 are preserved exactly. A multi-byte character (or an escape sequence such as
`ESC [ A`) can arrive in more than one read, so key decoders should buffer the bytes.

```nox
import nox.terminal

nox.terminal.enable_raw_mode()
try:
    while True:
        if nox.terminal.poll_input(100):
            chunk: str = nox.terminal.read_raw(32)
            if chunk == "q":
                break
finally:
    nox.terminal.disable_raw_mode()
```

## Notes

- Windows, WebAssembly and freestanding targets have no terminal control: `is_tty` is `False`, `enable_raw_mode`/`set_echo` raise `TerminalError`, and
  `get_size` uses the environment fallbacks.
- The terminal belongs to the whole process, so raw-mode state is process-wide. Always restore it (`finally`) — a program that exits in raw mode leaves the
  user's shell without echo.
