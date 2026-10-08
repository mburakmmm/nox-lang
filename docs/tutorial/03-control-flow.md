# 3. Control flow

## `if`

```nox
temperature: int = 23
if temperature > 30:
    print("hot")
elif temperature > 15:
    print("pleasant")
else:
    print("cold")
```

```output
pleasant
```

Combine conditions with `and`, `or`, `not`; chained comparisons work as in Python:

```nox
x: int = 5
if 0 < x < 10 and not x == 7:
    print("in range")
label: str = "even" if x % 2 == 0 else "odd"
print(label)
```

```output
in range
odd
```

## `while`

```nox
n: int = 1
while n < 100:
    n = n * 3
print(n)
```

```output
243
```

## `for` and `range`

`range(stop)`, `range(start, stop)` and `range(start, stop, step)` produce integers:

```nox
for i in range(3):
    print(i)
for i in range(10, 0, -4):
    print(i)
```

```output
0
1
2
10
6
2
```

A `for` loop also walks the characters of a string, the elements of a list and the keys of a dictionary:

```nox
for ch in "héy":
    print(ch)
for word in ["red", "green"]:
    print(word.upper())
```

```output
h
é
y
RED
GREEN
```

## `break` and `continue`

```nox
numbers: list[int] = [4, -1, 7, 200, 3]
total: int = 0
for n in numbers:
    if n < 0:
        continue       # skip negatives
    if n > 100:
        break          # stop at the first big value
    total += n
print(total)
```

```output
11
```

## Variables live in the whole function

A variable created inside an `if` or a loop is visible after it, because Nox has function scope, not block scope:

```nox
for i in range(3):
    last: int = i * i
print(last)
```

```output
4
```

## A complete example: FizzBuzz

```nox
for n in range(1, 16):
    if n % 15 == 0:
        print("FizzBuzz")
    elif n % 3 == 0:
        print("Fizz")
    elif n % 5 == 0:
        print("Buzz")
    else:
        print(n)
```

```output
1
2
Fizz
4
Buzz
Fizz
7
8
Fizz
Buzz
11
Fizz
13
14
FizzBuzz
```
