# The Playground (beta)

The [Playground](/playground/) lets you write, compile and run Nox in a browser tab. It is **beta**: the compiler it uses is the real one, but the page is new and
the environment around your program is deliberately small.

## How to use it

- Pick an example from the list, or type your own program in the editor. Errors are checked as you type and the first one appears at the top right.
- Press **Run** (or <kbd>Ctrl</kbd>/<kbd>⌘</kbd> + <kbd>Enter</kbd>). The output appears on the right with the exit code and the time spent compiling and running.
- **Stop** ends a running program; a program that is still running after 15 seconds is stopped for you.
- If your program reads input with `input()`, type the text in the *stdin* box first — each line is one `input()` call.
- **Copy link** puts your program into the URL (after the `#`), so you can send it to someone. The code stays in the link; it is never stored on a server.

## What runs where

Everything runs in your browser:

1. The Nox front end (about 2 MB of WebAssembly) type-checks your code and produces LLVM IR — the same IR a native `noxc` would produce.
2. An LLVM toolchain (clang and the linker, also WebAssembly, [`@yowasp/clang`](https://www.npmjs.com/package/@yowasp/clang)) turns the IR into a `.wasm` module. It is downloaded
   the first time you open the page (about 25 MB compressed, from a public CDN, at a pinned version) and kept in the browser cache afterwards.
3. The module runs in a separate worker, so an endless loop cannot freeze the page, and **Stop** simply discards the worker.

The source you type is not sent to any server — not for compiling, not for running.

## What a Playground program can and cannot do

The Playground compiles for `wasm32-freestanding` with the **network**, **process**, **shared-memory** and **dynamic-code** capabilities denied at compile time
(see [`--deny-capability`](wasm.md#capability-model-and---deny-capability)). A program that imports `nox.http` or `nox.process` is rejected with a message that names the
capability.

- The standard library that needs nothing from the outside works: strings, collections, `json`, `regex`, `csv`, `crypto`, `sqlite` (in memory) and so on.
- `nox.fs` works on a private **in-memory** file system that vanishes when the program ends; nothing touches your disk.
- `spawn`/`await`/`Channel` use the default WebAssembly mode (see [Targets and modes](wasm.md#targets-and-modes)), so patterns that need real fibers or real threads are
  not available here. Compile those locally with `--asyncify` or `--threads`.
- Output is capped at 1 MiB, and `sleep` is a short busy wait: this is a toy for learning, not a place to measure performance.

## Embedding it in your own page

The pieces are ordinary files: the front end, a few modules and the runtime objects. [The Nox compiler in the browser](browser-compiler.md) shows the API —
`createNoxCompiler`, `compile`, `runNox` — and the page source (`services/noxlang-site/site/playground/`) is a working example using workers.
A page that loads a compiler from another origin needs a content-security policy that allows WebAssembly (`'wasm-unsafe-eval'`), workers, and the CDN you load clang from;
the Nox site applies that policy to the `/playground` path only and keeps a stricter one everywhere else.

## Reporting a problem

If a program that compiles with `noxc build --target wasm32-freestanding` fails in the Playground — or the reverse — [open an issue](https://github.com/mburakmmm/nox-lang/issues)
with the program and what you saw. Browsers differ in how much memory a WebAssembly tab may use; a very large program can fail to link on a phone.
