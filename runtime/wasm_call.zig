//! `wasm_call(path, func, arg)` yerleşiğinin çalışma zamanı girişi (Faz 14): `path`teki `.wasm` ikilisini yükler, `func` adlı (yalnızca `i32` parametre/dönüşlü) export'u `arg` ile çağırıp sonucu
//! döner. Her çağrı modülü baştan ayrıştırıp çalıştırır ve bırakır (önbellek yok); allocator her zaman `rt` üzerindendir (İlke #6). Hata durumunda `0` döner. (Eski `foreign_bridge.zig`nin HPy kısmı
//! v2.2.69'da kaldırıldı; WASM'a özgü bu giriş korundu. Zengin WASM kullanımı için `nox.wasm` modülüne bakın.)

const std = @import("std");
const asap = @import("alloc/asap.zig");
const wasm_bridge = @import("wasm_bridge");


/// Doğrudan libc bağlamaları: bu dosya `std.Io`yu kullanmaz; runtime sistem `cc`siyle bağlandığı için bu semboller her zaman mevcuttur (yalnızca bir dosyayı baştan sona okumak için).
const libc = struct {
    extern "c" fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    extern "c" fn fclose(stream: *anyopaque) c_int;
    extern "c" fn fread(ptr: [*]u8, size: usize, count: usize, stream: *anyopaque) usize;
    extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
    extern "c" fn ftell(stream: *anyopaque) c_long;
};


fn readFileAll(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const f = libc.fopen(path, "rb") orelse return error.FileNotFound;
    defer _ = libc.fclose(f);
    if (libc.fseek(f, 0, 2) != 0) return error.SeekFailed; // SEEK_END
    const size = libc.ftell(f);
    if (size < 0) return error.TellFailed;
    _ = libc.fseek(f, 0, 0); // SEEK_SET
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = libc.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

/// `path`teki `.wasm` ikilisini yükler, `func_name` adlı (yalnızca `i32`
/// parametre/dönüşlü) export'u `arg` ile çağırıp sonucu döner.
pub export fn nox_wasm_call(
    rt: ?*anyopaque,
    path: ?[*:0]const u8,
    func_name: ?[*:0]const u8,
    arg: i64,
) i64 {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return 0));
    const allocator = state.allocator();
    const p = path orelse return 0;
    const fnm = func_name orelse return 0;

    const bytes = readFileAll(allocator, p) catch return 0;
    defer allocator.free(bytes);

    var mod = wasm_bridge.module.parse(allocator, bytes) catch return 0;
    defer mod.deinit();

    const func_index = mod.findExportedFunc(std.mem.span(fnm)) orelse return 0;
    const arg32: i32 = @truncate(arg);
    const result = wasm_bridge.interp.callFunc(allocator, &mod, func_index, &.{arg32}) catch return 0;
    return result orelse 0;
}
