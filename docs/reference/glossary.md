# Glossary

**ARC** — automatic reference counting. Layer 2 of the memory model: a value carries a count of its owners and is freed when the count reaches zero.

**ASAP destructor** — "as soon as possible": cleanup code inserted at the point after a value's last use, with no reference count. Layer 1 of the memory model.

**Backend** — the part of the compiler that turns typed IR into machine code: LLVM (default) or QBE.

**Capability** — a named kind of authority (`filesystem`, `network`, `threads`, …) a standard-library module or a plugin needs; the freestanding profile permits only capability-free modules, and the Plugin API uses capabilities for consent.

**Closure** — a function value together with the variables it captured from its enclosing function.

**Cycle collector** — the component that frees groups of objects that reference each other, which reference counting alone cannot.

**Dunder (special) method** — a method such as `__add__` or `__str__` whose name gives an operator or protocol meaning for a class.

**`extern def`** — a declaration of a function implemented in native code, callable from Nox.

**Fiber** — a lightweight stack-switching unit of execution; a task runs on one.

**Fixed-width integer** — `u8`, `i32`, `u64`, … : integers of a given size that trap on overflow and never convert implicitly.

**Freestanding** — a build with no operating system: a kernel-provided allocator and only capability-free modules.

**Golden test** — a test whose expected output (or generated IR) is stored in a file and compared byte for byte.

**Handle** — an opaque identifier that stands for a resource without exposing its address; NNI, the HPy bridge and the WASM bridge use handles at their boundaries.

**HPy** — a handle-based API for Python C extensions; Nox implements a compatible layer.

**LLVM / QBE** — the two compilation back ends. LLVM generates faster code and runs tasks in parallel; QBE is small and supports cross-compilation and debug info.

**`lowlevel`** — a block that allocates from an arena and permits raw pointers; typing stays mandatory.

**M:N scheduler** — many tasks (M) multiplexed over a pool of operating-system threads (N), with work stealing.

**Monomorphisation** — compiling a separate specialised copy of generic code for each concrete type it is used with.

**NAPI** — the Nox API: the source-level contract for libraries and frameworks.

**NNI** — the Nox Native Interface: the stable C ABI for native extensions.

**noxpkg** — the central package index and its web service.

**Plugin API** — manifests, versioning and capability consent layered on NNI.

**Prelude** — the names available without an import (`print`, `len`, `Exception`, …).

**Protocol** — a structural interface: any class with the required methods satisfies it, with no declaration.

**Task** — a unit of concurrent work started with `spawn`; `Task[T]` yields a `T` when awaited.

**Trampoline** — a generated function at a foreign boundary that converts values and translates errors.

**Trust boundary** — the line at which Nox's type and memory guarantees stop (`extern def`, `lowlevel`, plugins, dependencies with native code).
