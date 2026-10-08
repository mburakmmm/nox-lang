# Functions

## Defining functions

```nox
def area(width: int, height: int) -> int:
    return width * height

def greet(name: str) -> None:
    print("hello", name)

greet("nox")
print(area(3, 4))
```

```output
hello nox
12
```

Every parameter has a type and every function has a return type (`-> None` for procedures). The one exception is `self` in a method
([Classes](classes.md)). A function must return a value of its declared type on **every path**; the compiler reports
"does not return a value on all paths" otherwise. Function names are unique within a module (defining the same name twice is an
error), and a top-level function may not be called `main`.

Functions can be defined at module level, inside other functions (nested functions) and inside classes (methods).

## Default parameter values

A parameter may have a default. The default must be a **constant literal** — an `int`, `float`, `bool`, `str`, a negative number, or
`None` for an optional parameter — and parameters with defaults come last:

```nox
def connect(host: str, port: int = 8080, label: str | None = None) -> str:
    name: str = "-"
    if label is not None:
        name = label
    return host + ":" + str(port) + " " + name

print(connect("localhost"))
print(connect("example.com", 443, "prod"))
```

```output
localhost:8080 -
example.com:443 prod
```

## Keyword arguments

A call may name arguments: `f(1, b=3)`, `f(b=3, a=1)`. Positional arguments come first. An unknown name, a repeated parameter or
a missing required argument is a compile error. Keyword arguments work for functions, constructors, methods (including
`super().__init__`), generic functions and `spawn f(...)`. Function-typed *values* and built-ins take positional arguments only.

**Evaluation order.** Arguments are evaluated **in the order written**, left to right; binding to parameters happens afterwards by
name. So `f(b=g(), a=h())` calls `g` before `h`. (The one exception: in a `spawn` call, keyword arguments with side effects must be
written in parameter order.)

```nox
def trace(s: str) -> str:
    print("eval", s)
    return s

def join(x: str, y: str) -> str:
    return x + y

print(join(y=trace("y"), x=trace("x")))
```

```output
eval y
eval x
xy
```

There is no `*args`/`**kwargs` and no keyword-only or positional-only parameter marker in 2.0.

## Functions are values

A function name used as a value has a function type `(P1, P2) -> R`. Functions can be assigned, stored in lists and dictionaries,
passed as arguments and returned:

```nox
def double(n: int) -> int:
    return n * 2

def triple(n: int) -> int:
    return n * 3

def apply(f: (int) -> int, x: int) -> int:
    return f(x)

ops: list[(int) -> int] = [double, triple]
for op in ops:
    print(apply(op, 7))
print(ops[1](4))
```

```output
14
21
12
```

### Closures

A nested function or lambda may **read** variables of the enclosing function. The captured variables stay alive as long as the closure
does. Assigning to a captured variable from the nested function is a compile error — return a new value or use a one-field object
if shared mutation is needed.

```nox
def make_adder(k: int) -> (int) -> int:
    def add(x: int) -> int:
        return x + k
    return add

add5: (int) -> int = make_adder(5)
fs: list[(int) -> int] = [make_adder(1), make_adder(2), lambda z: z * 10]
for f in fs:
    print(f(3))
print(add5(1))
```

```output
4
5
30
6
```

### Bound methods

`obj.method` used as a value is a function bound to `obj`:

```nox
class Counter:
    n: int
    def __init__(self, n: int) -> None:
        self.n = n
    def add(self, k: int) -> int:
        return self.n + k

c: Counter = Counter(10)
g: (int) -> int = c.add
print(g(5))
```

```output
15
```

### Lambdas

`lambda a, b: expr` creates an anonymous function whose parameter and return types are inferred from the **expected function type**:
a lambda must appear where that type is known — an argument of a function-typed parameter, an annotated declaration, a return
value, or a function-list literal. Assigning a lambda to an un-annotated name is an error because there is nothing to infer from.

```nox
def compose(f: (int) -> int, g: (int) -> int) -> (int) -> int:
    return lambda x: g(f(x))

inc_then_double: (int) -> int = compose(lambda x: x + 1, lambda x: x * 2)
print(inc_then_double(4))
```

```output
10
```

## Recursion

Functions may call themselves and each other. The main thread runs on the operating-system stack, so very deep recursion works (a
200 000-level recursion is fine). Code running in a [fiber](concurrency.md) (a `spawn`ed task) has a smaller fixed stack, large
enough for roughly two thousand frames of an average function; deeply recursive algorithms should run on the main program or use
an explicit work list. The compiler may turn tail calls into loops, but you must not rely on it.

```nox
def depth(n: int) -> int:
    if n == 0:
        return 0
    return 1 + depth(n - 1)

print(depth(10000))
```

```output
10000
```

## Generic functions

`def first[T](xs: list[T]) -> T` is generic over `T`, specialised at compile time; see
[Protocols and generics](protocols-generics.md).

## Decorators

`@name` and `@name("arg")` before a top-level function attach **metadata** that tools can query with `nox.reflect`; they do not wrap the
function. See [Decorators and reflection](decorators.md).

## Async functions

`async def` defines a function that may be started with `spawn` and awaited; see [Concurrency](concurrency.md).

## Calling conventions at a glance

| Form | Meaning |
|---|---|
| `f(1, 2)` | positional |
| `f(1, b=2)` | positional then keyword |
| `obj.m(1)` | method call, `self` implicit |
| `Class(1)` | constructor call (`__init__`) |
| `f[int](x)`, `obj.m[int](x)` | explicit type argument to a generic function/method |
| `spawn f(1)` | start `f` as a task, yields `Task[T]` |
