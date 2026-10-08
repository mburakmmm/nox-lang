# Migrating from Nox 1.x to 2.0

Nox 2.0 removes the names that were deprecated during 1.x and aligns a handful of behaviours with common Python expectations. The versioning policy ([Versioning](../reference/versioning.md)) allows removal only in a major release, so this page lists every
change you can observe, with the fix. Most programs need no change; the compiler reports removed names as errors.

## 1. Removed names (compile errors)

**`nox.json`** — renamed in 1.x to the `parse`/`dump` family, old names removed:

| Removed | Use instead |
|---|---|
| `decode` | `parse` |
| `encode` | `dump` |
| `encode_pretty` | `dump_pretty` |
| `encode_string` | `dump_string` |
| `encode_array` | `dump_array` |
| `encode_object` | `dump_object` |
| `encode_pretty_at` | `dump_pretty_at` |
| `encode_pretty_array` | `dump_pretty_array` |
| `encode_pretty_object` | `dump_pretty_object` |

**`nox.csv`:**

| Removed | Use instead |
|---|---|
| `write` | `dump` |
| `write_row` | `dump_row` |

The replacements have identical signatures: the fix is a rename.

## 2. Behaviour changes (may silently affect 1.x code)

| Area | 1.x | 2.0 |
|---|---|---|
| Printing a `float` | `printf`-style formatting | Python's `repr`: `0.1`, `2.0`, `1e+16`, `inf`, `nan` |
| Negative indexes | undefined | Python semantics: `xs[-1]` is the last element; out of range raises `IndexError` (lists, strings, assignment, `pop`, `del`) |
| Fixed-width integer overflow (`u8`, `i32`, …) | LLVM wrapped, QBE trapped | **traps on both back ends**; plain `int` wraps on both |
| `int ** int` | computed through a `double` (inexact above 2⁵³, back ends disagreed) | exact integer exponentiation with 64-bit wrap-around; a negative exponent gives `0` (use a `float` base for fractions); `0 ** negative` raises `ZeroDivisionError` |
| Integer `//` and `%` by zero | undefined / garbage | raises `ZeroDivisionError` |
| Keyword arguments | evaluated in parameter order | evaluated **in the order written**; bound by name afterwards (`spawn` requires side-effecting keyword arguments in parameter order) |
| `print(None)`, `print(optional)` | unsupported / printed a pointer | prints `None` |
| `print(obj)` and containers | class name only | `__str__`/`__repr__` if defined, otherwise `Name(field=value, …)` structurally, recursively |
| `nox.router` | the query string was part of the matched path (`/x?a=1` never matched `/x`) | the query string is stripped before matching and exposed as `Context.query` |
| `int(x)` on fixed-width integers and `bool` | not available | available: `int(u8_value)`, `int(True)` |
| SQL parameter binding | an out-of-range `bind_*` index silently bound nothing | raises the driver's error; indexes are **zero-based** |
| `noxc build -g` | failed on the default (LLVM) back end | selects the QBE back end automatically; `-g` with an explicit `--backend llvm` is an error |
| Parser nesting | unbounded | expression depth limited to 200 with a readable error |
| Syntax errors | one raw line | `file:line:column`, the source line and a caret |
| `HttpRequest(...)` constructor | `peer_addr` was required | `peer_addr: str = ""` (new constructor parameters now always have defaults) |

## 3. New (non-breaking) features worth knowing

See [What's new in Nox 2.0](2.0.md): hexadecimal/binary/octal/underscore literals, f-string format specs and `str.format`, triple-quoted strings and docstrings, `except (A, B) as e`, chained comparisons, `assert`,
generator expressions (eager), `set[T]`, `__iter__`, generic methods and classes, `nox.native` and `nox.plugin`, many new standard-library modules.

## 4. Known limits that may matter when porting

`*args`/`**kwargs`, multiple inheritance, class-level attributes, annotated `self.x: T = v`, empty `[]`/`{}` literals nested inside other literals, and `list[Task[T]]` are not supported; a protocol cannot be an element type
(`list[Protocol]`); `set` elements are `int`, `float`, `bool` or `str`; generator expressions are evaluated eagerly; diagnostics and library messages are currently Turkish. See [Differences from Python](../language/python-differences.md).

## 5. Checklist

1. Rebuild with `noxc check` on every entry file; fix removed-name errors (section 1).
2. Search your code for `float` printing in expected output (tests, golden files) — the text may differ (`2.0`, not `2`).
3. Search for `**` on integers and for fixed-width arithmetic that relied on wrap-around: use `int` and mask (`& 0xFFFFFFFF`) to wrap deliberately.
4. If you matched routes with query strings in a custom way, simplify: use `Context.query`.
5. If you supply `HttpRequest` objects in tests, nothing changes; if you subclass or wrap `nox.http`, re-read [`nox.http`](../stdlib/http.md).
6. Pin Nox 2.x in CI.
