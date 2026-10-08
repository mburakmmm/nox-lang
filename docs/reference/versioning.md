# Versioning and stability policy

This is the long-form policy; [Stability and compatibility](../apis/stability.md) summarises it as a matrix.

## Version numbers

Nox follows [Semantic Versioning 2.0.0](https://semver.org): `MAJOR.MINOR.PATCH`.

- **MAJOR** (`X.0.0`) — may contain incompatible changes (see "What counts as a major change").
- **MINOR** (`x.Y.0`) — adds backward-compatible functionality: new syntax, a new standard-library module or function, a new CLI subcommand. No previously valid `.nox` source breaks.
- **PATCH** (`x.y.Z`) — bug fixes, performance and documentation. No correct program's observable behaviour changes.

Pre-release versions (`2.0.0-rc.1`) carry no compatibility promise.

## The source-compatibility guarantee

Within one MAJOR version, a valid `.nox` program that builds and runs under `X.0.0` builds and behaves the same under every later `X.Y.Z`. This covers the language syntax and semantics (the set of programs the checker accepts never shrinks),
the signatures and documented behaviour of the standard library, the `nox.json`/`nox.lock` formats and the existing behaviour of `noxc` subcommands.

### What is not covered

- **The internal runtime ABI** — `noxrt.o`, `nox_*` symbols, reference-count headers, object layouts, QBE/LLVM IR. A Nox program is always rebuilt from source; separately compiled Nox objects of different versions are not guaranteed to link.
  **Exceptions, stable from 2.0:** the [Nox Native Interface](../apis/nni.md) (`include/nox_nni.h`), the Plugin API manifest, and the documented `extern def` C-ABI mapping.
- **The text of diagnostics.** An error's *kind* (for example `TypeMismatch`) is stable; its wording may improve in any release. Tools must use `noxc`'s exit status, never parse messages.
- **The format of `--dump`/`-v` output**, `noxc explain` and similar developer tools.
- **Third-party packages.** A package's own API stability is its author's responsibility; `nox.lock` guarantees reproducible builds regardless.
- **The Zig toolchain version** needed to *build* the compiler.

## Standard-library classes that frameworks construct

Classes that frameworks and tests construct directly (`HttpRequest`, `HttpResponse`, `Row`, `Statement`, `Context`, …) keep their existing constructor parameters for the whole major version. New parameters are added only **with default
values**, and fields are only added, never removed or renamed. The same holds for objects the runtime constructs and hands to your code.

## Deprecation

A feature or function is marked deprecated (in the reference and the changelog) for **at least one MINOR release** before removal, and removed only in the next MAJOR release. A feature deprecated in 1.3 can disappear in 2.0 at the earliest and never in any 1.x.
2.0.0 removed the names deprecated during 1.x ([Migrating](../whatsnew/migrating.md)).

## What counts as a major change

Anything that makes a previously valid program fail to compile or behave differently: removing or renaming a public name, narrowing a type, changing evaluation order or numeric semantics, tightening a rule so that accepted programs are rejected.
Fixing a documented-incorrect behaviour that no correct program could rely on is a patch.

## "Every commit is a release"

From 1.0 on, every commit on `main` is a version: it bumps `build.zig.zon`, adds a `CHANGELOG.md` entry, is tagged `vX.Y.Z` and published once CI is green on that commit ([Releasing](../internals/releasing.md)). A published version is never altered or deleted — a
mistake is fixed by a new PATCH release.

## Supported versions

The newest release of the latest MAJOR (and the latest MINOR of the previous MAJOR for security fixes, once there is one) is supported. `noxc upgrade` moves you to the newest stable release.
