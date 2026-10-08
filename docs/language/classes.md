# Classes

A `class` declares a new reference type with fields and methods. Nox supports **single inheritance**, special ("dunder") methods
for operators and protocols, and structural [protocols](protocols-generics.md). There are no metaclasses, no multiple inheritance
and no dynamic attribute creation.

## Fields

A class's fields are fixed. They can be established two ways, and both may be used in the same class:

1. **Implicitly**, by the first `self.name = expr` assignment inside `__init__` (the type is inferred from the expression), or
2. **Explicitly**, with a bare `name: type` line in the class body (no initialiser — the assignment itself still happens in `__init__`).

If a field is declared explicitly it must actually be assigned in `__init__`; an unassigned declared field is a compile error, never a
zeroed value. Fields can only be *created* in `__init__`: assigning a new `self.name` from another method is a compile error. There
are no class-level attributes with initialisers (`LIMIT: int = 5` in a class body is a syntax error) — use a module-level constant.

```nox
class Account:
    """A bank account."""
    owner: str
    balance: int

    def __init__(self, owner: str, balance: int) -> None:
        self.owner = owner
        self.balance = balance

    def deposit(self, amount: int) -> None:
        self.balance += amount

    def describe(self) -> str:
        return self.owner + ": " + str(self.balance)

acct: Account = Account("ada", 100)
acct.deposit(50)
print(acct.describe())
```

```output
ada: 150
```

## `self`

`self` is the first parameter of every method. It may be written bare (`def deposit(self, amount: int)`) or explicitly typed
(`self: Account`) — they are equivalent; the compiler always infers the enclosing class. This is the single sanctioned exception to
"every parameter has a type".

## Construction and identity

`ClassName(args)` allocates an instance and runs `__init__`. A class without `__init__` takes no constructor arguments. Class values are **references**: `b: Account = acct` makes both names
refer to one object, so a change through either is visible through both. Memory is reclaimed automatically ([Memory](memory.md)).

```nox
class Cell:
    v: int
    def __init__(self, v: int) -> None:
        self.v = v

a: Cell = Cell(1)
b: Cell = a
b.v = 9
print(a.v, a == Cell(9), a == Cell(1))
```

```output
9 True False
```

Equality `==` is **structural** by default: two instances of the same class are equal when all their fields are equal (recursively).
Define `__eq__` to override.

## Inheritance

`class Dog(Animal):` declares a subclass. Subclasses inherit fields and methods and may override methods; calls dispatch dynamically
through a vtable. `super().method(...)` calls the base implementation (and `super().__init__(...)` chains constructors). A value of a
subclass can be used wherever the base class is expected, including inside `list[Base]`. `except Base:` also matches every subclass
([Exceptions](exceptions.md)).

```nox
class Animal:
    name: str
    def __init__(self, name: str) -> None:
        self.name = name
    def speak(self) -> str:
        return self.name + " makes a sound"
    def intro(self) -> str:
        return "this is " + self.speak()

class Dog(Animal):
    def __init__(self, name: str) -> None:
        super().__init__(name)
    def speak(self) -> str:
        return self.name + " barks"

class Puppy(Dog):
    def speak(self) -> str:
        return "tiny " + super().speak()

zoo: list[Animal] = [Animal("cat"), Dog("rex"), Puppy("bit")]
for a in zoo:
    print(a.intro())
```

```output
this is cat makes a sound
this is rex barks
this is tiny bit barks
```

There is no `isinstance` and no run-time type test; use a protocol, a virtual method, or an `except` clause for dispatch on type.

## Special methods

A class may define special methods; the compiler rewrites each operator into an ordinary method call, so ownership, inheritance and
both backends need no special support.

| Syntax | Method |
|---|---|
| `a + b`, `a - b`, `a * b`, `a / b`, `a // b`, `a % b`, `a ** b` | `__add__`, `__sub__`, `__mul__`, `__truediv__`, `__floordiv__`, `__mod__`, `__pow__` |
| `a & b`, `a \| b`, `a ^ b`, `a << b`, `a >> b` | `__and__`, `__or__`, `__xor__`, `__lshift__`, `__rshift__` |
| `2 * v` (left operand not a class) | `__rmul__` (likewise `__radd__`, `__rsub__`, …) |
| `a == b`, `a != b` | `__eq__`, `__ne__` (or `not __eq__`) |
| `a < b`, `a <= b`, `a > b`, `a >= b` | `__lt__`, `__le__`, `__gt__`, `__ge__` (a missing one falls back to the reflected method of the right operand) |
| `-a`, `~a` | `__neg__`, `__invert__` |
| `x in a`, `x not in a` | `__contains__` |
| `a[i]`, `a[i] = v` | `__getitem__`, `__setitem__` |
| `len(a)` | `__len__` |
| `str(a)`, `print(a)`, `f"{a}"` | `__str__` |
| `repr(a)`, and the elements of printed containers | `__repr__` (else `__str__`, else the structural form) |
| `bool(a)` | `__bool__`, else `__len__() != 0`, else `True` |
| `for x in a` | `__iter__` returning a `list[T]` |

Comparison methods must return `bool`, `__len__` an `int`, `__str__`/`__repr__` a `str`. `x += y` on a class value uses `__add__`; there
is no separate in-place protocol. Comparing against `None` is never overloaded. Operand evaluation order can differ from Python only for
reflected comparisons with side-effecting operands.

```nox
class Vec:
    x: int
    y: int
    def __init__(self, x: int, y: int) -> None:
        self.x = x
        self.y = y
    def __add__(self, o: Vec) -> Vec:
        return Vec(self.x + o.x, self.y + o.y)
    def __lt__(self, o: Vec) -> bool:
        return self.x < o.x
    def __neg__(self) -> Vec:
        return Vec(-self.x, -self.y)
    def __str__(self) -> str:
        return "Vec(" + str(self.x) + "," + str(self.y) + ")"
    def __len__(self) -> int:
        return 2
    def __getitem__(self, i: int) -> int:
        if i == 0:
            return self.x
        return self.y
    def __contains__(self, v: int) -> bool:
        return v == self.x or v == self.y

a: Vec = Vec(1, 2)
b: Vec = Vec(3, 4)
print(a + b, a < b, -a, len(a), a[1], 2 in a, [a, b])
```

```output
Vec(4,6) True Vec(-1,-2) 2 2 True [Vec(1,2), Vec(3,4)]
```

### Default printing

A class without `__str__`/`__repr__` prints structurally as `Name(field=value, ...)` — recursively and with Python-style quoting for strings
inside containers — so `print(obj)` is always useful for debugging:

```nox
class Item:
    name: str
    qty: int
    def __init__(self, name: str, qty: int) -> None:
        self.name = name
        self.qty = qty

print(Item("pen", 3), [Item("ink", 1)], repr(Item("x", 0)))
```

```output
Item(name='pen', qty=3) [Item(name='ink', qty=1)] Item(name='x', qty=0)
```

## Layout control for foreign code

`@repr("C")` lays fields out with natural C alignment and padding, `@packed` removes padding, and `sizeof(T)`, `alignof(T)` and
`offsetof(T, "field")` query layouts. They exist for [foreign-function interfaces](ffi.md); a class instance additionally carries a small
runtime header, which `offsetof` accounts for. Un-decorated classes have an unspecified internal layout.

## What classes do not have

Class-level attributes and constants, `@staticmethod`/`@classmethod`/`@property`, multiple inheritance, metaclasses, `__slots__`,
`__getattr__`/`__setattr__`, `isinstance`/`type`, and `__call__`. Attributes cannot be added to an instance at run time.
