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

> **Diagnostics language.** The text of messages produced by the compiler and by built-in runtime errors (`e.message` of an
> `IndexError`, the uncaught-exception report, type errors) is currently written in Turkish. Programs should branch on the exception
> *class*, never on built-in message text. User-raised messages are, of course, whatever you write.

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
