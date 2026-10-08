# The type checker

`compiler/typecheck/checker.zig` enforces mandatory static typing and produces the information code generation needs. It is the largest single component; this page describes its structure and the techniques
that keep the rest of the compiler simple.

## What it checks

- every declaration, parameter and return has a type; assignment compatibility (`int → float` is the only implicit conversion);
- scoping (function and module scope), `break`/`continue` placement, all-paths-return, optional narrowing (`x is None` guards, `and`/`or`/`not`, early exits);
- classes: field creation only in `__init__`, single inheritance, method overriding, special-method signatures, structural protocol satisfaction;
- generics: inference at call sites, explicit type arguments, monomorphisation of functions, classes and methods; function-typed arguments and lambda return inference;
- calls: arity, defaults, keyword arguments (bound by parameter, evaluated in source order), `spawn` data-race pre-checks;
- backend-dependent rules (spawn argument types, freestanding import allow-lists via capabilities);
- decorator arguments, `extern def` safety (FFI-safe types, `retains`/`@ffi.*`, callback targets), `lowlevel`-only builtins.

## Checker-driven rewriting

Many features are implemented by **rewriting the AST after checking**, so every later pass sees only simple constructs. Because the checker receives expressions by value it cannot rewrite them in place; instead it records
side tables keyed by the address of a child node and applies them once at the end (`call_expand_apply.zig`):

| Side table | Purpose |
|---|---|
| `call_expansions` | fill default arguments and reorder keyword arguments into positional order |
| `call_orders` | the source-order evaluation sequence for calls whose arguments have side effects |
| `expr_rewrites` | replace an expression: operator → dunder method call, `str(x)` → `x.__str__()`, `for` over a dictionary → `.keys()`, bound-method values, … |
| `stmt_for_rewrites` | give `for` loops a hidden local holding the iterable (strings, dictionaries, `__iter__`, module-level lists) |

Because the rewrite happens before ownership analysis, escape analysis, inlining and code generation, those stages needed no change when sugar such as default arguments, operator overloading, comprehensions or
lambdas was added. A lambda that captures variables lifts to a closure; a module-level lambda lifts to a top-level function.

## Generics

Free functions are instantiated per distinct argument types (`first__int`, `first__str`); classes per type-argument tuple (`Box__int`); methods of non-generic classes per explicit/inferred type argument. Mangled names are computed in
**one** place and shared with code generation — computing them twice (once in the checker, once in codegen) was the source of an earlier cross-module bug. Limits: a generic method on a generic class is not supported;
protocol-typed collections are not supported (use a base class).

## The prelude

`stdlib/nox/core.nox` is merged into every program. Rules for prelude functions: generic ones are instantiated only when used, so adding prelude code does not change unrelated programs; non-generic prelude functions must not
depend on externs that are unavailable in freestanding builds, and must not return tuples or index lists (older test harnesses merge no stdlib). Adding a class to the prelude renumbers class ids and so changes
every IR snapshot — regenerate them deliberately.

## Capabilities and profiles

A table maps each standard-library module to the capabilities it needs (`filesystem`, `network`, `process`, `clock`, `entropy`, `threads`, `shared_memory`, `libc_math`, `arch_x86_64`); `@capability.requires("…")`
marks individual functions. `--profile hosted` grants everything except architecture-specific modules; `--profile freestanding` grants only capability-free modules. Unknown modules are denied in freestanding builds.
