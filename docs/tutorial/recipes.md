# Recipes

Short, complete answers to questions that come up all the time. Every program here compiles, and every output block is what it prints. They deliberately use
only a few lines of the standard library each, so you can paste one into the [Playground](/playground/) and change it.

## Count how often each word appears

```nox
text: str = "the quick brown fox jumps over the lazy dog the end"
counts: dict[str, int] = {}
for word in text.split(" "):
    if word in counts:
        counts[word] += 1
    else:
        counts[word] = 1

pairs: list[tuple[str, int]] = []
for word in counts:
    pairs.append((word, counts[word]))
ranked: list[tuple[str, int]] = sorted(pairs, key=lambda p: -p[1])
print(ranked[0])
print(len(counts), "distinct words")
```

```output
('the', 3)
9 distinct words
```

## Remove duplicates but keep the order

A `set` remembers what you have seen; the list keeps the order:

```nox
def unique(xs: list[int]) -> list[int]:
    seen: set[int] = set()
    out: list[int] = []
    for x in xs:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out

print(unique([3, 1, 3, 2, 1, 4, 2]))
```

```output
[3, 1, 2, 4]
```

## Group records by a key

```nox
class Sale:
    region: str
    amount: int

    def __init__(self, region: str, amount: int) -> None:
        self.region = region
        self.amount = amount

sales: list[Sale] = [Sale("north", 120), Sale("south", 80), Sale("north", 45), Sale("east", 60), Sale("south", 20)]
totals: dict[str, int] = {}
for s in sales:
    if s.region in totals:
        totals[s.region] += s.amount
    else:
        totals[s.region] = s.amount

for region in sorted(list(totals.keys())):
    print(region, totals[region])
```

```output
east 60
north 165
south 100
```

## Print a neat table

f-strings take the full format mini-language — width, alignment, precision:

```nox
rows: list[tuple[str, int, float]] = [("apples", 12, 0.5), ("watermelons", 3, 4.25), ("figs", 140, 0.125)]
print(f"{'item':<12}{'qty':>5}{'price':>8}")
for name, qty, price in rows:
    print(f"{name:<12}{qty:>5}{price:>8.2f}")
```

```output
item          qty   price
apples         12    0.50
watermelons     3    4.25
figs          140    0.12
```

(`0.125` prints as `0.12`: formatting rounds half to even, like Python.)

## Memoise an expensive function

A dictionary makes an exponential recursion linear:

```nox
memo: dict[int, int] = {}

def fib(n: int) -> int:
    if n < 2:
        return n
    if n in memo:
        return memo[n]
    value: int = fib(n - 1) + fib(n - 2)
    memo[n] = value
    return value

print(fib(50), fib(80))
```

```output
12586269025 23416728348467685
```

## Retry something that might fail

```nox
class Flaky(Exception):
    pass

def unreliable(attempt: int) -> str:
    if attempt < 3:
        raise Flaky("not yet")
    return "ok"

def call_with_retry(limit: int) -> str:
    for attempt in range(1, limit + 1):
        try:
            return "succeeded on try " + str(attempt) + ": " + unreliable(attempt)
        except Flaky as e:
            print("try", attempt, "failed:", e.message)
    return "gave up"

print(call_with_retry(5))
print(call_with_retry(2))
```

```output
try 1 failed: not yet
try 2 failed: not yet
succeeded on try 3: ok
try 1 failed: not yet
try 2 failed: not yet
gave up
```

## Time a piece of code

```nox
import nox.time

start: int = nox.time.now_ms()
total: int = 0
for i in range(2000000):
    total += i % 7
elapsed: int = nox.time.now_ms() - start
print("sum", total)
print("finished quickly:", elapsed < 1000)
```

```output
sum 5999995
finished quickly: True
```

Print the elapsed time itself when you are measuring — it is left out of the output above only because it differs from one machine to the next.

## Read a CSV-like text

For real CSV with quoting, use [`nox.csv`](../stdlib/csv.md); for simple comma-separated lines `split` is enough:

```nox
data: str = "name,age,city\nAda,36,London\nAlan,41,Wilmslow\nGrace,85,New York"
lines: list[str] = data.split("\n")
header: list[str] = lines[0].split(",")
print(header)

total_age: int = 0
for line in lines[1:]:
    cells: list[str] = line.split(",")
    total_age += int(cells[1])
    print(cells[0], "lives in", cells[2])
print("average age", total_age // (len(lines) - 1))
```

```output
['name', 'age', 'city']
Ada lives in London
Alan lives in Wilmslow
Grace lives in New York
average age 54
```

## A state machine with an enum-like class

```nox
class Light:
    state: str

    def __init__(self) -> None:
        self.state = "red"

    def next(self) -> None:
        if self.state == "red":
            self.state = "green"
        elif self.state == "green":
            self.state = "yellow"
        else:
            self.state = "red"

light: Light = Light()
for step in range(5):
    print(step, light.state)
    light.next()
```

```output
0 red
1 green
2 yellow
3 red
4 green
```

## Run many things at once

`spawn` starts a task and the work runs on whatever core is free. Tasks cannot be stored in a list, so collect the results through a channel — each worker
sends its answer, and the main task receives exactly as many as it started:

```nox
async def square_sum(n: int, results: Channel[int]) -> None:
    total: int = 0
    for i in range(n):
        total += i * i
    await results.send(total)

async def main_task() -> None:
    results: Channel[int] = Channel[int](3)
    for n in [10, 100, 1000]:
        spawn square_sum(n, results)
    sums: list[int] = []
    for k in range(3):
        sums.append(await results.recv())
    print(sorted(sums))

t: Task[None] = spawn main_task()
await t
```

```output
[285, 328350, 332833500]
```

Results arrive in whatever order the workers finish, which is why the program sorts them before printing.
