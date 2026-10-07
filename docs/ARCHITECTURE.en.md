# Nox — Architecture and Contributor Guide (English summary)

This is an English summary of the two Turkish engineering documents that govern the project:
[`AGENTS.md`](../AGENTS.md) (the binding rules for anyone — human or AI agent — changing the compiler or
runtime) and [`nox-teknik-spesifikasyon.md`](../nox-teknik-spesifikasyon.md) (the full design history, one numbered
section per change, ~30,000 lines). If this summary and the Turkish documents disagree, **the Turkish documents are
authoritative**. For the language itself see [`LANGUAGE.md`](LANGUAGE.md); for the standard library see
[`STDLIB.md`](STDLIB.md); for platform status see [`PLATFORMS.md`](PLATFORMS.md).

## 1. What Nox is

A statically typed, ahead-of-time compiled language with Python-like syntax. Types are mandatory everywhere (including
inside `lowlevel`). Memory management is automatic and invisible: there is no ownership syntax. The compiler and runtime
are written in Zig; code generation targets LLVM (default, hosted macOS/Linux when `clang` exists) or QBE
(`--backend qbe`, and automatically for freestanding/`--target`/Windows/no-`clang` builds).

## 2. Pipeline

```
.nox source
  → lexer → parser → AST                       compiler/lexer, compiler/parser
  → type checker (mandatory static types,      compiler/typecheck
    generics via monomorphization, protocols,
    checker-driven AST rewrites)
  → ownership analysis (ASAP vs ARC decision)  compiler/ownership
  → typed IR → QBE IR  or  LLVM IR             compiler/codegen_qbe (qbe_emit / llvm_emit seam)
  → native code, linked statically with the Zig runtime   runtime/
```

Both backends consume the same typed IR and are exercised by the whole golden corpus; every codegen change must be
verified on both. The Zig runtime provides allocation, ARC, the cycle collector, the fiber/M:N scheduler, error values,
the string/list/dict implementations, the HPy/CPython bridge and the WASM bridge.

## 3. The non-negotiable invariants (AGENTS.md §2)

1. **No ownership syntax.** No `mut`/`read`/`owned`/`Annotated[...]`. When the compiler cannot prove ownership it silently
   falls back to ARC — never a compile error, never a hint request.
2. **Static typing everywhere**, including `lowlevel`; `lowlevel` only changes the allocation strategy.
3. **No unwind tables or landing pads.** Errors propagate through an implicit error-union return chain.
4. **No raw `PyObject*` or Nox heap address ever crosses into a C extension**; everything goes through opaque handles.
5. **WASM is a library-import mechanism, not a compile target.** No WASM backend.
6. **No hidden global mutable state.** Runtime functions take allocators explicitly (one narrow, documented exception:
   the freestanding runtime's one-time bootstrap state).
7. **Every new language feature ships with at least one golden test** (source → expected output / IR).

If a task cannot be completed without violating one of these, stop and ask.

## 4. Memory model — the ownership pyramid

| Layer | Mechanism | Notes |
|---|---|---|
| 1 | ASAP destructors | Conservative static analysis; frees at the last use, zero runtime cost. If unprovable → layer 2. |
| 2 | ARC | O(1) retain/release, no deep copies; promotion from layer 1 is silent. Atomic across worker threads. |
| 3 | Cycle collector | Scans only ARC objects (Nim-ORC-like); triggered by allocation pressure. |
| 4 | `lowlevel` | Arena / fixed-buffer / pool allocators; types still fully checked. |

## 5. Error handling

Functions that can fail compile to `{ok: T} | {err: ExceptionHandle}`. `except Class:` compiles to a runtime class-chain
check; `finally`, `with` and `defer` share one scope-exit mechanism with ASAP destructors (no separate code path). At the
C/WASM boundary the compiler generates a trampoline that marshals values, translates the foreign error convention into an
`ExceptionHandle`, and fences raw C `longjmp`s with a defensive barrier.

## 6. Trust boundary

`extern def` and `lowlevel` run **outside** Nox's type and ownership guarantees, with no sandbox. A dependency listed in
`nox.json` may declare its own `extern def`s, so adding a dependency means trusting its native code (same model as npm /
PyPI / crates.io — there is no capability system yet). `nox.fs` does not validate paths; callers handling untrusted input
must canonicalise and reject `..` themselves. A kernel-provided allocator installed via `nox_allocator_install` is part of
the same trust boundary. Adding an automatic "safe mode" to `extern def` would require a dedicated security design and must
not be done ad hoc.

## 7. Repository layout

```
compiler/      lexer, parser, typecheck, ownership, codegen_qbe, fmt, lsp, pkg
runtime/       alloc (ASAP/ARC/cycle), async_rt (fibers, M:N scheduler), errors, collections, stdlib_shims, hpy_bridge,
               cpython_compat, wasm_bridge, freestanding
stdlib/nox/    the standard library, written in Nox (thin Zig shims where the OS is needed)
tests/         unit, golden (source → output and IR snapshots), compat (real C/HPy/WASM extensions), cli, fuzz
docs/          LANGUAGE.md, STDLIB.md, PLATFORMS.md, this file, the 2.0 readiness roadmap
editors/       tree-sitter grammar, VS Code extension
benchmarks/    cross-language benchmark suite (not tracked in git)
```

## 8. How to change the language (AGENTS.md §7)

In this order, no skipping: grammar (parser + AST) → type-check rule → ownership impact → codegen (**both backends**) →
golden test → spec section. New expression kinds touch ~30 exhaustive switches (the compiler lists them); checker-driven
rewrites (default arguments, comprehensions, lambdas, operator overloading, f-strings…) go through side tables applied in
place at the end of `checkModule` (`compiler/typecheck/call_expand_apply.zig`) so downstream passes never see the sugar.
Architecture-affecting decisions (new syntax, memory-model behaviour, ABI changes) require confirmation before
implementation.

## 9. Definition of done (AGENTS.md §13–14)

- `zig build test` is green (run it twice after intentionally changing codegen: IR snapshots regenerate on the first run).
- A golden test exists for new or changed language behaviour; memory-related changes add leak and double-free tests and
  pass under the `GeneralPurposeAllocator` safety mode; error-handling changes cover success, failure and `finally`/`with`
  interaction; HPy/CPython changes are validated against a real extension in `tests/compat`.
- No invariant violated; the specification is updated when behaviour changed.
- Every commit is a release: bump `build.zig.zon` (patch by default, minor for real features), update `CHANGELOG.md`,
  tag `vX.Y.Z` and push the tag.

## 10. HPy / CPython compatibility tiers

Implement strictly bottom-up: Tier 0 (object lifecycle, refcount emulation, module init) → Tier 1 (buffer, sequence/mapping,
number, iterator protocols — the NumPy/Pandas core) → Tier 2 (GC hooks, weakrefs, subclassing across the boundary) →
Tier 3 (descriptors, metaclasses, capsules, async). Each Tier 0/1 addition needs an integration test against a real
extension.

## 11. Generics and polymorphism

Compile-time monomorphization plus structural protocols (no `implements` keyword). A call site with one or a few concrete
types gets dispatch-free specialisations; a genuinely heterogeneous collection falls back to fat pointers (data + vtable).
The choice is invisible to the user.
