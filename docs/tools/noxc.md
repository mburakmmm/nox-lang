# noxc — the compiler and project tool

`noxc` is the single command that checks, compiles, runs, formats, tests and packages Nox programs. This page is the complete reference; see the
[tutorial](../tutorial/01-hello.md) for a gentle introduction.

```text
noxc <file.nox>               compile the file to an executable (shortcut for build)
noxc <subcommand> [options]
```

> **Message language.** `noxc` chooses the language of its *help* from your locale (`LC_ALL`, `LC_MESSAGES`, `LANG`; Turkish if it starts with `tr`, English otherwise). Compiler diagnostics and
> status lines (`derlendi: …` = "built", `tip hatasi …` = "type error …", `GECTI` = "passed") are currently Turkish regardless of locale; their *kind* is stable, their wording is not.
> Branch on exit codes, not on message text.

## Exit status

`0` on success. `1` for any failure: a syntax or type error, a failed build, a failing test, an uncaught exception in a program started by `run` (the program's own exit status is returned when it exits
normally).

## Building and running

| Command | Description |
|---|---|
| `noxc build [options] <file.nox>` | compile to a native executable named after the file (or `-o`) |
| `noxc run [options] <file.nox> [-- args…]` | compile into `.nox/cache/bin/` and run; everything after `--` goes to the program (`nox.os.arg(1)`, …) |
| `noxc check [options] <file.nox>` | parse and type-check only — fast, no code generation. Exit status 0 means "no type errors" |
| `noxc test` | discover and run every `*_test.nox` under the current directory ([Testing](testing.md)) |
| `noxc expand <file.nox>` | print the decorator metadata the compiler extracted from the file |
| `noxc explain [--release] <file.nox>` | print each local variable's allocation decision (stack, arena or reference-counted) and why ([Memory](../language/memory.md#seeing-the-compilers-decisions-noxc-explain)) |
| `noxc fmt <file.nox>` | rewrite the file in the standard style, in place ([Formatter](formatter.md)) |

### Build options

| Option | Meaning |
|---|---|
| `-o <output>` | output file name (`build` only) |
| `--backend <llvm\|qbe>` | code-generation backend. Default `llvm`; `qbe` is chosen automatically for freestanding builds, `--target`, `--emit-asm`, `-g`, and when neither `clang` nor `zig` is installed ([Backends](backends.md)) |
| `--release` | the old name for `--backend llvm` |
| `--profile <hosted\|freestanding>` | which standard-library modules may be imported (default `hosted`; [Freestanding](freestanding.md)) |
| `--target <name>` | cross-compile: hosted targets `macos-arm64`, `linux-x64`, `linux-arm64`, `windows-x64`; freestanding architectures `x86_64`, `aarch64`, `riscv64` (assembly only) |
| `--emit-asm` | stop after producing assembly (`.s`) |
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
| `noxc publish <repo> [--ref <ref>] [--description <text>] [--tags a,b,c]` | submit package metadata to the central index (awaits admin approval) |
| `noxc install <name\|repo> [--ref <ref>]` | globally install a package that declares a `bin` entry point |
| `noxc uninstall <command>` | remove a globally installed command |
| `noxc list` | list globally installed packages |
| `noxc cache prune [--dry-run] [--all]` | delete stale package-cache directories |

Details: [Packages](packages.md) and [noxpkg](noxpkg.md).

## Maintenance

| Command | Description |
|---|---|
| `noxc upgrade [--check] [vX.Y.Z]` | update `noxc` itself to the latest release (or a given version); `--check` only reports |
| `noxc version`, `noxc --version`, `-V` | print the version |
| `noxc --help`, `-h` | print the help screen |

## Environment

`NOX_HOME` (the data directory, default `~/.nox`), `NOX_INDEX_URL`, `NOX_PUBLISH_API_BASE`, `NOX_UPGRADE_API_BASE` and others are listed in [Environment variables](../reference/environment.md).

## Examples

```sh
noxc run main.nox -- a b c        # run with arguments
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
