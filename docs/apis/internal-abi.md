# The internal runtime ABI

Underneath the three public APIs sits a fourth layer that is **not an API at all**: the interface between the code the compiler generates, the Zig runtime
and the standard library's native shims. It is documented here so contributors understand it and so nobody mistakes it for a promise.

> **Everything on this page may change in any release — including patch releases.** Never depend on it from plugins, extensions or libraries.
> Use [NNI](nni.md) and `extern def` instead.

## What is in it

- **Runtime symbols.** Generated code calls `nox_*` functions exported by the runtime (`nox_rc_alloc`, `nox_list_grow`, `nox_dict_set`, `nox_cycle_*`,
  `nox_async_spawn`, `nox_http_*`, …). These are the *fast* primitives: names, signatures and the data layouts they imply change as the compiler
  improves. Only the symbols declared in `include/nox_nni.h` are public.
- **Object layouts.** The reference-count header in front of every managed object, the packed length/ASCII header of `str`, the list header
  (length and capacity), dictionary buckets, class instances (type tag, vtable pointer, fields), closures and `Task`/`Channel` objects.
- **The runtime state.** The per-program (or per-worker) `RuntimeState`, allocator plumbing, cycle-collector tables and scheduler structures. The state is
  always threaded through generated code as a hidden first parameter — there is no hidden global state.
- **Generated symbol names.** Mangled names like `Class_method`, `tuple__int_str`, `__nox_*`, `$name__cbtramp`.
- **Intermediate representations.** The QBE `.ssa` and LLVM `.ll` text emitted by the compiler.
- **Prelude internals.** Everything in the always-merged prelude (`stdlib/nox/core.nox`) beyond its documented names.
- **Separate-compilation formats.** There is none: a program is always compiled from source as one unit. A `.o` built by one Nox version is not
  guaranteed to link with output of another.

## Why it is private

Keeping this layer private is what lets Nox change its memory management (reference-counting scheme, arenas, a nursery), its string
representation (the 2.0 `str` already carries a length and an ASCII flag), its backends and its scheduler **without** breaking any Nox program, library or
plugin. Every exposure would become a compatibility burden.

## The one deliberate exception for kernels

A freestanding runtime requires a kernel-provided allocator registered with `nox_allocator_install` ([Freestanding](../tools/freestanding.md)). That function pair
is a small, documented ABI of its own, and it is part of the same **trust boundary** as `extern def`: a wrong allocator corrupts the whole program.

## For contributors

The rules for changing this layer are in [Contributing](../internals/contributing.md) and [Runtime](../internals/runtime.md): every code-generation change must be
verified on **both** backends, snapshot-tested, and — if it touches layouts — re-run through the leak, double-free and `GeneralPurposeAllocator` safety suites.
