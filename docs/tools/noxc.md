# noxc — the compiler and project tool

`noxc` is the single command that checks, compiles, runs, formats, tests and packages Nox programs. This page is the complete reference; see the
[tutorial](../tutorial/01-hello.md) for a gentle introduction.

```text
noxc <file.nox>               compile the file to an executable (shortcut for build)
noxc <subcommand> [options]
```

> **Message language.** `noxc --help` follows your locale (`LC_ALL`, `LC_MESSAGES`, `LANG`; Turkish if the value starts with `tr`, English otherwise). Compiler diagnostics, standard-library exception text and every other `noxc` status line are English. Their *kind* is stable; their wording is not. Branch on exit codes, not on message text.

## Exit status

`0` on success. `1` for any failure: a syntax or type error, a failed build, a failing test, an uncaught exception in a program started by `run` (the program's own exit status is returned when it exits
normally).

## Building and running

| Command | Description |
|---|---|
| `noxc build [options] <file.nox>` | compile to a native executable named after the file (or `-o`) |
| `noxc sbom [dir] [-o file]` | write a deterministic CycloneDX 1.5 SBOM of `nox.json` + `nox.lock` (each locked dependency with its purl and commit; `nox:native` flags `extern def` / `lowlevel` / `bin`, found by a static scan of the cached sources; nothing is executed) |
| `noxc sign keygen <name>`, `sign lock --key <name> [dir]`, `sign trust <pub>`, `sign revoke <fp>`, `sign verify [dir]` | Ed25519 signing of `nox.lock` ([ADR-011](../internals/adr/011-lock-signing.md)); `verify` exits 0 only for a valid signature by a trusted, non-revoked key |
| `noxc run --sandbox [--allow-net] [--allow-write=DIR] [--allow-read=DIR] <file.nox>` | run the compiled program under an OS sandbox: no network, writes only to `$TMPDIR` ([ADR-010](../internals/adr/010-sandbox.md)); macOS `sandbox-exec`, Linux `bwrap` |
| `noxc run [options] <file.nox> [args…]` | compile into `$NOX_HOME/cache/run/` (keyed by path, source contents, the `noxc` binary, `noxrt.o`, and the installed stdlib) and run; a matching cache entry is not rebuilt. Everything after `--` goes to the program (`nox.os.arg(1)`, …) |
| `noxc check [options] <file.nox>` | parse and type-check only — fast, no code generation. Exit status 0 means "no type errors" |
| `noxc test [name\|path …]` | run every `*_test.nox` under the current directory, or only those whose file name contains `name`, or the given directory. A compile error is a failed file; the rest still run ([Testing](testing.md)) |
| `noxc expand <file.nox>` | print the decorator metadata the compiler extracted from the file |
| `noxc bindgen <header.h> --lib <lib>` | generate Nox `extern def` bindings (and a C shim where needed) from a C header ([bindgen](bindgen.md)) |
| `noxc explain [--release] <file.nox>` | print each local variable's allocation decision (stack, arena or reference-counted) and why ([Memory](../language/memory.md#seeing-the-compilers-decisions-noxc-explain)) |
| `noxc fmt <file.nox>` | rewrite the file in the standard style, in place ([Formatter](formatter.md)) |

### Build options

