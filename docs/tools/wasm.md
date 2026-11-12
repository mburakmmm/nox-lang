# WebAssembly

Nox programs compile to WebAssembly, and the compiler itself runs as WebAssembly in a browser tab ([Playground](playground.md)).

```bash
noxc build --target wasm32-wasi hello.nox -o hello.wasm
node --no-warnings tests/golden/wasm_run.mjs hello.wasm   # or wasmtime, wasmer, ...
```

The output is a WASI command (`_start`). The build path is LLVM: the `.ll` file is linked with wasi-libc and the `noxrt-wasm32-wasi.o` runtime through `zig cc -target wasm32-wasi`, so `zig` must be on `PATH`; `--backend qbe`, `--emit-asm` and `-g` are errors on this target. The runtime objects (`lib/noxrt-wasm32-*.o`, the `-sqlite3.o` objects and the `lib/compiler-rt-wasm32*.a` archives) are produced by `zig build wasm-rt`. Since v2.0.150 they ship inside the release archives (macOS, Linux, Windows), so a published `noxc` can build `--target wasm32-*` without compiling anything from source (`zig` on `PATH`; `--asyncify` also needs `wasm-opt`).

## What works

The whole language: classes, inheritance (multiple included), generators, `async`/`await`/`Channel`, exceptions, `with`, `__del__`, comprehensions, f-strings, `lowlevel`. From the standard library: `nox.strings`, `math`, `mathx`, `os`, `path`, `time`, `random`, `json`, `yaml`, `toml`, `csv`, `unicode`, `bytes`, `buffer`, `base64`, `bits`, `atomic`, `collections`, `url`, `uuid`, `validate`, `template`, `log`, `test`, `io`, **`fs`**, **`regex`**, **`gzip`**, **`crypto`** (hashes, HMAC, password digests), **`sqlite`**, **`http`**, **`router`**, **`web`**, **`reflect`**, **`transfer`**, **`websocket`**, **`tls`**, **`smtp`**, **`postgres`**, **`mysql`** and **`process`**. Anything that needs the outside world — sockets, child processes, a listening server — is a *capability* the host grants; see the [capability model](#capability-model-and---deny-capability).

## Targets and modes

| Mode | Flag | `spawn`/`await`/`Channel` | Real fibers | Real parallelism (`nox.thread`, M:N) | Known limit |
|---|---|---|---|---|---|
| Default | (none) | nested-run simulation | no | no | a task waiting on a task below it on the stack is reported as a deadlock |
| Asyncify | `--asyncify` | fibers (M:1) | yes | no | size and speed cost of Asyncify ([ADR-014](../internals/adr/014-wasm-asyncify.md)) |
| Threads | `--threads` | fibers + work-stealing pool (M:N) | yes (with Asyncify) | yes | needs shared memory; file handles are per thread ([ADR-015](../internals/adr/015-wasm-threads.md)) |

Every mode exists for both `wasm32-wasi` and `wasm32-freestanding`. Language and standard-library behaviour is identical across modes; only the concurrency model differs. This equivalence is checked by `zig build wasm-corpus-test` over the fixture corpus on all eight targets; the known differences (the last digit of libm, mode-specific scheduling order) are documented in the corpus lists.

## Limits

- **Concurrency depends on the mode** (see the table). In the default mode there are no threads and `spawn`/`await` use the nested-run simulation: a task runs to completion on the stack of the task awaiting it, and a task waiting for the result of a task below it is reported as a "deadlock". `--asyncify` gives real fibers (one thread, M:1); `--threads` gives real parallelism (M:N).
- **Modules that are not available.** `sharedmem`, `native`, `plugin`, `hpy` and the `hpy_*` / `wasm_call` built-ins are rejected at compile time with a message such as `module 'nox.sharedmem' cannot be used on the wasm32-wasi target (...)`. `native`, `plugin` and `hpy` can never work in WebAssembly (there is no dynamic loading).
- **The network belongs to the host.** `nox.http` compiles, but a real socket (client `get`/`post`/`request`/streaming, server `serve*`) does not work without a host capability: client calls raise a catchable `HttpCapabilityError` (a subclass of `HttpError`); `serve` prints a diagnostic and returns at once, like a real bind failure.
- **Node WASI on Windows has no `read_dir`.** Running a `wasm32-wasi` module under Node's `node:wasi` on Windows makes `nox.fs.read_dir` (and `remove_dir_all`, which uses it) raise `FsError`: Node's WASI does not implement `fd_readdir` on Windows (ENOSYS). Linux, macOS, `wasm32-freestanding` (virtual file system) and other WASI engines such as Wasmtime are not affected.
- **No native libraries.** `extern def ... from "lib"` cannot link a native library into a `.wasm`.
- **The file system** depends on the runner's WASI pre-opens (`wasm_run.mjs` opens `.` and `/tmp`).
- **Math** functions (`exp`, `sin`, ...) come from wasi-libc and may differ from the platform libm in the last digit (for example `exp(1.0)`).

Details and rationale: [ADR-012](../internals/adr/012-wasm-target.md). *Importing* a WebAssembly module into Nox ([`nox.wasm`](../stdlib/wasm.md) for a persistent instance handle, or the older single-call `wasm_call` built-in) is a separate mechanism: [HPy and WebAssembly](../internals/hpy-wasm.md).

## Capability model and `--deny-capability`

WebAssembly is a general-purpose compile target: a module compiles as long as what it needs is a *capability* (`network`, `filesystem`, `clock`, `entropy`, ...). Providing the capability is the host's job (WASI, the `nox_host` imports, or a browser page); if the host does not, you get a clear error at the call, not a link error or a crash. The model covers the `nox.http` client (network), `nox.fs` and `nox.sqlite` (virtual file system), sockets, processes and servers, each described below ([ADR-016](../internals/adr/016-wasm-capabilities.md)).

Environments that compile untrusted code (a code playground in a browser, for example) can also restrict capabilities at **compile time**; the flag works on every target, not just WebAssembly:

```bash
noxc build --target wasm32-freestanding --deny-capability fs,net,process prog.nox -o prog.wasm
NOX_DENY_CAPABILITY=net noxc check prog.nox       # an environment variable works too
```

The list is comma separated: `filesystem`/`fs`, `network`/`net`, `clock`, `entropy`/`random`, `threads`, `process`, `shared_memory`/`shm`, `libc_math`, `dynamic_code`/`dynamic`. A program that imports a module needing a denied capability, or calls a function marked `@capability.requires` for it, is rejected: `module 'nox.http' cannot be used: the capability 'network' is denied (--deny-capability)`. An unknown name is an error (a misspelled denial is never ignored silently). The second layer is the host: a host that provides none of the relevant `nox_host` imports does not grant the capability even if it was not denied.

On the freestanding asyncify target the host grants capabilities through a bit mask (`nox_host_caps_set`): `fetch` (1), `tcp` (2), `process` (4) and `serve` (8). All are **off by default**.

## `wasm32-freestanding` and `nox_host`

```bash
noxc build --target wasm32-freestanding prog.nox -o prog.wasm
noxc run   --target wasm32-freestanding prog.nox          # runs with node (compiler/wasm_host.mjs)
```

This produces a module with no WASI and no libc, suitable for a browser or an embedded host. The module sees the outside world only through the `nox_host` imports: `write`, `read`, `clock_ms`, `random_fill`, `sleep_ms` and `exit` ([ADR-013](../internals/adr/013-wasm-host.md)). Language and standard library are the same as on `wasm32-wasi`; the differences: `nox.fs` writes to the runtime's in-memory virtual file system, not a real disk (see below), the environment starts empty (`set_var` is module-local), and `arg(0)` is `"nox"`.

To run it in a browser or your own host, use `createHost`/`runNox` from `compiler/wasm_host.mjs`:

```js
import { runNox } from './wasm_host.mjs';
const code = await runNox(await (await fetch('prog.wasm')).arrayBuffer(), {
  write: (fd, bytes) => { (fd === 2 ? console.error : console.log)(new TextDecoder().decode(bytes)); return bytes.length; },
  read: () => 0,
  clockMs: (kind) => (kind === 0 ? Date.now() : performance.now()),
  randomFill: (bytes) => crypto.getRandomValues(bytes),
  sleepMs: () => {},
});
```

### Verification tools

`scripts/wasm_corpus.py` runs the fixture corpus in parallel on a selectable engine (`--target`, `--engine node|wasmtime`); `scripts/wasm_stress.py` repeats a mixed workload (channel fan-in, cyclic garbage, abandoned generators, `nox.thread`) on four targets for a given time and compares the output byte for byte with native.

### Cost

Measurements are in `benchmarks/wasm/RESULTS.md` (reproduce with `benchmarks/wasm_bench.py`). In short (Apple M4, Node 26): WebAssembly is 1.4x slower than native LLVM on CPU-bound code and 3-5x slower on memory-heavy code; `--asyncify` adds 0-4% on CPU-bound code compared with the default mode but slows workloads that suspend very often (500 thousand `spawn`/`await`) by 2.6x; `--threads` is 2.7x faster than Asyncify on four equal tasks but pays for atomic ARC on a single worker. Modules are 60-125 KB.

### In the browser

`createHost`/`runNox` work in a browser as they are, and so do `--asyncify` modules (plain WebAssembly). For threaded `wasm32-freestanding-threads` modules use `runNoxThreads(bytes, io)`: the main wasm thread runs as a Worker (a page cannot `Atomics.wait`), the page creates all Workers, and output and exit code are relayed to the page. The page must be `crossOriginIsolated` (`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`). `examples/wasm-browser/` has a sample page and a small server that adds those headers:

```bash
noxc build --target wasm32-freestanding-threads prog.nox -o examples/wasm-browser/prog.wasm
node examples/wasm-browser/serve.mjs      # http://127.0.0.1:8123/examples/wasm-browser/index.html?wasm=prog.wasm
```

Verified in Chromium: the default, `--asyncify` and `--threads` modes (including the 200-thread `thread_spawn_stress` and the shared atomic counter) give the same output as native. Firefox and Safari were not tried for threads. `wasm32-wasi` modules need a WASI shim in a browser (WASI imports instead of `nox_host`); `wasm_host.mjs` provides WASI only on Node.

### Other engines

`wasm32-wasi` and `wasm32-wasi-asyncify` modules also run under `wasmtime` (`noxc run` prefers it): the whole fixture corpus passes with zero differences through `scripts/wasm_corpus.py --target wasm32-wasi --engine wasmtime`. Threaded modules do not run under wasmtime or wasmer (wasi-threads was removed); they need `wasm_host.mjs` or a host that implements the `thread_spawn` contract.

## `--asyncify`: real fibers

```bash
noxc build --target wasm32-wasi --asyncify prog.nox -o prog.wasm     # needs wasm-opt (binaryen)
noxc run   --target wasm32-freestanding --asyncify prog.nox
```

`--asyncify` really suspends tasks that are waiting (stack switching): mutual channel waits, `nox.thread`/`sleep` ordering and `async` patterns run in the same order as under the native scheduler, and the deadlock limit disappears. The output module asks the host for no extra imports and runs on any WebAssembly engine. Cost: roughly 30-50% in speed and size and a dependency on `wasm-opt` ([ADR-014](../internals/adr/014-wasm-asyncify.md)). It is not parallelism (a single thread). The `wasm-opt` invocation enables bulk memory, sign extension, non-trapping float-to-int and mutable globals explicitly so older binaryen releases accept the objects.

## `--threads`: real parallel M:N

```bash
noxc build --target wasm32-wasi --threads prog.nox -o prog.wasm       # needs wasm-opt (binaryen) and node
NOX_POOL_WORKERS=4 noxc run --target wasm32-wasi --threads prog.nox
```

`--threads` brings the work-stealing M:N pool of the native `--release` runtime to WebAssembly: `spawn`/`await`, `Channel` and `nox.thread` really run in parallel on several threads (shared memory plus atomics). The module imports `env.memory` (shared) and `wasi::thread-spawn`; `compiler/wasm_host.mjs` provides them with Node Workers (wasmtime 50 removed `-Sthreads`, so `noxc run` uses only Node for this target). Another host can run the module by providing the same two imports. The worker count is set with `NOX_POOL_WORKERS`. Limits and rationale: [ADR-015](../internals/adr/015-wasm-threads.md). `--threads` also exists for `wasm32-freestanding`: the host provides `nox_host.thread_spawn(arg) -> tid` and calls `nox_host_thread_start(tid, arg)` on each new thread (with a shared `env.memory`).

## SQLite

`nox.sqlite` compiles on every WebAssembly target; the SQLite library is linked into the program statically (only programs that use `nox.sqlite` grow, by about 700 KB). On `wasm32-wasi`, file-based databases work in the directories the host pre-opens (`wasmtime run --dir=. app.wasm`) and persist between runs; there is no locking (a single process is assumed). On `wasm32-freestanding`, file-based databases live in the virtual file system (below).

## Virtual file system (wasm32-freestanding)

A `wasm32-freestanding` module has no operating system; `nox.fs` and file-based `nox.sqlite` go to an **in-memory virtual file system** that lives in the runtime's linear memory. No import is added for the host, and nothing is written to a real disk or server (safe for a playground). It starts with `/` and `/tmp`; relative paths resolve under `/`, and `..` never climbs above the root. By default the file system lives for the lifetime of the program and disappears at exit; in `--threads` mode it is shared between threads. See the next section to make it persistent. `remove_file` is safe even while a handle is open (like POSIX `unlink`). Limits: no symbolic links, permission bits or directory removal of non-empty directories except through `remove_dir_all`; `rename` cannot move a directory on top of another directory.

On `wasm32-wasi`, file operations go to the pre-opened directories of WASI (`.` and `/tmp`).

### Persistent virtual file system

The virtual file system can be made **persistent on request**: the host fills the tree before the module starts and stores a snapshot at exit. Nothing is imported for this: the module (only if it uses `nox.fs`/`nox.sqlite`) exports `nox_vfs_host_alloc/free/put/mkdir/snapshot` and the host reads and writes memory directly. `/tmp` counts as temporary: it is neither mirrored to the host nor saved.

- **Command line (Node):** `noxc run --target wasm32-freestanding --vfs-dir data/ prog.nox`, or with a built module `node wasm_host.mjs prog.wasm --vfs-dir=data/` (or `NOX_VFS_DIR`). The directory is loaded into the virtual file system at start (symbolic links are skipped; at most 512 MiB) and written back at exit: changed files are written with a temporary file plus `rename`, unchanged files are left alone, and files the program deleted are deleted from disk. A symbolic link under the root is never written through or deleted through. A program that does not use the file system does not touch the directory.
- **Browser / your own host:** `runNox(bytes, io, { vfs: { files, onSave } })`; `files` is `[{ path, data? }]` (a missing `data` means a directory) and `onSave(entries)` is called at exit with a snapshot in the same shape; writing it to IndexedDB/OPFS is up to you. For threaded modules, `runNoxThreads(bytes, io, { vfs: { files, onSave } })` follows the same contract. Low level: `vfsPreload(instance, entries)` and `vfsSnapshot(instance)`.

```js
import { runNox } from './wasm_host.mjs';
const saved = JSON.parse(localStorage.getItem('nox-vfs') ?? '[]').map((e) => ({ path: e.path, data: e.b64 && Uint8Array.from(atob(e.b64), (c) => c.charCodeAt(0)) }));
await runNox(bytes, io, { vfs: {
  files: saved,
  onSave: (entries) => localStorage.setItem('nox-vfs', JSON.stringify(entries.filter((e) => !e.path.startsWith('/tmp')).map((e) => ({ path: e.path, b64: e.data && btoa(String.fromCharCode(...e.data)) })))),
} });
```

Persistence is written at exit: if the program crashes (a trap) the snapshot is still taken, but if the process is killed it is not.

## Network: the `nox.http` client through the host's `fetch` (wasm32-freestanding --asyncify)

On the `wasm32-freestanding-asyncify` target, `nox.http.get/post/request` rely on the host's `fetch` (`window.fetch` in a browser, `globalThis.fetch` in Node, or any `fetch`-compatible function the host provides). The capability is **off by default**: unless the host grants it, client calls raise a catchable `HttpCapabilityError`.

```js
import { runNox } from './wasm_host.mjs';
await runNox(bytes, io, { fetch: globalThis.fetch });   // network on
await runNox(bytes, io, { fetch: null });               // network off (the default): HttpCapabilityError
```

On the command line, for Node: `noxc run --target wasm32-freestanding-asyncify --allow-net prog.nox` (or `NOX_ALLOW_NET=1`). At compile time, `--deny-capability network` forbids a module from using the network at all (this is what the Playground does).

- **How it works.** The fiber that makes the network call is parked and other fibers run (so with `spawn` requests go out in parallel). When no fiber is ready, the module returns to the host without reporting an exit; the host waits for the `fetch`es, delivers the results and resumes the program with `nox_host_resume()`. Nothing is imported by the module; the host only calls exports (`nox_host_caps_set`, `nox_host_fetch_pending`, `nox_host_fetch_complete`, `nox_host_status`, `nox_host_resume`, `nox_host_alloc/free`). Details: spec §3.351. If you write your own host, the `runNox` loop in `compiler/wasm_host.mjs` is the reference.
- **Limits.** Only `--asyncify` freestanding (suspending needs fibers); plain freestanding, `--threads` (see below) and `wasm32-wasi` keep raising `HttpCapabilityError`. The streaming client (`stream`, `stream_upload`, `nox.transfer`) is supported: a download is read from the `fetch` response reader chunk by chunk (only as `read_chunk` is called, with back-pressure) and `timeout_ms` is an idle timeout; an upload is buffered in the runtime and sent as one request on `finish()` (not every browser supports streaming upload bodies in `fetch`). `get/post/request` buffer the whole response. Redirects are followed by `fetch`. Header names are lower case, as `fetch` gives them. In a browser, CORS and mixed-content rules belong to the page. Timeouts use `AbortSignal.timeout`.
- **`--threads`.** Threaded freestanding modules can use the client too: the calling thread blocks in `nox_host.net_fetch`/`net_read` (a helper Worker plus `Atomics.wait` on Node, synchronous XHR in a browser Worker), with the capability off by default.

## Compiling in the browser

The compiler itself also runs as WebAssembly (a server-free playground, an embedded code sandbox): see [The Nox compiler in the browser](browser-compiler.md) and the [Playground](playground.md).

### WebSocket client

`nox.websocket` (`connect`, `send_text`, `recv`, `is_open`, `close`) compiles on every WebAssembly target. On `wasm32-freestanding-asyncify` it relies on the host's `WebSocket` (`window.WebSocket` in a browser, `globalThis.WebSocket` in Node 22+); the network capability is opened with the same switch as `fetch` (`runNox(bytes, io, { fetch, WebSocket })`, `--allow-net`). `send_text` has no reply, `recv` parks the fiber (other fibers run), at close it returns an empty `str` and `is_open()` becomes false; `wss://` is handled by the host. In other modes, or without the capability, `connect` raises `WebSocketError` with a "network capability" message. Binary messages arrive as `str` with the raw bytes. The server side (`serve_ws`) is not available on WebAssembly.

### Raw TCP: `nox.tls` and `nox.smtp`

`nox.tls` and `nox.smtp` compile on every WebAssembly target. For real connections on `wasm32-freestanding-asyncify` the host provides the **TCP capability**: `runNox(bytes, io, { tcp: await nodeTcp() })` (`nodeTcp` is built on Node's `net`/`tls` and exported from `wasm_host.mjs`), or `--allow-net` on the Node command line. A browser has no raw sockets: there `tcp` is not provided unless you give one, and `connect` raises `TlsError`/`SmtpError` with a "tcp capability" message. To get TCP in a browser, run the WebSocket-to-TCP bridge and pass `browserTcp` (see "TCP in a browser" below). **TLS terminates in the host**: the module carries no CA bundle or handshake code, and certificate validation (hostname included) lives in the host's TLS stack (Node: system CAs plus `NODE_EXTRA_CA_CERTS`). The `smtp` STARTTLS upgrade also happens in the host. Streaming uses the same suspension mechanism as `fetch` (a read parks the fiber, writes have no reply). Limit: `--threads`, plain freestanding and `wasm32-wasi*` do not have the capability.

### gRPC over TLS: `nox.grpc.connect_tls`

`nox.grpc` ([client](../stdlib/grpc.md)) compiles for `wasm32-freestanding-asyncify` and uses the host TCP capability. `connect_tls(host, port, ca_file, cert_file, key_file)` asks the host for TLS with ALPN `h2`; a server that does not select `h2` makes the connect fail. `ca_file`, `cert_file` and `key_file` are PEM paths on the **host's** file system (the host reads them: TLS terminates there): `nodeTcp({ tlsFiles: true })`, which the Node command line turns on together with `--allow-net`. An embedding host that builds `nodeTcp()` itself gets `tlsFiles: false` by default, and then a `connect_tls` that names a file fails with "TLS certificate files are not allowed by this host". Without file arguments it uses the host's trust store. `Redis` over TLS is not available in the wasm runtime.

### PostgreSQL

`nox.postgres` runs on WebAssembly with a PostgreSQL protocol 3.0 client written in Zig instead of `libpq` (it needs the host TCP capability, see "Raw TCP"). Authentication: trust, cleartext, MD5, SCRAM-SHA-256; queries: the simple protocol (`execute`/`query`) and the extended protocol (`prepare` + `bind_*`, text-format parameters and results, `$n` and `?` placeholders). The connection string is either `host=... port=... user=... password=... dbname=...` or `postgres://user:password@host:port/db?sslmode=require`. `sslmode=require|verify-ca|verify-full` uses SSLRequest plus the host's TLS (the host verifies the certificate, so all three modes verify — stricter than libpq's `require`); other modes are plain text (a deliberate departure from libpq's `prefer` default). Limits: no `COPY`, `LISTEN/NOTIFY`, binary format or named `PQprepare` statements (the same scope as the native driver).

### MySQL / MariaDB

`nox.mysql` runs on WebAssembly with a MySQL client protocol written in Zig instead of `libmysqlclient` (it needs the host TCP capability, see "Raw TCP"). Authentication: `mysql_native_password` and `caching_sha2_password` (MySQL 8's default: the fast path and, when the server's cache is empty, full authentication with the password encrypted under the server's RSA key with OAEP — no TLS required), including authentication-plugin switching. Queries use the text protocol (`COM_QUERY`); `prepare` + `bind_*` works as in the native driver, escaped on the client (aware of `NO_BACKSLASH_ESCAPES`) and embedded in the SQL. `last_insert_rowid()`, `changes()` and the `NULL` distinction work. Verified against real MySQL 8.4 and MariaDB 11 servers. Limits: no TLS (`open_url` carries no TLS option), TCP is used even for `localhost` (no Unix socket), only the first result of a multi-result statement such as `CALL` is returned, and there is no `LOCAL INFILE`.

### TCP in a browser (WebSocket-to-TCP bridge)

Every TCP-based module (`nox.tls`, `nox.smtp`, `nox.postgres`, `nox.mysql`, `nox.redis`, `nox.grpc`) works in a browser through a small Node process that turns a WebSocket into a TCP connection:

```bash
node compiler/wasm_tcp_bridge.mjs --listen 127.0.0.1:8765 --allow db.internal:5432,redis.internal:6379 --origin https://app.example.com --token SECRET
```

```text
import { runNox, browserTcp } from './wasm_host.mjs';
await runNox(bytes, io, { tcp: browserTcp({ url: 'ws://127.0.0.1:8765/', token: 'SECRET' }) });
```

One WebSocket carries one TCP connection (binary messages are the raw bytes). **TLS ends in the bridge**, not in the page: `connect(..., tls=True)` and the `STARTTLS` upgrades are performed by the bridge's TLS stack, which also verifies the certificate; the page never sees keys or certificates. The bridge is an open proxy, so `--allow` is **required** (same syntax as `--net-allow`; `"*"` allows everything); `--origin` and `--token` are optional extra checks, and a refused request gets an HTTP 403/400 before the WebSocket upgrade. `ca_file`/`cert_file`/`key_file` paths name files **on the bridge machine** and are honoured only with `--tls-files`. Limits: no back-pressure (a message is at most 16 MiB), one TLS upgrade per connection. The Node CLI can use the same path with `--tcp-bridge=ws://host:port/` (instead of `--allow-net`), which is how it is tested: the native redis programs run unchanged against real `redis-server` processes through the bridge.

### Redis

`nox.redis` runs on `wasm32-freestanding-asyncify` over the host TCP capability (see "Raw TCP"; `--allow-net` in the CLI host): the same RESP2 client as the native one — commands, binary payloads, Streams and consumer groups, cached scripts with `NOSCRIPT` recovery, `AUTH`/ACL users, dropped connections and `reconnect()`. `connect(..., tls=True, ca_file=...)` upgrades the connection with the host's TLS (the host verifies the certificate; a private CA goes through `ca_file`, an untrusted certificate is rejected). Mutual TLS client certificates are passed to the host as for gRPC. Verified against real `redis-server` processes with the same programs and expected output as the native tests. Not available on `wasm32-wasi` (no host TCP).

### Child processes (`nox.process`)

`nox.process` compiles on every WebAssembly target; running a process is a **host capability**. On `wasm32-freestanding-asyncify`, if the host provides a process provider (`runNox(bytes, io, { process: await nodeProcess() })`, or `--allow-process` on the Node command line, `noxc run --target wasm32-freestanding-asyncify --allow-process`), `Command(...).run()` works; otherwise it raises `ProcessError` ("could not run the process"). The default Node provider calls `child_process.spawn` **without a shell** (arguments are never interpreted by a shell, so there is no injection); output is buffered and the process is killed if `set_timeout` is exceeded. A browser has no processes (no provider is given). `--allow-net` does **not** turn the process capability on: network and process are separate switches.

### HTTP server (`nox.http.serve`)

The server is also a **host capability**: the module opens no socket. On `wasm32-freestanding-asyncify`, if the host provides a `serve` provider (`runNox(bytes, io, { serve: await nodeHttpServer(), serveSignal })`, `--allow-serve` on the Node command line, `noxc run --target wasm32-freestanding-asyncify --allow-serve`), `nox.http.serve(port, handler)` listens on the host (`port` 0: the host picks; the Node provider listens on `127.0.0.1` only by default, changed with `NOX_SERVE_HOST`), forwards every incoming request to the module, and the module runs `handler` in its own fiber per request. Handlers can use `nox.http.get` (the host's `fetch`), `nox.sqlite` and `nox.fs` like any fiber, and the `nox.router`/`nox.web` building blocks work unchanged. The provider interface is `listen(port, handle) -> Promise<{ port, close() }>` and `handle({ method, target, headers, body, peer }) -> Promise<{ status, headers, body }>`: instead of Node's `node:http` you can plug in another engine, a service worker or your own server. When `serveSignal` (an `AbortSignal`) aborts (the CLI does that on `Ctrl-C`/SIGTERM) the listeners close, `serve` returns and the program ends normally. Without the capability, `serve` prints a diagnostic and returns at once, as before.

Limits: handler rounds run in batches (requests in one round run concurrently; new requests wait in a queue until the round finishes); there are no streaming responses (`stream`/`respstream_*`), no WebSocket upgrade (`serve_ws`), no TLS (the host terminates it), no HTTP/2 and no multi-core `serve_multicore`; `wasm32-freestanding-asyncify` only.

## Host security policies

Capabilities are off by default; when they are on, the host's `node` providers apply the limits below. A host that runs untrusted code (a multi-tenant platform, for example) should tighten them or supply its own providers.

- **Network allow-list:** `--net-allow=host[:port],*.domain[:port],...` (or `NOX_NET_ALLOW`; also accepted by `noxc run`) together with `--allow-net` limits `fetch`, WebSocket and raw TCP connections to the listed destinations (no port, or `*`, means any port; `*.domain` does not cover the apex name). `fetch` redirects are followed manually and every hop is checked again. The host name is matched as the module gives it: there is no IP check after DNS resolution, so an allowed name that resolves to a private address is the operator's responsibility. It is not supported with `--threads` modules (refused explicitly). Programmatic equivalents: `netPolicy`, `restrictFetch`, `restrictTcp`, `restrictWebSocket`.
- **Process allow-list:** `--allow-process=git,/usr/bin/env` allows only the listed programs (plain `--allow-process` allows all; the program is matched as the module gives it, with no path search). `nodeProcess` limits the sum of stdout and stderr to `maxOutputBytes` (16 MiB by default) and kills the process when it is exceeded. Programmatic equivalent: `restrictProcess`.
- **HTTP server quotas:** `nodeHttpServer({ maxBodyBytes: 10 MiB, maxResponseBytes: 64 MiB, requestTimeoutMs: 30000, maxConcurrent: 64 })`. When one is exceeded the client gets 413 (body), 500 (response), 504 (handler time) or 503 (concurrency); the response of a request that timed out or whose client disconnected is dropped.
- **`--vfs-dir`:** a symbolic link under the root is never written through or deleted through, so nothing escapes the root.
- **Compiler in the browser:** the `compileToIr` options (`target`, `deny`, `label`) cannot contain control characters; otherwise a `\ndeny=` inside a `label` could have bypassed a capability restriction.
