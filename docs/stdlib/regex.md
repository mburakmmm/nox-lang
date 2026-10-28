# nox.regex

A backtracking regular-expression engine with the everyday subset of Python's `re`: groups and captures, alternation, counted and lazy
repetition, escape classes, anchors, back-references and lookahead. Text is UTF-8; `.` and classes work on code points, while the
`start`/`end` positions of a match are **byte** offsets.

```text
import nox.regex
```

**Capability:** none.

## Functions

| Function | Description |
|---|---|
| `search(pattern, text, flags=0)` | the first match anywhere in `text` as a `Match`, or `None` |
| `match(pattern, text, flags=0)` | a match that starts at the beginning of `text`, or `None` |
| `full_match(pattern, text, flags=0)` | a match of the **whole** text, or `None`; `is_full_match(...)` returns a `bool` |
| `find_matches(pattern, text, flags=0)` | every non-overlapping match as a `list[Match]` |
| `find_all(pattern, text, flags=0)` | the text of every non-overlapping match |
| `replace(pattern, repl, text, flags=0, count=0)` | replace matches; `repl` may use `\1`, `\g<name>`, `\g<1>`, `\n`, `\t`, `\\`; `count > 0` limits the replacements |
| `split(pattern, text, flags=0)` | split `text` at every match |
| `escape(s)` | escape pattern metacharacters so `s` matches literally |
| `is_match(pattern, text)`, `find(pattern, text)` | the original total functions: `bool` / byte index or `-1`; an invalid pattern gives `False` / `-1` instead of an error |

The other functions raise `RegexError` for an invalid pattern. Flags are `IGNORECASE`, `MULTILINE` and `DOTALL` (combine with `|`);
`(?i)`, `(?m)` and `(?s)` at the start of a pattern set the same flags.

A `Match` has `start`, `end`, `text` (the searched text), and the methods `whole()`, `group(i)` (an unmatched group is `""`),
`named(name)`, `groups()`, `matched(i)` and `count()`.

## Supported syntax

| Syntax | Meaning |
|---|---|
| a literal character | matches itself |
| `.` | any character except a newline (any character with `DOTALL`) |
| `*`, `+`, `?`, `{m}`, `{m,}`, `{m,n}`, `{,n}` | repetition of the preceding item (greedy; add `?` for lazy) |
| `[abc]`, `[a-z]`, `[^abc]`, `[\d_-]` | a class, a range, a negated class; escapes work inside classes |
| `\d \D \w \W \s \S` | digit / word / space classes and their complements (Unicode-aware) |
| `^`, `$`, `\A`, `\z`, `\Z` | start / end of the text (line start / end with `MULTILINE`) |
| `\b`, `\B` | word boundary / not a word boundary |
| `( )`, `(?: )`, `(?P<name> )`, `(?<name> )` | capturing group, non-capturing group, named group |
| `a|b` | alternation |
| `\1` ... `\99` | back-reference to a captured group |
| `(?= )`, `(?! )` | positive / negative lookahead |
| `\n \t \r \f \v \0 \xHH \uHHHH`, `\.` | escaped characters |

**Not supported:** lookbehind `(?<= )`, atomic and possessive groups, conditional patterns and `\p{...}` property classes.
Matching is bounded: a pattern that needs more than about twenty million steps (for example `(a+)+b` on a long run of `a`) reports
"no match" instead of hanging.

```nox
import nox.regex

m: nox.regex.Match | None = nox.regex.search("(?P<year>\\d{4})-(\\d{2})-(\\d{2})", "released 2026-10-29!")
if m is not None:
    print(m.whole(), m.start, m.end, m.named("year"), m.groups())
print(nox.regex.find_all("\\b\\w+@\\w+\\.com\\b", "ada@lovelace.com, bob@example.com"))
print(nox.regex.replace("(\\w+)@(\\w+)", "\\2 at \\1", "ada@lovelace"))
print(nox.regex.split("\\s*,\\s*", "a , b,c"))
print(nox.regex.is_full_match("[a-z]+\\d?", "abc1"), nox.regex.is_match("^colou?r$", "color"))
```

```output
2026-10-29 9 19 2026 ['2026', '10', '29']
['ada@lovelace.com', 'bob@example.com']
lovelace at ada
['a', 'b', 'c']
True True
```

## Notes

- Matching uses backtracking with an explicit stack, so long inputs do not exhaust the call stack.
- The validator in [`nox.validate`](validate.md) uses this module for its `pattern` rule.
