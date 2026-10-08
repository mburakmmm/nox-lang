# Strings

`str` is an immutable sequence of Unicode code points stored as UTF-8. Strings are reference-counted heap values, but because
they are immutable they behave like plain values.

## Indexing, length and slicing

`len(s)`, `s[i]` and slices count **code points**, not bytes, so non-ASCII text behaves intuitively. `s[i]` is a one-character `str`.
Negative indexes count from the end and an index out of range raises `IndexError`. For ASCII-only strings (the common case) the
runtime tracks that fact and `len` and `s[i]` are O(1).

```nox
s: str = "héllo"
print(len(s), s[1], s[-1], s[1:3], s[::-1])
for ch in "añb":
    print(ch)
```

```output
5 é o él olléh
a
ñ
b
```

Slices `s[a:b]`, `s[:b]`, `s[a:]`, `s[:]`, `s[a:b:step]` follow Python: bounds clamp, negative bounds count from the end, and a step of
zero raises `ValueError` (a literal zero step is a compile error). A slice is a value — assigning to one is not supported, and
strings cannot be modified in place.

## Operators

| Expression | Meaning |
|---|---|
| `a + b` | concatenation |
| `s * n`, `n * s` | repetition (`n <= 0` gives `""`) |
| `a == b`, `a != b` | equality |
| `a < b`, `a <= b`, `a > b`, `a >= b` | lexicographic comparison by code point |
| `x in s`, `x not in s` | substring test (the empty string is in every string) |

```nox
print("ab" * 3, "ab" < "b", "a" in "cat", "x" not in "cat", "ab" + "cd")
```

```output
ababab True True True abcd
```

## Methods

All methods return new strings; case and whitespace rules are **ASCII-based** (`"héllo".upper()` is `"HéLLO"`), while positions are
code points.

| Method | Result |
|---|---|
| `upper()`, `lower()`, `capitalize()`, `title()`, `swapcase()`, `casefold()` | case conversions |
| `strip([chars])`, `lstrip([chars])`, `rstrip([chars])` | trim whitespace, or any of `chars` |
| `split([sep])` | split on `sep`, or on runs of whitespace when omitted |
| `rsplit(sep[, maxsplit])`, `splitlines()` | split from the right / at line breaks |
| `sep.join(parts)` | join a `list[str]` |
| `replace(a, b)` | replace every occurrence |
| `startswith(p)`, `endswith(p)` | prefix / suffix tests |
| `removeprefix(p)`, `removesuffix(p)` | strip a prefix / suffix if present |
| `find(sub)`, `rfind(sub)` | first / last code-point index, or `-1` |
| `index(sub)`, `rindex(sub)` | like `find`, but raise `ValueError` when absent |
| `count(sub)` | non-overlapping occurrences |
| `partition(sep)`, `rpartition(sep)` | a 3-tuple `(before, sep, after)` |
| `isdigit()`, `isdecimal()`, `isnumeric()`, `isalpha()`, `isalnum()`, `isspace()`, `isupper()`, `islower()` | character-class tests |
| `ljust(w[, c])`, `rjust(w[, c])`, `center(w[, c])`, `zfill(w)` | padding |

```nox
t: str = "Hello, World"
print(t.upper(), t.lower(), t.title(), t.swapcase())
print(t.split(", "), "a b  c".split(), "-".join(["x", "y", "z"]))
print(t.replace("l", "L"), t.startswith("He"), t.endswith("ld"))
print(t.find("o"), t.find("zz"), t.index("W"), t.count("l"), t.rfind("o"))
print("7".zfill(3), "ab".ljust(5, "."), "ab".center(6, "*"))
print("pre_fix".removeprefix("pre_"), "a=b=c".partition("="), "xxhixx".strip("x"))
```

```output
HELLO, WORLD hello, world Hello, World hELLO, wORLD
['Hello', 'World'] ['a', 'b', 'c'] x-y-z
HeLLo, WorLd True True
4 -1 7 3 8
007 ab... **ab**
fix ('a', '=', 'b=c') hi
```

The module [`nox.strings`](../stdlib/strings.md) offers the same operations as functions plus a few extras (`reverse`, `repeat`, …).
`chr(cp)` and `ord(s)` convert between code points and one-character strings.

## Converting to and from `str`

`str(x)` renders an `int`, `float`, `bool` or `str`, and — new in 2.0 — lists, dictionaries, tuples, sets and class instances, with
exactly the text `print` would show. A class with `__str__` uses it. `int(s)` and `float(s)` parse and raise `ValueError` on
bad input. `repr`-style output is what containers show for their elements (`['a']`, not `[a]`).

```nox
class Pt:
    x: int
    y: int
    def __init__(self, x: int, y: int) -> None:
        self.x = x
        self.y = y

print(str([1, 2]), str({"k": [1]}), str((1, "x")), str(Pt(1, 2)))
```

```output
[1, 2] {'k': [1]} (1, 'x') Pt(x=1, y=2)
```

## F-strings

An f-string interpolates expressions with `{expr}`; each value is rendered like `str(value)`. A literal brace is written `{{` or `}}`.
Quotes inside a replacement field must differ from the f-string's own delimiter.

```nox
name: str = "Ada"
n: int = 3
print(f"{name} has {n * 2} items; {{literal}}")
```

```output
Ada has 6 items; {literal}
```

### The format mini-language

A field may carry a format specification, `{value:spec}`, with the full Python mini-language
`[[fill]align][sign][#][0][width][,|_][.precision][type]`:

- **align**: `<` left, `>` right, `^` centre, `=` pad between sign and digits; **fill** is any character before the align.
- **sign**: `+`, `-` (default) or a space.
- **#**: alternate form (`0x`, `0b`, `0o` prefixes).
- **0**: zero padding. **,** and **_**: thousands separators.
- **type** — integers: `b c d n o x X`; floats: `e E f F g G n %`; strings: `s`.

`f` and `%` round the *exact binary value* like Python, so `f"{2.675:.2f}"` is `2.67`. An invalid specification raises `ValueError`.
`!s` converts with `str`.

```nox
x: int = 42
pi: float = 3.14159
big: int = 1234567
p: float = 0.256
print(f"{x:5d}|{x:03d}|{x:<6}|{x:^6}|{x:>6}|{x:*>6}|{x:+d}")
print(f"{pi:.3f} {pi:10.2f} {big:,} {x:#x} {x:b} {p:.1%} {2.675:.2f}")
print(f"{'ab':>5} {'ab':<5}| {x!s}")
```

```output
   42|042|42    |  42  |    42|****42|+42
3.142       3.14 1,234,567 0x2a 101010 25.6% 2.67
   ab ab   | 42
```

`format(value, spec)` formats a single value, and `"...".format(...)` accepts positional (`{}`, `{0}`) and named (`{name}`)
fields with the same specifications:

```nox
print(format(3.14159, ".2f"), "{} scored {:.1f}".format("ada", 9.25), "{1}-{0}".format("a", "b"))
```

```output
3.14 ada scored 9.2 b-a
```

Not supported: the `!r` and `!a` conversions, nested `{}` inside a specification, attribute or index fields in `str.format` (use an f-string
instead), and `%`-style formatting (`"%d" % x`).

## Multi-line strings

Triple-quoted literals span lines and keep their newlines. There is no implicit dedent; `"""` strings used as documentation
should be dedented by the author.

## Encoding

Source files and string literals are UTF-8. Invalid UTF-8 can enter a program only through byte-level APIs (files, sockets,
`extern def`); `nox.strings` and `nox.binary` document how those are validated. NNI string handles are validated UTF-8 as well
([NNI](../apis/nni.md)).
