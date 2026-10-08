# 7. Errors

## Raising and catching

```nox
def parse_age(text: str) -> int:
    age: int = int(text)
    if age < 0:
        raise ValueError("age cannot be negative")
    return age

for text in ["42", "-5", "abc"]:
    try:
        print(parse_age(text))
    except ValueError as e:
        print("bad input:", text)
```

```output
42
bad input: -5
bad input: abc
```

`int("abc")` and the explicit `raise` both produce a `ValueError`, caught by one `except`. Built-in exceptions include `ValueError`, `IndexError`,
`KeyError` and `ZeroDivisionError`.

## Your own exceptions

```nox
class InsufficientFunds(Exception):
    needed: int

    def __init__(self, message: str, needed: int) -> None:
        super().__init__(message)
        self.needed = needed

def withdraw(balance: int, amount: int) -> int:
    if amount > balance:
        raise InsufficientFunds("not enough money", amount - balance)
    return balance - amount

try:
    print(withdraw(100, 30))
    print(withdraw(100, 130))
except InsufficientFunds as e:
    print(e.message, "- short by", e.needed)
```

```output
70
not enough money - short by 30
```

`except Base:` also catches subclasses, so catch the most specific class first. Every exception has `message` and `line` (the line of the `raise`).

## `finally`

A `finally` block always runs — after success, after a caught error, and when the function returns early:

```nox
def read_config(ok: bool) -> str:
    try:
        if not ok:
            raise ValueError("bad config")
        return "config loaded"
    finally:
        print("cleanup")

print(read_config(True))
try:
    read_config(False)
except ValueError as e:
    print("failed:", e.message)
```

```output
cleanup
config loaded
cleanup
failed: bad config
```

## `with`: guaranteed cleanup

Classes with `__enter__` and `__exit__` work with `with`, which runs `__exit__` however the block ends:

```nox
class Connection:
    name: str
    def __init__(self, name: str) -> None:
        self.name = name
    def __enter__(self) -> Connection:
        print("open", self.name)
        return self
    def __exit__(self) -> None:
        print("close", self.name)

with Connection("db") as conn:
    print("querying", conn.name)
```

```output
open db
querying db
close db
```

## `defer`

`defer` schedules a call for when the function exits, last-in first-out — handy for cleanup next to the code that needs it:

```nox
def cleanup(what: str) -> None:
    print("closing", what)

def process() -> None:
    defer cleanup("file")
    defer cleanup("socket")
    print("working")

process()
```

```output
working
closing socket
closing file
```

## When an error is not caught

An exception that nobody catches ends the program with exit status 1 and a message naming the exception class and the source line. Errors cost
nothing when they do not happen: Nox implements them as ordinary return values, not stack unwinding ([Exceptions](../language/exceptions.md)).
