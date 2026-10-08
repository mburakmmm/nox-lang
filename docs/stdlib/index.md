# The standard library

The standard library is written in Nox itself (`stdlib/nox/*.nox`) with thin Zig shims wherever the operating system is involved. It ships with every
compiler and is imported with `import nox.<module>` or `from nox.<module> import …`. Everything on these pages is part of the [stable Nox API](../apis/napi.md): signatures
and documented behaviour do not change within 2.x.

## How to read these pages

Each module page states how to import it, the **capability** it needs, a reference table of every public function and class, runnable examples whose output is checked, and
notes about limits and traps. Three conventions recur:

- **Qualified vs unqualified.** Ordinary functions are called qualified (`nox.strings.upper(s)`); `extern def` bindings are never name-mangled, so the few of those (the `libm` functions in
  [`nox.math`](math.md)) are called unqualified. Each page says which.
- **Exceptions.** Each module that can fail defines its own exception class (`FsError`, `JsonError`, …), a subclass of `Exception`. Import the class by name to catch it
  (`from nox.fs import FsError`); qualified names are not accepted in an `except` clause. The text of messages produced by the library is not part of the API.
- **Indexes.** Positions are zero-based everywhere, including SQL parameter indexes.

## Capabilities

Every module has a **capability** set — the kind of authority it needs. In the default `hosted` profile all are available; the `freestanding` profile (kernels, no operating system) permits only modules
with no capability requirement. `nox.crypto` and `nox.time` are finer-grained: only the functions that need entropy or a clock are marked.

| Capability | Meaning | Modules |
|---|---|---|
| none | pure computation | `strings`, `mathx`, `random`, `collections`, `bits`, `buffer`, `binary`, `path`, `console`, `json`, `toml`, `yaml`, `csv`, `regex`, `template`, `validate`, `url`, `gzip`, `db`, `orm`, `router`, `reflect`, `mem`, `test`, `uuid`, `crypto`*, `time`* |
| `filesystem` | files and directories | `fs`, `sqlite` |
| `network` | sockets | `http`, `websocket`, `tls`, `smtp`, `postgres`, `mysql` |
| `process` | the process and its children | `os`, `process` |
| `threads` | native threads | `thread`, `atomic` |
| `clock` | reading the system clock | `log` (and the clock functions of `time`) |
| `shared_memory` | cross-process memory | `sharedmem` |
| `libc_math` | the C math library | `math` |
| `entropy` | operating-system randomness | the salt-generating functions of `crypto` |

`base64`, `jwt`, `native` and `plugin` are hosted-only (they are not on the freestanding allow-list). See [Freestanding](../tools/freestanding.md).

## The prelude

Some names are available **without any import**: `print`, `len`, `range`, `sorted`, `min`, `max`, `sum`, `abs`, `round`, `enumerate`, `zip`, `map`, `filter`, `input`, the exception classes
(`Exception`, `ValueError`, `IndexError`, `KeyError`, `ZeroDivisionError`, `AssertionError`, `CancelledError`), `JsonValue`, and the generic concurrency types (`Task`, `Channel`, …). They are documented in
[Built-in functions](../language/builtins.md).

## Modules by area

### Text and numbers

| Module | Purpose |
|---|---|
| [`nox.strings`](strings.md) | split, join, trim, replace, search, padding, byte-level helpers |
| [`nox.math`](math.md), [`nox.mathx`](mathx.md) | floating-point mathematics (libm-backed / libc-free) |
| [`nox.random`](random.md) | pseudo-random numbers and shuffling |
| [`nox.time`](time.md) | wall clock, sleeping, calendar date-times, monotonic intervals |
| [`nox.regex`](regex.md) | simple pattern matching |
| [`nox.template`](template.md) | `{{ name }}` text templates, HTML-escaped by default |

### Data structures and binary data

| Module | Purpose |
|---|---|
| [`nox.collections`](collections.md) | stack, queue, deque, set, counter, ordered map, LRU cache, heap, priority queue |
| [`nox.bits`](bits.md) | rotations, byte swaps, endianness, single-bit helpers |
| [`nox.buffer`](buffer.md) | fixed-size byte buffers and spans |
| [`nox.binary`](binary.md) | cursor-based binary readers and writers |

### Files, processes and the environment

| Module | Purpose |
|---|---|
| [`nox.fs`](fs.md) | read, write, copy, rename, list, inspect |
| [`nox.path`](path.md) | path manipulation |
| [`nox.os`](os.md) | arguments, environment variables, working directory, exit |
| [`nox.process`](process.md) | run external programs |
| [`nox.console`](console.md), [`nox.log`](log.md) | levelled output without / with timestamps |

### Formats and encodings

| Module | Purpose |
|---|---|
| [`nox.json`](json.md), [`nox.toml`](toml.md), [`nox.yaml`](yaml.md), [`nox.csv`](csv.md) | parsers and writers |
| [`nox.validate`](validate.md) | validate JSON against a schema |
| [`nox.url`](url.md) | URLs, percent-encoding, query strings |
| [`nox.base64`](base64.md), [`nox.uuid`](uuid.md), [`nox.gzip`](gzip.md) | Base64, UUIDs, compression |

### Security

| Module | Purpose |
|---|---|
| [`nox.crypto`](crypto.md) | hashes, HMAC, secure randomness, password hashing |
| [`nox.jwt`](jwt.md) | HS256 JSON Web Tokens |

### Networking and the web

| Module | Purpose |
|---|---|
| [`nox.http`](http.md) | HTTP client and server (TLS and WebSocket upgrade included) |
| [`nox.router`](router.md) | path routing and middleware |
| [`nox.websocket`](websocket.md) | WebSocket client and server connection |
| [`nox.tls`](tls.md) | client TLS streams |
| [`nox.smtp`](smtp.md) | send e-mail |

### Databases

| Module | Purpose |
|---|---|
| [`nox.db`](db.md) | shared `Row`, `Statement` and the `DbConnection` protocol |
| [`nox.sqlite`](sqlite.md), [`nox.postgres`](postgres.md), [`nox.mysql`](mysql.md) | drivers |
| [`nox.orm`](orm.md) | parameterised CRUD helpers over any driver |

### Concurrency and low level

| Module | Purpose |
|---|---|
| [`nox.thread`](thread.md) | worker threads and thread channels |
| [`nox.atomic`](atomic.md) | atomic counters and flags shared between workers |
| [`nox.sharedmem`](sharedmem.md) | shared memory between processes |
| [`nox.mem`](mem.md) | bulk typed-pointer operations and volatile access |

### Reflection, extensions and testing

| Module | Purpose |
|---|---|
| [`nox.reflect`](reflect.md) | decorator and class metadata |
| [`nox.native`](native.md), [`nox.plugin`](plugin.md) | load native plugins ([NNI](../apis/nni.md), [Plugin API](../apis/plugin-api.md)) |
| [`nox.test`](test.md) | assertions and test suites |

## Third-party libraries

Anything outside `nox.*` — web frameworks such as [Nyx](https://github.com/mburakmmm/nyx), database layers, utilities — comes from packages: see [Packages](../tools/packages.md) and the
[noxpkg registry](../tools/noxpkg.md).
