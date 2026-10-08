# Expressions

## Operator precedence

From loosest to tightest binding (operators on one row bind equally):

| Level | Operators |
|---|---|
| 1 | `lambda` |
| 2 | `a if cond else b` (conditional expression; right-associative) |
| 3 | `or` |
| 4 | `and` |
| 5 | `not` |
| 6 | `==  !=  <  <=  >  >=  in  not in  is  is not` (chained, see below) |
| 7 | `\|` |
| 8 | `^` |
| 9 | `&` |
| 10 | `<<  >>` |
| 11 | `+  -` |
| 12 | `*  /  //  %` |
| 13 | unary `-  +  ~` |
| 14 | `**` (right-associative; binds tighter than a unary minus on its left) |
| 15 | subscription `x[i]`, slicing, call `f(x)`, attribute `x.name` |

```nox
print(-2 ** 2, 2 ** 3 ** 2, 1 + 2 << 3, 6 & 3 == 2, 2 + 3 * 4 - 1, 7 // 2 * 2, not 1 == 2)
```

```output
-4 512 24 True 13 6 True
```

## Boolean operators

`and`, `or` and `not` take and return `bool` and **short-circuit**. There is no implicit truthiness: `if x:` with an `int`, `str` or
`list` is a compile error; write the comparison, or use `bool(x)` / `len(x) > 0`.

## Comparisons

Comparison operators work on numbers (`int` and `float` mix), strings (code-point order), `bool` (equality only), lists, dictionaries,
tuples and classes (equality, structural: element-wise for lists/tuples/dictionaries, field-wise for classes unless `__eq__` is
defined). Comparisons **chain** like Python: `a < b < c` means `a < b and b < c`, and the middle operand is evaluated once and must
be free of side effects.

`x in c` and `x not in c` test membership: an element of a list, a key of a dict, a member of a set, a substring of a string.
`x is None`, `x is not None`, `x == None` and `x != None` test optionals and are never overloaded.

```nox
x: int | None = None
d: dict[str, int] = {"a": 1}
print(1 < 2 < 3, 1 < 3 < 2, 5 > 3 == 3)
print("a" in d, "b" not in d, 3 in [1, 2, 3], x is None, x is not None)
```

```output
True False True
True True True True False
```

## Conditional expressions

`a if cond else b` evaluates only the chosen branch. `cond` must be a `bool`; both branches must have the same type
(`1 if ok else 2.5` is rejected — convert explicitly). After an `x is not None` / `x is None` test the optional is narrowed in the
matching branch.

```nox
n: int = 15
label: str = "big" if n > 20 else "medium" if n > 10 else "small"
node_val: int | None = 7
print(label, node_val if node_val is not None else 0)
```

```output
medium 7
```

## Subscription and slicing

`x[i]` indexes a list, string, dictionary or tuple. List and string indexes may be negative; an out-of-range index raises
`IndexError`, a missing dictionary key raises `KeyError`. A tuple index must be a constant. `x[a:b]`, `x[:b]`, `x[a:]`, `x[:]`, `x[a:b:step]`
and `x[::-1]` produce a new list or string; bounds clamp, a zero step raises `ValueError`. Slices cannot be assigned to.

```nox
xs: list[int] = [1, 2, 3, 4, 5]
print(xs[1:3], xs[::2], xs[::-1], xs[-2:], xs[:-1], xs[10:])
t: tuple[int, str] = (1, "a")
print(t[0], t[-1])
```

```output
[2, 3] [1, 3, 5] [5, 4, 3, 2, 1] [4, 5] [1, 2, 3, 4] []
1 a
```

## Calls and attributes

`f(a, b, key=c)` calls a function, constructor or method ([Functions](functions.md)). `obj.name` reads a field, and `obj.method(...)` calls
a method. **Arguments are evaluated left to right, in the order written**; keyword arguments are bound by name afterwards, so
`f(b=g(), a=h())` calls `g` before `h`.

## Comprehensions

List, dictionary and set comprehensions build a collection from one or more `for` clauses with optional `if` filters. The loop
variable does not leak. The iterable may be a list, a `range(...)`, a `str` or a `dict`:

```nox
print([x * x for x in range(5) if x % 2 == 0])
print({k: len(k) for k in ["a", "bb"]})
print({c for c in "hello"})
print([a * b for a in [1, 2] for b in [3, 4] if a != b])
```

```output
[0, 4, 16]
{'a': 1, 'bb': 2}
{'h', 'e', 'l', 'o'}
[3, 4, 6, 8]
```

A comprehension's condition and iterable are `or`-level expressions; parenthesise a conditional expression there. Lambdas inside
comprehensions are not supported.

### Generator expressions

A generator expression such as `x * x for x in xs if x > 0` is accepted as the **sole argument of a call** (`sum(...)`, `"".join(...)`,
`any(...)`, `list(...)`). It is **evaluated eagerly** into a list — it is not a lazy generator, so it must not be used to model
infinite sequences, and side effects inside it happen before the call.

```nox
print(sum(x * x for x in [1, 2, 3] if x > 1), ", ".join(str(x) for x in [1, 2]))
```

```output
13 1, 2
```

## Lambdas

`lambda a, b: a * b` creates a function value. Parameter and return types come from the expected function type, so a lambda can be
passed to a function-typed parameter, assigned to an annotated variable, returned, or placed in a `list[(T) -> U]` literal.
Lambdas capture enclosing variables like nested `def`s (read-only). See [Functions](functions.md).

```nox
mul: (int, int) -> int = lambda p, q: p * q
print(mul(3, 4), sorted(["bb", "a", "ccc"], key=lambda s: len(s)))
```

```output
12 ['a', 'bb', 'ccc']
```

## Tuples and unpacking

`(1, "x")` and `1, "x"` build tuples; an assignment target may be a tuple pattern (`q, r = divmod(17, 5)`, `a, b = b, a`,
`self.x, self.y = p`). Tuples are compared and printed element-wise and can be returned from functions to return several values.

```nox
def split_pair(n: int) -> tuple[int, int]:
    return n // 10, n % 10

tens, ones = split_pair(47)
a: int = 1
b: int = 2
a, b = b, a
print(tens, ones, a, b)
```

```output
4 7 2 1
```

## Operator overloading

Classes may define special methods (`__add__`, `__eq__`, `__lt__`, `__getitem__`, `__len__`, `__str__`, `__bool__`, `__contains__`, …) that
give meaning to the operators; see [Classes](classes.md#special-methods).

## Assignment expressions

Nox has no walrus operator (`:=`); assign on a separate statement.
