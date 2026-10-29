//! Faz 10 (WASM): stdlib kabuklarının paylaştığı, ağ/iş parçacığı bağımlılığı OLMAYAN yardımcılar. `http_client.zig` bunları yeniden
//! dışa aktarır (eski çağıranlar değişmeden çalışır); wasm32-wasi çalışma zamanı `http_client.zig`yi (soket + `std.Thread`) HİÇ derlemez.

const std = @import("std");
const str_mod = @import("../str.zig");

/// Bir C bayt dizisini YENİ, sıfırla-sonlanan, paketlenmiş uzunluk+ascii başlıklı bir Nox `str`ine kopyalar — `runtime/str.zig`nin KANONİK
/// `nox_str_from_bytes` sarmalayıcısı.
pub fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes);
}

/// wasm32-wasi'de (tek iş parçacıklı) `std.Io` örneği: `http_client.sharedClientIo` (iş parçacığı havuzlu `Threaded`) yerine geçer.
pub fn sharedClientIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "dupeToNoxStr: baytları kopyalar" {
    const out = dupeToNoxStr(null, "abc") orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("abc", std.mem.span(out));
}
