# Frequently asked questions

## The language

**Is Nox just Python?** The syntax is Python's, but Nox is statically typed and compiled to native code. Type annotations are mandatory, there is no dynamic attribute access, integers are 64-bit, and the semantics are those of a compiled language.
[Differences from Python](../language/python-differences.md) is the full list.

**Do I have to write types everywhere?** On variable declarations, parameters and return values, yes (`x: int = 5`). Later assignments, loop variables, lambda parameters and `self` need none, and the compiler infers many expression types.

**How is memory managed? Is there a garbage collector?** No GC and no ownership annotations. The compiler frees values at their last use when it can prove that is safe, reference-counts the rest, and runs a cycle collector for reference cycles.
You never free memory yourself ([Memory](../language/memory.md)).

**Does Nox have exceptions?** Yes — `try`/`except`/`finally`/`raise` with class hierarchies. They are implemented as ordinary return values, not stack unwinding, so they cost nothing when not raised.

**Is there `async`?** Yes: `async def`, `spawn`, `await`, `Task[T]` and `Channel[T]`. Tasks run in parallel on all cores under the default (LLVM) back end ([Concurrency](../language/concurrency.md)).

**Why is `isinstance` missing / why no `*args`?** They are deliberately outside 2.0; adding them later will not break existing programs. Use protocols, base classes and explicit parameters.

**Can I call C?** Yes: `extern def` ([Foreign functions](../language/ffi.md)). For distributable plugins use the [Nox Native Interface](../apis/nni.md) and [Plugin API](../apis/plugin-api.md). Python C extensions and WebAssembly modules can be loaded too ([Internals](../internals/hpy-wasm.md)).

## Tools and platforms

**Which platforms are supported?** macOS arm64, Linux x86-64 and aarch64 are fully tested; Windows x86-64 is supported and smoke-tested ([Platforms](platforms.md)).

**Do I need clang?** Not required. The compiler uses `clang`, or `zig cc`, or falls back to its bundled QBE back end ([Backends](../tools/backends.md)).

**LLVM or QBE?** LLVM is the default and fastest, and is the parallel one. Use QBE for freestanding builds, cross-compilation, debug info (`-g`) and as a fallback. Both produce identical results.

**How do I debug?** `print` shows any value structurally; `noxc build -g` gives line-level debugging ([Debugging](../tools/debugging.md)).

**Where do packages come from?** Git repositories, listed in `nox.json` and pinned in `nox.lock`; the central index at <https://noxpkg.noxlang.com> helps you find them ([Packages](../tools/packages.md)).

**Why are error messages in Turkish?** The project began with Turkish diagnostics; English diagnostics are the next step. The error *kind* and exit codes are stable today, so tools should not parse message text ([Versioning](versioning.md)).

## Performance

**How fast is it?** Across a mixed benchmark suite LLVM-compiled Nox runs at roughly 1.5× the time of C; numeric loops and dictionary-heavy code are within a small factor of C, and string/collection code is far faster than CPython.

**Why is my multi-task program using only two threads?** Programs that merely `spawn` get a small default pool; use `serve_multicore`/`nox.thread.pool_run` or set `NOX_POOL_WORKERS` ([The scheduler](../language/concurrency.md#the-scheduler)).

## Safety

**Is Nox memory safe?** Pure Nox code is. `extern def`, `lowlevel`, native plugins and dependencies containing them are outside that guarantee ([Security](security.md)).

**Is it sandboxed?** No. Run untrusted code in an OS-level sandbox.

## Community

**Where do I report bugs or ask questions?** <https://github.com/mburakmmm/nox-lang/issues> and the project's discussion pages.

**How do I contribute?** See [Contributing](../internals/contributing.md).
