# The Nox compiler in the browser

The whole Nox compiler runs as WebAssembly: source code is compiled to `.wasm` **in the browser** (or in Node) and run there. No server, no `noxc` binary, no `zig` or `clang` installation is needed, and the code is sent nowhere. It powers the [Playground](playground.md) and is meant for embedded code sandboxes and offline tools.

There are two parts:

1. **The front end** (`noxc-frontend.wasm`, about 2 MB): lexer, parser, type checker and LLVM IR generation. The `nox.*` standard library is embedded in the module. It produces **byte-for-byte the same** IR as a native `noxc build --target wasm32-*` (it is the same code, `compiler/frontend.zig`). It checks and compiles a program in about 30 ms and returns syntax and type errors as readable text.
2. **The back end** (clang and wasm-ld, themselves WebAssembly): links the IR with the runtime objects and produces `.wasm`. The default provider is [`@yowasp/clang`](https://www.npmjs.com/package/@yowasp/clang) (an optional dependency, about 25 MiB gzipped, loaded lazily on first use and kept in the browser cache); any other provider with a compatible `runClang(argv, files)` can be passed instead.

## Usage

```js
import { createNoxCompiler } from './wasm_compiler.mjs';
import { runNox } from './wasm_host.mjs';

const nox = await createNoxCompiler({
  frontend: await (await fetch('noxc-frontend.wasm')).arrayBuffer(),
  // runtime objects: noxrt-wasm32-freestanding.o, ...-sqlite3.o, compiler-rt-wasm32.a (the lib/ directory of a release archive)
  asset: async (name) => new Uint8Array(await (await fetch(`lib/${name}`)).arrayBuffer()),
  clang: () => import('@yowasp/clang'),
});

const r = await nox.compile('print("hello", 6 * 7)\n', { target: 'wasm32-freestanding' });
if (!r.ok) console.error(r.diagnostics);              // for example "main.nox:1:9: syntax error: ..."
else await runNox(r.wasm, io);                         // io: write/read/clockMs/randomFill/sleepMs (see the WebAssembly page)
```

- `nox.compileToIr(source, opts)` runs only the front end (`{ ok, ir, plan, diagnostics }`): ideal for live error checking.
- `opts.target`: `wasm32-freestanding` (the default), `-asyncify`, `-threads`. `opts.deny`: compile-time capability bans (`['fs', 'network']`, see `--deny-capability`). `opts.label`: the file name shown in diagnostics. These options cannot contain control characters.
- `nox.addFile('/stdlib/...' | path, text)`: adds an in-memory virtual file (adding the same path again replaces it).
- `--asyncify` targets need a post-link `wasm-opt`: in a browser use `binaryen` (npm, Apache-2.0) with `import { binaryenAsyncify } from './wasm_asyncify.mjs'; createNoxCompiler({ ..., optimize: binaryenAsyncify(binaryen) })`. Without it a clear error is returned. The `nox.http` client (`fetch`) works only on this target.

When running, the host options on the [WebAssembly page](wasm.md) apply: the in-memory file system, optional persistence (`vfs`) and — only when explicitly given — the network (`fetch`). On pages that run untrusted code, restrict capabilities at compile time with `deny` and give `runNox` no `fetch` or `vfs`.

## Distribution and limits

- Next to the release archive a `nox-web-compiler-<version>.tar.gz` is published: `noxc-frontend.wasm`, `wasm_compiler.mjs`, `wasm_asyncify.mjs`, `wasm_host.mjs` and `lib/` (the runtime objects). From source: `zig build wasm-compiler wasm-rt`.
- The first compile loads clang/lld (hundreds of ms); later ones take about 0.3-1 s. Large programs and `nox.sqlite` (an output of about 800 KB) take a little longer.
- Native `extern def ... from "<library>"` declarations cannot be linked in a browser (there are no native libraries); the `native`, `plugin` and `hpy` modules are unavailable on WebAssembly anyway.
- Verification: `scripts/wasm_frontend_corpus.py` compares the front end's IR with native `noxc` over the whole `codegen_cases` corpus (467 identical, plus 16 rejected for the same reason); `scripts/web_compiler_e2e.mjs` runs the full pipeline (front end, clang, run) over the corpus and compares with `.expected` (`wasm32-freestanding` 453 ok, `wasm32-freestanding-asyncify` 458 ok with binaryen).
