# Code generation

`compiler/codegen_qbe/` turns the checked, rewritten AST into IR. Despite its name it hosts **both** back ends.

## The emission seam

Code generation never writes IR text directly. It calls helpers named `qbe*` (`qbeOp2`, `qbeCall`, `qbeLoadL`, `qbeJnz`, …) that go through `qbe_emit.zig` or `llvm_emit.zig` depending on the chosen backend. The seam
handles the differences: QBE's three-address SSA text versus LLVM's typed instructions, calling conventions, `alloca` placement, integer arithmetic flavours, floating-point and atomic operations. Consequences:

- a feature is implemented **once**;
- both back ends must be verified for every change (the fixture corpus runs on both);
- a few operations have back-end-specific lowering where QBE lacks an instruction (atomic reference counts exist only on LLVM; `udiv`/`urem` mapping; 64-bit overflow checks).

## Layout and ABI

`abi.zig` and `layout.zig` define the value representations: reference-counted payloads with a header, the packed `str` header (length plus ASCII flag), list headers (length/capacity), dictionary layout, class instances (type tag,
vtable pointer, fields in 8-byte slots — `@repr("C")`/`@packed` classes use real C layouts), closures (function pointer plus captured environment), tuples (generated structs), error unions (value or exception handle),
`Task`/`Channel` objects. These layouts are internal ([Internal ABI](../apis/internal-abi.md)).

## Major components

| File | Responsibility |
|---|---|
| `registration.zig` | collects declarations, resolves types, computes class layouts, vtables and cyclic classes |
| `expr.zig`, `calls.zig`, `stmt.zig` | expressions, calls (including built-ins), statements; arithmetic with overflow policy; printing |
| `exceptions.zig` | `raise`, `try`/`except`/`finally`, `with`, `defer`, scope-exit mechanism shared with memory release |
| `closures.zig` | closures, lambdas, bound methods, function values |
| `ownership.zig`, `local_escape.zig`, `inlining.zig`, `optimizations.zig` | retain/release emission, stack promotion, inlining of small functions, bounds-check elision |
| `async_thread.zig` | `spawn`, `await`, channels, `nox.thread`, the multi-core pool |
| `http_intrinsics.zig` | the `serve*` family and the generated per-call-site wrappers |
| `decorators.zig` | the static decorator/reflection tables |
| `ffi_callback.zig` | trampolines for `@ffi.callback` |
| `globals.zig` | module-level variables and per-worker globals |

## Semantics that both back ends must share

Plain `int` arithmetic wraps; fixed-width `+ - *` trap; conversions are range-checked; `//` and `%` raise `ZeroDivisionError`; keyword arguments with side effects are evaluated in source order; floats print as Python's
`repr`. A differential test runs the whole corpus on both back ends and compares output; a conformance test pins down the cases where a divergence would be a bug.

## Error propagation

A function that can raise returns a value plus a pending-exception check; every call site emits the check and jumps to the nearest handler or propagates. No unwind tables or landing pads are emitted (invariant 3). Raise
analysis (`exceptions.zig`) decides which functions need the check.

## Snapshots

`tests/golden/ir_snapshots/` stores the generated IR of every fixture. Any intended IR change is reviewed as a snapshot diff: delete the changed `.ssa` files and run the suite twice (the first run regenerates, the second
verifies). Changing the prelude renumbers class ids and so touches every snapshot.
