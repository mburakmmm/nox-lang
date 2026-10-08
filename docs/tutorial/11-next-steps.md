# 11. Next steps

You now know the shape of Nox: static types with Python's syntax, functions and classes, collections, errors, modules, tasks and a web server. Where
to go from here depends on what you want to build.

## Read the reference

- The [language reference](../language/index.md) is complete and precise: numbers and overflow, strings and formatting, classes and protocols,
  generics, exceptions, concurrency and memory.
- The [standard library reference](../stdlib/index.md) documents every module and function.
- [Differences from Python](../language/python-differences.md) is the quick checklist if you are porting code.

## Build something

- **Command-line tools:** `nox.os` (arguments, environment), `nox.fs`, `nox.path`, `nox.process`, `nox.console`, `nox.log`.
- **Web services:** `nox.http`, `nox.router`, `nox.json`, `nox.validate`, `nox.template`, databases, and the Nyx framework.
- **Data processing:** `nox.collections`, `nox.regex`, `nox.csv`, `nox.yaml`, `nox.toml`, `nox.binary`.
- **Systems work:** fixed-width integers, `ptr[T]`, `lowlevel`, [freestanding builds](../tools/freestanding.md) for kernels, and
  [`extern def`](../language/ffi.md) to call C.

## Extend Nox itself

Nox has three stable ways to connect with the outside world, described in [The three APIs](../apis/index.md):

- the **Nox API** — what library and framework authors can rely on in Nox source code;
- the **Nox Native Interface** — a C ABI for native extensions in C, C++, Rust or Zig;
- the **Plugin API** — manifests, versioning and capability consent on top of NNI.

## Tools

[`noxc`](../tools/noxc.md) does everything: `check`, `build`, `run`, `test`, `fmt`, `init`, `add`, `fetch`, `publish`, `upgrade`. There is an LSP server
and editor support ([Editors](../install/editors.md)), and a package registry at [noxpkg](../tools/noxpkg.md).

## Get involved

The compiler and runtime are written in Zig and open source. [Contributing](../internals/contributing.md) explains the layout, the test suites and
how a change reaches a release; [Architecture](../internals/architecture.md) describes how the compiler works.
