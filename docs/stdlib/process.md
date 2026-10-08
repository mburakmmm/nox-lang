# nox.process

Run external programs and capture their output.

```text
from nox.process import Command, Output, ProcessError
```

**Capability:** `process`.

> **Security.** A `Command` runs exactly the program and arguments you give it, with the full authority of your process. There is no shell: arguments are passed
> as an array, so they are never re-interpreted — but never build the *program* name from untrusted input.

## `Command`

A builder: every setter returns the same `Command`, so calls chain.

| Member | Description |
|---|---|
| `Command(program)` | prepares to run `program` (looked up on `PATH`) |
| `arg(v)` | appends one argument |
| `arg_list(xs)` | appends several arguments from a `list[str]` |
| `set_cwd(path)` | runs the program in a different working directory |
| `set_timeout(ms)` | kills the program if it runs longer than `ms` milliseconds (`0` means no limit) |
| `run()` | runs it **synchronously** and returns an `Output` |

## `Output`

| Field / method | Description |
|---|---|
| `status` | the exit status (`int`) |
| `stdout`, `stderr` | everything the program wrote, as `str` |
| `success()` | `True` when `status == 0` |

A program that exits with a non-zero status is **not** an error — inspect `status`. `run()` raises `ProcessError` only when the program could not be run at all:
not found, an argument containing a NUL byte, or the timeout expired.

```nox
from nox.process import Command, Output, ProcessError

out: Output = Command("echo").arg("hi").arg_list(["a", "b"]).run()
print(out.status, out.stdout.strip(), out.success(), out.stderr == "")

failed: Output = Command("sh").arg("-c").arg("echo err >&2; exit 3").run()
print(failed.status, failed.success(), failed.stderr.strip())

try:
    Command("definitely-not-a-program-xyz").run()
except ProcessError as e:
    print("could not run")
```

```output
0 hi a b True True
3 False err
could not run
```

## Notes

- `run()` blocks until the program ends and buffers all output in memory.
- Standard input of the child is empty.
- To run a command in parallel with other work, `spawn` a task that calls it ([Concurrency](../language/concurrency.md)).
