# Decorators and reflection

A decorator is a line starting with `@` immediately before a `def`, a method or a `class`. In Nox decorators are **metadata, not wrappers**:
the compiler records *which* declaration was decorated, with *which* literal arguments, and does **not** interpret the meaning or rewrite
the function. A framework (or your own code) reads the recorded metadata through `nox.reflect` and decides what it means. This keeps the
language small and the behaviour static — nothing is wrapped at run time.

```text
@name                       a decorator without arguments
@name("path", 5, True)      with literal arguments
@name(["admin", "ops"])     a list of string literals
@ffi.escape("xs")           dotted names are allowed
```

Decorator arguments must be **literals**: strings, integers, booleans or a list of string literals. Nested or computed arguments are a compile
error.

## What can be decorated

| Target | Notes |
|---|---|
| top-level `def` | recorded with its parameters and return type; if it has the exact signature `(Context) -> HttpResponse` it is also usable as a handler |
| `class` | recorded with the parameters of its `__init__` |
| method | recorded with the method's parameters (without `self`) and the owning class |
| `extern def` | the compiler-interpreted `@ffi.*` and `@capability.requires` decorators ([Foreign functions](ffi.md)) |

A few decorator names **are** interpreted by the compiler, because they describe how to compile rather than what to do:

| Decorator | On | Meaning |
|---|---|---|
| `@repr("C")` | class | natural C field alignment and padding ([Classes](classes.md#layout-control-for-foreign-code)) |
| `@packed` | class | no padding between fields |
| `@ffi.escape("p", …)`, `@ffi.noescape("p", …)` | `extern def` | which pointer arguments the native code may retain |
| `@ffi.callback("cb", "userdata")` | `extern def` | Nox function passed as a C callback |
| `@capability.requires("clock")` | `def`/`extern def` | the function needs a runtime capability ([Freestanding](../tools/freestanding.md)) |

Every other decorator name is yours.

## Reading metadata: `nox.reflect`

`nox.reflect` is the query API. Every decorator occurrence in the program is a numbered *record*; `decorator_count()` says how many exist and
the accessors below take the record index `i`:

| Function | Result |
|---|---|
| `decorator_name(i)` | the decorator's name (`"get"`) |
| `decorator_kind(i)` | what it decorates: `0` function, `1` class, `2` method |
| `decorator_target_name(i)` | the function, class or method name |
| `decorator_owner(i)` | the owning class of a method record (empty otherwise) |
| `decorator_arg_count(i)` | number of arguments |
| `decorator_arg_kind(i, j)` | per-argument kind: `0` string, `1` int, `2` bool, `3` string list |
| `decorator_arg(i, j)`, `decorator_arg_int(i, j)`, `decorator_arg_bool(i, j)` | the argument value |
| `decorator_arg_list_len(i, j)`, `decorator_arg_list_item(i, j, k)` | a list argument |
| `decorator_param_count(i)`, `decorator_param_name(i, k)`, `decorator_param_type(i, k)`, `decorator_return_type(i)` | the decorated declaration's signature (informational) |
| `class_count()`, `class_name(i)`, `class_init_param_count(i)`, `class_init_param_name(i, k)`, `class_init_param_type(i, k)`, `class_index(name)` | every class's `__init__` signature — enough for a framework to write its own dependency-injection wiring |
| `decorator_is_handler(i)`, `decorator_handler(i)` | for `kind == 0` records with a `(Context) -> HttpResponse` signature, the function as a callable value |
| `router_from_decorators()` | builds a `nox.router.Router` from `@get`/`@post`/`@put`/`@delete` handlers (a small example consumer) |

Asking an accessor for an argument kind it does not hold (for example `decorator_arg_bool` on an int) returns a safe default (`0`, `False`,
`""`) instead of failing.

```nox
import nox.reflect

@controller("/users", 2, True)
class UserController:
    def __init__(self, prefix: str) -> None:
        self.prefix = prefix

    @get("/:id")
    def show(self, id: int) -> str:
        return "x"

    @post("/")
    @auth(["admin", "ops"])
    def create(self, body: str, n: int) -> bool:
        return True

def find(kind: int, name: str) -> int:
    n: int = nox.reflect.decorator_count()
    i: int = 0
    while i < n:
        if nox.reflect.decorator_kind(i) == kind and nox.reflect.decorator_name(i) == name:
            return i
        i = i + 1
    return -1

c: int = find(1, "controller")
print(nox.reflect.decorator_target_name(c), nox.reflect.decorator_arg(c, 0), nox.reflect.decorator_arg_int(c, 1), nox.reflect.decorator_arg_bool(c, 2))
g: int = find(2, "get")
print(nox.reflect.decorator_owner(g) + "." + nox.reflect.decorator_target_name(g), nox.reflect.decorator_arg(g, 0))
a: int = find(2, "auth")
print(nox.reflect.decorator_arg_list_len(a, 0), nox.reflect.decorator_arg_list_item(a, 0, 1), nox.reflect.decorator_param_count(a))
```

```output
UserController /users 2 True
UserController.show /:id
2 ops 2
```

A *method* decorator makes the method a candidate handler; to call it the framework uses the bound-method value `obj.method`
([Functions](functions.md#bound-methods)) after constructing the class itself, using the recorded `__init__` parameters.

## `noxc expand`

`noxc expand file.nox` prints the decorator metadata the compiler extracted from a file — the same data `nox.reflect` serves — which is
handy for debugging a framework's decorators.

## Limits

- Decorators never run code and never change a function's signature or behaviour.
- Only literal arguments are recorded; there is no decorator composition.
- Generic classes and functions are not reflected.
- Metadata for a package's decorators is included when the package is imported.
