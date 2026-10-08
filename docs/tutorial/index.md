# Tutorial

This tutorial teaches Nox by building up small, complete programs. It assumes you can read a little Python or any similar language; it does
not assume you know anything about types, compilers or memory management. Every code block compiles, and every block followed by its
output was run to produce it.

| Chapter | You will learn |
|---|---|
| [1. Hello, Nox](01-hello.md) | install check, `noxc run`, `noxc build`, projects |
| [2. Values and types](02-values-and-types.md) | `int`, `float`, `str`, `bool`, annotations, f-strings, conversions |
| [3. Control flow](03-control-flow.md) | `if`, `while`, `for`, `range`, `break`/`continue` |
| [4. Functions](04-functions.md) | parameters, defaults, keyword arguments, closures, lambdas |
| [5. Collections](05-collections.md) | lists, dictionaries, sets, tuples, comprehensions |
| [6. Classes](06-classes.md) | classes, inheritance, special methods, protocols, generics |
| [7. Errors](07-errors.md) | exceptions, `finally`, `with`, `defer` |
| [8. Modules and packages](08-modules-and-packages.md) | multi-file projects, `nox.json`, dependencies |
| [9. Concurrency](09-concurrency.md) | tasks, channels, fan-out/fan-in |
| [10. A small web service](10-a-small-web-service.md) | HTTP server, routing, JSON |
| [11. Next steps](11-next-steps.md) | where to go from here |

## Conventions

Commands you type in a terminal are shown in `sh` blocks. Nox source is shown in `nox` blocks; when a block is followed by an `output` block,
that is exactly what the program prints. The compiler's *error messages* are currently written in Turkish; this tutorial quotes the English
meaning when it shows one.

If you want to experiment as you read, save a block as `hello.nox` and run `noxc run hello.nox` (see [Install](../install/index.md) if
`noxc` is not available yet).
