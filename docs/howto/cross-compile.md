# Cross-compile

`noxc build --target <name>` produces an executable for another system from any host that has `zig` on its `PATH`. The program goes through the same LLVM back end as a native build, so it is optimised the same way.

## Desktop targets

| `--target` | Produces |
|---|---|
| `macos-arm64`, `macos-x64` | macOS executable |
| `linux-x64`, `linux-arm64` | Linux executable |
| `linux-riscv64` | Linux executable (static musl) |
| `windows-x64` | Windows `.exe` |

```sh
noxc build --target windows-x64 main.nox -o app.exe
noxc build --target linux-arm64 main.nox -o app
```

Without `zig`, a desktop `--target` falls back to QBE and a C compiler for that target, or fails if there is none. The complete list of targets and their support level is in [Platforms](../reference/platforms.md).

## Things to know

- **The runtime travels with the compiler.** Cross builds link `noxrt-<target>.o` from the compiler's `lib/` directory, so a compiler installed from a release archive can cross-compile without extra downloads.
- **Embedded C libraries are per target.** Programs that import `nox.lz4`, `nox.yyjson` and the like also need `noxclibs-<target>.a` next to the runtime ([Embedded C libraries](embedded-c-libraries.md)). Release archives from 2.1.176 include it.
- **Run it where it belongs.** A Windows `.exe` built on Linux is checked on a real Windows machine in the project's CI on every change; you can verify yours the same way.
- **WebAssembly is a target too:** `--target wasm32-wasi` or `wasm32-freestanding` ([WebAssembly](../tools/wasm.md)).
- **Mobile targets produce libraries**, not executables (`--emit-obj`, `--emit-static-lib`, `--emit-shared-lib`), and are experimental ([Platforms](../reference/platforms.md)).

## Freestanding

For bare metal, `--profile freestanding --target x86_64|aarch64|riscv64` builds a kernel-style ELF ([Freestanding](../tools/freestanding.md)).
