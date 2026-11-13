# noxc bindgen

Generate Nox bindings from a C header.

```text
noxc bindgen <header.h> --lib <library> [-o <file.nox>] [--prefix <p[,p2]>] [-I <dir>] [-D <name[=value]>]
                        [--shim <file.c>] [--shim-lib <file.o>] [--no-compile] [--no-classes] [--config <bindgen.json>] [--cc <compiler>]
```

`bindgen` runs the C preprocessor (`cc -E`) on the header, reads the declarations with a small built-in C declaration parser (no libclang, no extra
dependency) and writes a `.nox` file of `extern def` declarations and constants. C++ headers are handled through their `extern "C"` surface; for a Rust
library, generate the C header with `cbindgen` first.

```text
noxc bindgen sqlite3.h --lib sqlite3 --prefix sqlite3_,sqlite_ -o sqlite.nox
```

| Option | Meaning |
|---|---|
| `--lib` | where the symbols live: a system library name (`"m"`, linked `-lm`) or an object/archive path. Written into every `from "..."` clause. Required |
| `-o` | output file (default `<header>.nox`) |
| `--prefix` | emit only names starting with the prefix (case-insensitive, comma-separated). **Required to get `#define` constants**, because the preprocessor does not say which header a macro came from |
| `-I`, `-D` | forwarded to the preprocessor and the shim compiler |
| `--shim`, `--shim-lib` | the generated C shim and the object name used in the generated `from` clauses (default `<output>_shim.c` / `<output>_shim.o`) |
| `--no-compile` | do not compile the shim; the command prints the `cc` line to run |
| `--no-classes` | do not write the [high-level classes](#high-level-classes) (only the raw functions) |
| `--config` | a JSON file with variadic shims, `long_double`, `event_callbacks`, `unchecked_accessors`, and the class settings `classes` / `owned_returns` |

## What is generated

| C | Nox |
|---|---|
| `int8_t … uint64_t`, `char`, `short`, `int`, `long`, `long long` | `i8 … i64`, `u8 … u64` (`long` and plain `char` follow the C compiler's own target: `__SIZEOF_LONG__`, `__CHAR_UNSIGNED__`) |
| `size_t`, `uintptr_t` / `ssize_t`, `ptrdiff_t`, `intptr_t` | `usize` / `isize` |
| `double`, `_Bool` | `float`, `bool` |
| `float` | `float` through the shim (the shim converts) |
| `const char *` parameter | `str` (plain `char` only; `unsigned char *` / `uint8_t *` stay `ptr`) |
| every other pointer, function pointer, array parameter | `ptr` |
| `enum` type | `i32`; the enumerators become `NAME: i32 = i32(value)` constants |
| `static const <integer> NAME = expr;` | `NAME: <type> = <type>(value)` |
| `#define NAME <integer expression>` / `"string"` (needs `--prefix`) | `NAME: int = value` / `NAME: str = "..."` |
| `struct` / `union` | memory is always a `ptr`; helpers and field accessors, below |
| `extern T name;` | `name_get()` / `name_set(v)` (no setter for `const`) |
| function pointer parameter with a `void *` userdata | `@ffi.callback(...)` declaration, below |

### Structs, unions and by-value arguments

For every complete `struct`/`union` in the header `bindgen` generates, through the C shim (so the C compiler decides layout, padding, bit fields and `const`):

| Function | Meaning |
|---|---|
| `Name_new()` / `Name_free(p)` / `Name_size()` | zeroed memory for one struct (`calloc`), release it, `sizeof`. **`Name_free` only releases blocks made by `Name_new` (or returned by by-value wrappers).** Never call it on a pointer the library owns (use the library's own destroy function) and note that it does not free memory the fields point to |
| `Name_get_f(p)` / `Name_set_f(p, v)` | read / write field `f` (also bit fields; no setter for `const` fields) |
| `Name_get_f(p, i)` / `Name_set_f(p, i, v)`, `Name_f_ptr(p)`, `Name_f_LEN` | an array field: element access, the array's start (use `nox.ffi.cstr` for a `char` array) and its length. For a fixed-length array the accessors are **bounds-checked**: an index `>= Name_f_LEN` makes the getter return `0`/`NULL` and the setter do nothing. Set `"unchecked_accessors": true` in `--config` for raw `p->f[i]` access (and always for flexible arrays, whose length is unknown) |
| `Name_get_f(p)` for a nested struct | the **address** of the nested struct (read or write it with that struct's accessors); `Name_set_f(p, v)` copies `*v` into it |

Fields of an anonymous inner `struct`/`union` are reachable directly on the outer type. A function that takes or returns a struct **by value** (`vec2 add(vec2 a, vec2 b)`) is called
with pointers to struct memory, and a returned struct is a **new** block you free with `Name_free`:

```nox-fragment
a: ptr = vec2_new()
vec2_set_x(a, 1.5)
vec2_set_y(a, 2.0)
c: ptr = vec2_add(a, b)       # a NEW block: free it (or use the generated classes below, which do it for you)
print(vec2_get_x(c))
vec2_free(a)
vec2_free(c)
```

### Callbacks

When a function takes a function pointer whose own signature has a non-`const` `void *` (the userdata) and the function has a `void *` next to it, `bindgen` writes the
declaration with [`@ffi.callback`](../language/ffi.md#callbacks), including `ud_index=` when the userdata is not the callback's last parameter (`sqlite3_exec` has it first):

```nox-fragment
def on_row(ncols: i32, vals: ptr, names: ptr) -> i32:
    print(ncols)
    return i32(0)

sqlite3_exec(db, "select * from t", on_row, np())     # the userdata argument is left out: the compiler fills it in
sqlite3_exec(db, "create table x(a)", None, np())     # None = no callback (a NULL function pointer)
```

A closure or lambda goes through a [`nox.ffi.Callback`](../stdlib/ffi.md) handle in the same place. Callback parameters are scalars, enums and pointers; read a `char *` with `nox.ffi.cstr(p)`.

### The C shim

Some functions cannot be called directly from Nox, so `bindgen` also writes a small C file that wraps them:

- `static inline` functions have no symbol in the library;
- `float` (32-bit) parameters and results do not match Nox's `float` (64-bit), so the shim converts;
- struct/union arguments and results, struct field access and global variables go through it too.

A shimmed function becomes a raw `extern def nox_shim_<name>` (linked from the shim object) plus an ordinary Nox `def` that calls it. **The wrapper always has the C name**
(`mylib_half`, `vec2_add`). When the library also exports a symbol of that name, the wrapper is marked `@link_name("nox_w_<name>")` — a built-in attribute that changes only the
object-file symbol of a `def`, never its Nox name — so the two do not collide at link time. Names that are Nox keywords or builtins (`in`, `from`, `sum`, …) get a trailing underscore
in Nox (functions: `in_`; parameters: `from_`). Helper and accessor names (`Name_get_f`, `counter_get`, …) are shim symbols themselves; if one would collide with a library function
it gets a trailing `_`.

### Wide and special types: `_Complex`, `__int128`, `long double`

| C type | In Nox | Helpers (generated once) |
|---|---|---|
| `float _Complex`, `double _Complex` | a `ptr` block | `cfloat_make(re, im)` / `cdouble_make(re, im)`, `_re(p)`, `_im(p)`, `_new`, `_free`, `_size` |
| `__int128`, `unsigned __int128` | a `ptr` block | `i128_make(lo, hi)` / `u128_make(lo, hi)` (two `u64` halves), `_lo(p)`, `_hi(p)`, `_new`, `_free`, `_size` |
| `long double` | `float` (narrowed to `f64`, precision is lost) | none; **off by default**: set `"long_double": "f64"` in the config |

Arguments are the addresses of such blocks; a result is a NEW block that the caller releases with `<name>_free`. Struct fields and globals of these types give the address of the
field, like nested structs. Bit fields work like any field (`Name_get_f` / `Name_set_f`; the C compiler decides the layout).

### Variadic functions (`...`)

A `printf`-style function cannot be called directly. Describe the fixed-signature versions you need in a JSON file and pass it with `--config bindgen.json`:

```json
{
  "variadic": [
    {"function": "my_log", "name": "my_log_s", "args": ["str"]},
    {"function": "my_logn", "name": "my_logn_si", "args": ["str", "int"]}
  ],
  "long_double": "f64",
  "event_callbacks": ["lib_on_event"]
}
```

`function` is the C function, `name` the generated Nox function (a C shim that makes the real variadic call), `args` the types of the part after the fixed parameters: `int`, `long`,
`double`, `str`, `ptr` or `size`. A variadic function without an entry is skipped with a warning that points here. `event_callbacks` lists functions whose callback the library calls
from its OWN thread: the callback parameter stays a plain `ptr` for [`nox.ffi.EventQueue`](../stdlib/ffi.md#callbacks-from-a-library-thread).

### What is skipped (with a warning)

SIMD vector types (`__m128`, `float32x4_t`, `vector_size`) and callbacks that take or return a struct by value. A declaration the parser cannot understand is skipped with a warning naming its line, never silently.

## Using the output

```nox-fragment
c: ptr = mylib_new("demo")
if mylib_run(c, i64(5), MYLIB_FLAG_FAST) != MYLIB_OK:
    print("failed")
mylib_free(c)
```

Constants made from `#define` are `int`s, and a constant that is never reassigned fits a fixed-width parameter **implicitly** when its value is in range, including expressions
such as `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE` (see [numbers](../language/numbers.md)); no `i32(...)` is needed. The generated `extern def`s
are raw native calls: they run with the full authority of the process ([trust boundary](../language/ffi.md#the-trust-boundary)). Combine them with
[`@ffi.errors`](../language/ffi.md#errors) and [`nox.ffi.Callback`](../stdlib/ffi.md) to get exceptions and closure callbacks.

## High-level classes

Unless you pass `--no-classes`, `bindgen` also writes, below the raw functions (which stay available), a Nox **class** for every struct/union it made helpers for:

```nox-fragment
from vec import Vec2

a: Vec2 = Vec2.new()          # zeroed C memory, freed automatically when `a` goes away
a.set_x(3.0)
a.set_y(4.0)
b: Vec2 = Vec2.new()
b.set_x(1.0)
c: Vec2 = a.add(b)            # `vec2_add(vec2, vec2)`: the result is a NEW block that `c` owns
print(c.len())
```

- The constructor is `Name(p, owned)`; `Name.new()` allocates. `__del__` calls the free function when `owned` is true, so you never write `free`.
- Scalar fields become `x()` / `set_x(v)`. A function whose **first parameter** is the struct (by value or pointer) becomes a method (the `Name_` or `lib_` prefix is dropped:
  `vec2_add` -> `add`, `sqlite3_stmt_readonly` -> `readonly`); a function that **returns** the struct and takes no struct first becomes a `@staticmethod`.
  Parameters and results of struct type use the class. Names that would clash are skipped with a warning, and the raw function is still there.
- A pointer **returned by the library** is wrapped as *borrowed* (`owned=False`, never freed by the class), because `bindgen` cannot know who owns it. List the functions that hand
  you an owned pointer in `owned_returns`, and give opaque handles (`typedef struct sqlite3 sqlite3;`, no body) their destroy function in `classes`:

```json
{
  "classes": [{"record": "sqlite3", "free": "sqlite3_close"}, {"record": "sqlite3_stmt", "free": "sqlite3_finalize"}],
  "owned_returns": ["sqlite3_open_helper"]
}
```

  The class then calls that function in `__del__` (instead of `Name_free`). Objects that must be destroyed in a particular order (a statement before its connection) still need
  you to keep the owner alive or `del` them in order; the generated code cannot see that relationship.
- Cost: the class adds one small ARC object per wrapped value. Measured on an Apple M-series CPU with a by-value `vec2_add` returning a new block, 30 million iterations of
  "add, read, free" take 0.67 s through the raw functions and 0.86 s through the class (about 22 ns and 29 ns per iteration), so per-call allocation is not a bottleneck for
  per-frame game or UI code.

## Worked example: yyjson

`noxc bindgen yyjson.h --lib yyjson.o --prefix yyjson` turns the whole yyjson header (about 9000 lines, mostly `static inline` functions) into 331 functions and 116
constants, 288 of them through the generated shim. Reading, walking (with the array iterator) and writing a JSON document work from Nox on both backends, and on
a 1.6 MB document the generated binding walks it 4.8 times faster and writes it 8.4 times faster than `nox.json` (writing is as fast as C itself). The
benchmark and the numbers are in `benchmarks/yyjson/` and `benchmarks/RESULTS.md`.

