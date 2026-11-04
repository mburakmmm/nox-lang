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
| [11. Files and JSON](11-files-and-json.md) | reading and writing files, directories, parsing and producing JSON |
| [12. Testing](12-testing.md) | `noxc test`, assertions, `TestSuite`, testing handlers |
| [13. Generics and protocols](13-generics-and-protocols.md) | one function or container for many types, shape-based interfaces |
| [14. Databases](14-databases.md) | SQLite, prepared statements, transactions, PostgreSQL and MySQL |
| [15. Command-line tools](15-command-line-tools.md) | arguments, environment, input, exit codes, running programs |
| [16. WebAssembly and the browser](16-webassembly.md) | targets, capabilities, running in a page, the Playground |
| [17. Publishing a package](17-publishing.md) | `nox.json`, tags, `noxc login`, `noxc publish` |
| [18. Next steps](18-next-steps.md) | where to go from here |
| [Recipes](recipes.md) | short answers: word counts, grouping, tables, retries, tasks |

## Conventions

Commands you type in a terminal are shown in `sh` blocks. Nox source is shown in `nox` blocks; when a block is followed by an `output` block,
that is exactly what the program prints. Compiler error messages are English; branch on the error kind and the exit status, not on the wording.

If you want to experiment as you read, save a block as `hello.nox` and run `noxc run hello.nox` (see [Install](../install/index.md) if
`noxc` is not available yet) — or paste it into the [Playground](/playground/) and run it in your browser without installing anything.
