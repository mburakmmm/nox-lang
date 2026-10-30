//! Faz 10 (WASM): derlenmiş Nox programının (`main(argc, argv)`) giriş köprüsü. Asyncify kipinde (`wasm_options.asyncify`, ADR-014) `main` fiber sürücüsünün
//! ana kökü olarak çalışır; aksi halde doğrudan çağrılır. WASI için `__main_argc_argv` (wasi-libc `_start`ı çağırır), freestanding için `wasm_libc.zig`nin `_start`ı bunu kullanır.

const builtin = @import("builtin");
const wasm_options = @import("wasm_options");
const asyncify = @import("async_rt/asyncify.zig");

extern fn main(argc: i32, argv: u64) callconv(.c) i32;

threadlocal var g_argc: i32 = 0;
threadlocal var g_argv: u64 = 0;

fn mainThunk(_: usize) callconv(.c) i32 {
    return main(g_argc, g_argv);
}

pub fn run(argc: i32, argv: u64) i32 {
    if (comptime wasm_options.asyncify) {
        g_argc = argc;
        g_argv = argv;
        return asyncify.nox_asyncify_run(&mainThunk, 0);
    }
    return main(argc, argv);
}

/// WASI: wasi-libc'nin `__main_void`u bunu çağırır (argv işaretçisi 32-bit, Nox ise 64-bit sözcük bekler).
fn mainArgcArgv(argc: i32, argv: i32) callconv(.c) i32 {
    return run(argc, @as(u64, @as(u32, @bitCast(argv))));
}

comptime {
    if (builtin.os.tag == .wasi) @export(&mainArgcArgv, .{ .name = "__main_argc_argv" });
}
