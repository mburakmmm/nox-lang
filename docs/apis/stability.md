# Stability and compatibility

This page is the single compatibility matrix for Nox 2.x. The long-form policy is in [Versioning](../reference/versioning.md).

## The promise

| Surface | Promise within 2.x | Granularity |
|---|---|---|
| Language semantics ([reference](../language/index.md)) | source compatibility | every documented behaviour |
| Public standard library ([reference](../stdlib/index.md)) | source compatibility; signatures and documented behaviour do not change; new parameters only with defaults | every documented name |
| `nox.reflect` | source compatibility | the whole module |
| `nox.json` manifest, `nox.lock` format | compatible; new optional fields may be added | file formats |
| `noxc` subcommands and documented flags | existing behaviour kept; new flags may be added | CLI |
| **NNI v1** | **binary compatibility** — a plugin built against NNI v1 loads on every Nox implementing NNI v1; members are only appended to `NoxApiV1` | C ABI |
| **Plugin API 1** | manifest format and `nox.plugin` semantics fixed; optional fields may be added | manifest + Nox module |
| `extern def` C-ABI type mapping | fixed | FFI |
| **Internal runtime ABI**, IR, generated symbols | **none** | — |
| Diagnostics *text* | **none** — the error *kind* is stable, the wording may improve in any release | messages |
| Performance characteristics | not a promise (they improve) | — |

## What a release number means

`MAJOR.MINOR.PATCH`:

- **PATCH** — bug fixes, performance work, documentation. Never breaks a valid program.
- **MINOR** — new features, new standard-library modules or functions, new flags. Never breaks a valid program; a name may be *deprecated* (kept working,
  documented as deprecated).
- **MAJOR** — the only place something deprecated may be removed or semantics may change. 2.0.0 is such a release; its changes are listed in
  [Migrating from 1.x](../whatsnew/migrating.md).

Pre-releases (`2.0.0-rc.1`) carry no promise.

## Deprecation

A deprecated name stays functional for **at least one MINOR release**, is marked in the reference and the changelog, and is removed no earlier than the
next MAJOR release. Security fixes may take effect immediately.

## Backends

LLVM and QBE are two implementations of one language. Both are tested against the entire golden corpus and **must agree on program output**
(including integer overflow behaviour and keyword-argument evaluation order). Differences are limited to speed, to the scheduler (parallel under LLVM,
single-threaded under QBE) and to the argument/result types allowed for `spawn`; correct programs do not depend on them.

## Platforms

Tier 1 (tested in CI on every commit): macOS arm64, Linux x86-64, Linux arm64. Windows x86-64 builds and is smoke-tested end to end. See [Platforms](../reference/platforms.md).

## What this means for you

- A **program** you write against the documented language and library keeps working across 2.x.
- A **library or framework** you write against [NAPI](napi.md) does too, as long as it stays within it.
- A **native extension** built against NNI v1 keeps loading; add a [manifest](plugin-api.md) to make it self-describing.
- Do not depend on error messages, symbol names, IR, or runtime layouts.
