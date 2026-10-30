//! Faz 10 (WASM): stdlib kabuklarının paylaştığı, ağ/iş parçacığı bağımlılığı OLMAYAN yardımcılar. `http_client.zig` bunları yeniden
//! dışa aktarır (eski çağıranlar değişmeden çalışır); wasm32-wasi çalışma zamanı `http_client.zig`yi (soket + `std.Thread`) HİÇ derlemez.

const std = @import("std");
const str_mod = @import("../str.zig");

/// Bir C bayt dizisini YENİ, sıfırla-sonlanan, paketlenmiş uzunluk+ascii başlıklı bir Nox `str`ine kopyalar — `runtime/str.zig`nin KANONİK
/// `nox_str_from_bytes` sarmalayıcısı.
pub fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes);
}

const wasm_host = @import("../wasm_host.zig");

fn fillRandom(buffer: []u8) void {
    if (comptime wasm_host.is_freestanding_wasm) {
        wasm_host.random_fill(buffer.ptr, buffer.len);
    } else {
        _ = std.os.wasi.random_get(buffer.ptr, buffer.len);
    }
}

fn hostRandom(_: ?*anyopaque, buffer: []u8) void {
    fillRandom(buffer);
}

fn hostRandomSecure(_: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    fillRandom(buffer);
}

/// Çok iş parçacıklı wasm'de `std.Io.Threaded` derlenmez (Zig 0.16 hatası): freestanding'deki entropi kancalı `failing` varyantı kullanılır.
const use_host_io = wasm_host.is_freestanding_wasm or !@import("builtin").single_threaded;

/// wasm32-freestanding'de `std.Io`: hiçbir işletim sistemi G/Ç'si yok (`std.Io.failing`), ama entropi `nox_host.random_fill`den gelir (parola özetleri tuz için ister).
const host_io_vtable = blk: {
    var v = std.Io.failing.vtable.*;
    v.random = hostRandom;
    v.randomSecure = hostRandomSecure;
    break :blk v;
};

/// wasm32'de (tek iş parçacıklı) `std.Io` örneği: `http_client.sharedClientIo` (iş parçacığı havuzlu `Threaded`) yerine geçer. wasi: `Threaded.global_single_threaded`;
/// freestanding: yukarıdaki entropi kancalı `failing` varyantı.
pub fn sharedClientIo() std.Io {
    if (comptime use_host_io) return .{ .userdata = null, .vtable = &host_io_vtable };
    return std.Io.Threaded.global_single_threaded.io();
}

test "dupeToNoxStr: baytları kopyalar" {
    const out = dupeToNoxStr(null, "abc") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("abc", std.mem.span(out));
}
