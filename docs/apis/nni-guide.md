# Writing a native plugin

This guide builds complete NNI plugins in **C**, **Zig** and **Rust**, loads them from Nox, adds a manifest, sends events from a native thread and
shows the testing and packaging workflow. Read the [NNI reference](nni.md) for the exact contracts and the [Plugin API](plugin-api.md) for manifests.

Every plugin below was built and loaded with the commands shown.

## 1. A plugin in C

`myext.c` exposes `add(int, int) -> int` and `greet(str) -> str`:

```c
#include "nox_nni.h"
#include <stdio.h>
#include <string.h>

/* add(int, int) -> int */
static NoxStatus fn_add(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    if (argc != 2 || args[0].kind != NOX_V_INT || args[1].kind != NOX_V_INT) {
        const char* msg = "add(int, int) expects two integers";
        return api->error_set(rt, 1, (const uint8_t*)msg, strlen(msg));
    }
    out->kind = NOX_V_INT;
    out->u.i = args[0].u.i + args[1].u.i;
    return NOX_OK;
}

/* greet(str) -> str */
static NoxStatus fn_greet(const NoxApiV1* api, NoxRuntime* rt, const NoxValue* args, size_t argc, NoxValue* out) {
    if (argc != 1 || args[0].kind != NOX_V_STRING) return NOX_ERROR;
    const uint8_t* name;
    size_t n;
    if (api->string_view(rt, args[0].u.h, &name, &n) != NOX_OK) return NOX_ERROR;
    char buf[256];
    int len = snprintf(buf, sizeof buf, "hello, %.*s!", (int)n, (const char*)name);
    out->kind = NOX_V_STRING;
    out->u.h = api->string_new(rt, (const uint8_t*)buf, (size_t)len);
    return out->u.h ? NOX_OK : NOX_OUT_OF_MEMORY;
}

NOX_EXPORT NoxStatus nox_plugin_init_v1(const NoxApiV1* api, NoxRuntime* rt) {
    if (api->abi_version < 1 || api->struct_size < sizeof(NoxApiV1)) return NOX_ABI_UNSUPPORTED;
    api->register_function(rt, "add", fn_add);
    api->register_function(rt, "greet", fn_greet);
    return NOX_OK;
}
```

