# 5. Collections

## Lists

A `list[T]` holds elements of one type and grows as needed:

```nox
fruits: list[str] = ["apple", "banana"]
fruits.append("cherry")
fruits.insert(0, "avocado")
print(fruits, len(fruits), fruits[0], fruits[-1])
print(fruits[1:3], "banana" in fruits, fruits.index("cherry"))
fruits.remove("banana")
last: str = fruits.pop()
print(fruits, last)
```

```output
['avocado', 'apple', 'banana', 'cherry'] 4 avocado cherry
['apple', 'banana'] True 3
['avocado', 'apple'] cherry
```

Indexes may be negative; an index out of range raises `IndexError`. Lists support `+`, `*`, `sort()`, `reverse()`, `extend()`, `copy()` and `clear()`:

```nox
a: list[int] = [3, 1, 2]
a.sort()
b: list[int] = a + [10, 20]
print(a, b, a * 2, sorted(b, reverse=True))
```

```output
[1, 2, 3] [1, 2, 3, 10, 20] [1, 2, 3, 1, 2, 3] [20, 10, 3, 2, 1]
```

An empty list gets its type from the annotation: `names: list[str] = []`.

## Dictionaries

A `dict[K, V]` maps keys to values and remembers insertion order:

```nox
ages: dict[str, int] = {"ada": 36, "alan": 41}
ages["grace"] = 85
print(ages, len(ages), ages["ada"], "alan" in ages)
print(ages.get("bob", 0), ages.get("ada"))
for name in ages:
    print(name, ages[name])
for name, age in ages.items():
    print(name, "is", age)
del ages["alan"]
print(ages.keys(), ages.values())
```

```output
{'ada': 36, 'alan': 41, 'grace': 85} 3 36 True
0 36
ada 36
alan 41
grace 85
ada is 36
alan is 41
grace is 85
['ada', 'grace'] [36, 85]
```

`ages["missing"]` raises `KeyError`; `get` returns a default (or `None` when you give none). Keys are `int`, `float`, `bool` or `str`.

## Sets

```nox
a: set[int] = {1, 2, 3}
b: set[int] = {3, 4}
a.add(9)
print(a, 2 in a, len(a), a | b, a & b, a - b)
```

```output
{1, 2, 3, 9} True 4 {1, 2, 3, 9, 4} {3} {1, 2, 9}
```

Sets hold unique `int`, `float`, `bool` or `str` elements and keep insertion order.

## Tuples

A tuple is a fixed group of values that may have different types. It is how functions return several values:

```nox
point: tuple[int, int] = (3, 4)
x, y = point
person: tuple[str, int] = ("Ada", 36)
print(point, x + y, person[0], person[1], point == (3, 4))
```

```output
(3, 4) 7 Ada 36 True
```

## Comprehensions

Build collections from other collections in one expression:

```nox
squares: list[int] = [n * n for n in range(6)]
evens: list[int] = [n for n in range(10) if n % 2 == 0]
lengths: dict[str, int] = {w: len(w) for w in ["a", "bb", "ccc"]}
letters: set[str] = {c for c in "hello"}
pairs: list[int] = [a * b for a in [1, 2] for b in [3, 4]]
print(squares, evens, lengths, letters, pairs)
```

```output
[0, 1, 4, 9, 16, 25] [0, 2, 4, 6, 8] {'a': 1, 'bb': 2, 'ccc': 3} {'h', 'e', 'l', 'o'} [3, 4, 6, 8]
```

## Sorting and searching

```nox
words: list[str] = ["pear", "fig", "banana"]
print(sorted(words), sorted(words, key=lambda w: len(w)))
print(max(words, key=lambda w: len(w)), sum(len(w) for w in words))
for i, w in enumerate(words):
    print(i, w)
print(zip([1, 2], ["a", "b"]))
```

```output
['banana', 'fig', 'pear'] ['fig', 'pear', 'banana']
banana 13
0 pear
1 fig
2 banana
[(1, 'a'), (2, 'b')]
```

Collections are **reference values**: `b: list[int] = a` makes both names refer to the same list; use `a.copy()` or `list(a)` to duplicate it.
