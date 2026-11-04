# Installing Nox

Nox ships as a single archive per platform containing `noxc` (the compiler and tool), `noxlsp` (the language server), the runtime objects, the standard library, the bundled `qbe` back end (Linux, macOS) and the header
`include/nox_nni.h`.

Prefer a picker that detects your system and shows every option? Use the [download page](/download/). Just want to try the language first? Open the [Playground](/playground/) — nothing to install.

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

## Arch Linux (AUR)

```sh
yay -S noxc-bin          # or any AUR helper
```

*The package is being published to the AUR. Until it appears there, build it from this repository (it downloads the release archive):*

```sh
git clone https://github.com/mburakmmm/nox-lang && cd nox-lang
python3 scripts/update_aur_package.py --tag v<version> --outdir /tmp/noxc-bin
cd /tmp/noxc-bin && makepkg -si
```

`noxc-bin` installs the prebuilt release (x86-64 and aarch64) under `/usr/lib/noxc` with `noxc` and `noxlsp` in `/usr/bin`, and needs `gcc` to link (`clang` or `zig` are optional). Update it through your AUR helper;
`noxc upgrade` refuses to run on a pacman install and tells you so.

## Snap (Linux)

```sh
sudo snap install noxc --classic
```

*The Snap Store listing is awaiting approval of the classic confinement. Until it is live, install the `.snap` attached to a [release](https://github.com/mburakmmm/nox-lang/releases):* `sudo snap install --dangerous --classic noxc_<version>_amd64.snap`.

The snap uses *classic* confinement because `noxc` has to run your system's C toolchain and write wherever your project lives. `noxc` and `noxlsp` are available as `noxc` and `noxc.noxlsp`. Update with `sudo snap refresh noxc`
(snaps also refresh themselves); `noxc upgrade` refuses to run on a snap install.

## AppImage (Linux)

Download `noxc-<version>-x86_64.AppImage` (or `aarch64`) from the [releases](https://github.com/mburakmmm/nox-lang/releases), then:

```sh
chmod +x noxc-*.AppImage
./noxc-*.AppImage run hello.nox          # arguments go to noxc
```

One file, no installation, any distribution (it needs FUSE, or run it with `--appimage-extract-and-run`). Name it or link it as `noxc` to put it on your `PATH`; invoked under the name `noxlsp` it starts the language server instead.
Update by downloading the new file (`noxc upgrade` refuses to run from an AppImage).

## Homebrew (macOS and Linux)

```sh
brew tap mburakmmm/nox
brew install noxc
```

This installs `noxc` and `noxlsp` and puts the bundled `qbe` where `noxc` finds it. Apple Silicon macOS, Linux x86-64 and Linux arm64 are supported (there is no Intel macOS build). Update with
`brew upgrade noxc`; `noxc upgrade` refuses to run on a Homebrew install and tells you so.

## Windows

**Installer (recommended).** Download `nox-lang-v<version>-windows-x64-setup.exe` from the [GitHub releases](https://github.com/mburakmmm/nox-lang/releases) and run it. It installs for your user by default (no administrator
rights, under `%LOCALAPPDATA%\Programs\Nox`; the first page offers "install for all users" instead), can add Nox to your `PATH`, and registers an uninstaller in *Settings → Apps*. Uninstalling removes only the `PATH` entry it
added. Silent install for scripts: `nox-lang-v<version>-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART` (add `/DIR="C:\tools\nox"` to choose the folder, `/MERGETASKS="!addpath"` to skip the `PATH` change).
The installer is not code-signed yet, so Windows SmartScreen may show a warning the first time: choose *More info → Run anyway*, or verify the `.sha256` file next to the download.

**Script.**

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
noxc upgrade                    # update in place (checksum verified; installs managed by Homebrew use `brew upgrade noxc`)
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
