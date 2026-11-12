# noxc bindgen

Generate Nox bindings from a C header.

```text
noxc bindgen <header.h> --lib <library> [-o <file.nox>] [--prefix <p[,p2]>] [-I <dir>] [-D <name[=value]>]
                        [--shim <file.c>] [--shim-lib <file.o>] [--no-compile] [--cc <compiler>]
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

## What is generated

| C | Nox |
|---|---|
| `int8_t … uint64_t`, `char`, `short`, `int`, `long` (64-bit), `long long` | `i8 … i64`, `u8 … u64` |
| `size_t`, `uintptr_t` / `ssize_t`, `ptrdiff_t`, `intptr_t` | `usize` / `isize` |
| `double`, `_Bool` | `float`, `bool` |
| `const char *` parameter | `str` |
| every other pointer, function pointer, array parameter | `ptr` |
| `enum` type | `i32`; the enumerators become `NAME: i32 = i32(value)` constants |
| `static const <integer> NAME = expr;` | `NAME: <type> = <type>(value)` |
| `#define NAME <integer expression>` / `"string"` (needs `--prefix`) | `NAME: int = value` / `NAME: str = "..."` |
| `typedef`s, `struct`/`union` names | resolved; a struct is only ever used through a pointer, i.e. `ptr` |

### The C shim

Some functions cannot be called directly from Nox, so `bindgen` also writes a small C file that wraps them:

- `static inline` functions have no symbol in the library;
- `float` (32-bit) parameters and results do not match Nox's `float` (64-bit), so the shim converts.

Each such function becomes a raw `extern def nox_shim_<name>` (linked from the shim object) plus an ordinary Nox `def` that calls it. The wrapper keeps the
C name for `static inline` functions and gets a trailing underscore when the library also exports a symbol of that name (`mylib_half` -> `mylib_half_`),
because a top-level Nox `def` and the C symbol would otherwise collide at link time. Names that are Nox keywords or builtins (`in`, `from`, `sum`, …) get the
same treatment (functions: `in_`; parameters: `from_`).

### What is skipped (with a warning)

Variadic functions (`...`), `long double`, `_Complex`, `__int128`, and functions that take or return a `struct`/`union` **by value**. A declaration the parser
cannot understand is skipped with a warning naming its line, never silently. Struct fields are not generated yet (structs stay opaque `ptr`).

## Using the output

```nox-fragment
c: ptr = mylib_new("demo")
if mylib_run(c, i64(5), MYLIB_FLAG_FAST) != MYLIB_OK:
    print("failed")
mylib_free(c)
```

Constants made from `#define` are plain `int`s, so convert them where a parameter has a fixed width (`i32(SQLITE_OPEN_READWRITE)`). The generated `extern def`s
are raw native calls: they run with the full authority of the process ([trust boundary](../language/ffi.md#the-trust-boundary)). Combine them with
[`@ffi.errors`](../language/ffi.md#errors) and [`nox.ffi.Callback`](../stdlib/ffi.md) to get exceptions and closure callbacks.
