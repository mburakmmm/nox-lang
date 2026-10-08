# HPy / CPython and WebAssembly bridges

Two bridges let Nox programs use code written for other ecosystems. Both obey the same rule: **no raw foreign pointer or Nox heap address crosses the boundary — everything goes through opaque handles** (invariant 4).

## Python C extensions (HPy-style)

Goal: load Python C extensions — NumPy-class libraries — through an isolated handle system rather than by embedding CPython. The layers, in the order they are implemented (a higher tier is never started before the one below
it is complete):

| Tier | Scope |
|---|---|
| 0 | object lifecycle, reference-count emulation, base type protocol, module initialisation |
| 1 | buffer protocol (PEP 3118), sequence/mapping/number/iterator protocols — the core NumPy/Pandas use |
| 2 | GC hooks (`tp_traverse`/`tp_clear` emulation), weak references, subclassing across the boundary |
| 3 | descriptors, metaclasses, capsules, advanced strides, async protocols |

The context table (`ctx_*` functions) is implemented in full. Code lives in `runtime/hpy_bridge/` and `runtime/cpython_compat/` (a C-API emulation layer). Every Tier 0/1 addition is validated against a **real** compiled extension in
`tests/compat`, not just unit tests. Errors translate through the same trampoline mechanism as `extern def`: a foreign error becomes a Nox exception (`HPyError`) and raw `longjmp` is fenced at the boundary.

## WebAssembly

WASM is a **library import mechanism, never a compilation target** (invariant 5): a WASM module is loaded by an embedded runtime and its exports are exposed through the same handle abstraction as native extensions — there
is one foreign-function mechanism, not two. `runtime/wasm_bridge/` contains a WASM parser (fuzz-tested) and the runtime glue; the choice of embedded engine is isolated there and invisible to the compiler.

## Trampolines

For every imported symbol the compiler generates a trampoline that (1) converts Nox values to the handle or linear-memory representation, (2) checks the boundary's error convention on return (`PyErr_Occurred`
equivalent, or the WASM trap/return-code convention) and converts it to a Nox exception, and (3) defends against raw `longjmp` escaping into Nox frames with an isolated barrier. The barrier does not violate the
"no unwind tables" rule: Nox's own control flow never uses unwinding.

## Relationship to the public APIs

These bridges predate and are independent of [NNI](../apis/nni.md) and the [Plugin API](../apis/plugin-api.md), which are the supported way to write *new* native extensions for Nox. The bridges exist to run *existing* Python and WASM code.
