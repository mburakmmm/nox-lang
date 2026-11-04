# Symbol names

A top-level Nox `def` becomes a **global symbol** in the object file, under its plain name (`$name` in QBE, `@name` in LLVM). If a C library symbol of the same name is called by the runtime or by generated code, the user function would take its place at link time: `def printf(...)` would silently break `print`, `def getenv(...)` would hijack the runtime's environment lookup, `def read(...)` would replace the `read` used by `nox.io`, and on WebAssembly a signature mismatch makes the call trap.

## Policy

The **SYMBOL** of a top-level function whose name is on the **reserved-name list** — made of the runtime symbols of standard C, POSIX, libm and the target systems (Darwin, glibc/musl, Android, Windows, wasi-libc) — becomes `nox_user_<name>`. The Nox-level name does not change: you keep writing `printf(...)` in source, and error messages, `reflect` and `noxc expand` show the original name. This is the same on both back ends and on every target (native, mobile, WebAssembly).

```python
def getenv(x: int) -> int:     # nox_user_getenv in the object file
    return x + 1

print(getenv(41))              # 42; the runtime's own getenv is unaffected
```

- The list covers the whole standard C/POSIX/libm namespace, not only the symbols linked today (`compiler/codegen_qbe/reserved_symbols.zig`); the runtime may link a new libc function tomorrow.
- `extern def` declarations are NOT affected: `extern def sqrt(x: float) -> float from "m"` is meant to bind the real `sqrt`.
- Nox built-ins (`abs`, `round`, `min`, ...) and keywords cannot be defined as user functions in the first place.
- Embedding code (`nox_embed`) that calls a Nox function from C by name must use the `nox_user_` prefixed name for a function with a reserved name. Names that are not reserved are called by their plain name as before.
- The symbols of class methods have the form `Class_method`; a reserved name can only appear if the class name collides with a libc prefix (`pthread`, `clock`, ...). There is no protection for that case (a documented limit).

## Verification

- `tests/golden/codegen_cases/reserved_symbol_names.nox` defines and calls a user function for EVERY name on the list; some are also used through function values, `spawn` and `nox.thread.start`. It runs on both back ends and on all eight WebAssembly targets. When the list changes, run `scripts/gen_reserved_symbol_fixture.py`; CI checks that it is current with `--check`.
- `scripts/check_reserved_symbols.py` verifies, by reading `nm -u` of the runtime objects (`zig-out/lib/noxrt*.o`), that every symbol they resolve from libc is on the list. When the runtime starts linking a new libc function, CI breaks here.
