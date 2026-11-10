# Enums and `match`

An `enum` is a type whose value is exactly one of several **variants**, and a variant can carry data (a *tagged union*). `match` takes a value apart by variant. The compiler checks that every variant is handled.

```nox
enum Shape:
    Circle(radius: float)
    Rect(w: float, h: float)
    Empty

def area(s: Shape) -> float:
    match s:
        case Shape.Circle(r):
            return 3.14159 * r * r
        case Shape.Rect(w, h):
            return w * h
        case Shape.Empty:
            return 0.0

c: Shape = Shape.Circle(2.0)
print(area(c))
print(area(Shape.Rect(2.0, 3.0)))
print(area(Shape.Empty))
```

```output
12.56636
6.0
0.0
```

## Defining an enum

The body lists **variants**, one per line: `Name` (no data) or `Name(field: Type, ...)` (data). Methods go in the same body and may use `match self`. A docstring and `pass` are allowed.

```text
enum Token:
    Word(text: str)
    Pair(left: str, right: str)
    Item(node: Node, weight: int)
    End

    def is_end(self) -> bool:
        match self:
            case Token.End:
                return True
            case _:
                return False
```

Field types are ordinary types: numbers, `str`, lists, dictionaries, classes and other enums. An enum must have at least one variant.

## Creating values

A variant with data is built like a function call, `Shape.Circle(2.0)`. A variant without data is written without parentheses, `Shape.Empty`. Both can be used anywhere a value is expected: assigned, passed, stored in lists and dictionaries, returned.

Values compare with `==` (same variant and equal data). Enum values follow the usual memory rules, with no keywords to learn: they are released automatically.

## `match`

```text
match subject:
    case Enum.Variant(a, b):
        ...
    case Enum.Other:
        ...
    case _:
        ...
```

- The subject is evaluated once. It must be a value of an enum.
- A pattern names the variant with its enum, `Shape.Circle`. The enum can be imported and qualified like any class: `shapes.Shape.Circle(r)`; a generic enum is named the same way in an annotation (`o: shapes.Option[int]`).
- **Binding.** Inside the parentheses each name receives that field's value, in declaration order, with the field's type. `_` ignores a field. Naming fields works too: `Shape.Rect(h=height, w=width)`. When a pattern has parentheses it must account for every field (use `_`); without parentheses (`Shape.Rect:`) the fields are ignored.
- `case _:` matches anything not matched above and must come last.
- Cases are tried top to bottom and the first one that fits runs. There is no fall-through, so no `break` is needed.

### Nested patterns, literals and guards

A field can itself be matched with a pattern, a literal or a name:

```nox
enum Option[T]:
    Some(value: T)
    Nothing

enum Token:
    Word(text: str)
    Num(n: int)
    End

def deep(o: Option[Option[int]]) -> str:
    match o:
        case Option.Some(Option.Some(v)):
            return "some some " + str(v)
        case Option.Some(Option.Nothing):
            return "some nothing"
        case _:
            return "nothing"

def lit(t: Token) -> str:
    match t:
        case Token.Word("end"):
            return "the end word"
        case Token.Num(0):
            return "zero"
        case Token.Num(n) if n > 100:
            return "large"
        case Token.Num(n):
            return "num " + str(n)
        case _:
            return "other"

a: Option[Option[int]] = Option.Some(Option.Some(4))
print(deep(a), lit(Token.Word("end")), lit(Token.Num(0)), lit(Token.Num(500)), lit(Token.Num(7)), lit(Token.End))
```

```output
some some 4 the end word zero large num 7 other
```

- **Nested pattern.** `Option.Some(Option.Some(v))` matches when the outer variant matches and the inner value matches its pattern.
- **Literal.** An `int`, `float`, `str` or `bool` literal (including `-1`) matches a field that equals it.
- **Guard.** `case P if condition:` runs only when the pattern matches *and* the condition is true; otherwise the next case is tried. The condition can use the names the pattern binds.
- **Exhaustiveness.** A case with a literal, a nested pattern or a guard does not count as covering its variant, because it can fail. Finish such a `match` with `case _:` (or a plain case for the variant).

### Exhaustiveness

Without a `case _:`, every variant has to appear in some case, otherwise the program does not compile:

```text
type error (TypeMismatch): line 7: non-exhaustive match on enum 'E': missing variant(s) C (add the missing case(s) or a `case _:`)
```

Because the compiler proves every variant is handled, a function whose cases all `return` needs no `return` after the `match`.

### Other compile-time checks

- the subject's type and the pattern's enum must be the same enum;
- the variant must exist, and a positional pattern must bind as many names as the variant has fields.

## Generic enums

An enum can have type parameters, like a generic class. `Option` and `Result` need no library: they are ordinary enums.

```nox
enum Option[T]:
    Some(value: T)
    Nothing

    def unwrap_or(self, default: T) -> T:
        match self:
            case Option.Some(v):
                return v
            case Option.Nothing:
                return default

enum Result[T, E]:
    Ok(value: T)
    Err(error: E)

def first[T](xs: list[T]) -> Option[T]:
    if len(xs) == 0:
        return Option.Nothing
    return Option.Some(xs[0])

def divide(a: int, b: int) -> Result[int, str]:
    if b == 0:
        return Result.Err("division by zero")
    return Result.Ok(a // b)

x: Option[int] = Option.Some(5)
y: Option[int] = Option.Nothing
print(x.unwrap_or(0), y.unwrap_or(7))
nums: list[int] = [4, 5]
print(first(nums).unwrap_or(-1))
r: Result[int, str] = divide(1, 0)
match r:
    case Result.Ok(v):
        print("ok", v)
    case Result.Err(e):
        print("error", e)
```

```output
5 7
4
error division by zero
```

The type arguments come from the arguments of the variant (`Option.Some(5)` is an `Option[int]`) or, when the variant carries nothing that determines them, from the type the value is going to: the annotation of a variable, a parameter, a return type. `print(Option.Nothing)` has no such context and is rejected with a message that says so.

## Limits

- A guard can use names, literals, operators, calls, attributes and indexing; lambdas, comprehensions and dictionary literals are not supported inside a guard (compute them in the body).
- `match` bindings are not available inside generator functions (`yield`).

## How it works

An enum is a class underneath, so every class rule applies (inheritance from an enum is not meant to be used). Each value stores a tag and the fields of its variant; the unused fields of other variants stay empty and are never read. A `match` is a chain of `if` tests on the tag, which is why it costs the same as writing the tests by hand.
