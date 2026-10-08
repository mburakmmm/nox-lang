# Lexical structure

A Nox source file is UTF-8 text with the extension `.nox`. The lexer turns it into a stream of tokens; indentation produces
explicit `INDENT`/`DEDENT` tokens exactly as in Python.

## Lines and indentation

A *logical line* normally ends at the end of a physical line. A logical line continues onto the next physical line when:

- it ends with a backslash `\`, or
- an opening bracket `(`, `[` or `{` has not been closed yet.

```nox
total: int = 1 + \
    2
values: list[int] = [
    10,
    20,
    30,
]
print(total, values)
```

```output
3 [10, 20, 30]
```

Blocks are formed by indentation. The body of a `def`, `class`, `if`, `elif`, `else`, `while`, `for`, `try`, `except`,
`finally`, `with` or `lowlevel` statement is an indented block on the following lines. Rules:

- Indent with **spaces**. A tab in the indentation is a syntax error ("indentation with tab; use spaces").
- All lines of one block must use the same indentation; a dedent must return to the indentation of an enclosing block, or the
  compiler reports *inconsistent indentation*.
- Blank lines and comment-only lines are ignored for indentation purposes.
- A compound statement's body may **not** be written on the same line (`if x: print(x)` is a syntax error) — there are no
  one-line compound statements, and there are no semicolons: one statement per logical line.

## Comments and docstrings

A comment starts with `#` and runs to the end of the line. A comment may follow code on the same line.

A triple-quoted string (`"""..."""` or `'''...'''`) that is the first statement of a class body is the class's *docstring*; the
formatter and `nox.reflect` keep it. In any other position a triple-quoted string is just a multi-line `str` literal (and a
bare string expression statement is allowed and ignored).

```nox
class Point:
    """A point on the plane."""
    x: int
    y: int

    def __init__(self, x: int, y: int) -> None:
        self.x = x
        self.y = y

p: Point = Point(3, 4)  # trailing comment
print(p.x + p.y)
```

```output
7
```

## Identifiers

An identifier is a letter or `_` followed by letters, digits or `_`. **Identifiers are ASCII-only**; non-ASCII letters are a
syntax error (non-ASCII text is fully supported inside string literals). Identifiers are case sensitive.

A leading double underscore names a *special method* when used as a method name (`__init__`, `__add__`, …; see
[Classes](classes.md)). Names beginning with `__nox_` are reserved for the compiler's prelude and are not part of the language
surface.

### Reserved words

The following words are keywords and cannot be used as identifiers:

```text
and       as        async     await     break     class     continue  def
defer     del       elif      else      except    extern    False     finally
for       from      if        import    in        is        lambda    lowlevel
None      not       or        pass      protocol  raise     retains   return
spawn     True      try       while     with      with_rt
```

`assert` is a *soft* keyword: it starts an assertion only when it begins a statement and is followed by an expression.
`self` is an ordinary name, conventionally the first parameter of a method. A top-level function may not be called `main`
(the compiler synthesises the program entry point under that name).

## Literals

### Integers

Decimal (`42`, `1_000_000`), hexadecimal (`0xFF`), binary (`0b1010`) and octal (`0o17`) literals. Underscores may separate digits.
A literal has type `int`; it converts to a fixed-width integer type where one is expected and the value fits (see
[Numbers](numbers.md)). `noxc fmt` rewrites non-decimal literals as decimal.

```nox
print(255 == 0xFF, 0b101, 0o17, 9_000)
```

```output
True 5 15 9000
```

### Floating-point numbers

`3.14`, `1e-3`, `2.5E+10`, `1_0.5`. An exponent always makes the literal a `float`. See [Numbers](numbers.md) for how floats are
printed.

### Booleans and `None`

`True`, `False` (type `bool`) and `None`.

### Strings

String literals use single quotes, double quotes, or triple quotes (which may span lines). The escape sequences are:

| Escape | Meaning |
|---|---|
| `\n`, `\t`, `\r` | newline, tab, carriage return |
| `\\`, `\"`, `\'` | backslash, double quote, single quote |
| `\uXXXX` | the code point U+XXXX (four hex digits) |

An unrecognised escape keeps the character after the backslash (`"\q"` is `"q"`). There are no raw strings, no `\x` or `\U`
escapes, and adjacent literals are not concatenated implicitly — write `"a" + "b"`. Prefixing a literal with `f` makes an
*f-string* (see [Strings](strings.md#f-strings)).

```nox
print("tab:\there", 'quote: \'', "café")
print("""first
second""")
```

```output
tab:	here quote: ' café
first
second
```

## Operators and delimiters

```text
+  -  *  /  //  %  **          arithmetic
&  |  ^  ~  <<  >>             bitwise
== != <  <= >  >=              comparison
=  +=  -=  *=  /=  //=  %=  **=  &=  |=  ^=  <<=  >>=    assignment
(  )  [  ]  {  }  ,  :  .  ->  delimiters
```

See [Expressions](expressions.md) for precedence and [Statements](statements.md) for assignment forms.
