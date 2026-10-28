# WebAssembly coverage

`runtime/wasm_bridge/` is a **library import**, not a compilation target (AGENTS invariant 5). This page lists exactly what it accepts today. Anything not listed is rejected with a named error, never silently ignored.

## Module format

| Part | Status |
|---|---|
| Header, version | parsed |
| Type section (1) | parsed; only the function form `0x60` |
| Function section (3) | parsed |
| Export section (7) | parsed; function exports are callable |
| Code section (10) | parsed (locals + body) |
| Import (2), Table (4), Memory (5), Global (6), Start (8), Element (9), Data (11), custom sections | skipped by size, no meaning |

Value types: `i32` only in the interpreter. A module that declares `i64`, `f32` or `f64` parameters is rejected by the call path (`TypeMismatch`).

## Instructions (straight-line code, `i32`)

`unreachable` (traps), `nop`, `end`/`return`, `call`, `local.get`, `local.set`, `local.tee`, `i32.const`, `i32.add`, `i32.sub`, `i32.mul`. Every other opcode is `UnsupportedInstruction`. There is no `block`/`loop`/`if`/`br` (no control flow), no memory access, no tables, no imports, no `i64`/floats.

## Errors and limits

`Trap` (unreachable, malformed LEB128), `StackUnderflow`, `StackOverflow` (fixed operand stack), `UnsupportedInstruction`, `TypeMismatch`, `ExportNotFound`, `TooManyArgs`, `UnexpectedEof`, `OutOfMemory`. LEB128 is capped at five bytes. The parser has a fuzz target (`tests/fuzz/wasm_parser_fuzz.zig`).

## Decided target surface

The next steps, in this order, each with its own golden/fuzz tests: (1) the rest of the `i32` numeric instructions (comparisons, division with trap on zero and overflow, bitwise, shifts, `select`, `drop`); (2) structured control flow (`block`, `loop`, `if`/`else`, `br`, `br_if`); (3) linear memory with bounds-checked `load`/`store`; (4) `i64`. Floats, tables, imports and multi-value are out of scope until a real module needs them. A WASM back end for Nox is never added.
