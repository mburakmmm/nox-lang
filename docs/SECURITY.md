# Nox security model (2.0)

Nox gives you memory safety and static typing **inside the language**. It is not a sandbox. This page states exactly where the
guarantees stop, so you can decide what to trust.

## What Nox guarantees (pure Nox code)

Mandatory static types, automatic memory management (no use-after-free / double-free from Nox code), bounds-checked list/string
indexing, fixed-width integer overflow traps, checked division by zero, no unwind tables, and no ownership syntax to get wrong.

## Where the guarantees stop — the trust boundary

| Mechanism | Authority | Nox's checks |
|---|---|---|
| `extern def … from "<lib>"` | Raw native code, full OS authority | Type-marshalling and error translation only; the native function itself is **not** constrained or sandboxed |
| `lowlevel` blocks | Changes the *allocation strategy* (arena/pool); `extern def` calls inside run with full native authority | Types still fully checked |
| NNI plugins (`nox.native`, `include/nox_nni.h`) | Shared library with full native authority | Handles are opaque and generation-checked; a plugin never sees a pointer into Nox's heap, but it is not sandboxed |
| HPy/CPython extensions, WASM modules | Native code / WASM linear memory | Opaque handles only; no raw `PyObject*` crosses the boundary; WASM is isolated to its linear memory |
| `nox_allocator_install` (freestanding) | Supplies **all** heap memory | Not validated — a wrong allocator corrupts the whole program |

**Dependencies.** A `nox.json` dependency may declare its own `extern def`s (and so can its transitive dependencies). Adding a
package means trusting its native code. `nox.lock` pins the exact commit (SHA) of every dependency and `noxc` verifies it, which
protects against a moved tag or branch — it does **not** audit, sign, or sandbox what the code does. There is no capability system
yet (the trust model is the same as npm / PyPI / crates.io).

**Standard library.** `nox.fs` / `nox.os` do not validate paths. If a path can come from a user or the network, canonicalise it
against an allowed root and reject `..` yourself before calling them.

## Practical guidance

1. Treat `extern def` and every dependency that contains one like a C dependency: review it, pin it, and prefer small, audited ones.
2. Keep native calls behind a narrow Nox wrapper that validates arguments (lengths, ranges, UTF-8) before crossing the boundary.
3. Run untrusted Nox *source* only inside an OS-level sandbox (container, seccomp, a separate user) — `noxc run` executes it with
   your authority.
4. Report vulnerabilities privately to the maintainers (see the repository's security contact) rather than in a public issue.

## Not planned for 2.0

Automatic sandboxing of `extern def`, package signing, and a capability system each need a dedicated security design and will not be
added ad hoc (AGENTS.md §9.5). They are candidates for a future 2.x design.

See also: [NATIVE-API.md](NATIVE-API.md) (NNI), [`AGENTS.md`](../AGENTS.md) §9.5 (Turkish, authoritative).
