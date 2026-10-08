# 6. Classes

## A first class

```nox
class Account:
    owner: str
    balance: int

    def __init__(self, owner: str, balance: int) -> None:
        self.owner = owner
        self.balance = balance

    def deposit(self, amount: int) -> None:
        self.balance += amount

    def describe(self) -> str:
        return self.owner + " has " + str(self.balance)

acct: Account = Account("Ada", 100)
acct.deposit(50)
print(acct.describe())
print(acct)
```

```output
Ada has 150
Account(owner='Ada', balance=150)
```

A class declares its fields (`owner: str`) and a constructor `__init__`. `self` does not need a type annotation. Printing an object shows its fields
unless you define `__str__`.

## Special methods

Define methods with the usual Python names to give operators meaning:

```nox
class Vec:
    x: int
    y: int

    def __init__(self, x: int, y: int) -> None:
        self.x = x
        self.y = y

    def __add__(self, other: Vec) -> Vec:
        return Vec(self.x + other.x, self.y + other.y)

    def __eq__(self, other: Vec) -> bool:
        return self.x == other.x and self.y == other.y

    def __str__(self) -> str:
        return "(" + str(self.x) + ", " + str(self.y) + ")"

a: Vec = Vec(1, 2)
b: Vec = Vec(3, 4)
print(a + b, a == b, a == Vec(1, 2), [a, b])
```

```output
(4, 6) False True [(1, 2), (3, 4)]
```

## Inheritance

```nox
class Animal:
    name: str

    def __init__(self, name: str) -> None:
        self.name = name

    def speak(self) -> str:
        return self.name + " makes a sound"

class Dog(Animal):
    def speak(self) -> str:
        return self.name + " barks"

class Cat(Animal):
    def speak(self) -> str:
        return self.name + " meows"

pets: list[Animal] = [Animal("generic"), Dog("Rex"), Cat("Tom")]
for pet in pets:
    print(pet.speak())
```

```output
generic makes a sound
Rex barks
Tom meows
```

A subclass may use a base-class value wherever the base class is expected; the right `speak` runs. Nox has single inheritance.

## Protocols: structural interfaces

A protocol lists the methods something must have. Any class with those methods fits — no declaration needed:

```nox
protocol Shape:
    def area(self) -> float:
        pass

class Square:
    side: float
    def __init__(self, side: float) -> None:
        self.side = side
    def area(self) -> float:
        return self.side * self.side

class Circle:
    radius: float
    def __init__(self, radius: float) -> None:
        self.radius = radius
    def area(self) -> float:
        return 3.14159 * self.radius * self.radius

def report(shape: Shape) -> None:
    print("area:", shape.area())

report(Square(2.0))
report(Circle(1.0))
```

```output
area: 4.0
area: 3.14159
```

## Generics

A function or class can work over any type, written with square brackets:

```nox
class Box[T]:
    item: T

    def __init__(self, item: T) -> None:
        self.item = item

    def get(self) -> T:
        return self.item

def first[T](xs: list[T]) -> T:
    return xs[0]

print(Box[int](5).get(), Box[str]("hi").get(), first([10, 20]), first(["a", "b"]))
```

```output
5 hi 10 a
```

Each use is compiled into a specialised version, so generic code is as fast as hand-written code.

## References, not copies

```nox
class Cell:
    value: int
    def __init__(self, value: int) -> None:
        self.value = value

a: Cell = Cell(1)
b: Cell = a
b.value = 99
print(a.value, a == Cell(99))
```

```output
99 True
```

Assigning an object copies the reference; both names now see the change. `==` compares fields unless you define `__eq__`. You never free
memory yourself — the compiler does it ([Memory](../language/memory.md)).
