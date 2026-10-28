# HPy and CPython compatibility: what exists

AGENTS §10 describes a tiered target (Tier 0–3) for HPy/CPython extensions. This page states what the code does today so that no page claims more.

## What exists

- A **HPy 0.9 Universal ABI host** (`runtime/hpy_bridge/`): the `HPyContext` function table (180 `ctx_*` entries, layout pinned by `abi_dump.zig`), handles that hide object addresses (invariant 4), module loading for the `nox-hpy-host-v1` package profile, error capture per context.
- The package flow around it: `nox-hpy.json` manifest, `.nox` facade, `nox.hpy.load_package`, SHA-256 pinning, five target triples (see [HPy host v1](hpy-wasm.md)).
- A real extension fixture (`sampleext.c`, pinned digest) that runs under QBE and LLVM on five platforms.

## What does not exist

- **No CPython C-API emulation layer.** `runtime/cpython_compat/` from the AGENTS repo layout was never created. An extension built against CPython's `Python.h` cannot be loaded. NumPy and Pandas are therefore **not supported**, and no page may say they run "as is".
- Tier 1 beyond the HPy surface (PEP 3118 buffer protocol over CPython objects, number/sequence/mapping protocol emulation), Tier 2 (GC hooks, weakref, subclassing across the boundary) and Tier 3 (descriptors, metaclasses, capsules, async protocol) are not implemented as CPython emulation.

## Decision

The product target for the HPy path is **`nox-hpy-host-v1` stays a preview profile**: extensions written for HPy (not CPython) with scalar, string, `bytes` and opaque-object values. It leaves preview when (1) at least two independent HPy extensions, not written by this project, pass in CI on the five triples; (2) the context layout stays unchanged for two minor releases; (3) container values (list/tuple/dict) have an ownership contract and a real-extension test. A CPython emulation layer is not started: it needs its own design and a named first consumer, and the tier table stays a roadmap, not a claim.
