# Installing Nox

Nox ships as a single archive per platform containing `noxc` (the compiler and tool), `noxlsp` (the language server), the runtime objects, the standard library, the bundled `qbe` back end (Linux, macOS) and the header
`include/nox_nni.h`.

## Requirements

- **To compile and run programs:** a C toolchain for linking (`cc`) — Xcode Command Line Tools on macOS, `build-essential`/`gcc` on Linux, MinGW-w64 or Zig on Windows — and, for the default LLVM back end, **`clang` or `zig`** on `PATH`.
  With neither, Nox falls back to the bundled QBE back end automatically.
- **To build Nox from source:** [Zig](https://ziglang.org) 0.16.

## macOS and Linux

```sh
curl -fsSL https://noxlang.com/install.sh | sh
```

The script downloads the latest release for your platform (macOS arm64, Linux x86-64, Linux arm64) and unpacks it under `~/.nox-lang`. Add its `bin` directory to your `PATH`:

```sh
export PATH="$HOME/.nox-lang/bin:$PATH"
noxc --version
```

Environment variables for the installer: `NOX_INSTALL_DIR` (install root) and `NOX_VERSION` (a specific tag such as `v2.0.0` instead of the latest).

## Windows

```powershell
irm https://noxlang.com/install.ps1 | iex
```

This installs `noxc.exe` and friends under `%USERPROFILE%\.nox-lang` (override with `NOX_INSTALL_DIR`) and checks for a C toolchain. Install [Zig](https://ziglang.org/download/) (`winget install zig.zig`) so Nox can use `zig cc` to link — this is also the default LLVM path on Windows.

## From a release archive

Download `nox-lang-<version>-<platform>.tar.gz` (or `.zip` on Windows) and its `.sha256` file from the [GitHub releases](https://github.com/mburakmmm/nox-lang/releases), verify the checksum, unpack, and put `bin/` on your `PATH`.
The archive's layout is `bin/`, `lib/` (runtime objects and `lib/nox/stdlib`) and `include/`.

## From source

```sh
git clone https://github.com/mburakmmm/nox-lang
cd nox-lang
zig build                       # builds into zig-out/
zig-out/bin/noxc --version
zig build test --summary all    # optional: the full test suite
```

## Updating

```sh
noxc upgrade --check            # is there a newer release?
noxc upgrade                    # update in place (checksum verified)
noxc upgrade v2.1.0             # a specific version
```

## Check your installation

```sh
printf 'print("hello from nox")\n' > hello.nox
noxc run hello.nox
```

Next: the [tutorial](../tutorial/index.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `noxc: command not found` | add the install `bin/` directory to `PATH` |
| a note that neither clang nor zig was found and QBE is used | install `clang` (Xcode CLT / `apt install clang`) or `zig` for the faster LLVM back end; the program still compiles |
| linking fails with `cc` not found | install a C toolchain (`xcode-select --install`, `apt install build-essential`) |
| `libsqlite3` / `libpq` / `libmysqlclient` errors at run time | those libraries are loaded on first use; install the one you need |
| Windows: build errors about MinGW | install Zig and re-run; or install MinGW-w64 and ensure `cc` is on `PATH` |
