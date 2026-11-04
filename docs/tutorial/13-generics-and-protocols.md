# 13. Generics and protocols

Types are mandatory in Nox, which raises a fair question: how do you write a function once that works for `int`, `str` and your own classes? Nox gives you
two tools, and both are resolved at compile time — there is no `Any`, no boxing and no run-time cost. This chapter builds up both with small, useful
examples; the [language reference](../language/protocols-generics.md) has every detail.

## A function that works for any type

Put the type parameter in square brackets after the name, then use it like any other type. The compiler infers it from the call:

```nox
def last[T](xs: list[T]) -> T:
    return xs[len(xs) - 1]

def count_if[T](xs: list[T], keep: (T) -> bool) -> int:
    n: int = 0
    for x in xs:
        if keep(x):
            n += 1
    return n

print(last([10, 20, 30]), last(["a", "b"]))
print(count_if([1, 5, 8, 12], lambda v: v > 4))
print(count_if(["fig", "apple", "kiwi"], lambda w: len(w) == 4))
```

```output
30 b
3
1
```

`last` is compiled twice — once for `int`, once for `str` — each a plain direct function. Nothing is decided at run time.

## A container that works for any type

A class can take type parameters too. Here is a tiny stack, used with two different element types:

```nox
class Stack[T]:
    items: list[T]

    def __init__(self) -> None:
        self.items = []

    def push(self, item: T) -> None:
        self.items.append(item)

    def pop(self) -> T:
        return self.items.pop()

    def is_empty(self) -> bool:
        return len(self.items) == 0

def balanced(text: str) -> bool:
    open_stack: Stack[str] = Stack[str]()
    for ch in text:
        if ch == "(" or ch == "[":
            open_stack.push(ch)
        elif ch == ")" or ch == "]":
            if open_stack.is_empty():
                return False
            top: str = open_stack.pop()
            if (top == "(" and ch != ")") or (top == "[" and ch != "]"):
                return False
    return open_stack.is_empty()

numbers: Stack[int] = Stack[int]()
numbers.push(1)
numbers.push(2)
print(numbers.pop(), numbers.pop(), numbers.is_empty())
print(balanced("(a[b]c)"), balanced("(]"), balanced("(("))
```

```output
2 1 True
True False False
```

`Stack[int]` and `Stack[str]` are separate classes, each with its own compiled methods — and a `Stack[int]` can never receive a string, because the
compiler checks every call.

## Shape instead of ancestry: protocols

Generics say "any type, same code". A **protocol** says "any type with these methods". It is the Nox answer to Python's duck typing, but checked at compile
time: a class satisfies a protocol just by having the methods — it never has to say so.

```nox
protocol Scorer:
    def score(self, word: str) -> int:
        pass

class LengthScorer:
    def score(self, word: str) -> int:
        return len(word)

class VowelScorer:
    def score(self, word: str) -> int:
        n: int = 0
        for ch in word:
            if ch in "aeiou":
                n += 1
        return n

def best(words: list[str], scorer: Scorer) -> str:
    winner: str = words[0]
    for w in words:
        if scorer.score(w) > scorer.score(winner):
            winner = w
    return winner

words: list[str] = ["sky", "banana", "queue", "strengths"]
print(best(words, LengthScorer()))
print(best(words, VowelScorer()))
```

```output
strengths
queue
```

Neither scorer mentions `Scorer`. If you pass a class that lacks `score`, the compiler stops with a message naming the missing method.

## Different classes in one list

A protocol can also be the type of a variable, a field or a list element. That is how one list holds objects of *different* classes:

```nox
protocol Greeter:
    def greet(self) -> str:
        pass

class English:
    def greet(self) -> str:
        return "hello"

class Turkish:
    def greet(self) -> str:
        return "merhaba"

class Pirate:
    name: str

    def __init__(self, name: str) -> None:
        self.name = name

    def greet(self) -> str:
        return "ahoy, " + self.name

crowd: list[Greeter] = [English(), Turkish(), Pirate("Nox")]
for g in crowd:
    print(g.greet())
```

```output
hello
merhaba
ahoy, Nox
```

## Which one should I use?

| You want… | Use |
|---|---|
| the same algorithm over many element types | a generic function (`def f[T](...)`) |
| a container or wrapper parameterised by what it holds | a generic class (`class Box[T]`) |
| to accept "anything that can do X" as an argument | a protocol parameter (`scorer: Scorer`) |
| a list of unrelated classes that share behaviour | a list of protocol type (`list[Greeter]`), or a common base class if they are related |

The compiler picks the cheapest representation for you: a protocol *parameter* is compiled once per concrete class with direct calls, and only a value
*stored* as a protocol carries a small method table. You never write anything different.

Next: [14. Databases](14-databases.md).