Build it (point `-I` at the directory containing `nox_nni.h`, shipped in the release's `include/` directory and in the repository):

```sh
cc -shared -fPIC -I include -o libmyext.so    myext.c     # Linux
cc -shared -fPIC -I include -o libmyext.dylib myext.c     # macOS
```

### Loading it raw with `nox.native`

```nox-fragment
from nox.native import open_plugin, Plugin, NativeError

p: Plugin = open_plugin("./libmyext.dylib")
p.arg_int(40)
p.arg_int(2)
print(p.call_int("add"))          # 42
p.arg_str("nox")
print(p.call_str("greet"))        # hello, nox!
try:
    p.call("nope")
except NativeError as e:
    print(e.message)              # nope: no registered native function with that name
p.close()
```

Arguments are pushed one at a time (`arg_int`, `arg_float`, `arg_bool`, `arg_str`) and consumed by the next call. `call_int`, `call_float`, `call_bool`,
`call_str` read the result; `call` ignores it. A `NOX_ERROR` status raises `NativeError` with the message you gave `error_set`.

### Loading it with a manifest (recommended)

Add `nox-plugin.json` next to the library:

```json
{
  "name": "demo.hello",
  "version": "1.0.0",
  "plugin_api": 1,
  "library": {
    "macos-arm64": "libmyext.dylib",
    "linux-x64": "libmyext.so",
    "linux-arm64": "libmyext.so",
    "windows-x64": "myext.dll"
  },
  "capabilities": [],
  "functions": [
    { "name": "add", "args": ["int", "int"], "returns": "int" },
    { "name": "greet", "args": ["str"], "returns": "str" }
  ]
}
```

```nox-fragment
from nox.plugin import load_plugin, LoadedPlugin, PluginError

p: LoadedPlugin = load_plugin("nox-plugin.json", [])
p.arg_int(40)
p.arg_int(2)
print(p.call_int("add"))          # 42
p.arg_str("nox")
print(p.call_str("greet"))        # hello, nox!
try:
    p.arg_str("oops")
    p.arg_int(1)
    print(p.call_int("add"))
except PluginError as e:
    print(e.message)              # add: argument 1 must be int, got str
p.shutdown()
```

The wrong-typed call never reaches native code: `nox.plugin` checks every call against the manifest signature first.

## 2. A plugin in Zig

```zig
const std = @import("std");
const c = @cImport(@cInclude("nox_nni.h"));

fn hypot2(api: [*c]const c.NoxApiV1, rt: ?*c.NoxRuntime, args: [*c]const c.NoxValue, argc: usize, out: [*c]c.NoxValue) callconv(.c) c.NoxStatus {
    _ = api;
    _ = rt;
    if (argc != 2 or args[0].kind != c.NOX_V_FLOAT or args[1].kind != c.NOX_V_FLOAT) return c.NOX_ERROR;
    const a = args[0].u.f;
    const b = args[1].u.f;
    out.*.kind = c.NOX_V_FLOAT;
    out.*.u.f = @sqrt(a * a + b * b);
    return c.NOX_OK;
}

export fn nox_plugin_init_v1(api: [*c]const c.NoxApiV1, rt: ?*c.NoxRuntime) callconv(.c) c.NoxStatus {
    if (api.*.abi_version < 1 or api.*.struct_size < @sizeOf(c.NoxApiV1)) return c.NOX_ABI_UNSUPPORTED;
    return api.*.register_function.?(rt, "hypot", hypot2);
}
```

```sh
zig build-lib -dynamic -O ReleaseFast -I include -lc -femit-bin=libzigplug.dylib plug.zig
```

The manifest declares `{ "name": "hypot", "args": ["float", "float"], "returns": "float" }`; from Nox:

```nox-fragment
p: LoadedPlugin = load_plugin("nox-plugin.json", [])
p.arg_float(3.0)
p.arg_float(4.0)
print(p.call_float("hypot"))      # 5.0
```

## 3. A plugin in Rust

Rust needs no binding generator — declare the few `#[repr(C)]` types of the header (or generate them with `bindgen` from `nox_nni.h`). `Cargo.toml`:

```text
[package]
name = "rustplug"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]
```

`src/lib.rs` — `word_count(str) -> int`:

```text
use std::os::raw::{c_char, c_int, c_void};

pub const NOX_OK: i32 = 0;
pub const NOX_ERROR: i32 = 1;
pub const NOX_ABI_UNSUPPORTED: i32 = 3;
pub const NOX_V_INT: i32 = 1;
pub const NOX_V_STRING: i32 = 4;

#[repr(C)] #[derive(Clone, Copy)]
pub union NoxValueData { pub i: i64, pub f: f64, pub h: u64 }

#[repr(C)]
pub struct NoxValue { pub kind: i32, pub reserved: i32, pub u: NoxValueData }

pub type NoxRuntime = c_void;
pub type NoxNativeFn =
    extern "C" fn(*const NoxApiV1, *mut NoxRuntime, *const NoxValue, usize, *mut NoxValue) -> i32;

#[repr(C)]
pub struct NoxApiV1 {
    pub abi_version: u32,
    pub struct_size: u32,
    pub retain: extern "C" fn(*mut NoxRuntime, u64),
    pub release: extern "C" fn(*mut NoxRuntime, u64),
    pub string_new: extern "C" fn(*mut NoxRuntime, *const u8, usize) -> u64,
    pub string_view: extern "C" fn(*mut NoxRuntime, u64, *mut *const u8, *mut usize) -> i32,
    pub bytes_new: extern "C" fn(*mut NoxRuntime, *const u8, usize) -> u64,
    pub bytes_view: extern "C" fn(*mut NoxRuntime, u64, *mut *const u8, *mut usize) -> i32,
    pub alloc: extern "C" fn(*mut NoxRuntime, usize, usize) -> *mut c_void,
    pub free: extern "C" fn(*mut NoxRuntime, *mut c_void, usize, usize),
    pub error_set: extern "C" fn(*mut NoxRuntime, i32, *const u8, usize) -> i32,
    pub register_function: extern "C" fn(*mut NoxRuntime, *const c_char, NoxNativeFn) -> i32,
    pub post_event: extern "C" fn(*mut NoxRuntime, i64, *const NoxValue) -> i32,
}

extern "C" fn word_count(api: *const NoxApiV1, rt: *mut NoxRuntime,
                         args: *const NoxValue, argc: usize, out: *mut NoxValue) -> i32 {
    unsafe {
        let api = &*api;
        if argc != 1 || (*args).kind != NOX_V_STRING {
            let msg = b"word_count(str) expects one string";
            return (api.error_set)(rt, 1, msg.as_ptr(), msg.len());
        }
        let mut data: *const u8 = std::ptr::null();
        let mut len: usize = 0;
        if (api.string_view)(rt, (*args).u.h, &mut data, &mut len) != NOX_OK { return NOX_ERROR; }
        let text = std::str::from_utf8_unchecked(std::slice::from_raw_parts(data, len));
        (*out).kind = NOX_V_INT;
        (*out).u.i = text.split_whitespace().count() as i64;
        NOX_OK
    }
}

#[no_mangle]
pub extern "C" fn nox_plugin_init_v1(api: *const NoxApiV1, rt: *mut NoxRuntime) -> c_int {
    unsafe {
        let a = &*api;
        if a.abi_version < 1 || (a.struct_size as usize) < std::mem::size_of::<NoxApiV1>() {
            return NOX_ABI_UNSUPPORTED;
        }
        (a.register_function)(rt, b"word_count\0".as_ptr() as *const c_char, word_count)
    }
}
```

```sh
cargo build --release          # target/release/librustplug.dylib (or .so / .dll)
```

Declare `{ "name": "word_count", "args": ["str"], "returns": "int" }` in the manifest; `p.arg_str("the quick  brown fox")` followed by
`p.call_int("word_count")` returns `4`. Rust's `catch_unwind` is not needed: make sure no panic crosses the `extern "C"` boundary (build with
`panic = "abort"` or wrap bodies in `std::panic::catch_unwind` and map a caught panic to `NOX_PANIC`).

