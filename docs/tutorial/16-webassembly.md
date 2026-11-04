# 16. WebAssembly and the browser

The same Nox program that compiles to a native executable also compiles to **WebAssembly** — a compact binary format that runs in browsers, in Node, and in
standalone runtimes such as Wasmtime. The compiler itself runs as WebAssembly too, which is how the [Playground](/playground/) can compile your code inside a
browser tab with nothing sent to a server.

## Your first `.wasm`

Take any program — this one only uses features that work everywhere:

```nox
def collatz(n: int) -> int:
    steps: int = 0
    while n != 1:
        if n % 2 == 0:
            n = n // 2
        else:
            n = 3 * n + 1
        steps += 1
    return steps

for start in [6, 7, 27]:
    print("collatz(" + str(start) + ") takes", collatz(start), "steps")
```

```output
collatz(6) takes 8 steps
collatz(7) takes 16 steps
collatz(27) takes 111 steps
```

Build it for WebAssembly instead of your own machine by naming a **target**:

```sh
noxc build --target wasm32-wasi collatz.nox -o collatz.wasm
wasmtime collatz.wasm                                # or any other WASI runtime
noxc run --target wasm32-wasi collatz.nox            # build and run in one step
```

`wasm32-wasi` produces a WASI command, the portable format for command-line programs: any WASI runtime can run it. `noxc run` picks `wasmtime` or `wasmer` if you
have one and falls back to Node. Linking WebAssembly needs `zig` on your `PATH`.

## Two flavours

| Target | What it is | Use it for |
|---|---|---|
| `wasm32-wasi` | a WASI command; the file system is whatever the runtime lets the module see | servers-side runtimes, command-line tools, plugins for other programs |
| `wasm32-freestanding` | no operating system at all; the module talks to its **host** through a handful of imports | browsers, embedded interpreters, your own host program |

On `wasm32-freestanding` the file system is a private, in-memory one that lives inside the module — nothing touches a real disk — which is exactly what you want when
you run code you did not write.

## What the host decides

A WebAssembly module cannot open a socket, start a process or read your files on its own. Anything beyond computation is a **capability** that whoever runs the
module chooses to grant, and all of them are off by default:

| Capability | What it enables | How the Node host grants it |
|---|---|---|
| network | `nox.http` client, WebSocket | `--allow-net` |
| processes | `nox.process` | `--allow-process` |
| a server | `nox.http.serve` | `--allow-serve` |

```sh
noxc run --target wasm32-freestanding-asyncify --allow-net fetch_example.nox
```

You can tighten it further — for example, `--net-allow=api.example.com:443` lets the program reach one server and nothing else. If you are *compiling* code you do
not trust, ban a capability before it even builds:

```sh
noxc build --target wasm32-freestanding --deny-capability network,process,fs prog.nox -o prog.wasm
```

A program that then imports `nox.http` is rejected with a clear message instead of failing later. The [WebAssembly guide](../tools/wasm.md) lists every
capability and limit.

## Tasks, fibers and threads

By default `spawn` and `await` work on WebAssembly through a simple nested-run scheme, which is fine for most programs but cannot untangle every pattern. Two flags
give you the real thing:

- `--asyncify` — real fibers on a single thread, so channels and `await` behave exactly like the native scheduler (this also unlocks the network and server
  capabilities, which have to *pause* a task while the host does I/O);
- `--threads` — real parallelism across worker threads.

## Running in a browser page

A page needs a `wasm32-freestanding` module (`noxc build --target wasm32-freestanding collatz.nox -o collatz.wasm`), a few lines of JavaScript, and `wasm_host.mjs` (it is in the `compiler/` directory of the repository and in the `nox-web-compiler` bundle attached to each release):

```js
import { runNox } from './wasm_host.mjs';

const bytes = await (await fetch('collatz.wasm')).arrayBuffer();
await runNox(bytes, {
  write: (fd, chunk) => { console.log(new TextDecoder().decode(chunk)); return chunk.length; },
  read: () => 0,
  clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()),
  randomFill: (bytes) => crypto.getRandomValues(bytes),
  sleepMs: () => {},
});
```

The host is a plain object with five functions — that is the entire surface a module sees.

## Compile in the browser, too

Because the compiler is WebAssembly as well, a page can accept Nox source, compile it and run the result locally. That is exactly what the
[Playground](/playground/) does: open it, pick an example, edit, press <kbd>Ctrl</kbd>+<kbd>Enter</kbd>. The first run downloads the compiler (about 25 MB, cached
afterwards); every later run compiles in a fraction of a second. The pieces are documented in [The Nox compiler in the browser](../tools/browser-compiler.md) if
you want to embed them in your own page — a docs site with runnable examples, for instance.

Next: [17. Publishing a package](17-publishing.md).
