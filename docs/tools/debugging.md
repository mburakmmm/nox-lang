# Debugging

## Print-style debugging

`print` renders every value structurally — lists, dictionaries, tuples, sets and class instances (`Name(field=value, …)`) — so `print(obj)` is usually enough. [`nox.log`](../stdlib/log.md) adds timestamps and
levels; `assert cond, "message"` documents assumptions and is always on.

An uncaught exception ends the program with exit status 1 and a message naming the exception class and the **source line** of the `raise`. Every exception carries `message` and `line`.

## Debug information (`-g`)

```sh
noxc build -g -o app main.nox       # QBE backend; DWARF line tables
```

`-g` emits DWARF **line tables** (the QBE backend generates them; asking for LLVM together with `-g` is an error). A debugger can then set breakpoints and step by source line. Limits:

- **Linux:** breakpoints and stepping work with `gdb`/`lldb`.
- **macOS:** the linker drops the debug map, so breakpoints are not verified by the debugger.
- **Locals are not inspectable** — the Variables pane is empty; only line-level control is available.
- Steps into standard-library code can show the wrong file for the line.

VS Code: install the CodeLLDB extension, use `noxc build -g` as the pre-launch task and launch the produced binary; no Nox-specific debug adapter is needed because DAP works from DWARF.

## Inspecting what the compiler did

| Tool | Shows |
|---|---|
| `noxc explain file.nox` | allocation decision (stack / arena / reference-counted) for every local and why |
| `noxc expand file.nox` | decorator metadata |
| `noxc build` leaves `file.ll` / `file.ssa` | the generated IR |
| `noxc build --emit-asm` | the assembly |
| `noxc check -v file.nox` | verbose front-end output (AST dump) |

## Runtime switches

| Variable | Effect |
|---|---|
| `NOX_POOL_WORKERS=N` | number of scheduler worker threads (LLVM backend) |
| `NOX_STACK_PAINT=1` | measure fiber-stack usage; prints `NOX_STACK_HWM_BYTES=<n>` at exit (useful before deep recursion in tasks) |

Debug builds of the runtime report leaked reference-counted allocations at exit ("memory address … leaked"); a clean run prints nothing.

## Crashes and stack overflow

Fibers have a guard page: overflowing a task's stack terminates the program instead of corrupting memory. Deep recursion belongs on the main program (OS stack) or an explicit work list.
Fixed-width integer overflow and out-of-range conversions terminate with a message naming the type.
