# Types

Every Nox value has a static type known at compile time. Types are written in annotations and are **mandatory** on variable
declarations, parameters and return values. There is no `Any` and no implicit dynamic fallback — not even inside
[`lowlevel`](memory.md#lowlevel-blocks) blocks.

## Declaring variables

A name is introduced by its first assignment, which must carry the type:

```nox
count: int = 0
name: str = "nox"
ratio: float = 0.5
ready: bool = True
count = count + 1      # later assignments omit the annotation
print(count, name, ratio, ready)
```

```output
1 nox 0.5 True
```

Assigning a value of the wrong type is a compile error. Re-declaring a name in the same scope with a *different* type is a
compile error too (this includes reusing a loop variable name for loops over different element types). The one implicit
conversion is `int → float` on assignment and in mixed arithmetic.

## The scalar types

| Type | Values | Notes |
|---|---|---|
| `int` | signed 64-bit integer | wraps on overflow ([Numbers](numbers.md)) |
| `float` | IEEE-754 double | printed like Python's `repr` |
| `bool` | `True`, `False` | never converts to or from `int` implicitly |
| `str` | immutable UTF-8 text | indexed by code point ([Strings](strings.md)) |
| `None` | the single value `None` | the type of "no value"; also the return type of procedures |

### Fixed-width integers

For byte-level work, binary formats and `lowlevel` code there are ten more integer types:

`i8 i16 i32 i64 isize` and `u8 u16 u32 u64 usize`.

They never mix implicitly — with each other, with `int` or with `float`. Convert explicitly with the type name used as a
function: `u8(200)`, `int(b)`. **Overflow of `+`, `-` and `*` on a fixed-width integer terminates the program** with a message,
identically on both backends; plain `int` wraps. `list[u8]` and friends are stored byte-packed.

```nox
b: u8 = u8(200)
c: u8 = u8(55)
print(int(b) + int(c), b + c)
```

```output
255 255
```

## Collection types

| Type | Written as | Literal |
|---|---|---|
| list | `list[T]` | `[1, 2, 3]` |
| dictionary | `dict[K, V]` | `{"a": 1}` |
| set | `set[T]` | `{1, 2, 3}` (and `set()` for the empty set) |
| tuple | `tuple[A, B, ...]` | `(1, "x")` |

- A `list[T]` is a growable array; elements may be of any single type, including other lists and classes.
- A `dict[K, V]` keeps **insertion order**. Keys are `int`, `float`, `bool` or `str`; values are `int`, `float`, `bool`, `str`,
  a class, a `list[T]` or a `dict`.
- A `set[T]` holds unique elements of type `int`, `float`, `bool` or `str` and iterates in insertion order.
- A tuple is an immutable value with a fixed number of elements of possibly different types; it cannot be a dictionary key and
  cannot be iterated.

The empty literals `[]` and `{}` take their type from the surrounding context (an annotated declaration, a parameter, a return
type):

```nox
names: list[str] = []
table: dict[str, int] = {}
names.append("ada")
table["ada"] = 1
pair: tuple[str, int] = ("ada", 1)
unique: set[int] = {3, 1, 3}
print(names, table, pair, len(unique))
```

```output
['ada'] {'ada': 1} ('ada', 1) 2
```

See [Expressions](expressions.md) and [Built-in functions](builtins.md) for the operations on collections.

## Class and protocol types

Every `class` declares a type of the same name; every `protocol` declares a structural interface type (see [Classes](classes.md)
and [Protocols and generics](protocols-generics.md)). Class instances are reference values: assigning one to another variable
shares the object.

## Optional types

`T | None` means "a `T` or `None`". It is available for `str`, `list`, `dict`, classes and the scalar types:

```nox
def first_word(text: str) -> str | None:
    if text == "":
        return None
    return text.split(" ")[0]

w: str | None = first_word("hello world")
if w is not None:
    print(w.upper())
```

```output
HELLO
```

Use `x is None` / `x is not None` (or `== None` / `!= None`) to test. After such a test the optional is **narrowed** to `T`
inside the matching branch, through `and`/`or`/`not`, and after a guard whose branch always exits:

```nox
def length_or_zero(s: str | None) -> int:
    if s is None:
        return 0
    return len(s)

print(length_or_zero(None), length_or_zero("abc"))
```

```output
0 3
```

Using an un-narrowed optional where a plain `T` is needed is a compile error. `print(x)` shows `None` or the value; `str(x)` and
f-strings need a narrowed value. A scalar optional (`int | None`) is boxed internally — this is invisible to the program.

## Function types

A function type is written `(P1, P2) -> R`. Top-level functions, nested functions, lambdas and bound closures are values of
function type and can be stored, passed and returned ([Functions](functions.md)):

```nox
def apply(f: (int) -> int, x: int) -> int:
    return f(x)

def double(n: int) -> int:
    return n * 2

print(apply(double, 21), apply(lambda n: n + 1, 41))
```

```output
42 42
```

## Generic types

User code can declare generic functions, methods and classes with type parameters in square brackets (`def first[T](xs: list[T])
-> T`, `class Box[T]`). Each use is specialised at compile time (monomorphisation); nothing is boxed or erased. The built-in
generic types are `Task[T]`, `Channel[T]`, `ThreadHandle[T]` and `ThreadChannel[T]` ([Concurrency](concurrency.md)), and
`ptr[T]` ([Foreign functions](ffi.md)). See [Protocols and generics](protocols-generics.md).

## Pointers

`ptr` is an opaque machine pointer and `ptr[T]` a typed one; they exist for foreign-function interfaces and `lowlevel` code and
are covered in [Foreign functions](ffi.md). Ordinary Nox code never needs them.

## Type compatibility summary

- Types are **nominal** for classes and **structural** for protocols.
- There is no subtyping among the built-in types; `int` and `float` mix in arithmetic (result `float`), everything else is an
  explicit conversion: `float(x)`, `int(x)`, `str(x)`, `bool(x)`, `list(x)`.
- A subclass instance can be used where its base class is expected (single inheritance).
- Two function types are compatible when their parameter and return types are identical.
