# The three APIs

Nox deliberately separates **what you may build on** from **what the compiler and runtime may change**. There are three public, versioned
APIs, each aimed at a different kind of author, and one private layer underneath that is never a compatibility promise.

```text
Nox 2.x
├── NAPI  — the Nox API                  source-level contract for libraries and frameworks written in Nox
├── NNI   — the Nox Native Interface     C ABI + opaque handles for native extensions (C, C++, Rust, Zig)
├── Plugin API                           manifests, versioning and capability consent, layered on NNI
└── Internal runtime ABI                 compiler ↔ runtime ↔ stdlib shims — PRIVATE, unstable
```

| API | You are… | You write | Stability promise |
|---|---|---|---|
| [**NAPI**](napi.md) | writing a library or framework in Nox (a web framework, an ORM, a CLI toolkit) | `.nox` source | source compatibility for the whole 2.x series |
| [**NNI**](nni.md) | writing native code that Nox programs call and that must not depend on runtime internals | C, C++, Rust or Zig against `nox_nni.h` | binary compatibility: a plugin built against NNI v1 loads in every Nox that implements v1 |
| [**Plugin API**](plugin-api.md) | shipping or consuming a native plugin as a *product* — with a name, a version, declared functions and capabilities | a `nox-plugin.json` manifest next to an NNI library | manifest format and `nox.plugin` semantics are stable within `plugin_api: 1` |
| [Internal ABI](internal-abi.md) | contributing to the compiler/runtime | Zig | **none** — may change in any release |

The single hard rule: **the public interfaces and the internal runtime ABI must never be confused.** The layout of reference-counted objects,
the runtime state, string/list/dictionary/class memory layouts, generated symbol names and every `nox_*` runtime symbol that is not part of NNI
are internal.

## Which API do I use?

- *"I want a reusable Nox library."* — just write Nox. Follow the [NAPI](napi.md) contract and the [package](../tools/packages.md) workflow.
- *"I need to call a C library I already have."* — [`extern def`](../language/ffi.md). No plugin needed.
- *"I am writing a native extension that Nox users should install and call safely, possibly from several Nox versions."* — NNI
  ([guide](nni-guide.md)), packaged with the [Plugin API](plugin-api.md).
- *"I want to run a Python C extension or a WebAssembly module."* — the HPy/WASM bridges ([Internals](../internals/hpy-wasm.md)).

## How they compose

A plugin author writes an NNI library, adds a `nox-plugin.json`, and ships both. A Nox program loads it with `nox.plugin.load_plugin(manifest,
allowed_capabilities)`, which reads the manifest, checks the API version and the platform, asks the user's code for consent to the declared
capabilities, loads the library through NNI, and verifies that the functions the library registered are exactly the ones the manifest declares.
Calls then go through typed wrappers that check argument types against the manifest before any native code runs.

A framework written in Nox (NAPI) can build on any of these: it consumes plugins for native engines, uses `nox.reflect` for decorators, and
exposes its own stable Nox API to its users.

## Trust

All three public APIs that involve native code — `extern def`, NNI and plugins — run native code with **full process authority**. The Plugin
API's capabilities are a consent and declaration mechanism, not a sandbox. See [Security](../reference/security.md).

## Versioning at a glance

| Thing | Version | Where it lives |
|---|---|---|
| Nox language / NAPI | the Nox release (`2.x.y`), semantic versioning | `build.zig.zon`, [Versioning](../reference/versioning.md) |
| NNI | `NOX_NNI_ABI_VERSION` (currently `1`); members only ever appended to `NoxApiV1` | `include/nox_nni.h` |
| Plugin API | `plugin_api` in the manifest (currently `1`) | `nox.plugin.PLUGIN_API_VERSION` |
| Internal ABI | none | — |

See [Stability and compatibility](stability.md) for the full matrix and deprecation policy.
