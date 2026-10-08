# 4. Functions

## Defining and calling

```nox
def area(width: int, height: int) -> int:
    return width * height

def greet(name: str) -> None:
    print("Hello,", name)

greet("Ada")
print(area(3, 4))
```

```output
Hello, Ada
12
```

Parameters and the return value are typed; `-> None` means the function returns nothing. A function that promises a value must return one on
every path through its body — the compiler checks this.

## Default values and keyword arguments

```nox
def connect(host: str, port: int = 8080, secure: bool = False) -> str:
    scheme: str = "https" if secure else "http"
    return scheme + "://" + host + ":" + str(port)

print(connect("example.com"))
print(connect("example.com", secure=True))
print(connect(port=9000, host="localhost"))
```

```output
http://example.com:8080
https://example.com:8080
http://localhost:9000
```

Defaults are constant literals and come last. Arguments are evaluated in the order you write them.

## Returning several values

```nox
def divide(a: int, b: int) -> tuple[int, int]:
    return a // b, a % b

q, r = divide(17, 5)
print(q, r)
```

```output
3 2
```

## Functions are values

A function has a type such as `(int) -> int`, and can be stored, passed and returned:

```nox
def double(n: int) -> int:
    return n * 2

def apply_twice(f: (int) -> int, x: int) -> int:
    return f(f(x))

print(apply_twice(double, 5))
print(apply_twice(lambda n: n + 3, 5))
```

```output
20
11
```

A **lambda** takes its types from where it is used — here the parameter type `(int) -> int`.

## Closures

A nested function can read the variables around it, and stays valid after the outer function returns:

```nox
def make_counter_step(step: int) -> (int) -> int:
    def advance(current: int) -> int:
        return current + step
    return advance

by_five: (int) -> int = make_counter_step(5)
print(by_five(10), by_five(by_five(0)))
```

```output
15 10
```

## Recursion

```nox
def factorial(n: int) -> int:
    if n <= 1:
        return 1
    return n * factorial(n - 1)

print(factorial(10), factorial(20))
```

```output
3628800 2432902008176640000
```

`int` is 64-bit: `factorial(21)` would overflow and wrap. The `nox.mathx` module and fixed-width types give other options when that matters.

## Built-ins you will use constantly

`len`, `sum`, `min`, `max`, `sorted`, `abs`, `round`, `range`, `enumerate`, `zip` — see [Built-in functions](../language/builtins.md).

```nox
scores: list[int] = [72, 95, 88]
print(len(scores), sum(scores), min(scores), max(scores), sorted(scores))
print(round(sum(scores) / len(scores), 1))
```

```output
3 255 72 95 [72, 88, 95]
85.0
```
