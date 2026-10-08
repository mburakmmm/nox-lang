# The formatter

`noxc fmt file.nox` rewrites a file **in place** in the standard Nox style. It is a real formatter — it parses the file, preserves comments and blank lines, and prints the syntax tree — so the result does not depend on
the input's spacing.

```sh
noxc fmt main.nox
```

The command prints nothing on success. It fails (status 1) if the file does not parse; fix the syntax error first.

## What it does

- Indents with four spaces and normalises spacing around operators, commas and colons (`x:int=1` → `x: int = 1`, `if x>0 :` → `if x > 0:`, `print( "a" )` → `print("a")`).
- Wraps nothing: it never changes line breaks inside an expression you broke over several lines in brackets, and it keeps your blank lines and `#` comments in place.
- Prints non-decimal integer literals as decimal (`0xFF` → `255`) and keeps string quoting as written.
- Re-creates syntactic sugar faithfully: comprehensions, chained comparisons, f-strings, `str.format`, generator expressions and augmented assignments are printed in the form you wrote them.

```nox
x: int = 1
if x > 0:
    print("a")
```

The formatter is idempotent: formatting a formatted file changes nothing.

## Editors

`noxlsp` serves the same formatter as the LSP `textDocument/formatting` request, so "Format Document" in an editor ([Editors](../install/editors.md)) gives byte-identical results to `noxc fmt`.
