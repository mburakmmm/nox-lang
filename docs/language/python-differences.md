# Differences from Python

Nox looks like Python and most small Python programs become Nox programs by adding type annotations. This page is the checklist of what
differs, grouped by what you will hit first. Everything here is deliberate unless marked *(not yet)*.

## Types are mandatory

Every variable's first assignment, every parameter and every return value carries a type. There is no `Any`, no dynamic attribute
creation, no `setattr`/`getattr`/`exec`/`eval`. `x = []` is an error — write `x: list[int] = []`. A name keeps its type for its scope.

## Numbers

| Python | Nox |
|---|---|
| unbounded `int` | 64-bit `int` that **wraps** on overflow; fixed-width types (`u8`…`i64`) **trap** on overflow |
| `2 ** -1` is `0.5` | `int ** int` is an `int` (negative exponent → `0`); use a `float` base |
| `10 ** 30` is exact | wraps modulo 2⁶⁴ |
| `True + 1` is `2` | `bool` never takes part in arithmetic — `int(True) + 1` |
| `if x:` truthiness | conditions must be `bool` — write `if x != 0:` / `if len(xs) > 0:` |
| `round(2.5)` is `2` | same (half to even), but `round(x)` always returns `int` |
| `int(u8_value)` n/a | `int(x)` works on fixed-width integers and `bool` |

Integer `//` and `%` by zero raise `ZeroDivisionError`; float division never raises (`inf`/`nan`). Floats print like Python's `repr`.

## Syntax

- No semicolons, no one-line compound statements (`if x: y()` must be two lines), no walrus `:=`, no `lambda` with statements.
- No `*args`/`**kwargs`, no keyword-only (`*`) or positional-only (`/`) markers, no argument unpacking at call sites, no star-assignment
  (`a, *b = xs`). Default values must be constant literals.
- No `yield`/generators/iterators; generator expressions are accepted only as a call argument and are evaluated **eagerly** into a list.
- No `global`/`nonlocal`: module-level names are assigned directly from functions; a nested function may only **read** captured variables.
- No raw strings (`r"…"`), no adjacent-literal concatenation, no `\x`/`\U` escapes, no `%` formatting, no `!r` in f-strings. ASCII-only identifiers.
- No `try … else`, no `for … else`/`while … else`, no bare `raise` (use `raise e`), no `raise … from …`, no multi-item `with`.
- No `async with`/`async for`/`await` on arbitrary expressions: `await` takes a `Task` or a channel operation.
- No `del name` (only `del xs[i]` and `del d[k]`), no `pass`-only protocol bodies other than `pass` itself.
- `__name__ == "__main__"` does not exist: the top-level statements of the entry file are the program, and `main` is a reserved name.
- Python's `match` statement, `type` aliases, decorators that wrap, `@property`, `@staticmethod` and `@classmethod` are not part of Nox.

## Collections and iteration

- `map`, `filter`, `zip`, `enumerate` and `reversed` return **new lists**, not lazy iterators; `range` is only usable in `for`, comprehensions and
  `list(...)`.
- `dict` keys are `int`, `float`, `bool` or `str`; values are scalars, classes, lists or dicts. `set` elements are `int`, `float`, `bool` or
  `str`. Both keep **insertion order** (as Python dicts do; Python sets do not). Tuples cannot be dictionary keys.
- Lists are homogeneous: `[1, "a"]` is a type error. A list of subclasses needs an annotation (`xs: list[Base] = [Dog(), Cat()]`).
- Slices are values — you cannot assign to a slice or delete one. `xs.sort()` needs `int`, `float` or `str` elements unless you pass `key=`.
- A loop variable keeps its value after the loop, but after a `range` loop it is one past the last element, not the last element.
- `sorted`, `min`, `max` take `key=`, but the elements (or the keys) must be `int`, `float` or `str`.

## Strings

`str` is UTF-8 and indexed by code point; case conversion and whitespace classification are ASCII-only (`"é".upper()` is unchanged). The format
mini-language is fully supported in f-strings, `format()` and `str.format`.

## Classes

- Single inheritance only; no metaclasses, `__slots__`, `__getattr__`, `__call__`, class-level attributes or `isinstance`.
- Fields are fixed: created in `__init__` (or declared in the class body) and never added later. `self` may be left unannotated.
- `==` on two instances compares fields structurally unless you define `__eq__`; `is` is only for `None`.
- Operator overloading uses the usual dunder names; `x += y` calls `__add__`.
- A class used before it is defined is fine; a protocol is structural and only usable as a parameter type (no `list[Protocol]`).

## Errors and resources

Exceptions are classes, `except Base:` catches subclasses, and `e.message`/`e.line` are available. There is no traceback object — an uncaught
exception prints the class and source line. Resources are released by `with`, `defer` and `finally`; there is no `__del__` and no `weakref`.
The text of built-in errors is currently Turkish.

## Modules

`import a.b` / `from a.b import x [as y]` only — no `import *`, no relative imports, no `__all__`, no dynamic import. All modules compile together;
module-level variables are read from other modules with `from m import name`, not as `m.name`. Third-party code arrives through `nox.json` and
`noxc fetch`, not `pip`.

## Concurrency

There is no GIL and no `threading`/`asyncio`. Tasks (`spawn`/`await`), channels and `nox.thread` replace them, and on the default backend tasks run
in parallel on a worker pool ([Concurrency](concurrency.md)). There is no `list[Task[T]]`; gather results through a channel.

## Performance model

Nox is compiled ahead of time to native code. There is no interpreter overhead, no boxing of `int`/`float`, and memory is released
deterministically. A straight port of a numeric Python loop typically runs one to two orders of magnitude faster.
