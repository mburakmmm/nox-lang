# NAPI — the Nox API

NAPI is the contract between the Nox language/standard library and the people who build **libraries and frameworks in Nox**: web frameworks,
ORMs, test runners, CLI toolkits, dependency-injection containers. It answers one question precisely: *what may I rely on staying the same
across Nox 2.x releases?*

The promise is **source compatibility**: Nox source that compiles and behaves correctly on Nox 2.0 keeps compiling and behaving the same on every
2.x release. Nothing in NAPI is a binary promise — Nox programs are always compiled from source as one unit.

## What is stable

### Language semantics

Everything in the [language reference](../language/index.md) is part of NAPI: typing rules, scoping, evaluation order (arguments are evaluated left to
right as written), integer behaviour (plain `int` wraps; fixed-width integers trap on overflow, identically on both backends), the special-method
protocol, the exception hierarchy and `try`/`finally`/`with`/`defer`/`break`/`continue` cleanup order, structural protocols, generics and
monomorphisation, closures, `async`/`spawn`/`await` semantics and cooperative cancellation.

Compiler *diagnostics text* is not covered (only the error *kind* is stable): do not parse messages.

### The public standard library

The names, signatures and documented behaviour of the `nox.*` modules in the [standard library reference](../stdlib/index.md). Excluded:

- names beginning with `__nox_` and the contents of the prelude beyond its documented names,
- anything the reference marks *experimental* or *deprecated*.

**Constructor freeze.** Classes that frameworks construct directly — `HttpRequest`, `HttpResponse`, `Row`, `Statement` and similar — keep their
existing constructor parameters for the whole major version; new parameters are only ever added **with default values**, and fields are only
added, never removed or renamed. The same holds for objects the runtime constructs and hands to your code (for example the `HttpRequest` given to a
`serve` handler).

### Reflection for decorators

`nox.reflect` — the metadata API behind `@decorator` syntax ([Decorators](../language/decorators.md)) — including class `__init__` signatures,
method records and `decorator_handler`. The *meaning* of a decorator is always yours.

### Concurrency

`Task[T]`, `Channel[T]`, `TaskLocal[T]`, `ThreadHandle[T]`, `ThreadChannel[T]`, `spawn`/`await`, `CancelledError`, and the rule that tasks are correct
under both the single-threaded and the multi-core scheduler. Which scheduler runs your tasks is *not* part of the contract.

### HTTP

`nox.http` client and server abstractions, `HttpRequest`/`HttpResponse` fields and constructors, `nox.router` (routes, path parameters, middleware),
the serve entry points and their argument order.

### Foreign functions

The `extern def` C-ABI type mapping and the `@ffi.callback` trailing-`userdata` convention ([Foreign functions](../language/ffi.md)).

### Packages

The `nox.json` manifest, the `nox.lock` format and `requires[]` resolution ([Packages](../tools/packages.md)).

### Native extensions

NNI v1 ([NNI](nni.md)) and the Plugin API ([Plugin API](plugin-api.md)) are covered by their own, stronger (binary) promises.

## What is *not* stable

AST and compiler internals · QBE and LLVM IR output · reference-count header layout · object, list, dictionary and string layouts · the runtime
state · the cycle-collector implementation · generated symbol names (`Class_method`, `tuple__int_str`, `__nox_*`) · every `nox_*` runtime
symbol that is not part of NNI · **binary compatibility between separately compiled Nox object files**.

## Guidance for framework authors

1. **Depend on source features.** Generics (including higher-order generics), callbacks and closures, decorators plus `nox.reflect`, allocator-independent
   collections and the task scheduler are all you need. Prefer the narrow modules (`nox.mem`, `nox.atomic`, `nox.thread`, `nox.fs`, `nox.os`,
   `nox.reflect`) over reaching toward runtime symbols.
2. **Treat module state as per-worker.** Under the multi-core scheduler each worker keeps its own copy of module-level variables; share data with
   channels, `nox.atomic` or `nox.sharedmem` ([Concurrency](../language/concurrency.md)).
3. **Pin and test against both backends.** The default backend is LLVM with a parallel scheduler; QBE is single-threaded. A framework should be correct
   under both (`noxc build --backend qbe`).
4. **Never parse diagnostics; branch on exception classes.**
5. **Gate native code behind the Plugin API** so users can see and consent to what your framework loads.
6. **Pin Nox in CI.** Declare the Nox version you test with; the stability promise is per *major* version.

## Deprecation policy

A name is deprecated for at least one MINOR release (with a note in the reference and the changelog) before it can be removed, and removal only happens in
the next MAJOR release. Removed in 2.0: the deprecated aliases listed in [Migrating from 1.x](../whatsnew/migrating.md). See
[Versioning](../reference/versioning.md).
