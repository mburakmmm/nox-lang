# Architecture

This section explains how Nox is built, for contributors and the curious. It is a summary of the engineering rules that govern the project (`AGENTS.md`) and of the design history
(`nox-teknik-spesifikasyon.md`, one numbered section per change). If a summary here and those documents ever disagree, the engineering documents win.

## The pipeline

```text
.nox source
  → lexer → parser → AST                       compiler/lexer, compiler/parser
  → type checker (mandatory static types,      compiler/typecheck
    generics by monomorphisation, protocols,
    checker-driven AST rewrites)
  → ownership analysis (ASAP vs ARC decision)  compiler/ownership
  → typed IR → QBE IL  or  LLVM IR             compiler/codegen_qbe  (qbe_emit / llvm_emit seam)
  → native code, linked statically with the Zig runtime     runtime/
```

Both back ends consume the **same typed IR** through one emission seam (`qbe*` helpers that either write QBE text or LLVM text), so every code-generation change is exercised by both and the whole corpus
runs on both. The Zig runtime provides allocation, reference counting, the cycle collector, the fiber scheduler, error values, strings, lists and dictionaries, the HPy/CPython bridge and the WASM bridge.

## Repository layout

```text
compiler/    lexer, parser, typecheck, ownership, codegen_qbe, fmt, pkg (fetch/index/install/upgrade), lsp, main
runtime/     alloc (ASAP/ARC/cycle/lowlevel), async_rt (fibers, scheduler, worker pool, reactor), errors, collections,
             stdlib_shims (Zig side of nox.*), hpy_bridge, cpython_compat, wasm_bridge, freestanding
stdlib/nox/  the standard library, written in Nox
tests/       unit, golden (source → output and IR snapshots), compat (real C/HPy/WASM/NNI extensions), cli, fuzz
docs/        this documentation
editors/     tree-sitter grammar, VS Code extension
services/    the noxpkg registry and the website (both written in Nox)
include/     nox_nni.h — the public native interface header
```

## The seven non-negotiable invariants

1. **Ownership never appears in user syntax.** No `mut`/`read`/`owned`/`Annotated`. When the compiler cannot prove ownership it falls back silently to reference counting — never an error, never a hint request.
2. **Static typing everywhere — including `lowlevel`.** `lowlevel` relaxes only the allocation strategy.
3. **No unwind tables or landing pads** in generated code. Error propagation is an implicit error-union return chain.
4. **No raw `PyObject*` and no Nox heap address ever reaches a C extension.** Everything crosses through opaque handles.
5. **WebAssembly is a library-import mechanism, not a compilation target.** There is no WASM back end.
6. **No global or hidden mutable state.** The runtime takes its allocator explicitly; the runtime state is threaded through generated code as a hidden first parameter. (One narrow, documented exception: the freestanding runtime's one-time bootstrap state.)
7. **Every language feature ships with at least one golden test.**

Changes that would violate one of these are not accepted; they are raised with the maintainers instead.

## Where to read next

| Topic | Page |
|---|---|
| lexer, parser, module loading | [Compiler front end](compiler.md) |
| type rules, generics, rewrites | [The type checker](type-checker.md) |
| memory strategy decisions | [Ownership analysis](ownership.md) |
| IR, back ends, optimisations | [Code generation](codegen.md) |
| ARC, cycles, errors, strings | [The runtime](runtime.md) |
| fibers, work stealing | [The scheduler](scheduler.md) |
| Python/WASM bridges | [HPy and WASM](hpy-wasm.md) |
| test suites | [Testing internals](testing.md) |
| how to send a change | [Contributing](contributing.md) |
| how a release happens | [Releasing](releasing.md) |
