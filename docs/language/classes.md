# Classes

A `class` declares a new reference type with fields and methods. Nox supports single inheritance plus [mixins](#several-bases-mixins), special ("dunder") methods
for operators and protocols, and structural [protocols](protocols-generics.md). There are no metaclasses and no dynamic attribute creation.

## Fields

A class's fields are fixed. They can be established three ways, and all may be used in the same class:

1. **Implicitly**, by the first `self.name = expr` assignment inside `__init__` (the type is inferred from the expression), or
2. **With an annotation**, `self.name: type = expr` inside `__init__`: the declared type is the field's type, so an empty `[]` or `{}` or a `None` needs no further hint (`self.items: list[int] = []`), or
3. **Explicitly**, with a bare `name: type` line in the class body (no initialiser — the assignment itself still happens in `__init__`).

If a field is declared explicitly it must actually be assigned in `__init__`; an unassigned declared field is a compile error, never a
zeroed value. Fields can only be *created* in `__init__`: assigning a new `self.name` from another method is a compile error. Values shared by
the whole class are [class attributes](#class-attributes-and-constants).

### Class attributes and constants

`NAME: type = literal` in a class body declares a **constant**: `int`, `float`, `bool` or `str`, with a literal value (a leading `-` is allowed). It is not a field and takes no space in an instance. Read it as `ClassName.NAME`, `self.NAME` or `obj.NAME`; the compiler replaces the read with the literal. Subclasses inherit them. The value cannot be an expression (`N: int = 1 + 2` is an error).

If the program **assigns** the name anywhere (`ClassName.NAME = value`, `ClassName.NAME += 1`, in a method, a function or another module), it is a
**mutable class attribute** instead: one storage shared by the class, its subclasses and every instance, held like a module-level variable, and
reads see the latest value. Names that are never assigned stay compile-time constants. Assign through the declaring class: `self.NAME = v` and
`Sub.NAME = v` are compile errors (instances and subclasses have no copy of a class attribute). Mixins share the attribute with the class that
declares it.

```nox
class Limits:
    MAX: int = 5
    RATE: float = 2
    count: int

    def __init__(self) -> None:
        self.count = 0

    def room(self) -> int:
        return Limits.MAX - self.count

print(Limits.MAX, Limits().room())
```

```output
5 5
```

```nox
class Counter:
    count: int = 0
    LIMIT: int = 3

    def __init__(self) -> None:
        Counter.count += 1

    @staticmethod
    def reset() -> None:
        Counter.count = 0

a: Counter = Counter()
b: Counter = Counter()
print(Counter.count, a.count, Counter.LIMIT)
Counter.reset()
print(b.count)
```

```output
2 2 3
0
```

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

### Several bases (mixins)

`class C(A, B, D):` is allowed. The **first** base is the real base class (vtable dispatch, `super()`, `except A:`). The others are
**mixins**: their methods, declared fields and constants are copied into `C` at compile time. Name resolution follows Python's order:
`C`'s own members, then `A` and its bases, then `B`, then `D`.

As in Python, a mixin's `__init__` runs only when you call it, and you call a base's method explicitly with `Base.method(self, ...)`.
The compiler turns `Mixin.method(self, args)` into a call of a private copy of that method, and `A.method(self, args)` on the real base
into `super().method(args)`. A mixin's `__init__` may create fields, so the mixin keeps its own state:

```nox
class Animal:
    def __init__(self, name: str) -> None:
        self.name: str = name

    def speak(self) -> str:
        return self.name + " makes a sound"

class Swimmer:
    def __init__(self, depth: int) -> None:
        self.depth = depth
        self.laps = 0

    def swim(self) -> str:
        self.laps += 1
        return "swims to " + str(self.depth) + ", lap " + str(self.laps)

class Duck(Animal, Swimmer):
    def __init__(self, name: str) -> None:
        super().__init__(name)
        Swimmer.__init__(self, 3)

    def speak(self) -> str:
        return self.name + " quacks, then " + Animal.speak(self)

d: Duck = Duck("Donald")
print(d.speak())
print(d.swim(), "|", d.swim(), d.laps)
```

```output
Donald quacks, then Donald makes a sound
swims to 3, lap 1 | swims to 3, lap 2 2
```

A mixin may instead declare its state as a class-level field (`depth: int`); then `C.__init__` must assign it. Limits: `super()` is an
error inside a mixin method (the method is copied into `C`); `except B:` does not match a `C` for a mixin `B` (there is no `isinstance`
either; use a [protocol](protocols-generics.md) to accept any class with the right methods); a value of type `C` cannot be passed where
the mixin type `B` is expected; generic classes cannot be mixins.

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
| `for x in a` | `__next__() -> T \| None` (lazy: one value per pull, `None` ends it) or `__iter__` returning a `list[T]` |

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

## Static methods, class methods and properties

`@staticmethod` is a function that lives in the class namespace: it takes no `self`, and is called as `Account.cap(x)` (or through an instance,
`acc.cap(x)`, as long as the receiver expression has no side effects). `@classmethod` takes `cls` as its first (un-annotated) parameter; inside the
body `cls(...)` constructs an instance and `cls.NAME` reads a class constant. `cls` is bound at compile time to the class the method is
called through, so `Sub.empty()` builds a `Sub`. `@property` turns a method into an attribute read (`acc.pretty`), and an `@name.setter` method
makes `acc.name = value` call it; a property without a setter is read-only.

```nox
class Account:
    LIMIT: int = 1000

    def __init__(self, balance: int) -> None:
        self.balance = balance

    @staticmethod
    def cap(x: int) -> int:
        if x > Account.LIMIT:
            return Account.LIMIT
        return x

    @classmethod
    def empty(cls) -> Account:
        return cls(0)

    @property
    def pretty(self) -> str:
        return "$" + str(self.balance)

    @property
    def amount(self) -> int:
        return self.balance

    @amount.setter
    def amount(self, v: int) -> None:
        self.balance = Account.cap(v)

acc: Account = Account.empty()
acc.amount = 5000
print(acc.pretty, Account.cap(12))
```

```output
$1000 12
```

These decorators cannot be combined with other decorators, are not available in generic classes, and a static/class method cannot be used as a
first-class value (`f = Account.cap`).

## What classes do not have

Per-instance or per-subclass copies of class attributes, full multiple inheritance (only mixins), metaclasses, `__slots__`,
`__getattr__`/`__setattr__`, `isinstance`/`type`, and `__call__`. Attributes cannot be added to an instance at run time.
