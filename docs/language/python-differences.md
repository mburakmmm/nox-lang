# Differences from Python

Nox looks like Python and most small Python programs become Nox programs by adding type annotations. This page is the checklist of what
differs, grouped by what you will hit first. Everything here is deliberate unless marked *(not yet)*.

## Types are mandatory

Every variable's first assignment, every parameter and every return value carries a type. There is no `Any`, no dynamic attribute
creation, no `setattr`/`getattr`/`exec`/`eval`. `x = []` is an error — write `x: list[int] = []`. A name keeps its type for its scope.
Inside functions `x := expr` infers the type from the value (not `None`/empty containers; see [Types](types.md#inferred-local-declarations)); this is not Python's walrus operator.

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

- No `lambda` with statements. Semicolons, one-line compound statements (`if x: y()`), `try … else`, `for/while … else`, `with a, b:`, raw strings
  (`r"…"`), adjacent literal concatenation, `...` and `global x` are supported; `noxc fmt` writes the expanded canonical form.
- No Python expression walrus (`(n := f())`); `x := value` is a *declaration* statement that infers the type (see [Types](types.md#inferred-local-declarations)).
- `*args`, `**kwargs`, keyword-only (`*`), positional-only (`/`) and call-site unpacking (`f(*xs)`, `f(**d)`) are supported (see
  [Functions](functions.md)); `f(**d)` never binds a named parameter by key. There is no star-assignment (`a, *b = xs`). Default values must be
  constant literals.
- `yield` generators are **lazy** state machines typed `Iterator[T]` (see [Functions](functions.md#generators-yield)); `yield` inside `try … finally` is allowed, there is no `send()`. Generator expressions are accepted only as a call argument and are evaluated eagerly into a list.
- `nonlocal` is supported (the variable needs an explicit type at its first declaration); `global x` is accepted and changes nothing, because module-level names are assigned directly from functions.
- No `%` formatting and no `!a` in f-strings (`!r` and `!s` work). `\xHH` is limited to ASCII; use `\uHHHH`/`\UHHHHHHHH` for other characters. Identifiers are compared by code point (no NFKC normalization; see [`nox.unicode`](../stdlib/unicode.md) for normalizing text).
- No bare `raise` (use `raise e`) and no `raise … from …`.
- `async with` and `async for` exist; `await` takes a `Task`, a channel operation or an async-protocol call, not an arbitrary expression.
- No `del name` (only `del xs[i]` and `del d[k]`).
- `__name__ == "__main__"` does not exist: the top-level statements of the entry file are the program, and `main` is a reserved name.
- Python's `type` aliases and decorators that wrap are not part of Nox. `match` (on `enum`s), `@property`, `@staticmethod` and `@classmethod` are.
- Chained comparisons (`a < b < c`) work.

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

`str` is UTF-8 and indexed by code point; case conversion and character classes follow Unicode like Python (no normalization, no locale-specific mappings). The format
mini-language is fully supported in f-strings, `format()` and `str.format`.

## Classes

- Multiple inheritance (`class C(A, B)`: `C` is a subtype of every base, see [Classes](classes.md#several-bases-multiple-inheritance)); class attributes are shared storage assigned only through the declaring class (`Cls.X = v`, never `self.X = v`); no metaclasses, `__slots__`, `__getattr__`, `__call__` or `isinstance`.
- Fields are fixed: created in `__init__` (or declared in the class body) and never added later. `self` may be left unannotated.
- `==` on two instances compares fields structurally unless you define `__eq__`; `is` is only for `None`.
- Operator overloading uses the usual dunder names; `x += y` calls `__add__`.
- A class used before it is defined is fine; a protocol is structural and only usable as a parameter type (no `list[Protocol]`).

## Errors and resources

Exceptions are classes, `except Base:` catches subclasses, and `e.message`/`e.line` are available. There is no traceback object — an uncaught
exception prints the class and source line. Resources are released by `with`, `defer` and `finally`; `__del__` runs once when the last reference goes away ([Classes](classes.md#destructors-__del__)); there is no `weakref`.
Built-in error text is English; match the exception class, not the wording.

## Modules

`import a.b` / `from a.b import x [as y]` only — no `import *`, no relative imports, no dynamic import; a module may restrict what others can use with an opt-in `__all__`. All modules compile together;
module-level variables are read from other modules with `from m import name`, not as `m.name`. Third-party code arrives through `nox.json` and
`noxc fetch`, not `pip`.

## Concurrency

There is no GIL and no `threading`/`asyncio`. Tasks (`spawn`/`await`), channels and `nox.thread` replace them, and on the default backend tasks run
in parallel on a worker pool ([Concurrency](concurrency.md)). There is no `list[Task[T]]`; gather results through a channel.

## Performance model

Nox is compiled ahead of time to native code. There is no interpreter overhead, no boxing of `int`/`float`, and memory is released
deterministically. A straight port of a numeric Python loop typically runs one to two orders of magnitude faster.
