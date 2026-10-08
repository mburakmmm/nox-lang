# nox.strings

Function-style string utilities. Everything here is also available as methods on `str` (`s.upper()`, `s.split(",")`, …; see
[Strings](../language/strings.md)); the module form is useful when you want to pass an operation as a function value or you need the
byte-level helpers.

```text
import nox.strings        # then: nox.strings.upper(s)
```

**Capability:** none (available in every profile).

## Functions

| Function | Description |
|---|---|
| `split(s, sep)` | splits `s` on every occurrence of `sep`; empty fields are kept (`"a,b,,c"` → `['a','b','','c']`) |
| `splitn(s, sep, n)` | at most `n` splits: the last element holds the remainder |
| `rsplit(s, sep)` | splits like `split` but returns the pieces **from the right** (`"a,b,c"` → `['c','b','a']`) |
| `join(parts, sep)` | joins a `list[str]` with `sep` |
| `trim(s)`, `trim_start(s)`, `trim_end(s)` | removes surrounding / leading / trailing whitespace |
| `upper(s)`, `lower(s)` | ASCII case conversion |
| `replace(s, old, new)` | replaces every occurrence |
| `starts_with(s, prefix)`, `ends_with(s, suffix)` | prefix / suffix tests |
| `index_of(s, needle)` | **byte** offset of the first occurrence, or `-1` |
| `contains(s, needle)` | substring test |
| `repeat(s, n)` | `s` repeated `n` times |
| `eq_ignore_case(a, b)` | ASCII case-insensitive equality |
| `pad_left(s, width, ch)`, `pad_right(s, width, ch)` | pads to `width` with the one-character string `ch` |
| `zfill(s, width)` | left-pads with `"0"` |
| `byte_at(s, idx)` | the byte value (0–255) at byte offset `idx` |
| `char_from_byte(b)` | a one-byte string from a byte value |
| `byte_len(s)` | length in **bytes** (`len(s)` counts code points) |

```nox
import nox.strings

print(nox.strings.split("a,b,,c", ","), nox.strings.splitn("a,b,c,d", ",", 2), nox.strings.rsplit("a,b,c", ","))
print(nox.strings.trim("  hi \n"), "|", nox.strings.trim_start("  hi "), "|", nox.strings.trim_end("  hi "), "|")
print(nox.strings.upper("abc"), nox.strings.lower("ABC"), nox.strings.replace("aXbXc", "X", "-"))
print(nox.strings.byte_at("A", 0), nox.strings.char_from_byte(66), nox.strings.byte_len("héllo"), len("héllo"))
print(nox.strings.join(["a", "b"], "+"), nox.strings.starts_with("hello", "he"), nox.strings.ends_with("hello", "lo"))
print(nox.strings.index_of("hello", "l"), nox.strings.index_of("hello", "z"), nox.strings.contains("hello", "ell"))
print(nox.strings.repeat("ab", 3), nox.strings.eq_ignore_case("AbC", "aBc"))
print(nox.strings.pad_left("7", 3, "0"), nox.strings.pad_right("7", 3, "."), nox.strings.zfill("7", 3))
```

```output
['a', 'b', '', 'c'] ['a', 'b,c,d'] ['c', 'b', 'a']
hi | hi  |   hi |
ABC abc a-b-c
65 B 6 5
a+b True True
2 -1 True
ababab True
007 7.. 007
```

## Notes

- Positions returned by `index_of` and taken by `byte_at` are **byte** offsets; the `str` methods `find`/`index` and `s[i]` use **code points**. For
  ASCII text they agree.
- Case conversion and whitespace trimming follow ASCII rules; non-ASCII letters are left unchanged.
- For everyday work prefer the string methods: they are available without an import and cover more (`capitalize`, `partition`, `splitlines`, …).
