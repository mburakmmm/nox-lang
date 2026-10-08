# The Nox language reference

This part of the documentation describes the Nox language *as it is in 2.0*: its syntax, its static semantics and its runtime
behaviour. It is a reference, not a tutorial — if you are new, start with the [tutorial](../tutorial/index.md).

Nox is a **statically typed, ahead-of-time compiled** language with Python-like syntax. There is no interpreter and no garbage
collector. A program is type-checked as a whole, lowered to one typed intermediate representation and handed to a backend
(LLVM by default, QBE as an alternative — see [Backends](../tools/backends.md)) that links it statically with a small runtime
written in Zig.

## How to read this reference

Each page covers one area and states rules in the same shape: what the construct is, how it is written, what the compiler
checks, and what happens at run time. Every complete `nox` code block in these pages is compiled — and, when an `output` block
follows it, executed and compared — by the documentation test (`scripts/check_docs.py`), so the examples are current.

| Page | What it defines |
|---|---|
| [Lexical structure](lexical.md) | Lines, indentation, tokens, literals, comments, keywords |
| [Types](types.md) | The type system: scalars, collections, optionals, function and generic types |
| [Numbers](numbers.md) | Integer and floating-point semantics, overflow, division, conversions |
| [Strings](strings.md) | `str` semantics, methods, f-strings and the format mini-language |
| [Expressions](expressions.md) | Operators, precedence, comparisons, slicing, comprehensions, lambdas |
| [Statements](statements.md) | Assignment, control flow, `assert`, `del`, scoping |
| [Functions](functions.md) | Parameters, defaults, keyword arguments, closures, first-class functions |
| [Classes](classes.md) | Fields, methods, special methods, single inheritance |
| [Protocols and generics](protocols-generics.md) | Structural protocols, generic functions/classes/methods |
| [Exceptions](exceptions.md) | `raise`/`try`/`except`/`finally`, `with`, `defer`, the error model |
| [Concurrency](concurrency.md) | `async`/`spawn`/`await`, tasks, channels, threads, the scheduler |
| [Memory](memory.md) | What the compiler does for you; `lowlevel` |
| [Modules](modules.md) | `import`, packages, entry point, module-level state |
| [Decorators and reflection](decorators.md) | Metadata decorators and `nox.reflect` |
| [Foreign functions](ffi.md) | `extern def`, `ptr`, callbacks, the trust boundary |
| [Built-in functions](builtins.md) | The prelude: everything available without an import |
| [Grammar](grammar.md) | A compact grammar of the whole language |
| [Differences from Python](python-differences.md) | What Python code needs to change to be Nox code |

## Design principles

Four rules shape every part of the language, and knowing them makes the rest predictable:

1. **Types are mandatory and static.** Every variable, parameter and return value has a type; there is no `Any`, no implicit
   dynamic fallback, and `lowlevel` code is type-checked exactly like everything else.
2. **Ownership is invisible.** There are no ownership keywords, borrow markers or lifetimes. The compiler picks the cheapest
   safe memory strategy automatically ([Memory](memory.md)).
3. **Errors are values on the return path.** Exceptions are ordinary classes propagated through an implicit error-return chain —
   no stack unwinding, no landing pads ([Exceptions](exceptions.md)).
4. **One program, one compilation unit.** All modules of a program compile together, so there is no separate-compilation ABI to
   worry about inside a program ([Modules](modules.md)).

## A first look

```nox
class Counter:
    count: int

    def __init__(self, start: int) -> None:
        self.count = start

    def bump(self) -> int:
        self.count += 1
        return self.count

def total(xs: list[int]) -> int:
    t: int = 0
    for x in xs:
        t += x
    return t

c: Counter = Counter(10)
c.bump()
print(c.bump(), total([1, 2, 3]))
```

```output
12 6
```
