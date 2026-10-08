# Ownership analysis

Nox's memory model has no user syntax; the compiler decides, per value, the cheapest safe strategy. This page describes the decision procedure and its guarantees. The user-visible summary is in [Memory](../language/memory.md).

## The pyramid

| Layer | Mechanism | Where |
|---|---|---|
| 1 | Stack allocation and ASAP destructors | `compiler/ownership/analysis.zig`, `compiler/codegen_qbe/local_escape.zig`, `inlining.zig` |
| 2 | ARC fallback | `runtime/alloc/arc.zig` |
| 3 | Cycle collector | `runtime/alloc/cycle_detector.zig` |
| 4 | `lowlevel` arenas | `runtime/alloc/lowlevel.zig` |

## Layer 1: conservative escape analysis

For every allocation the analysis asks whether the value escapes its function: stored in a field or container, returned, captured by a closure, passed to a callee that may retain it, sent to another task, or aliased. The analysis is
**conservative**: if ownership or lifetime cannot be proved, the value is promoted to ARC — silently. Promotion is never an error and never visible to the program. Outcomes:

- a small fixed-size literal list that never escapes is **stack-allocated** (within a per-frame budget);
- other non-escaping values are freed at the exact point of last use (**ASAP destructor**), with no reference count;
- everything else is reference counted.

Every ASAP decision has golden tests for both the allocation point and the release point. Foreign functions are assumed **not to retain** their arguments unless declared with `retains(...)` / `@ffi.escape`.

`noxc explain` prints the decision and reasons for each local (see [Memory](../language/memory.md#seeing-the-compilers-decisions-noxc-explain)).

## Layer 2: ARC

Reference counts are O(1) retain/release with no deep copies. Counts live in a header before the object. On the LLVM backend they are **atomic** (so objects may cross scheduler workers); on QBE, which has no atomic
instructions, they are plain and the scheduler is single-threaded. Releases of deeply linked structures use a depth-limited worklist so a long chain cannot overflow a fiber stack.

## Layer 3: the cycle collector

Only ARC-managed class instances can form cycles. The collector is a trial-deletion algorithm (Bacon–Rajan, as in Nim's ORC): decrements that do not reach zero register a candidate root; when allocation pressure
crosses a threshold (and at exit) the candidates' subgraphs are scanned. Classes that cannot be part of a cycle (decided from the class graph) skip registration entirely. Under the multi-core scheduler the scan runs
inside a stop-the-world barrier.

## Layer 4: `lowlevel`

A `lowlevel` block gets an arena; heap values created inside belong to it and must not escape (checked at code generation). Typing is unchanged.

## Testing requirements

Any ownership change needs: golden tests for allocation and release points; a leak test and a double-free test; the debug allocator ("GeneralPurposeAllocator in safety mode") green; and, if reference counting is
touched, the concurrency torture suites.
