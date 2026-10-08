# Built-in functions

The **prelude** is everything available without an `import`. It consists of compiler built-ins and a small set of functions and classes
written in Nox itself (`stdlib/nox/core.nox`, merged into every program). Names beginning with `__nox_` are internal.

## Output and input

| Function | Description |
|---|---|
| `print(*values, sep=" ", end="\n")` | prints its arguments separated by `sep` and followed by `end`; with no arguments prints a blank line. Each value is rendered like `str(value)` (containers structurally) |
| `input() -> str` | reads one line from standard input (without the newline); an empty string at end of input |

```nox
print("a", "b", sep="-", end="!\n")
print()
print([1, 2], {"k": 1}, (1, "x"), None, 2.0)
```

```output
a-b!

[1, 2] {'k': 1} (1, 'x') None 2.0
```

## Conversions

| Function | Description |
|---|---|
| `int(x)` | from `float` (truncating), `str` (decimal; `ValueError` if malformed), `bool`, fixed-width integer |
| `float(x)` | from `int`, `bool`, fixed-width integer, `str` |
| `str(x)` | text of an `int`, `float`, `bool`, `str`, list, dict, set, tuple or class (uses `__str__`) |
| `repr(x)` | like `str`, with strings quoted (uses `__repr__`) |
| `bool(x)` | truthiness of `bool`, `int`, `float`, `str`, `list`, `dict` or a class (`__bool__`, `__len__`) |
| `list(x)` | a new list from `range(...)`, a list (copy), a `str` (its characters) or a `dict` (its keys) |
| `chr(cp)`, `ord(s)` | code point ↔ one-character string |
| `u8(x)`, `i32(x)`, … | fixed-width integer conversions (range-checked) |
| `format(value, spec)` | formats one value with the [format mini-language](strings.md#the-format-mini-language) |

## Sizes and sequences

| Function | Description |
|---|---|
| `len(x)` | number of elements of a `str` (code points), list, dict, set or tuple, or `__len__` of a class |
| `range(stop)`, `range(start, stop[, step])` | integer progression, usable in `for`, comprehensions and `list(...)` |
| `enumerate(xs)` | a list of `(index, element)` tuples |
| `zip(a, b)` | a list of pairs, as long as the shorter input |
| `reversed(xs)` | a **new list** in reverse order (not a lazy iterator) |
| `sorted(xs, key=f, reverse=False)` | a new sorted list; stable; without `key` the elements must be `int`, `float` or `str` |
| `map(f, xs)`, `filter(f, xs)` | a **new list** (not lazy) |
| `any(bs)`, `all(bs)` | over a `list[bool]` |

```nox
xs: list[int] = [3, 1, 2]
print(sorted(xs), sorted(["b", "a"], reverse=True), sorted(xs, key=lambda n: -n))
print(list(reversed(xs)), list(range(3)), list("ab"), list({"k": 1}))
print(enumerate(["a", "b"]), zip([1, 2], ["x", "y"]))
print(map(lambda n: n + 1, [1, 2]), filter(lambda n: n > 1, [1, 2, 3]))
print(any([False, True]), all([True, False]))
```

```output
[1, 2, 3] ['b', 'a'] [3, 2, 1]
[2, 1, 3] [0, 1, 2] ['a', 'b'] ['k']
[(0, 'a'), (1, 'b')] [(1, 'x'), (2, 'y')]
[2, 3] [2, 3]
True False
```

`xs.sort()` sorts in place and accepts `reverse=` and `key=` as well.

## Numbers

| Function | Description |
|---|---|
| `abs(x)` | absolute value of an `int` or `float` |
| `min(a, b)`, `max(a, b)` | of two numbers or strings (both arguments the same type) |
| `min(xs)`, `max(xs)`, with `key=f` | of a list; `ValueError` when the list is empty |
| `sum(xs)` | sum of a `list[int]` or `list[float]`; also accepts a generator expression |
| `round(x)` | nearest `int`, halves to even |
| `round(x, n)` | a `float` rounded to `n` digits, using the exact binary value like Python |
| `divmod(a, b)` | the tuple `(a // b, a % b)` |

```nox
print(sum([1, 2, 3]), sum([1.5, 2.5]), sum(x * x for x in [1, 2]))
print(max([3, 9, 2]), min(["b", "a"]), max(["aa", "b"], key=lambda s: len(s)), min(4, 2), max(1.5, 0.5))
print(abs(-4), abs(-1.5), round(2.567, 1), divmod(17, 5), divmod(-7, 2))
```

```output
6 4.0 5
9 a aa 2 1.5
4 1.5 2.6 (3, 2) (-4, 1)
```

## Memory, layout and low-level helpers

`sizeof(T)`, `alignof(T)`, `offsetof(T, "field")` ([Foreign functions](ffi.md)); `ptr_*`, `detach`, `adopt` (inside `lowlevel`).

## Prelude classes

`Exception`, `ValueError`, `IndexError`, `KeyError`, `ZeroDivisionError`, `AssertionError`, `CancelledError`, `HPyError`, and `JsonValue` (the
node type of [`nox.json`](../stdlib/json.md)). The generic types `Task[T]`, `Channel[T]`, `TaskLocal[T]`, `ThreadHandle[T]` and `ThreadChannel[T]`
are built in ([Concurrency](concurrency.md)).

## What is not built in

`isinstance`, `type`, `id`, `hash`, `open`, `getattr`/`setattr`, `eval`/`exec`, `iter`/`next`, `*args`-style functions, `print(file=…)`, and
`%` string formatting. File access is [`nox.fs`](../stdlib/fs.md); dynamic attribute access does not exist by design.
