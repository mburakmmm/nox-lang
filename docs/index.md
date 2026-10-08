# Nox documentation

**Nox** is a statically typed, ahead-of-time compiled programming language with Python's syntax. It compiles to native code through LLVM, has a small runtime written in Zig, manages memory automatically
without a garbage collector and without ownership annotations, and runs tasks in parallel on all your cores.

> *Native without the ownership noise.*

```nox
class Account:
    owner: str
    balance: int

    def __init__(self, owner: str, balance: int) -> None:
        self.owner = owner
        self.balance = balance

    def deposit(self, amount: int) -> None:
        self.balance += amount

acct: Account = Account("Ada", 100)
acct.deposit(50)
print(f"{acct.owner} has {acct.balance}")
```

```output
Ada has 150
```

## Start here

| If you want to… | Read |
|---|---|
| install Nox | [Installing Nox](install/index.md) |
| learn the language | the [Tutorial](tutorial/index.md) |
| look something up | the [Language reference](language/index.md) and the [Standard library](stdlib/index.md) |
| see what is new in 2.0 | [What's new in Nox 2.0](whatsnew/2.0.md) and [Migrating from 1.x](whatsnew/migrating.md) |
| build libraries, frameworks or native extensions | [The three APIs](apis/index.md) |
| use the tools | [noxc](tools/noxc.md), [Packages](tools/packages.md), [Testing](tools/testing.md) |
| understand how it works or contribute | [Internals](internals/architecture.md) |

## What makes Nox different

- **Python syntax, mandatory types.** Every variable, parameter and return value has a static type, checked before the program runs — with none of the ceremony of a borrow checker.
- **Invisible memory management.** The compiler places values on the stack or frees them at their last use when it can prove it is safe, and falls back silently to reference counting when it cannot; a cycle collector handles the
  rest. There are no ownership keywords, no lifetimes and no GC pauses.
- **Fast by default.** Programs compile to native code through LLVM (QBE is an alternative back end); numeric loops run at C speed.
- **Concurrency without colour wars.** Lightweight tasks, typed channels, and a work-stealing scheduler that uses every core — the same source runs correctly on one thread or many.
- **Batteries included.** An HTTP server and client with TLS and WebSockets, JSON/TOML/YAML/CSV, SQLite/PostgreSQL/MySQL, regular expressions, cryptography, a router, templates, testing and more.
- **A real native boundary.** `extern def` for C, the Nox Native Interface for stable plugins in C/C++/Rust/Zig, a Plugin API with manifests and capability consent, Python C extensions through HPy, and WebAssembly modules.
- **From web service to kernel.** The same language compiles a freestanding kernel with a kernel-provided allocator.

## Quick links

- [Language tour in one page](language/python-differences.md) — if you already know Python
- [`nox.http`](stdlib/http.md) · [`nox.json`](stdlib/json.md) · [`nox.sqlite`](stdlib/sqlite.md) · [`nox.thread`](stdlib/thread.md)
- [Security model](reference/security.md) · [Platforms](reference/platforms.md) · [FAQ](reference/faq.md)
- The package registry: [noxpkg](tools/noxpkg.md) · The web framework: [Nyx](https://github.com/mburakmmm/nyx)

## About this documentation

Every code example in these pages is compiled, and every example followed by an `output` block is also run and compared, as part of the project's test process. If something here disagrees with the compiler, that is a bug —
please report it at <https://github.com/mburakmmm/nox-lang/issues>.
