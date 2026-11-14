# nox.pcre2

Perl-compatible regular expressions on top of [PCRE2](https://github.com/PCRE2Project/pcre2) (BSD-3), with its JIT compiler. It lives **next to** `nox.regex`, which is unchanged (a Python `re` subset engine written in Zig): the surface is the same (`search`, `match`, `full_match`, `is_match`, `find_all`, `find_matches`, `split`, `replace`, `escape`, `Match`, the same flags, **byte** positions), plus a compiled-pattern class `Pcre2` and the full PCRE feature set: backreferences, lookahead and lookbehind, atomic groups, possessive and lazy quantifiers, Unicode properties (`\p{Lu}`), named groups (`(?P<name>...)`).

```text
import nox.pcre2
from nox.pcre2 import Pcre2, Match, Pcre2Error
```

**Capability:** `dynamic_code` (the JIT generates machine code at run time, so `--deny-capability dynamic_code` rejects this module; use `nox.regex` there). The C library is shipped as a separate archive linked only into programs that import this module; it behaves identically on **macOS, Linux and Windows**. It is not available on WebAssembly, mobile and bare-metal targets.

## Compiled patterns and the JIT

`compile(pattern, flags=0, jit=True)` returns a `Pcre2`: immutable, usable from several threads, freed by ARC. JIT compilation costs more than a single match, so compile once and reuse; the one-shot module functions compile without JIT. If the JIT is unavailable or fails (hardened systems), matching silently uses the interpreter; results are always the same (`p.is_jit()` tells which is in use). A PCRE2 match limit turns catastrophic backtracking into a `Pcre2Error` instead of a hang.

Methods: `search(text, start=0)`, `match(text, start=0)`, `full_match(text)`, `is_match(text)`, `is_full_match(text)`, `find_all(text)`, `find_matches(text)`, `count_matches(text)`, `split(text)`, `replace(repl, text, count=0)` (`\1`, `\g<name>` in `repl`, like `nox.regex.replace`), `group_count()`.

Flags: `IGNORECASE`, `MULTILINE`, `DOTALL`, `EXTENDED` (verbose patterns), `BYTES`. By default patterns are UTF-8 with Unicode properties (`\w`, `\d`, `\b` behave like Python 3 `str`), and the subject must be valid UTF-8; `BYTES` matches raw bytes instead. Invalid patterns raise `Pcre2Error` with the PCRE2 message and the byte offset.

## Speed

On 1.3 MB of text (Apple M4; `benchmarks/pcre2/run.py`):

| Task | `nox.regex` | `nox.pcre2` JIT | C PCRE2 JIT | CPython `re` |
|---|---|---|---|---|
| count `[0-9]+` (50 000 matches) | 3.4 ms | 0.8 ms | 0.7 ms | 4.4 ms |
| count `\b(foo\|bar\|baz)\b` | 17.2 ms | 2.0 ms | 1.9 ms | 12.2 ms |
| count `(\w+)@(\w+)\.com` | 28.5 ms | 2.1 ms | 2.0 ms | 27.1 ms |

```nox
import nox.pcre2
from nox.pcre2 import Pcre2

p: Pcre2 = nox.pcre2.compile("(?<=\\$)\\d+")
print(p.find_all("cost $15 and $200 or 30"))
```

```output
['15', '200']
```
