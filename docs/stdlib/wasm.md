# nox.wasm

Run a WebAssembly module from Nox, with a persistent instance handle.

```text
import nox.wasm
from nox.wasm import Instance, WasmError, open, open_with_limits, from_bytes
```

**Capability:** `filesystem` (it reads a module file; `from_bytes` needs no file). It is not `dynamic_code`: nothing is loaded natively, the module only runs inside the sandboxed interpreter, so the module is available on mobile targets too. It is not available on `--target wasm32-*` (the wasm runtime has no embedded engine) or on freestanding targets.

The engine is Nox's own pure-Zig validator and interpreter (no JIT, no third-party code, so it behaves the same on every host including iOS and Android). The module runs **sandboxed**: it has no file, network or process access. A module that imports functions needs a `Host` (below); a module that imports host memory, tables or globals cannot be opened. Two limits stop runaway modules: a **fuel** budget (instructions executed; default 2 billion) and a **memory ceiling** (default 4096 pages of 64 KiB = 256 MiB). A trap, an exhausted budget or an invalid module raises `WasmError`.

The handle is opaque (Nox never receives the module's raw memory, only bounds-checked copies through `read_*`/`write_*`). An `Instance` works in a `with` block and `close()` is idempotent.

## Opening

| Function | Meaning |
|---|---|
| `open(path)` | read and instantiate a `.wasm` file |
| `open_with_limits(path, fuel, max_pages)` | same with an instruction budget and a memory page ceiling (`<= 0` keeps the default) |
| `from_bytes(data)` | instantiate from a `list[int]` of byte values (0..255) |
| `from_bytes_with_limits(data, fuel, max_pages)` | `from_bytes` with the same limits |

## Calling

| Method | Meaning |
|---|---|
| `call(name, args)` | call an exported function with integer arguments (at most 16); returns the first result (0 if none). `i32` results are sign-extended |
| `call_f(name, args)` | call with `float` arguments (`f32`/`f64` parameters take the value; integer parameters truncate); returns the first result as `float` |
| `result(i)` / `result_count()` | raw 64-bit pattern of result `i` from the last call (multi-value) |
| `exports()` | names of the exported functions |
| `signature(name)` | `"i32,i32->i32"`, or `""` when there is no such export |

`f64_bits`, `f64_from_bits`, `f32_bits` and `f32_from_bits` convert between a `float` and the raw bit pattern, for modules that pass floats through integer slots.

## Linear memory

| Method | Meaning |
|---|---|
| `memory_size()` | size in bytes (0 without a memory) |
| `read_bytes(offset, length)` / `write_bytes(offset, data)` | copy bytes as a `list[int]` |
| `read_str(offset, length)` / `write_str(offset, text)` | UTF-8 text (a `str` cannot contain NUL, so a read stops at the first NUL) |
| `load(offset, width)` / `store(offset, width, value)` | little-endian unsigned integer of 1, 2, 4 or 8 bytes |

Every access is bounds-checked against the module's current memory; an out-of-range access raises `WasmError` and never touches memory outside the module.

```nox
import nox.wasm

# (module (memory 1) (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
code: list[int] = [0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1, 7, 13, 2, 3, 97, 100, 100, 0, 0, 3, 109, 101, 109, 2, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 106, 11]
with nox.wasm.from_bytes(code) as m:
    print(m.call("add", [40, 2]))
    print(m.signature("add"))
    m.write_str(64, "hello wasm")
    print(m.read_str(64, 10))
    m.store(16, 4, 305419896)
    print(m.load(17, 2))
```

```output
42
i32,i32->i32
hello wasm
13398
```

## Host functions (imports)

A module's imported functions are answered with Nox functions through a `Host`:

```text
h: Host = nox.wasm.host()
h.func1("env", "twice", twice)      # func0 .. func4 by number of parameters
inst: Instance = h.open(path)       # or h.open_bytes(data), h.open_with_limits(path, fuel, max_pages)
```

A host function takes up to **4 parameters and returns 1 result, all `int`**: `i32` arrives sign-extended, `i64` as is, `f32`/`f64` as raw bit patterns (convert with `f64_from_bits`/`f32_from_bits`). A lambda works. If the host function raises an exception, execution stops and the call raises `WasmError`; the instance stays usable. A missing import is reported by name before the module runs. The dispatcher exists only for the duration of each call (there are no stored callbacks).

```nox
import nox.wasm

# (module (import "env" "twice" (func (param i32) (result i32))) (func (export "run") (param i32) (result i32) local.get 0 call 0 i32.const 1 i32.add))
code: list[int] = [0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 2, 13, 1, 3, 101, 110, 118, 5, 116, 119, 105, 99, 101, 0, 0, 3, 2, 1, 0, 7, 7, 1, 3, 114, 117, 110, 0, 1, 10, 11, 1, 9, 0, 32, 0, 16, 0, 65, 1, 106, 11]
h: nox.wasm.Host = nox.wasm.host()
h.func1("env", "twice", lambda x: x * 2)
inst: nox.wasm.Instance = h.open_bytes(code)
print(inst.call("run", [20]))
inst.close()
```

```output
41
```

## WASI preview1 subset (opt-in)

WASI is **off by default**; `h.enable_wasi(args)` turns on a small, capability-based subset: `fd_write` to stdout/stderr (captured in memory and read with `stdout()`/`stderr()`; `h.inherit_output()` also writes to the real streams on Unix), `args_get`/`args_sizes_get`, empty `environ_*`, `proc_exit`, `sched_yield` and inert `fd_*` calls (no file system, no stdin, no network). The clock and randomness are separate capabilities: `h.allow_clock()` enables `clock_time_get` and `h.allow_random()` enables `random_get`; without them the call returns the `EPERM` errno. `proc_exit(code)` stops the module; `inst.run_start()` runs `_start` and returns the exit code (0 on a normal return), and a plain `call` raises `WasmExit` instead.

A WASI function that the engine does not implement is reported by name when the module is opened.

## Speed

The engine is a plain interpreter (no JIT, by design: the same code runs on iOS and Android). Measured on an Apple M4, ReleaseFast: a recursive `fib(32)` takes about 170 ms (V8's JIT: 9 ms) and a 100-million-iteration `i64` loop about 1.3 s (V8: 0.12 s), roughly 10-20 times slower than a JIT. It is meant for plugins, sandboxed helpers and portable modules, not for heavy numeric kernels; for those compile the code natively or use `extern def`. The fuel budget counts branches and calls.

## Robustness

The binary parser, the instantiation step (imports, memory and table setup, `start` function) and the execution of exported functions are fuzzed (`tests/fuzz/wasm_parser_fuzz.zig`), and every single-byte mutation and every prefix of three small valid modules is checked on each test run: no input may crash, hang or leak. Differential tests compare 36 904 numeric vectors and real compiled programs against Node's WebAssembly engine on every CI run.

