# nox.wasm

Run a WebAssembly module from Nox, with a persistent instance handle.

```text
import nox.wasm
from nox.wasm import Instance, WasmError, open, open_with_limits, from_bytes
```

**Capability:** `filesystem` (it reads a module file; `from_bytes` needs no file). It is not `dynamic_code`: nothing is loaded natively, the module only runs inside the sandboxed interpreter, so the module is available on mobile targets too. It is not available on `--target wasm32-*` (the wasm runtime has no embedded engine) or on freestanding targets.

The engine is Nox's own pure-Zig validator and interpreter (no JIT, no third-party code, so it behaves the same on every host including iOS and Android). The module runs **sandboxed**: it has no file, network or process access, and `open` rejects a module that imports host functions or a host memory (host functions are a later step). Two limits stop runaway modules: a **fuel** budget (instructions executed; default 2 billion) and a **memory ceiling** (default 4096 pages of 64 KiB = 256 MiB). A trap, an exhausted budget or an invalid module raises `WasmError`.

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