| Option | Meaning |
|---|---|
| `-o <output>` | output file name (`build` only) |
| `--backend <llvm\|qbe>` | code-generation backend. Default `llvm`; `qbe` is chosen automatically for freestanding builds, `--emit-asm`, `-g`, and when neither `clang` nor `zig` is installed. Mobile targets stay on LLVM ([Backends](backends.md)) |
| `--release` | the old name for `--backend llvm` |
| `--profile <hosted\|freestanding>` | which standard-library modules may be imported (default `hosted`; [Freestanding](freestanding.md)) |
| `--target <name>` | cross-compile. Desktop hosted names build through LLVM when `zig` is on `PATH` (QBE otherwise, or with `--backend qbe`): `macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`, `linux-riscv64`, `windows-x64`. Freestanding: `x86_64`, `aarch64`, `riscv64`. Mobile names are LLVM libraries: `ios-arm64`, `ios-simulator-arm64`, `android-arm64`, `android-x64`. `wasm32-wasi` and `wasm32-freestanding` are LLVM-only WebAssembly modules ([WebAssembly](wasm.md)) Cross-building needs `zig` on `PATH`. With `--backend qbe`, `windows-x64` also needs the patched `qbe` that ships in the release archives (stock QBE 1.3 fails with `invalid operand for instruction`; `scripts/build_qbe.sh` builds the patched one) |
| `--asyncify` | with `--target wasm32-wasi` or `wasm32-freestanding`: real fibers through Binaryen Asyncify (needs `wasm-opt`) instead of the nested-run simulation ([WebAssembly](wasm.md)) |
| `--threads` | with `--target wasm32-wasi`: real parallel M:N through shared memory and atomics (includes the Asyncify fibers; needs `wasm-opt` and `node`) ([WebAssembly](wasm.md)) |
| `--emit-asm` | stop after producing assembly (`.s`). Not valid for a mobile target |
| `--emit-obj`, `--emit-static-lib`, `--emit-shared-lib` | mobile library output. iOS is a static archive. Android's packaged form is `--emit-shared-lib`. One flag only |
| `-g` | emit DWARF line tables for debugging — QBE backend only, selected automatically ([Debugging](debugging.md)) |
| `--dump`, `-v` | verbose output: dump the AST and compiler decisions |

A bare `noxc file.nox` builds `file`; it does not run it (use `noxc run`).

## Projects and packages

| Command | Description |
|---|---|
| `noxc init [name]` | scaffold a project (`nox.json` and `main.nox`) in `name/` or the current directory |
| `noxc fetch` | download the dependencies listed in `nox.json` into the cache and record exact commits in `nox.lock` |
| `noxc update` | re-resolve dependencies to the latest commits of their refs and rewrite `nox.lock` |
| `noxc add <alias> [repo] [--ref <ref>]` | add a dependency to `nox.json` (looks `repo` up in the index when omitted; `ref` defaults to `master`) |
| `noxc delete <alias>` | remove a dependency from `nox.json` and `nox.lock` |
| `noxc search <query>` | search the central index; `noxc search <index.json\|url> <query>` searches another index |
| `noxc login [--no-browser]` | sign in to the registry with GitHub (needed to publish); saves a token in `~/.nox/credentials` |
| `noxc logout` | delete the local token and revoke it on the server |
| `noxc whoami` | show which GitHub account you are signed in as |
| `noxc publish <repo> [--ref <ref>] [--description <text>] [--tags a,b,c]` | submit package metadata to the central index (requires `noxc login`; awaits admin approval) |
| `noxc install <name\|repo[@ref]> [--ref <ref>] [--force]` | globally install a package that declares a `bin` entry point. `github.com/org/name@v1.2.3` sets the ref; `--ref` overrides it. `git@host:path` is not split on the first `@` |
| `noxc refresh [command] [--force]` | update globally installed packages (all of them without an argument). A package whose remote commit is unchanged, built by the same `noxc`, is reported as *up to date* and skipped (one `git ls-remote`, no clone or build); `--force` rebuilds anyway. After `noxc upgrade`, packages are rebuilt once with the new compiler |
| `noxc uninstall <command>` | remove a globally installed command |
| `noxc list` | list globally installed packages |
| `noxc cache prune [--dry-run] [--all]` | delete stale package-cache directories and old/oversized `noxc run`/`noxc test` binaries (`--all` empties the run cache) |

Details: [Packages](packages.md) and [noxpkg](noxpkg.md).

## Maintenance

| Command | Description |
|---|---|
| `noxc upgrade [--check] [vX.Y.Z]` | update `noxc` itself to the highest stable release (or a given version); `--check` only reports. The version is the highest `vX.Y.Z` in the release list (drafts and pre-releases are skipped), not GitHub's "latest" flag, and `noxc upgrade` never downgrades without an explicit version |
| `noxc version`, `noxc --version`, `-V` | print the version |
| `noxc --help`, `-h` | print the help screen |

## Progress output

