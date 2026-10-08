# 2. Values and types

## The basic types

```nox
age: int = 36
height: float = 1.82
name: str = "Ada"
active: bool = True
print(age, height, name, active)
```

```output
36 1.82 Ada True
```

| Type | Examples |
|---|---|
| `int` | `0`, `-7`, `1_000_000`, `0xFF` (64-bit, wraps on overflow) |
| `float` | `3.14`, `1e-3` |
| `str` | `"text"`, `'text'`, `"""multi-line"""` |
| `bool` | `True`, `False` |
| `None` | `None` — "no value"; see [optionals](../language/types.md#optional-types) |

A variable is created by its first assignment, which carries the type. Later assignments do not repeat it:

```nox
counter: int = 0
counter = counter + 1
counter += 1
print(counter)
```

```output
2
```

Assigning a value of the wrong type is a compile error — `counter = "one"` would be rejected before the program runs.

## Arithmetic

```nox
print(7 + 2, 7 - 2, 7 * 2, 7 / 2, 7 // 2, 7 % 2, 7 ** 2)
print(-7 // 2, -7 % 2)
```

```output
9 5 14 3.5 3 1 49
-4 1
```

`/` always gives a `float`; `//` and `%` round toward minus infinity, like Python. Mixing an `int` and a `float` gives a `float`.

## Strings

```nox
first: str = "Ada"
last: str = "Lovelace"
full: str = first + " " + last
print(full, len(full), full.upper(), full[0], full[-1])
print(full.split(" "), "Love" in full, full.replace("a", "4"))
```

```output
Ada Lovelace 12 ADA LOVELACE A e
['Ada', 'Lovelace'] True Ad4 Lovel4ce
```

Strings are immutable and indexed by character (code point), so non-English text works as you expect.

### f-strings

Put an expression in braces inside an `f"..."` string. A format specification after a colon controls the layout:

```nox
item: str = "tea"
price: float = 3.5
qty: int = 4
print(f"{item}: {qty} x {price} = {qty * price}")
print(f"{price:8.2f}|{qty:03d}|{item:>6}|{1234567:,}")
```

```output
tea: 4 x 3.5 = 14.0
    3.50|004|   tea|1,234,567
```

## Converting between types

Conversions are always explicit:

```nox
print(int("42") + 1, float("2.5") * 2, str(7) + "!", int(3.9), float(3), bool(0))
```

```output
43 5.0 7! 3 3.0 False
```

`int("abc")` raises `ValueError` (chapter 7). The only implicit conversion is `int → float` when a `float` is expected.

## Reading input

```nox
line: str = input()
print("you typed:", line)
```

`input()` reads one line from standard input.

## Conditions are `bool`s

Nox does not treat `0`, `""` or `[]` as false. A condition must be a `bool`, produced by a comparison:

```nox
n: int = 0
if n == 0:
    print("zero")
items: list[int] = []
if len(items) == 0:
    print("empty")
```

```output
zero
empty
```

## Numbers that must not overflow

`int` wraps around at 64 bits. For code that must never overflow silently there are fixed-width types such as `u8` and `i32` that stop the
program instead — see [Numbers](../language/numbers.md).
