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

### Protocols and collections

Protocol types are parameter types: a `list[Shape]` holding instances of different concrete classes is **not** supported in 2.0. For a
genuinely heterogeneous collection, give the classes a common base class (single inheritance, virtual dispatch — see
[Classes](classes.md#inheritance)) and use `list[Base]` (annotate the list: a literal mixing subclasses has no common element type without the annotation):

```nox
class Shape2:
    def area(self) -> float:
        return 0.0

class Rect(Shape2):
    w: float
    h: float
    def __init__(self, w: float, h: float) -> None:
        self.w = w
        self.h = h
    def area(self) -> float:
        return self.w * self.h

class Disc(Shape2):
    r: float
    def __init__(self, r: float) -> None:
        self.r = r
    def area(self) -> float:
        return 3.0 * self.r * self.r

shapes: list[Shape2] = [Rect(2.0, 3.0), Disc(1.0)]
total: float = 0.0
for s in shapes:
    total += s.area()
print(total)
```

```output
9.0
```

## Choosing between them

| You want | Use |
|---|---|
| One algorithm over `int`, `str`, user types… with the same operations | a generic function (`[T]`) |
| A container parameterised by element type | a generic class |
| "Anything with these methods" for a function parameter | a protocol |
| A heterogeneous list with run-time dispatch | a base class and subclasses |