Commands that wait on the network or the build (`upgrade`, `install`, `refresh`, `fetch`, `update`, `add`, `search`, and automatic dependency fetching during `build`/`run`) report what they are doing on stderr, one `==>` line per stage:

```text
==> Checking the latest release ... done
==> Upgrading noxc to v2.0.135 (macos-arm64)
==> Downloading nox-lang-v2.0.135-macos-arm64.tar.gz (19.8 MB)
    [===========>            ]  48%  9.5 MB / 19.8 MB  4.1 MB/s  eta 2.5s
==> Verifying checksum ... done
```

In a terminal the download line is a live bar (percentage, size, speed, estimated time) that is replaced by a summary (`19.8 MB in 4.8s (4.1 MB/s)`) when it finishes. When stderr is not a terminal (a pipe, a file, CI) or `TERM=dumb`, no bar is drawn: you get only the stage lines and the summary, so logs stay readable. A stage that finishes in under a tenth of a second omits its duration.

## Capability restrictions

`--allow-net` also applies to `noxc run --target wasm32-freestanding-asyncify`: it gives the module the host's `fetch` so `nox.http` works; without it the client raises `HttpCapabilityError` (see [WebAssembly](wasm.md#network-the-noxhttp-client-through-the-hosts-fetch-wasm32-freestanding---asyncify)).

`--allow-process` and `--allow-serve` likewise give a `wasm32-freestanding-asyncify` module the host's child-process and HTTP-server capabilities (off by default; see [WebAssembly](wasm.md)).

`--vfs-dir <dir>` (with `noxc run --target wasm32-freestanding`) loads a directory into the module's virtual file system before the run and writes it back on exit, so `nox.fs` and file-based `nox.sqlite` persist; see [WebAssembly](wasm.md#persistent-virtual-file-system).

`--deny-capability <list>` (also `--deny-capability=<list>`, valid with every subcommand) makes the compiler reject any program that imports a module needing one of the listed capabilities, or calls a function marked `@capability.requires` for it: `filesystem`/`fs`, `network`/`net`, `clock`, `entropy`/`random`, `threads`, `process`, `shared_memory`/`shm`, `libc_math`, `dynamic_code`/`dynamic`. It is meant for environments that compile untrusted code (a playground, a CI sandbox) and works on every target; see [WebAssembly](wasm.md#capability-model-and---deny-capability).

## Scripts

A Nox file can be run like a script. `noxc run` compiles it once, keeps the binary in the run cache (keyed by the source, the compiler and the standard library, so editing the file recompiles it and an unchanged file starts immediately) and runs it:

```nox
#!/usr/bin/env -S noxc run
import nox.os

print("hello,", nox.os.arg(1))
```

```sh
chmod +x greet.nox
./greet.nox world        # hello, world
```

Everything after the file path is passed to the program, like `python script.py a b`; a leading `--` is optional and accepted for older invocations. Compiler and sandbox options (`--backend`, `--sandbox`, ...) go **before** the file path, so they never reach the program. `env -S` is needed for the two-word shebang on Linux; macOS accepts it too. The plain form `#!/usr/bin/env noxc` does not run the script: a bare `noxc file.nox` only builds it.

## Environment

`NOX_HOME` (the data directory, default `~/.nox`), `NOX_INDEX_URL`, `NOX_PUBLISH_API_BASE`, `NOX_UPGRADE_API_BASE` and others are listed in [Environment variables](../reference/environment.md).

## Examples

```sh
noxc run main.nox a b c           # run with arguments (everything after the file goes to the program)
noxc build -o app main.nox        # produce ./app
noxc check main.nox               # type-check only
noxc build --backend qbe main.nox # use the QBE backend
noxc search http                  # find packages
noxc add nyx                      # add a dependency by name
noxc upgrade --check              # is there a newer noxc?
```

## Tool locations

`noxc` finds its runtime object (`noxrt.o`) and standard library next to the executable (`<root>/lib/noxrt.o`, `<root>/lib/nox/stdlib`), so an installed `noxc` works from any directory. A
release archive also contains `noxlsp` (the [language server](lsp.md)) and, on Linux and macOS, a bundled `qbe`. Set `NOX_RESOURCE_DIR` to point at a different resource directory.
