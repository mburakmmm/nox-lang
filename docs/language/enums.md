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
- A pattern names the variant with its enum, `Shape.Circle`. The enum can be imported and qualified like any class: `shapes.Shape.Circle(r)`.
- **Binding.** Inside the parentheses each name receives that field's value, in declaration order, with the field's type. `_` ignores a field. Naming fields works too: `Shape.Rect(h=height, w=width)`. When a pattern has parentheses it must account for every field (use `_`); without parentheses (`Shape.Rect:`) the fields are ignored.
- `case _:` matches anything not matched above and must come last.
- Cases are tried top to bottom and the first one that fits runs. There is no fall-through, so no `break` is needed.

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

- Patterns are one level deep: `Variant(a, b)`. Nested patterns (`Shape.Circle(Point(x, y))`), literal patterns and `case x if cond:` guards are not supported; test conditions inside the case body.
- `match` bindings are not available inside generator functions (`yield`).
- A generic enum type cannot be named through a module prefix in an annotation (`m.Option[int]`, a limit of every generic class); import it with `from m import Option`.

## How it works

An enum is a class underneath, so every class rule applies (inheritance from an enum is not meant to be used). Each value stores a tag and the fields of its variant; the unused fields of other variants stay empty and are never read. A `match` is a chain of `if` tests on the tag, which is why it costs the same as writing the tests by hand.
