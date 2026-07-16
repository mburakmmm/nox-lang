# Nox

*[Türkçe](README.md) | English*

Nox is a fully **AOT (Ahead-of-Time) compiled** language that combines
Python's syntactic familiarity with the performance and determinism of
systems programming languages. No interpreter, no GC pauses — it uses a
[QBE](https://c9x.me/compile/)-based compiler backend and a lightweight
runtime written in Zig.

> **`v1.0.0` has been released and tagged** — every phase (Q–Z) of the
> production-readiness roadmap in `docs/uretim-hazirlik-analizi.md` is
> complete; see [`nox-teknik-spesifikasyon.md` §3.43](nox-teknik-spesifikasyon.md)
> (the concrete "done" definition) and [`VERSIONING.md`](VERSIONING.md)
> (semver policy + stability guarantee). **The `main` branch is currently
> under active development towards `v1.1.0`** (`noxc --version` reports
> this correctly) — see the `[Unreleased]` section of
> [`CHANGELOG.md`](CHANGELOG.md) for changes not yet released. See
> [Contributing](CONTRIBUTING.en.md) to contribute.
>
> The technical specification (`nox-teknik-spesifikasyon.md`) is Nox's
> full design history and rationale, written in Turkish as an ongoing
> engineering log across every development phase — it stays Turkish by
> design. For an English-language reference to the language itself
> (syntax, type system, memory model), see
> [`docs/LANGUAGE.md`](docs/LANGUAGE.md).

```nox
class Counter:
    def __init__(self, start: int) -> None:
        self.value = start

    def increment(self) -> None:
        self.value = self.value + 1

c: Counter = Counter(0)
i: int = 0
while i < 5:
    c.increment()
    i = i + 1
print(c.value)
```

## Why Nox?

- **Mandatory static typing** with Python-like syntax (unlike Mojo's
  gradual-typing approach).
- **AOT compilation directly to native code via QBE** — no LLVM/MLIR
  dependency.
- **A layered, mostly invisible memory model** (the "Ownership Pyramid"):
  the compiler emits zero-cost ASAP destructors whenever possible, and
  falls back to ARC (reference counting) when ownership is ambiguous —
  no explicit ownership syntax is ever exposed to the user.
- **An HPy-inspired C extension model** and an embedded WASM runtime (for
  importing as a library).
- **A Go-style fiber/cooperative async runtime** (`spawn`/`await`,
  `Task`/`Channel`) plus real concurrent I/O (a kqueue/epoll-based
  reactor).
- **Shared-nothing, multi-core thread support** (`nox.thread`) — real OS
  threads (`ThreadHandle[T]`/`.join()`), each with its own independent
  fiber runtime, and continuous, bidirectional communication between them
  (`ThreadChannel[T]`), delivering real parallelism beyond a single OS
  core.
- A growing standard library (`nox.http`, `nox.json`, `nox.strings`,
  `nox.math`, `nox.os`/`nox.fs`, `nox.time`, `nox.test`) and a Go-style
  decentralized (GitHub-URL-based) package system.

For the full record of architectural/design decisions, see
[`nox-teknik-spesifikasyon.md`](nox-teknik-spesifikasyon.md) (Turkish).

## Installation

### Prebuilt (recommended)

A one-line install for macOS (Apple Silicon) and Linux (x86-64/aarch64)
— includes `noxc`/`noxlsp`, the runtime, the `nox.*` stdlib, and an
embedded `qbe` (only a C compiler — `cc` — needs to be present on the
system, for linking):

```sh
curl -fsSL https://raw.githubusercontent.com/mburakmmm/nox-lang/main/install.sh | sh
```

See the `NOX_VERSION`/`NOX_INSTALL_DIR` environment variables to install
a specific version or change the install root (see
[`install.sh`](install.sh)). Verify with `noxc --version`.

### Building from source

For contributors, or users on an unsupported platform (e.g. an Intel
Mac). Requirements: [Zig 0.16](https://ziglang.org/download/) and
[QBE](https://c9x.me/compile/) (`brew install qbe` / build from source).

```sh
git clone https://github.com/mburakmmm/nox-lang.git
cd nox-lang
zig build            # installs zig-out/bin/noxc + zig-out/lib/{noxrt.o,nox/stdlib/}
zig build test        # runs the full test suite (unit + golden + end-to-end)
```

`noxc` locates its stdlib/runtime files relative to its own executable's
location (`<exe_dir>/../lib/...`) — you can add `zig-out/bin/noxc` to
your `PATH` and run it from outside the project root as well. If you use
a different install layout, you can override this root with the
`NOX_RESOURCE_DIR` environment variable (a **separate** setting from
`NOX_HOME`, which is the root of the third-party package cache).

## Usage

```sh
noxc init myproject         # scaffolds a new project (nox.json + main.nox)
noxc check main.nox         # type-checking only — no codegen/qbe/cc, fast feedback
noxc build main.nox         # compiles main.nox, produces the "main" binary
noxc run main.nox -- a b c  # compiles + runs, forwarding argv
noxc test                   # discovers and runs all *_test.nox files under the CWD
noxc fetch                  # populates the dependency cache from nox.json
noxc update                 # re-resolves dependencies to their latest refs, updates nox.lock
```

If a project needs one or more third-party dependencies, define a
`nox.json` at the project root:

```json
{
  "name": "myproject",
  "entry": "main.nox",
  "requires": [
    { "alias": "somepkg", "repo": "github.com/someuser/somepkg", "ref": "v1.2.3" }
  ]
}
```

```nox
import somepkg.util
import nox.http

print(somepkg.util.parse("..."))
```

`noxc build`/`run`/`test` resolve `requires[]` and lock it into
`nox.lock` (committed to VCS) — for reproducible builds, everything runs
fully offline after the first resolution.

## Benchmarks

`zig build bench -Doptimize=ReleaseFast` — see
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) for the full, raw
output (Turkish). Three categories, summarized in the collapsible
sections below: **language fundamentals** (vs. Python/C), **stdlib**
(JSON/strings/math/fs/time/dict), and **HTTP throughput**
(Nox/Go/Zig/FastAPI).

<details>
<summary><strong>Language fundamentals — vs. Python/C (10 scenarios, identical algorithm)</strong></summary>

| Benchmark | Nox | Python | C | Nox / Python | Nox / C |
|---|---|---|---|---|---|
| numeric_recursion | 15.3ms | 377.2ms | 14.0ms | **24.7x faster** | 1.10x slower |
| tight_loop_arithmetic | 14.4ms | 1759.6ms | 4.8ms | **122.4x faster** | 2.97x slower |
| list_traversal | 63.3ms | 1289.4ms | 3.1ms | **20.4x faster** | 20.09x slower |
| oop_arc_churn | 36.0ms | 475.4ms | 44.8ms | **13.2x faster** | 0.80x (Nox faster than C) |
| generics_protocols | 61.2ms | 1573.8ms | 26.0ms | **25.7x faster** | 2.35x slower |
| exceptions_control_flow | 21.0ms | 673.0ms | 5.9ms | **32.0x faster** | 3.57x slower |
| lowlevel_arena | 63.3ms | 1323.1ms | 5.0ms | **20.9x faster** | 12.65x slower |
| string_passing | 72.9ms | 1241.2ms | 8.9ms | **17.0x faster** | 8.17x slower |
| deep_equality | 7.1ms | 51.7ms | 3.3ms | **7.3x faster** | 2.19x slower |
| list_class_field | 6.1ms | 49.5ms | 4.3ms | **8.2x faster** | 1.43x slower |

**Summary:** **7x–122x faster** than Python in every scenario; generally
**1x–4x slower** than C (very close to C on arithmetic/OOP-heavy code,
even faster than C on `oop_arc_churn` — memory-access-heavy scenarios
like list traversal show a bigger gap, 12x-20x). See
[`benchmarks/compare/`](benchmarks/compare/) for the methodology and the
C/Python source files.
</details>

<details>
<summary><strong>Stdlib — JSON/strings/math/fs/time/dict (Nox only, large N — regression/stress test)</strong></summary>

| Benchmark | Time (min) |
|---|---|
| json_bench | 17.8ms |
| strings_bench | 5.6ms |
| math_bench | 4.0ms |
| os_fs_bench | 2.9ms |
| time_bench | 5.9ms |
| dict_bench | 2.8ms |
| strings_perf_bench (`byte_at` + O(n) `join`, Phase EE.1) | 200.0ms |

`strings_perf_bench` measures two Phase EE.1 optimizations together (an
alloc-free `byte_at`-based comparison + a single-pass O(n) `join` in
Zig) — when temporarily reverted to the old behavior (`s[i]`-based
allocating comparison + a pure-Nox O(n²) `join`) and re-measured:
**6040ms → 200ms, a ~30x speedup** (output values byte-for-byte
identical in both cases). Also Phase M.8 (exception-check elision for
provably-safe method calls): **480ms → 270ms, a ~44% speedup** (300M
method calls). See [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) for
the full methodology.
</details>

<details>
<summary><strong>HTTP throughput — Nox / Go / Zig / FastAPI (via <code>wrk</code>)</strong></summary>

Four servers (`benchmarks/http_compare/`) all produce the identical
response (status 200, header `x: x`, body `"ok"`), each using 10
threads/processes, measured with `wrk` (Apple M4, 10 cores — see
`benchmarks/http_compare/run_compare.sh` for reproducibility).

| Server | Moderate concurrency (c=30) | High concurrency (c=100) |
|---|---|---|
| Nox (`serve_multicore`, N=10) | **20,562** req/s | 12,859 req/s |
| Zig (raw `std.c` sockets, N=10 threads) | 14,743 req/s | 10,866 req/s |
| Go (`net/http`, default keep-alive) | 191,244 req/s | **195,110** req/s |
| FastAPI (`uvicorn --workers 10`) | 22,142 req/s | 23,994 req/s |

Nox beats the raw Zig socket baseline at both levels. Go's large lead is
because keep-alive (unlike Nox/Zig's `Connection: close` design)
eliminates TCP handshake cost per request — this reflects the real,
measurable cost of `nox.http.serve` not yet supporting keep-alive, not a
difference in raw request-processing speed. See "Bölüm 3" in
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) (Turkish) for the full
methodology, including how this section's *first* published version was
wrong (a Debug-mode runtime link + a misconfigured `max_connections`
setting in the benchmark itself) and how it was corrected.
</details>

## Security

`extern def`/`lowlevel` grant the authority to run raw native code —
outside Nox's type/ownership guarantees, with no sandboxing or
validation. Adding a `nox.json` dependency means trusting the native code
that package (and its transitive dependencies) declares via `extern
def`. Stdlib modules like `nox.fs`/`nox.os` also perform no path/input
validation (e.g. `nox.fs` is not protected against path traversal). See
[AGENTS.md §9.5](AGENTS.md#95-güven-sınırı-trust-boundary--extern-def--lowlevel)
for details (Turkish).

## Project Structure

| Directory | Contents |
|---|---|
| `compiler/` | Lexer → parser → checker → ownership analysis → QBE codegen |
| `runtime/` | Runtime written in Zig (ARC, async fibers, HPy/WASM bridges, stdlib shims) |
| `stdlib/` | The standard library, written in Nox itself (`nox.*`) |
| `tests/` | Unit + golden + end-to-end (CLI subprocess) tests |
| `benchmarks/` | Nox/Python/C/Go/Zig/FastAPI comparative benchmark suite |
| `docs/` | Production-readiness analysis, roadmap, and the English language reference |

## Contributing

See [CONTRIBUTING.en.md](CONTRIBUTING.en.md).

## Versioning

For the semver policy + language/ABI stability guarantee effective from
`v1.0.0` onward, see [VERSIONING.md](VERSIONING.md).

## License

[MIT](LICENSE).
