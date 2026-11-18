# Exceptions

Nox keeps Python's `try`/`except`/`finally`/`raise` syntax. Exceptions are ordinary **classes**; the error model underneath is not
stack unwinding but an implicit **error-return chain** (compare Zig's error unions): a function that can raise is compiled to return
either a value or an exception handle, and every call site checks it. No unwind tables or landing pads are ever emitted, so exceptions
cost nothing on the success path and work identically on both backends.

## The exception hierarchy

`Exception` is the root and is always available. Each instance has a `message: str` and a `line: int` (the source line of the `raise`,
filled in automatically). Built-in subclasses:

| Class | Raised by |
|---|---|
| `Exception` | the root; user-raised generic errors |
| `ValueError` | bad conversions (`int("x")`), zero slice step, out-of-range shift, `list.remove`/`index` of a missing value |
| `IndexError` | list/string index out of range, `pop`/`del` past the end |
| `KeyError` | missing dictionary key (`d[k]`, `d.pop(k)`, `del d[k]`) |
| `ZeroDivisionError` | integer `//` or `%` by zero, `0 ** negative` |
| `AssertionError` | a failed `assert` |
| `CancelledError` | a cancelled [task](concurrency.md) |

Standard-library modules define their own subclasses (`JsonError`, `SqliteError`, `NativeError`, `PluginError`, …).

> **Diagnostics language.** Compiler diagnostics, built-in runtime errors (`e.message` of an `IndexError`, the uncaught-exception report, type errors) are English. Programs should branch on the exception *class*, never on built-in message text. User-raised messages are whatever you write.

## Raising and defining exceptions

`raise` takes an instance of `Exception` or a subclass. Define your own exceptions as subclasses and call `super().__init__(message)`:

```nox
class AppError(Exception):
    code: int

    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code

class NotFound(AppError):
    pass

def find(key: str) -> int:
    if key == "":
        raise ValueError("empty key")
    if key == "x":
        raise NotFound("no such key", 404)
    return 1

print(find("a"))
```

```output
1
```

## Catching

```nox
class AppError(Exception):
    code: int
    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code

class NotFound(AppError):
    pass

def find(key: str) -> int:
    if key == "":
        raise ValueError("empty key")
    if key == "x":
        raise NotFound("no such key", 404)
    return 1

for key in ["a", "", "x"]:
    try:
        print(find(key))
    except NotFound as e:
        print("not found:", e.message, e.code)
    except (ValueError, KeyError) as e:
        print("value-ish:", e.message)
    finally:
        print("done", key)
```

```output
1
done a
value-ish: empty key
done 
not found: no such key 404
done x
```

Rules:

- `except Base:` matches `Base` **and every subclass** (single inheritance), tested in clause order — put specific classes first.
- `except (A, B) as e:` matches either class; `except Exception as e:` is a catch-all; a bare `except:` also catches everything.
- The bound name (`e`) is scoped like any other local and its class is the *clause's* class (for a tuple clause, the common base, so
  `e.message` is always available).
- `raise` inside an `except` clause raises a new exception (there is no implicit chaining); a bare `raise` re-raise is not supported —
  raise the bound exception again with `raise e`.
- An exception escaping a `finally` body replaces the one in flight (the replaced exception object is reclaimed only when the program
  exits — avoid raising from `finally` in long-running code).
- Exceptions cross `async` boundaries: `await t` re-raises whatever the task raised.

### Uncaught exceptions

An exception that escapes the top level terminates the program with exit status 1 after printing the class and source line to standard
error. A failed fixed-width overflow or an out-of-range fixed-width conversion is *not* an exception: it terminates the program with a
message and cannot be caught.

## `finally`

A `finally` body runs when the `try` body finishes normally, when it exits by `return`, `break` or `continue`, and when an exception
propagates — exactly once. `try` may have `except` clauses, a `finally`, or both.

### `try … else`

An `else:` block after the `except` clauses runs only when the `try` body finished without an exception (and without `return`, `break` or
`continue`). Exceptions raised inside the `else` block are *not* caught by the `except` clauses of the same `try`, and a `finally` body, if any,
runs after the `else` block:

```nox
def parse(text: str) -> None:
    try:
        n: int = int(text)
    except ValueError:
        print("bad number")
    else:
        print("number", n)
    finally:
        print("done")

parse("42")
parse("x")
```

```output
number 42
done
bad number
done
```

## `with`

`with expr as name:` calls `expr.__enter__()` (its result is bound to `name`), runs the body, and calls `expr.__exit__()` on every way out
of the body — normal completion, `return`, `break`, `continue` or an exception. In Nox `__exit__` takes no arguments and cannot
suppress an exception.

```nox
class Resource:
    name: str
    def __init__(self, name: str) -> None:
        self.name = name
    def __enter__(self) -> Resource:
        print("enter", self.name)
        return self
    def __exit__(self) -> None:
        print("exit", self.name)

def work() -> int:
    with Resource("a") as r:
        print("using", r.name)
        return 7

print(work())
try:
    with Resource("b") as r2:
        raise ValueError("oops")
except ValueError as e:
    print("caught after exit")
```

```output
enter a
using a
exit a
7
enter b
exit b
caught after exit
```

A `with` statement can manage several resources: `with a as x, b as y:` is `with a as x:` containing `with b as y:` — `b` is entered after `a` and
exited before it. `noxc fmt` writes the nested form.

## Re-raising and chaining

A bare `raise` inside an `except` block raises the exception that block caught again (`noxc fmt` keeps the bare form when the clause binds no name; when it does bind one, the formatter writes `raise e`). Outside an `except` block a bare `raise` is a syntax error.
`raise X from Y` raises `X` and records `Y.message` in `X.cause` (a `str`, empty for an ordinary `raise`); `raise X from None` is just `raise X`. There is no traceback object, so the cause is the message text.

```nox
class AppError(Exception):
    pass

def load(path: str) -> None:
    try:
        raise ValueError("bad number")
    except ValueError as e:
        raise AppError("could not load " + path) from e

try:
    load("cfg")
except AppError as e:
    print(e.message, "|", e.cause)

try:
    try:
        raise ValueError("inner")
    except ValueError:
        print("cleanup")
        raise
except ValueError as e:
    print("again:", e.message)
```

```output
could not load cfg | bad number
cleanup
again: inner
```

## `defer`

`defer call(args)` (Go-style) schedules a call for when the enclosing function exits by any route; several `defer`s run **last in,
first out**. Only a call expression is accepted. Deferred arguments are evaluated at the `defer` statement.

```nox
def cleanup(s: str) -> None:
    print("cleanup", s)

def run() -> None:
    defer cleanup("one")
    defer cleanup("two")
    print("body")

run()
```

```output
body
cleanup two
cleanup one
```

`finally`, `with`, `defer`, `return`, `break` and `continue` all share the same scope-exit mechanism that releases memory, so cleanup always
runs in a single, predictable order.

## `assert`

`assert cond, "message"` raises `AssertionError` when `cond` is false; assertions are always compiled in.

## Errors across boundaries

Foreign code never sees a Nox exception: at an `extern def` boundary the compiler generates a trampoline that converts the foreign error
convention into an exception on return, and fences raw `longjmp`s ([Foreign functions](ffi.md)). NNI functions report errors through
`error_set`, which becomes a `NativeError` ([NNI](../apis/nni.md)).
