# Security model

Nox gives you memory safety and static typing **inside the language**. It is not a sandbox. This page states exactly where the guarantees stop, so you can decide what to trust.

## What Nox guarantees (pure Nox code)

Mandatory static types, automatic memory management (no use-after-free or double-free from Nox code), bounds-checked list and string indexing, trapping fixed-width integer overflow, checked division by zero, and no
unwind tables or ownership syntax to get wrong.

## Where the guarantees stop — the trust boundary

| Mechanism | Authority | What Nox checks |
|---|---|---|
| `extern def … from "<lib>"` | raw native code with full OS authority | type marshalling and error translation only; the native function itself is **not** constrained |
| `lowlevel` blocks | change the *allocation strategy*; `extern def` calls inside run with full native authority | types are still fully checked |
| NNI plugins (`nox.native`) and Plugin API plugins (`nox.plugin`) | a shared library with full native authority | handles are opaque and generation-checked, so a plugin never sees a pointer into Nox's heap — but it is not sandboxed; Plugin API capabilities are *consent*, not enforcement |
| HPy/CPython extensions and WASM modules | native code / WASM linear memory | opaque handles only; no raw `PyObject*` crosses; WASM is isolated to its linear memory |
| `nox_allocator_install` (freestanding) | supplies **all** heap memory | not validated — a wrong allocator corrupts the whole program |

**Dependencies.** A `nox.json` dependency may declare its own `extern def`s (and so may its transitive dependencies), and its code runs as part of your program. Adding a package means trusting its code. `nox.lock` pins the
exact commit of every dependency and `require_signed_commit` can demand a signed commit — these protect against a moved tag or branch, not against what the code does. There is no signing of packages, no audit and no capability system in 2.0
(the same trust model as npm, PyPI and crates.io).

**The registry.** noxpkg approves *metadata*; approval does not mean the code was reviewed ([noxpkg](../tools/noxpkg.md)).

## The standard library

- `nox.fs` and `nox.os` perform **no path validation**. If a path can come from an untrusted source, canonicalise it against an allowed root ([`nox.path.canonicalize`](../stdlib/path.md)) and reject anything outside before calling them.
- `nox.process` runs the program and arguments you give it with your authority; there is no shell, but never take the program name from untrusted input.
- SQL: always pass values through `Statement.bind_*`; table and column names cannot be bound and must come from your code.
- `nox.template` escapes for HTML text and quoted attributes only.
- `nox.random` is not cryptographically secure; use `nox.crypto.secure_random_hex`. SHA-1 is available for interoperability only.
- `nox.jwt.verify` checks the signature but not `exp`/`nbf`/`aud`; enforce claims yourself.
- HTTP servers cut off clients that stall while reading or writing; put a reverse proxy in front for public services and use TLS (`serve_tls`, or terminate TLS at the proxy).

## Practical guidance

1. Treat `extern def` and every dependency that contains one like a C dependency: review, pin and prefer small, audited ones.
2. Keep native calls behind a narrow Nox wrapper that validates arguments (lengths, ranges, UTF-8) before crossing the boundary.
3. Run untrusted Nox *source* only inside an OS-level sandbox (container, a separate user, seccomp) — `noxc run` executes it with your authority.
4. Load plugins only from sources you trust; declare and grant the minimum capabilities.
5. Keep secrets out of source control; read them from the environment.

## Reporting vulnerabilities

Please report security problems privately to the maintainers (see the repository's security policy and contact on GitHub) rather than in a public issue.

## Not in 2.0

Automatic sandboxing of `extern def`, package signing and a capability system each need a dedicated security design and are not added ad hoc; they are candidates for a future 2.x design.
