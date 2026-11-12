# nox.fnmatch

Shell-style file name matching.

```text
import nox.fnmatch
from nox.fnmatch import fnmatch, filter_names, has_magic, escape
```

**Capability:** none (pure Nox). Matching is **case-sensitive** and works on bytes, so it is exact for ASCII names.

| Pattern | Matches |
|---|---|
| `*` | any run of characters, including none |
| `?` | exactly one character |
| `[abc]`, `[a-z]` | one character from the set or range |
| `[!abc]` | one character not in the set |

A `[` without a closing `]` is an ordinary character. Unlike [`nox.glob`](glob.md), `fnmatch` treats a leading `.` like any other character (`*` matches `.hidden`).

| Function | Description |
|---|---|
| `fnmatch(name, pattern)` | whether `name` matches `pattern` entirely |
| `filter_names(names, pattern)` | the names that match, in order |
| `has_magic(pattern)` | whether `pattern` contains `*`, `?` or `[` |
| `escape(s)` | wrap special characters in `[...]` so they match literally |

```nox
import nox.fnmatch
from nox.fnmatch import fnmatch, filter_names

print(fnmatch("report.txt", "*.txt"), fnmatch("a1", "a[0-9]"), fnmatch("ab", "a[!b]"))
print(filter_names(["a.py", "b.txt", "c.py"], "*.py"))
```

```output
True True False
['a.py', 'c.py']
```
