# Testing internals

Nox is tested far more heavily than a typical language implementation of its size: roughly 1,200 tests in 180 build steps, plus opt-in stress suites. This page maps them.

## Running them

```sh
zig build test --summary all                 # the whole default suite (a few minutes)
zig build test --summary all > out.txt 2>&1  # and read the output before committing
```

The default `zig build test` is the gate every change must pass. After intentionally changing code generation, run it **twice**: the first run regenerates changed IR snapshots, the second verifies them.

## Suites

| Suite | Location | What it proves |
|---|---|---|
| Unit tests | `test` blocks next to the Zig code | each runtime/compiler function (with leak/double-free detection) |
| Typecheck goldens | `tests/golden/typecheck_cases/` + `typecheck_golden_test.zig` | the checker accepts valid programs and rejects invalid ones with the expected error kind |
| Codegen goldens | `tests/golden/codegen_cases/*.nox` + `.expected`, registered in `fixture_corpus.zig` | source → program output, **on both back ends** |
| IR snapshots | `tests/golden/ir_snapshots/` | byte-exact generated IR per fixture |
| Ownership goldens | `tests/golden/ownership_cases/` | the escape/allocation decisions |
| Formatter goldens | `tests/golden/fmt_cases/` | the formatter's output and idempotence |
| Conformance | `backend_conformance_test.zig`, `conformance_cases/` | both back ends agree on tricky semantics (overflow, evaluation order, …) |
| Differential corpus | `backend_differential_corpus_test.zig` (`zig build backend-differential-corpus-test`) | the *entire* fixture corpus produces identical output on LLVM and QBE |
| Compat | `tests/compat/` | real C, Zig, WASM and NNI extensions; real HTTP/TLS/WebSocket servers over sockets |
| CLI | `tests/cli/` | the `noxc` binary as a subprocess: subcommands, packages, install, upgrade, backends, plugins |
| Fuzz | `tests/fuzz/` | the lexer, parser and checker never crash on random input; the WASM parser likewise |
| Freestanding | `freestanding_*_test.zig`, `kernel_boot_x86_64_test.zig` | the kernel path, including booting a real image in QEMU |
| Docs | `scripts/check_docs.py` | every code block in these docs compiles and its output matches |

## Opt-in, slow suites

| Step | What it does |
|---|---|
| `zig build stress-test` | many rounds of cross-worker channel/task stress |
| `zig build concurrency-torture-test`, `concurrency-torture2-test` | seed-driven concurrency torture including thread channels and list transfers |
| `zig build http-soak-test` | a multi-core and TLS server under sustained load |
| `zig build worker-pool-test`, `async-rt-test` | the scheduler in isolation (the latter also runs on Windows CI) |
| `zig build backend-differential-corpus-test` | the full two-back-end comparison |

These run in a separate workflow and in the release gate.

## Writing a test for a change

1. A language feature: add a `.nox` fixture plus `.expected` under `codegen_cases/` and register it (the corpus runs it on both back ends); add typecheck goldens for each new error.
2. A memory change: a leak test and a double-free test, with the debug allocator on.
3. An error-handling change: success path, failure path and a `finally`/`with` interaction.
4. A foreign-code change: a test against a real extension in `tests/compat`.
5. A standard-library change: a fixture, and the page in these docs with a checked example.

A feature without a golden test is not accepted.

## What the tests have found

The most valuable bugs were found by writing real programs, not by unit tests: `for` over module-level lists, a router that ignored query strings, integer power computed through floating point, spawn statements that leaked their handle,
`int()` of fixed-width values, `print(None)`, `return` inside `with`. This documentation is itself a test: writing and running every example found several of them, which is why `check_docs.py` is part of the process.

## Performance regression gate

`benchmarks/gate.py` runs the core-language kernels (`benchmarks/lang_perf`) and the two standard-library suites (`benchmarks/stdlib_perf`, 39 jobs) and compares them with a checked-in baseline. Install a release build first (`zig build -Doptimize=ReleaseFast`; a Debug runtime is about 100 times slower, and a full `zig build test` leaves `zig-out` in Debug).

```sh
benchmarks/gate.py --check            # exit status 1 if a job is more than 35% slower than the baseline
benchmarks/gate.py --update           # rewrite benchmarks/baseline.json (review the diff before committing)
```

The baseline is machine independent where it can be: a job that has a C reference (`stdlib_perf*.c`, compiled with `clang -O2`) is stored as the Nox/C ratio, the others as milliseconds, which only mean something on the same machine. The gate also fails any job that is more than 40 times slower than its C reference. Jobs under 1 ms are treated as noise.

## Front-end diagnostics and the differential runner (noxc-nightly)

Two hidden developer commands print the front end's output in a stable form: `noxc tokens [--json] <file>` (one line per token: `line:col kind start-end "lexeme"`, or `ERROR <name> line:col` with exit code 1 on a lexical error) and `noxc ast <file>` (parse only, then the AST dump that `build --dump` prints). They are not in the help screen.

`scripts/frontend_diff.py` runs a Zig and a Nox front-end component over every `.nox` file in the repository and compares exit code and output (`--component lexer|ast`; `--zig-only` checks the runner itself; `--selftest` proves it catches a difference and shrinks it to a minimal example). `zig build frontend-diff-test` runs the self-check plus a Zig-against-Zig pass. The global `--frontend zig|nox` flag selects the component; the ordinary `noxc` accepts only `zig`.

`noxc tokens` also takes `--trivia` (print the comment and blank-line channel the formatter uses). In the nightly binary `--frontend nox tokens` runs the lexer written in Nox (`selfhost/lexer.nox`, generated from `selfhost/lexer.nox.in` by `scripts/gen_selfhost_lexer.py`), and `noxc-nightly lex-bench <file>` compares its speed with the Zig lexer. `frontend_diff.py --fuzz N --seed S` adds N randomly damaged inputs (broken quotes, tabs, truncated UTF-8) so error paths are compared too; `--sub-args=--trivia` passes extra flags to the sub-command.

`frontend_diff.py --component check` compares the whole front half of the pipeline (module loading, parsing, type checking) between the stable `noxc` and `noxc-nightly`, whose default front end is the Nox lexer. `noxc-nightly lex-bench <file> [N] --max-ratio=3.0` fails when the Nox lexer is more than three times slower than the Zig one.
