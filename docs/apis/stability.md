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
| **Host ABI v3-rc (`nox_host.h`)** | **frozen, append-only (release candidate)** — layouts, status codes `0..11`, value kinds `0..11`, dtype/capability ids and every v1/v2/v3 function signature are fixed (`_Static_assert` gate `tests/compat/host_abi/abi_layout.c`); hosts built against v1 or v2 keep working (`abi_version` 1..3). Future releases may only *append* functions, constants, capability bits and new structs. It is promoted to **v3-stable** once NoxPy phases 3–6 have validated it end to end; until then an incompatible fix is possible only for a defect that cannot be worked around, and would be announced as such in the changelog | C ABI |
| **Plugin API 1** | manifest format and `nox.plugin` semantics fixed; optional fields may be added | manifest + Nox module |
| `extern def` C-ABI type mapping | fixed | FFI |
| **Internal runtime ABI**, IR, generated symbols | **none** | — |
| Diagnostics *text* | **none** — the error *kind* is stable, the wording may improve in any release | messages |
| Performance characteristics | not a promise (they improve) | — |

## Changes to the stable surfaces since 2.0

Everything below is additive: a program, library or plugin written for 2.0 builds and runs unchanged.

| Surface | Since 2.0 |
|---|---|
| **NNI v1** | no change: `NOX_NNI_ABI_VERSION` is still 1 and `NoxApiV1` has the same members in the same order. The documentation is checked against `include/nox_nni.h` on every change (`scripts/check_docs.py`). Fuzzing found and fixed three bugs in the host side in 2.1.149; none changed the ABI. |
| **Plugin API 1** | no change to the manifest or to `nox.plugin`. |
| **Host ABI (`nox_host.h`)** | v2 → v3 (UR-008 … UR-015): classes, callbacks, async tasks, pinned buffers, typed arrays, a host allocator, capability probing and recoverable integer overflow, all additive (`NOX_HOST_ABI_VERSION` is 3; `abi_version` 1 and 2 are still accepted). Frozen as **v3-rc**; see [Host ABI](host-abi.md). The Nox-side `nox.host` module is part of the standard library and follows its source-compatibility promise only after v3-stable. |
| **NAPI (language and standard library)** | additions only: variadic and implicit-`None` functions documented, new builtins (`pow` with a modulus, `hex`, `oct`, `bin`, `int(text, base)`, `min`/`max` `default=`), new modules (`nox.lz4`, `nox.xxhash`, `nox.yyjson`, `nox.pcre2`, `nox.brotli`, and `compress` in `nox.zstd`), and the package `source` label. See [What's new in 2.2](../whatsnew/2.2.md). |
| **Platforms** | Windows x86-64 and Linux riscv64 cross-compilation from any host with `zig`; iOS and Android remain experimental. |

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

Tier 1 (tested in CI on every commit): macOS arm64, Linux x86-64, Linux arm64. Windows x86-64 runs the Debug `zig build test` corpus and end-to-end LLVM/QBE smoke tests on every commit (Release modes are not run there). See [Platforms](../reference/platforms.md).

## What this means for you

- A **program** you write against the documented language and library keeps working across 2.x.
- A **library or framework** you write against [NAPI](napi.md) does too, as long as it stays within it.
- A **native extension** built against NNI v1 keeps loading; add a [manifest](plugin-api.md) to make it self-describing.
- Do not depend on error messages, symbol names, IR, or runtime layouts.
