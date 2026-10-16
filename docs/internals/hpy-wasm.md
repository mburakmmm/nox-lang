# HPy host v1 and WebAssembly

Nox can load a native extension that was produced for the `nox-hpy-host-v1` profile. This page is the host contract. QBE and LLVM both pass the pinned fixture on macOS ARM64, macOS x64 (Rosetta), Linux ARM64, Linux x64, and Windows x64 (Wine). Each run printed `42 42 7 9 1 0 255 42`. It does not claim that a CPython extension, NumPy, or Pandas runs unchanged.

The direction is one way. An aHPy Universal module (`.hpy0`), a `nox-hpy.json` manifest, and a generated `.nox` facade are consumed by a Nox package. Nox does not load its own modules into Python, does not emit a Python package, and does not embed CPython. There is no Hybrid ABI and no native sandbox. The existing `hpy_*` builtins remain an unsafe developer door; they do not call the package loader.

## v1 surface

Profile `nox-hpy-host-v1`, HPy 0.9, Universal ABI. The required capabilities are ABI bits, not a security sandbox:

`module-open`, `module-close`, `object-close`, `call-positional`, `error-take`, `extension-object`.

Optional bits: `bytes`, `call-keywords`, `hpy-debug`, `hpy-trace`.

Value kinds: `none`, `void`, `bool`, `int64`, finite `float64`, `unicode`, and opaque objects. `bytes` is a `list[int]` of values 0–255, including embedded NULs, and is accepted only when the manifest lists `bytes`. A keyword-only parameter is `call_int_keyword(name, key, value)` and is accepted only when the manifest lists `call-keywords`. Positional entry of a keyword-only parameter is `AHPY_NOX007`. Defaults, variadic arguments, and overloads are rejected. Lists, tuples, and dictionaries stay out of this profile: their element ownership is not part of v1, and a container kind is `AHPY_NOX008` before init.

The host is 64-bit only. The five triples are `linux-aarch64`, `linux-x86_64`, `macos-aarch64`, `macos-x86_64`, and `windows-x86_64`. A 32-bit ELF, Mach-O, or PE image is `AHPY_NOX006` before `HPyInit_*`, as is an image whose format does not match the selected triple. The checked-in `sample.hpy0` is the macOS ARM64 pin. Another OS builds `sampleext.c` and rewrites that target's digest; it does not load the macOS image.

Ownership words in the manifest (`owned`, `borrowed`, `value`) are generator metadata. Nox source does not grow `owned` or `borrowed`. `nox.hpy` exposes `Module` and `Object` as ordinary values. `load_package(root)` opens a package root. `with` closes the module on scope exit, on an error, and on an early return. Closing a module closes the objects it still holds. A second close, or a use after close, raises `HPyError`. The exception's class name is the type and `.message` carries the diagnostic text (`AHPY_NOX001` through `AHPY_NOX008`).

Calls are synchronous on the calling fiber. A `Module` is not shared across operating-system threads. The error text is thread-local and is consumed once. Two runtimes do not share an `HPyContext`. Each `load_package` creates its own context and destroys it on close. An HPy `ValueError` (and the other standard types) keeps its type name and message in `HPyError.message`. The context layout is the one locked by `runtime/hpy_bridge/abi_dump.zig`; the backends do not embed a second copy.

## Package identity

`nox.json` `requires[]` stays a git identity. The native contract is `nox-hpy.json` at the dependency root. `nox.lock` may carry the schema version, aHPy version, source commit, HPy ABI, target, artifact SHA-256, and module name. An old lock that is not an HPy package still opens. An HPy package without those fields does not install. The digest is checked before the cache accepts the tree and again before `dlopen`. A missing platform artifact does not select another target. Targets are exact: `linux-aarch64`, `linux-x86_64`, `macos-aarch64`, `macos-x86_64`, `windows-x86_64`.

The artifact path is relative to the package root (the cache, or the staged copy next to the built executable). The process working directory is not a search path. `..`, a symlink, a wrong size, a wrong SHA-256, or a duplicate target fails before init. If source and a prebuilt binary are both present, the hashed binary is the one that loads. Nox does not recompile the extension. License, notice, and SBOM files are copied when they exist and are not invented. A signature is not required in v1. Build scripts do not receive a registry secret or an unrestricted loader path.

A breaking manifest needs a new schema version. An older reader rejects that version before init.

## WebAssembly

WASM remains a library import, not a compilation target. Exports go through the same opaque-handle rule as other foreign calls. `runtime/wasm_bridge/` holds the parser and the runtime glue. That bridge is not part of the `nox-hpy-host-v1` package profile.

## Host contract policy

`nox-hpy-host-v1` is the supported host profile. It is tied to HPy 0.9 Universal and to the noxc version recorded in `tests/compat/hpy_host/PIN`. A mixed pin (different noxc version, or a different evidence commit) is rejected by `evidenceAgrees`. The pin does not follow aHPy `main`.

A breaking manifest change needs a new `schema_version`. An older reader rejects that version before init. Deprecation of a profile is a new profile name, not a silent change of this one. Rollback is the previous pin commit plus its artifact digest, not a moved tag.

There is no native sandbox. An extension runs with the process's privileges. Report a host bug in the nox-lang repository. Do not treat `AHPY_NOX00N` as a security boundary.

## Troubleshooting

| Result | Meaning |
| --- | --- |
| `AHPY_NOX001` | Manifest ownership does not match the v1 rule |
| `AHPY_NOX002` | Path, symlink, hash, size, or use after close |
| `AHPY_NOX003` | Manifest shape, or the export is not declared |
| `AHPY_NOX004` | Required capability missing, or `bytes` without the bit |
| `AHPY_NOX005` | Two packages, same module name, different digest |
| `AHPY_NOX006` | Target or image is not one of the five 64-bit triples |
| `AHPY_NOX007` | Call shape: keyword-only used positionally, or the reverse |
| `AHPY_NOX008` | Type, non-finite float, bad Unicode, or a byte outside 0–255 |
| `ValueError: …` | The extension set that HPy error; the text is kept |

## Author notes

Generate the facade against `nox.hpy` only. Do not emit raw `ptr` or `hpy_*` calls into the generated user module. Do not add a reverse path that imports Nox from Python. Do not describe this profile as "CPython extensions run as-is" or as a NumPy compatibility layer. The pinned producer commit and the schema live in `tests/compat/hpy_host/`. The pin moves when aHPy commits the exporter; it does not follow a floating branch.
