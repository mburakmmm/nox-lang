# nox.regex

A small regular-expression matcher for simple patterns. It is **not** a full regex engine: there are no groups, alternation or counted repetition. For anything
beyond the subset below, use [string methods](../language/strings.md#methods) or write the matching logic directly.

```text
import nox.regex
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `is_match(pattern, text)` | whether `pattern` matches **anywhere** in `text` (only at the start when the pattern begins with `^`) |
| `find(pattern, text)` | the 0-based **byte** index where the first match starts, or `-1` |

## Supported syntax

| Syntax | Meaning |
|---|---|
| a literal character | matches itself |
| `.` | any single character |
| `*`, `+`, `?` | zero or more, one or more, zero or one of the preceding item |
| `^`, `$` | start / end of the text |
| `[abc]`, `[a-z]`, `[^abc]` | a character class, a range, a negated class |

**Not supported:** groups `( )` and captures, alternation `a|b`, back-references, counted repetition `{m,n}`, and escape classes such as `\d` or `\w`
(write `[0-9]` and `[a-zA-Z0-9_]`).

```nox
import nox.regex

print(nox.regex.is_match("^a.c", "abc"), nox.regex.is_match("b+", "abbbc"), nox.regex.is_match("[0-9]+$", "x12"))
print(nox.regex.find("c", "abc"), nox.regex.find("z", "abc"), nox.regex.is_match("^colou?r$", "color"))
```

```output
True True True
2 -1 True
```

## Notes

- Matching uses backtracking; avoid patterns with several nested `*` over large inputs.
- The validator in [`nox.validate`](validate.md) uses this module for its `pattern` rule.