## 4. Sending events from a native thread

Native threads must not touch the Nox object graph. They send **events** that Nox code drains on its own scheduler. This plugin starts a thread that posts
numbered values and a final string:

```c
static const NoxApiV1* g_api;
static NoxRuntime* g_rt;

static void* worker(void* arg) {
    int64_t n = (int64_t)(intptr_t)arg;
    for (int64_t i = 0; i < n; i++) {
        NoxValue v = { .kind = NOX_V_INT, .reserved = 0, .u = { .i = i * 10 } };
        g_api->post_event(g_rt, 7, &v);           /* kind 7: a number */
    }
    NoxHandle h = g_api->string_new(g_rt, (const uint8_t*)"done", 4);
    NoxValue sv = { .kind = NOX_V_STRING, .reserved = 0, .u = { .h = h } };
    g_api->post_event(g_rt, 8, &sv);              /* kind 8: finished */
    g_api->release(g_rt, h);
    return NULL;
}
/* register a `start_thread(int)` function that stores api/rt and pthread_create()s `worker` */
```

```nox-fragment
from nox.native import Event

p.arg_int(3)
p.call("start_thread")
got: int = 0
done: bool = False
while not done:
    ev: Event | None = p.wait_event(2000)      # waits up to 2000 ms
    if ev == None:
        done = True
    else:
        if ev.kind == 7:
            got += ev.int_value
        else:
            print(ev.str_value, got)           # done 30
            done = True
```

`wait_event` and `poll_event` return an `Event` (`kind`, `value_kind`, `int_value`, `float_value`, `str_value`) or `None`. Payloads are copied, so the
plugin can release its handles immediately after `post_event`. Stop the thread in `nox_plugin_shutdown_v1`.

## 5. Testing a plugin

- **Unit-test the C/Rust/Zig code** with its own test framework — NNI functions are plain functions taking an `NoxApiV1*`; you can pass a mock table.
- **Integration-test through Nox:** a `*_test.nox` file that loads the plugin with `load_plugin` and asserts on results (`noxc test`).
- **Test the failure paths:** wrong argument counts and types (the manifest check), `NOX_ERROR` returns (`NativeError`), and a missing library or platform entry (`PluginError`).
- **Test on every platform you ship** — the manifest's `library` table picks the file per platform.

The repository's own tests do exactly this: `tests/compat/nni_ext/plugin.c` is exercised by `tests/cli/nni_test.zig` and `tests/cli/plugin_test.zig`.

## 6. Packaging

Ship a directory containing `nox-plugin.json` and the libraries for each platform. Users put it anywhere and call
`load_plugin("path/to/nox-plugin.json", allowed_capabilities)`. Declare every capability the code needs — see [Plugin API](plugin-api.md#capabilities).
Version your manifest (`version`) independently of `plugin_api`, and keep NNI calls within the table members you rely on (`struct_size` gating) so one
binary works across Nox releases.

## Checklist

- [ ] Gate on `abi_version` and `struct_size` in `nox_plugin_init_v1`.
- [ ] Validate `argc` and every `kind` in every function (or declare signatures in the manifest *and* still validate).
- [ ] Never let an exception, panic or `longjmp` cross the boundary.
- [ ] Release every handle you create and do not keep views past the handle's lifetime.
- [ ] Stop your threads in `nox_plugin_shutdown_v1`.
- [ ] Declare capabilities honestly.
