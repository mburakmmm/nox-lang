# Protocols and generics

Nox has two complementary mechanisms for writing code that works over many types. Both are resolved **at compile time** by
monomorphisation — the compiler generates a specialised, dispatch-free copy of the code for every concrete type it is used with. There
is no boxing, no type erasure and no run-time cost.

## Generic functions

A function becomes generic by listing type parameters in square brackets after its name. The type arguments are inferred from the call:

```nox
def first[T](xs: list[T]) -> T:
    return xs[0]

def pair[A, B](a: A, b: B) -> tuple[A, B]:
    return a, b

print(first([1, 2, 3]), first(["a", "b"]), pair(1, "z"))
```

```output
1 a (1, 'z')
```

Type parameters can be inferred from function-typed arguments too — from the lambda body when the other arguments do not determine
them. A type argument can also be given explicitly with `f[int](x)`. A generic function is instantiated only for the types it is
actually called with; an unused generic function costs nothing.

```nox
def map_list[T, U](xs: list[T], f: (T) -> U) -> list[U]:
    out: list[U] = []
    for x in xs:
        out.append(f(x))
    return out

print(map_list([1, 2, 3], lambda v: str(v) + "!"))
```

```output
['1!', '2!', '3!']
```

## Generic classes

A class may declare type parameters; every use names the concrete types:

```nox
class Box[T]:
    item: T

    def __init__(self, item: T) -> None:
        self.item = item

    def get(self) -> T:
        return self.item

class Pair[A, B]:
    a: A
    b: B

    def __init__(self, a: A, b: B) -> None:
        self.a = a
        self.b = b

b: Box[int] = Box[int](5)
s: Box[str] = Box[str]("x")
p: Pair[int, str] = Pair[int, str](1, "u")
print(b.get(), s.get(), p.a, p.b)
```

```output
5 x 1 u
```

Each distinct instantiation (`Box[int]`, `Box[str]`) is a separate compiled class. The built-in generic types `Task[T]`, `Channel[T]`,
`ThreadHandle[T]`, `ThreadChannel[T]` and `ptr[T]` follow the same syntax.

## Generic methods

A method of a **non-generic** class can be generic. Call it with an explicit type argument or let it be inferred:

```nox
class Picker:
    def pick[T](self, a: T, b: T) -> T:
        return a

k: Picker = Picker()
print(k.pick[int](1, 2), k.pick("x", "y"))
```

```output
1 x
```

Current limits: a generic method on a **generic** class (`Box[T].map_to[U]`) is not supported — write a free generic function that
takes the box instead.

## Protocols

A protocol describes the *shape* a type must have; any class with matching methods satisfies it. No declaration of intent
(`implements`) is needed — the match is structural. Every method of a protocol has the body `pass`: protocols declare shape, never
behaviour.

```nox
protocol Shape:
    def area(self) -> float:
        pass

class Square:
    s: float
    def __init__(self, s: float) -> None:
        self.s = s
    def area(self) -> float:
        return self.s * self.s

class Circle:
    r: float
    def __init__(self, r: float) -> None:
        self.r = r
    def area(self) -> float:
        return 3.0 * self.r * self.r

def describe(shape: Shape) -> None:
    print(shape.area())

describe(Square(2.0))
describe(Circle(1.0))
```

```output
4.0
3.0
```

A function with a protocol-typed parameter is compiled once **per concrete type** that is passed to it (monomorphisation) — `describe`
above becomes two direct, non-virtual functions. Passing a class that lacks a required method is a compile error naming the missing
method:

```text
'B' class does not satisfy protocol 'Named': method 'name' missing
```

### Protocols as value types

A protocol can also be the type of a variable, a field, a function result or a collection element. This is how a `list[Shape]` holds instances of **different** classes:

```nox
protocol Shape:
    def area(self) -> float:
        pass
    def name(self) -> str:
        pass

class Square:
    s: float
    def __init__(self, s: float) -> None:
        self.s = s
    def area(self) -> float:
        return self.s * self.s
    def name(self) -> str:
        return "square"

class Circle:
    r: float
    def __init__(self, r: float) -> None:
        self.r = r
    def area(self) -> float:
        return 3.0 * self.r * self.r
    def name(self) -> str:
        return "circle"

def describe(shape: Shape) -> None:
    print(shape.name())

shapes: list[Shape] = [Square(2.0), Circle(1.0)]
sq: Square = Square(3.0)
shapes.append(sq)
total: float = 0.0
for s in shapes:
    total += s.area()
    describe(s)
print(total)
```

```output
square
circle
square
16.0
```

Nothing changes in the syntax: you write the protocol name where a type goes and assign any class that has the right methods. The compiler picks the representation:

- A parameter of protocol type (`def describe(shape: Shape)`) is still compiled once per concrete type, with direct calls (monomorphisation). `describe(Circle(5.0))` costs the same as before.
- A value that is *stored* as a protocol (a list element, a field, a variable, a function result) holds the object together with a table of its protocol methods. Calls through it are dynamic, like calls on a base class. The object is shared, not copied: a change made through `sq` is visible through `shapes[2]`.

The conversion happens where a value flows into a protocol-typed place: assignments, list literals, `append`/`insert`, call arguments, `return`. A class that lacks a method is a compile error at that point. A protocol whose methods mention another protocol in their signatures cannot be used as a value type (parameters of such a protocol still work).

If you prefer an explicit hierarchy, a common base class gives the same result: see [Classes](classes.md#inheritance).

## Choosing between them

| You want | Use |
|---|---|
| One algorithm over `int`, `str`, user types… with the same operations | a generic function (`[T]`) |
| A container parameterised by element type | a generic class |
| "Anything with these methods" for a function parameter | a protocol |
| A heterogeneous list with run-time dispatch | a protocol (`list[Shape]`), or a base class and subclasses |
