# The Nox Language — English Reference

*This is a fresh, English-language reference to the Nox language itself
(syntax, type system, memory model) — not a translation of
[`nox-teknik-spesifikasyon.md`](../nox-teknik-spesifikasyon.md), which is
Nox's Turkish-language design history and engineering log, written phase
by phase as the compiler was built. That document remains the
authoritative source for *why* any given decision was made and is kept
up to date; this one exists so English-only readers have a current
picture of *what the language looks like today* without wading through
thousands of lines of phase history. If the two ever disagree, the
Turkish spec is authoritative — file an issue.*

## Overview

Nox combines Python's syntactic familiarity with the performance and
determinism of a systems language. It is fully **ahead-of-time
compiled**: there is no interpreter and no garbage collector. Source
compiles to [QBE](https://c9x.me/compile/) IR, which QBE lowers to native
machine code; a small runtime written in Zig handles memory management,
error propagation, and the C/WASM bridge.

Where Nox differs from Python:

- **Static typing is mandatory**, not optional. Every parameter, variable,
  and return value must have a type annotation (with one narrow,
  intentional exception — see [`self`](#self-and-classes) below). There
  is no implicit fallback to a dynamic/`Any` type anywhere in the
  language.
- **Single inheritance only, no metaclasses.** `class Dog(Animal):` is
  supported (methods dispatch through a vtable, `super()` works, and
  `except Base:` matches subclasses), but there is no multiple
  inheritance. Structural polymorphism is also available through
  [protocols](#protocols).
- **No garbage collector.** Memory is managed by a layered, mostly
  invisible model — see [Memory Model](#memory-model).

## Basic Syntax

Nox follows Python's grammar closely: indentation-based blocks,
`def`/`class`/`if`/`elif`/`else`/`while`/`for`/`return`/`pass`, `#`
comments, `and`/`or`/`not`, and the usual arithmetic/comparison
operators.

```nox
def area(width: int, height: int) -> int:
    return width * height

x: int = 5
if x > 0:
    print("positive")
elif x == 0:
    print("zero")
else:
    print("negative")

i: int = 0
while i < 3:
    print(i)
    i = i + 1

numbers: list[int] = [1, 2, 3]
for n in numbers:
    print(n)
```

`for` iterates a `range(...)`, any `list[T]` expression, a `str` (one `str` per
character) or a `dict` (its keys, in insertion order):

```nox
for i in range(5):            # 0 1 2 3 4
for i in range(2, 10, 3):     # 2 5 8   (a negative step counts down)
for ch in "héllo":            # one character at a time
for key in table:             # dict keys
for item in make_items():     # any list expression
```

`range(stop)`, `range(start, stop)` and `range(start, stop, step)` take `int`s; a step
of zero is an error. A name declared in a scope keeps its type there: re-declaring
`x` with a different type (or reusing a loop variable name for loops over different
element types) is a compile error.

`break` leaves the innermost `while`/`for` loop and `continue` jumps to its
next iteration (in a `while` loop that is the condition check; in a `for`
loop it is the next element). Both are compile errors outside a loop — a
nested `def` inside a loop is a new function and does not count. A `break`
or `continue` that leaves a `try ... finally`, a `with`, or a `lowlevel`
block runs the `finally` body / `__exit__` / arena teardown first, exactly
like `return` does.

```nox
total: int = 0
for n in numbers:
    if n < 0:
        continue      # skip negatives
    if n > 100:
        break         # stop at the first big value
    total = total + n
```

`in` / `not in` test membership: `x in xs` (element equality, same rules as `==`),
`key in d` (dict key) and `needle in text` (substring; the empty string is in every
string). The left operand must match the list's element type, the dict's key type, or be a
`str`. They bind like the other comparison operators, so `not x in xs` means
`not (x in xs)`.

```nox
if 3 in numbers and "ab" in word:
    print("found")
if key not in table:
    table[key] = 0
```

A conditional expression `a if cond else b` evaluates only the chosen branch. The
condition must be a `bool`; both branches must have the same type (`int`, `float`,
`bool`, `str`, `list`, `dict` or a class), so `1 if ok else 2.5` is rejected —
convert one branch explicitly. It binds more loosely than every operator and is
right-associative, so `"A" if n > 20 else "B" if n > 10 else "C"` works without
parentheses. After a `x != None` / `x == None` test the optional `x` is narrowed in
the matching branch: `node.val if node != None else 0`.

```nox
label: str = "big" if n > 10 else "small"
```


**Default parameter values and keyword arguments.** A parameter may have a default,
`def f(a: int, b: int = 2)`; it must be a constant literal (`int`, `float`, `bool`, `str`, a
negative number, or `None` for an optional parameter), and parameters with defaults come last.
Call sites may name arguments: `f(1, b=3)`, `f(b=3, a=1)`; positional arguments come first,
and an unknown name, a repeated parameter or a missing required argument is a compile error.
This works for functions, constructors, methods (including `super().__init__`), generic
functions and `spawn f(...)`; function-typed values and built-ins take positional arguments only.
Arguments are evaluated in parameter order, not in the order written.

```nox
def connect(host: str, port: int = 8080, tls: bool = False) -> str:
    return host + ":" + str(port)

connect("localhost")
connect("example.com", tls=True)
```

**Lambda:** `lambda a, b: a * b` — parameter and return types come from the expected function type, so a lambda can be passed
to a function-typed parameter, assigned to an annotated variable, returned, or placed in a `list[(T) -> U]` literal. Lambdas capture
variables like nested `def`s (read-only); inside comprehensions they are not supported.

**Comprehensions:** `[x * x for x in xs if x > 0]`, `{k: len(k) for k in names}`, multiple `for`/`if` clauses
(`[a * b for a in A for b in B if a != b]`), over lists, `range(...)`, `str` and `dict`. The loop variable does not leak.
The condition and the iterable are `or`-level expressions (use parentheses for a conditional expression there).

**Slicing:** `xs[a:b]`, `xs[:b]`, `xs[a:]`, `xs[:]`, `xs[a:b:step]`, `xs[::-1]` on `list[T]` (a new list) and `str`
(by code point). Bounds clamp and negative indexes count from the end like Python; a zero step raises `ValueError`
(a literal zero is a compile error). Slices are values: assigning to one is not supported. Strings also compare with
`<`, `<=`, `>`, `>=` (code point order) and repeat with `s * n` / `n * s`.

**Dictionaries** (`dict[K, V]`, keys `int`/`float`/`bool`/`str`, values `int`/`float`/`bool`/`str`/class/`list[T]`/`dict`; `groups[k].append(v)` works on list values) keep
insertion order: `d[k]`, `d[k] = v`, `k in d`, `len(d)`, `d.keys()`, `d.values()`, `for k in d`,
`d.get(k, default)` (the default is only evaluated when the key is missing), `d.get(k)` (a
`V | None`), `d.pop(k)` (raises `KeyError`), `d.pop(k, default)`, `d.setdefault(k, default)`,
`d.update(other)`, `d.copy()`, `d.clear()` and the `del d[k]` statement (raises `KeyError`).
Deleting is O(n).

**Lists** (`list[T]`) have the full Python-style API: `xs.append(v)`, `xs.extend(ys)`,
`xs.insert(i, v)` (negative/oversized `i` clamps like Python), `xs.pop()`, `xs.pop(i)`,
`xs.remove(v)`, `del xs[i]`, `xs.clear()`, `xs.index(v)`, `xs.count(v)`, `xs.reverse()`,
`xs.sort()`, `xs.copy()` (a shallow copy), `xs + ys`, `xs * n` / `n * xs` (`n <= 0` gives an empty
list), `sorted(xs)` and `reversed(xs)` (both return a **new list**, `reversed` is not a lazy
iterator). `remove`/`index` raise `ValueError` when the value is missing; `pop(i)`/`del xs[i]` raise
`IndexError` when `i` is out of range or negative (negative indexing is deliberately not
supported, except that `insert` clamps like Python). Element equality is `==` (structural for
classes and nested lists). `append`/`insert`/`extend` need a variable or `name.field` receiver
(the list may be reallocated), the other methods accept any expression. `xs.extend(xs)` is safe.

**Variable declarations require an explicit type on first assignment**
(`x: int = 5`); subsequent assignments to the same name don't repeat the
annotation (`x = 6`).

**Types:** `int`, `float`, `bool`, `str`, `None`, `list[T]`,
`dict[K, V]`, user-defined `class` names, first-class function types
(`(int, int) -> int`), and generic user types (`Task[T]`, `Channel[T]`).
Mixed `int`/`float` arithmetic promotes to `float`; the only other
implicit conversion is `int → float` on assignment. `float(x)` converts explicitly from
`int`, `bool`, fixed-width integers or `str` (the `str` form raises `ValueError` on bad input).

**Deliberately not supported** (each one considered and explicitly
deferred, not overlooked): multiple return values via tuple unpacking,
`*args`/`**kwargs`, multiple inheritance, metaclasses, and dynamic
attribute manipulation (`setattr`, `exec`, runtime class generation).
(f-strings, augmented assignment on variables, single inheritance and
metadata-only decorators — see `nox.reflect` — are supported.)

## `self` and Classes

```nox
class Counter:
    value: int          # optional explicit field declaration (see below)

    def __init__(self, start: int) -> None:
        self.value = start

    def increment(self) -> None:
        self.value = self.value + 1

c: Counter = Counter(0)
c.increment()
print(c.value)
```

- **`self` may be written bare** (`def increment(self):`) or explicitly
  typed (`def increment(self: Counter):`) — both are equivalent; the
  compiler infers `self`'s type as the enclosing class either way. This
  is the one sanctioned exception to "every parameter needs an explicit
  type" (see `AGENTS.md` §5 and spec §3.63 for why).
- **Class fields** can be established two ways, and both can be used in
  the same class: (1) implicitly, by the first `self.<name> = <expr>`
  assignment inside `__init__` (the type is inferred from the assigned
  expression), or (2) explicitly, with a bare `<name>: <type>` line
  directly in the class body (PEP 526-style — no initializer; the actual
  assignment still happens in `__init__`). If a field is explicitly
  declared, the compiler requires it to actually be assigned somewhere in
  `__init__` — an explicitly declared field that's never assigned is a
  compile error, not a null/zeroed value.
- Fields can only be created inside `__init__`; assigning a brand-new
  `self.<name>` from any other method is a compile error.
- Protocol implementation is structural (no `implements` keyword), and
  `except ClassName` also matches subclasses of `ClassName` (single
  inheritance hierarchy).

## Protocols

Protocols provide **structural** polymorphism — a class doesn't declare
that it implements a protocol; it simply has to have the right method
shape:

```nox
protocol Shape:
    def area(self) -> float:
        pass

class Circle:
    def __init__(self, r: float) -> None:
        self.r = r

    def area(self) -> float:
        return 3.14159 * self.r * self.r

class Square:
    def __init__(self, s: float) -> None:
        self.s = s

    def area(self) -> float:
        return self.s * self.s

def print_area(shape: Shape) -> None:
    print(shape.area())

print_area(Circle(2.0))
print_area(Square(3.0))
```

Every method in a protocol body must have exactly `pass` as its body —
protocols declare shape only, never behavior.

## Generics

Free functions can be generic over a type parameter, resolved at compile
time (monomorphization) from the argument types at each call site — there
is no runtime type erasure or boxing:

```nox
def first[T](items: list[T]) -> T:
    return items[0]

x: int = first([1, 2, 3])
y: str = first(["a", "b"])
```

Methods can be generic too: `def first[T](self, fallback: T) -> T` is
called as `obj.first[int](5)` or with the type argument inferred from the
arguments (`obj.first(5)`). Current limits: one type parameter per
method, and a generic method on a generic class is not supported.

## Error Handling

Python's `try`/`except`/`raise`/`finally` syntax is preserved, matching
by exact class identity (there's no subclass hierarchy to walk):

```nox
class HttpError:
    def __init__(self, message: str) -> None:
        self.message = message

def fetch(url: str) -> str:
    if url == "":
        raise HttpError("empty url")
    return "..."

try:
    body: str = fetch("")
except HttpError as e:
    print(e.message)
finally:
    print("done")
```

Under the hood, `raise` compiles to an implicit error-return thread
through every call frame (Zig-style error unions), not stack unwinding —
QBE has no landing-pad/unwind-table support.

`with EXPR as NAME:` is also supported for any class implementing
`__enter__`/`__exit__` (Python's context-manager protocol).

## Memory Model — the "Ownership Pyramid"

There is no explicit ownership syntax anywhere in Nox — no `&`, no
`move`, no `Annotated[...]`, no `read`/`mut`/`owned` keywords. The
compiler picks the cheapest safe strategy automatically, layer by layer:

1. **Layer 1 — invisible borrow-checker + ASAP destructors (zero cost).**
   The default. When ownership and lifetime are statically provable
   (an estimated 80–90% of real code), the compiler inserts destructor
   calls directly at scope exit — no refcount, no runtime cost.
2. **Layer 2 — ARC (automatic reference counting).** Whenever Layer 1
   can't prove ownership statically, the compiler silently promotes the
   value to reference counting instead of erroring — O(1)
   increment/decrement, never a deep copy.
3. **Layer 3 — cycle collector.** A lightweight background scan (Bacon &
   Rajan trial-deletion, in the spirit of Nim's ORC) detects reference
   cycles between ARC-managed class instances, triggered by an
   allocation-pressure threshold and at program exit.
4. **Layer 4 — `lowlevel` blocks.** Analogous to Rust's `unsafe`, gives
   direct access to arena/pool allocation and fully manual memory
   management. Static typing stays fully mandatory even inside
   `lowlevel` — it relaxes only the allocation *strategy*, never the type
   system.

```nox
def compute() -> int:
    total: int = 0
    lowlevel:
        nums: list[int] = [1, 2, 3, 4, 5]
        i: int = 0
        while i < 5:
            total = total + nums[i]
            i = i + 1
    return total
```

## Async and Concurrency

**Cooperative fibers** (`async def`/`spawn`/`await`, `Task[T]`,
`Channel[T]`) run on a single OS thread with a kqueue/epoll-based I/O
reactor — Go-style green threads:

```nox
async def producer(ch: Channel[int]) -> None:
    await ch.send(10)
    await ch.send(20)

async def main_task() -> None:
    ch: Channel[int] = Channel[int](0)
    t: Task[None] = spawn producer(ch)
    a: int = await ch.recv()
    b: int = await ch.recv()
    print(a)
    print(b)
    await t

t2: Task[None] = spawn main_task()
await t2
```

**Real OS-thread parallelism** (`nox.thread`) is shared-nothing: each
`ThreadHandle[T]` runs its own independent fiber runtime on its own OS
thread (not a shared work-stealing scheduler), communicating via
`ThreadChannel[T]`:

```nox
import nox.thread

async def worker(x: int) -> int:
    return x * 2

async def run() -> None:
    h: ThreadHandle[int] = nox.thread.start(worker, 21)
    result: int = await h.join()
    print(result)

t: Task[None] = spawn run()
await t
```

(A top-level user function must not be named `main` — the compiler
synthesizes its own program entry point of that name.)

## Standard Library

Growing, written in Nox itself (`stdlib/nox/*.nox`) with thin Zig shims
for anything that needs to call into the OS: `nox.http` (client +
multi-core server), `nox.json`, `nox.strings`, `nox.math`, `nox.os` /
`nox.fs`, `nox.time`, `nox.test`, `nox.log`, `nox.random`, `nox.crypto`,
`nox.regex`, `nox.path`. `ValueError`/`IndexError` and a few other core
types are available everywhere with no `import` needed.

## FFI and Native Code

`extern def` declares a function implemented in a native `.o`/library,
callable from Nox with normal static typing at the boundary:

```nox
extern def nox_http_response_ok(h: ptr) -> int from "zig-out/lib/noxrt.o"
```

There is also an HPy-inspired opaque-handle model for C extensions (so
native code never gets a raw pointer into Nox's managed heap) and an
embedded WASM runtime for importing WASM modules as libraries. Both
`extern def` and `lowlevel` are trust boundaries: they run outside Nox's
type/ownership guarantees with no sandboxing (see the main
[README](../README.en.md#security) and `AGENTS.md` §9.5 for the full
security model).

## Tooling

```sh
noxc init myproject         # scaffold a new project
noxc check main.nox         # type-check only, no codegen — fast feedback
noxc build main.nox         # compile to a native binary
noxc run main.nox -- a b c  # compile + run, forwarding argv
noxc test                   # discover and run *_test.nox files
noxc fetch / noxc update    # third-party dependency management (nox.json/nox.lock)
```

See the main [README](../README.en.md) for installation and the full CLI
reference, and [`VERSIONING.md`](../VERSIONING.md) for the stability
guarantee.
