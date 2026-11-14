# WebAssembly coverage

`runtime/wasm_bridge/` is a **library import** (an embedded interpreter that loads WASM modules into a Nox program). Compiling Nox *to* WebAssembly is a separate feature: [WebAssembly](../tools/wasm.md). This page lists what the interpreter accepts today (v2.1.148); the user-facing API is [nox.wasm](../stdlib/wasm.md). A module is validated with the specification's algorithm in one pass (`compile.zig`) and rejected with `InvalidModule` before anything runs; an opcode outside the list below is rejected, never silently ignored. A WASM back end for Nox is never added.

## Module format

| Part | Status |
|---|---|
| Header, version, type section (1), function (3), export (7), code (10) | parsed and validated |
| Import (2) | functions are bound to Nox host functions (up to 4 `int` parameters, 1 result); other import kinds are rejected |
| Table (4), element (9), reference types | supported (`call_indirect`, `table.get/set`, `ref.null/is_null/func`) |
| Memory (5), data (11), data count (12) | supported, including shared memories (threads); `memory.grow` is limited by `max_pages` |
| Global (6), start (8) | supported (`v128` globals are rejected) |
| Custom sections | skipped |

## Value types and instructions

`i32`, `i64`, `f32`, `f64`, `v128` (SIMD, inside the module only), `funcref`/`externref`. Multi-value results and block types are supported.

- The whole MVP numeric, control-flow (`block`, `loop`, `if`, `br`, `br_if`, `br_table`, `return`, `call`, `call_indirect`), variable, memory and parametric instruction set.
- Sign-extension operators, non-trapping (saturating) float-to-int conversions (`0xFC 0-7`), bulk memory (`0xFC 8-17`: `memory.copy/fill/init`, `data.drop`, table equivalents), reference types.
- Fixed-width SIMD (`0xFD`, v2.1.98), everything except relaxed SIMD.
- Threads (`0xFE`, v2.1.99): shared memory and atomics; since v2.1.155 optionally on real OS threads through the wasi-threads `thread-spawn` contract (see [nox.wasm](../stdlib/wasm.md#threads-atomics-shared-memory-and-wasi-threads)).
- A small opt-in WASI preview1 subset.

Not supported (rejected): exception handling, tail calls, GC and function-reference types, memory64, multi-memory, component model, relaxed SIMD, `v128` host-function signatures and `v128` crossing the Nox boundary.

## Errors and limits

`Trap` (unreachable, division by zero, out-of-range memory/table access, misaligned atomic, infinite `wait`), `InvalidModule`, `UnsupportedInstruction`, `StackOverflow`, `TypeMismatch`, `ExportNotFound`, `TooManyArgs`, `UnexpectedEof`, `OutOfMemory`, and the fuel limit (`open_with_limits`, default budget counts branches and calls). Memory pages are capped.

## Verification

Fuzzing: `tests/fuzz/wasm_parser_fuzz.zig` (parser, instantiation, execution; every single-byte mutation and prefix of small valid modules on each test run). Differential tests against Node's WebAssembly engine on every CI run: 36 904 numeric vectors, 9 330 SIMD vectors, 5 109 atomics vectors, plus compiled programs. See [nox.wasm](../stdlib/wasm.md#robustness).
