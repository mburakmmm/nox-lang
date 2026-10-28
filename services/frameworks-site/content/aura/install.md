# Install and run

Aura is a Nox program plus a native shell. You do not `pip install` it and you do not add it as a header-only library. From a checkout of [github.com/mburakmmm/aura](https://github.com/mburakmmm/aura), at the repository root:

```sh
./scripts/build_host.sh
noxc run examples/counter/main.nox
```

The window opens at 800×600. Continue increments the counter. The word Aura at the top does not change, so that text is not repainted.

## Requirements

- Nox 2.0 (`noxc`).
- A supported shell: macOS, Windows, or Linux.
- Linux needs Wayland, Xkbcommon, X11, D-Bus and wayland-protocols. The Windows shell links Skia with MSVC; the Nox program is linked with the MinGW `cc`.
- Network on the first build. The script downloads a pinned Skia archive into `third_party/`.

Text is measured with the OFL Noto Sans files under `native/fonts/`.

## Headless checks

```sh
noxc run examples/counter/main.nox -- --self-check
./scripts/test.sh
./scripts/certify.sh
./scripts/bench.sh
```

`test.sh` builds the shell and runs `noxc test`. `certify.sh` adds the ten headless self-checks and does not leave a window open. `bench.sh` writes phase timings and setup counters for eight scenarios.

The `--` is required: arguments after it are the program’s, not `noxc`’s.

## Publishing

The version in `nox.json` and the git tag (`v` plus that version) are the same number. `noxc` does not host the package bytes. [noxpkg](https://noxpkg.noxlang.com) indexes the repository URL, the tag and the description. An admin approves the metadata.

```sh
./scripts/release.sh
```

The script runs the tests and, if they pass, prints the tag, push and `noxc publish` commands. It does not run them.
