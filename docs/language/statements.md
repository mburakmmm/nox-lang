# Statements

A Nox program is a sequence of statements. The top-level statements of the entry file are the program's entry point — there is no
`main` function ([Modules](modules.md#the-entry-point)).

## Expression statements

Any expression may stand alone as a statement (typically a call). Its value is discarded. A bare string literal is allowed and
ignored.

## Assignment

### Declaration

The first assignment to a name declares it and **must state its type**:

```nox
count: int = 0
names: list[str] = []
```

Re-stating the same type on a later assignment in the same scope is allowed; re-declaring a name with a *different* type is a
compile error. A declaration without a value is not allowed for local variables (a class body may declare *fields* without a value —
see [Classes](classes.md#fields)).

### Plain, augmented and tuple assignment

```nox
x: int = 1
x = x + 1                 # plain
x += 3                    # augmented: += -= *= /= //= %= **= &= |= ^= <<= >>=
xs: list[int] = [1, 2, 3]
xs[0] = 10                # subscript target
xs[1] *= 5
class Box:
    n: int
    def __init__(self) -> None:
        self.n = 0
b: Box = Box()
b.n += 1                  # attribute target
a: int = 1
c: int = 2
a, c = c, a               # tuple assignment (swap)
print(x, xs, b.n, a, c)
```

```output
5 [10, 10, 3] 1 2 1
```

Augmented assignment accepts a variable, an attribute or a subscript whose subexpressions are free of calls (`f()[0] += 1` is
rejected). Assigning to a slice, to a call result, or to a tuple element is not supported. For a class value `x += y` uses `__add__`
(there is no separate in-place protocol).

## `pass`

`pass` does nothing; it is the body of an empty block. (In a `protocol`, `pass` is the required body of each method — see
[Protocols and generics](protocols-generics.md).)

## `if`, `elif`, `else`

The condition must be a `bool`.

```nox
n: int = 0
if n > 0:
    print("positive")
elif n == 0:
    print("zero")
else:
    print("negative")
```

```output
zero
```

## `while`

```nox
i: int = 0
while i < 3:
    i += 1
print(i)
```

```output
3
```

## `for`

`for target in iterable:` iterates a `range(...)`, any `list[T]` expression, a `str` (one `str` per character), a `dict` (its keys in
insertion order), or a `set[T]`, and any object whose class defines `__iter__` returning a list. A tuple target unpacks pairs:

```nox
for i in range(2, 10, 3):          # 2 5 8   (a negative step counts down)
    print(i)
d: dict[str, int] = {"a": 1, "b": 2}
for k, v in d.items():
    print(k, v)
for i, x in enumerate(["p", "q"]):
    print(i, x)
for a, b in zip([1, 2], ["u", "v"]):
    print(a, b)
```

```output
2
5
8
a 1
b 2
0 p
1 q
1 u
2 v
```

`range(stop)`, `range(start, stop)` and `range(start, stop, step)` take `int`s; a zero step is an error. Modifying a list while iterating
over it is allowed but iterates over the live list; copy first (`for x in xs.copy():`) when you add or remove elements.

There is no `else` clause on loops.

### `break` and `continue`

`break` leaves the innermost `while`/`for`; `continue` jumps to its next iteration. Both are compile errors outside a loop (a nested
`def` is a new function and does not count). A `break` or `continue` that leaves a `try … finally`, a `with` or a `lowlevel` block runs
the `finally` body, the `__exit__` method or the arena teardown first, exactly as `return` does.

## `return`

`return expr` ends the function with a value of the declared return type; a function returning `None` may use a bare `return`. A
function with a non-`None` return type must return on every path. `return a, b` returns a tuple.

## `del`

`del xs[i]` removes a list element (`IndexError` when out of range, negative indexes allowed); `del d[k]` removes a dictionary entry
(`KeyError` when absent). Deleting from a dictionary is O(n).

```nox
xs: list[int] = [1, 2, 3, 4]
d: dict[str, int] = {"a": 1, "b": 2}
del xs[0]
del d["a"]
print(xs, d)
```

```output
[2, 3, 4] {'b': 2}
```

## `assert`

`assert cond` and `assert cond, "message"` raise `AssertionError` when `cond` is false. Assertions are always on — they are not removed in
optimised builds.

## `raise`, `try`, `with`, `defer`

See [Exceptions](exceptions.md).

## Definitions

`def`, `class`, `protocol` and `extern def` are statements; see [Functions](functions.md), [Classes](classes.md),
[Protocols and generics](protocols-generics.md) and [Foreign functions](ffi.md). `import` and `from … import` are covered in
[Modules](modules.md).

## Scoping

Nox has **function scope and module scope — not block scope**. A variable first assigned inside an `if`, `while` or `for` body is
visible in the rest of the enclosing function or module, and a loop variable stays defined after the loop (its value there is
unspecified — after a `range` loop it is one past the last element, not the last element as in Python — so do not rely on it):

```nox
for i in range(3):
    last: int = i
print(last)
```

```output
2
```

Rules for names:

- A name declared with an annotation inside a function is **local** to that function and may shadow a module-level name of the same
  name without affecting it.
- An un-annotated assignment to a name that is declared at module level (`total += 1`, `total = 5`) from inside a function assigns the
  **module-level variable**. There is no `global` keyword.
- Reading an undeclared name is a compile error ("undefined variable").
- Parameters are locals; assigning to a parameter changes only the local.
- A nested `def` can read the enclosing function's variables (closure); assigning to them from the nested function is not supported.

```nox
total: int = 0

def bump() -> None:
    total += 1          # module-level variable

def shadow() -> None:
    total: int = 100    # a new local; the module-level total is untouched
    print(total)

bump()
bump()
shadow()
print(total)
```

```output
100
2
```

## Module-level initialisation order

Top-level `name: T = expr` declarations are initialised **before** any other top-level statement runs, in source order, so a function
called from a later statement always sees initialised module variables. Cyclic dependencies between module-level initialisers are
not detected; keep initialisers simple.
