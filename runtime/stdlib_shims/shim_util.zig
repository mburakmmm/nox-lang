//! Faz 10 (WASM): stdlib kabuklarının paylaştığı, ağ/iş parçacığı bağımlılığı OLMAYAN yardımcılar. `http_client.zig` bunları yeniden
//! dışa aktarır (eski çağıranlar değişmeden çalışır); wasm32-wasi çalışma zamanı `http_client.zig`yi (soket + `std.Thread`) HİÇ derlemez.

const std = @import("std");
const str_mod = @import("../str.zig");

/// Bir C bayt dizisini YENİ, sıfırla-sonlanan, paketlenmiş uzunluk+ascii başlıklı bir Nox `str`ine kopyalar — `runtime/str.zig`nin KANONİK
/// `nox_str_from_bytes` sarmalayıcısı.
pub fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes);
}

/// v2.1.57: geçici tamponlar için allocator. Hosted ve wasm'da `std.heap.page_allocator` (eski davranış); freestanding (wasm DIŞI) çekirdekte `page_allocator` YOKTUR (`std.heap.page_size_max`
/// sağlanmaz): `lib_freestanding.zig` çalışma zamanı kurulurken çekirdeğin kendi allocator'ını burada bir kez kaydeder (AGENTS §2.6 belgeli bootstrap-durumu istisnası; `project/global-state-allowlist.tsv`).
pub const bare_kernel = (@import("builtin").os.tag == .freestanding or @import("builtin").os.tag == .other) and !@import("builtin").cpu.arch.isWasm();
var g_bare_scratch: std.mem.Allocator = undefined;
var g_bare_scratch_ready: bool = false;

pub fn setBareScratch(a: std.mem.Allocator) void {
    g_bare_scratch = a;
    g_bare_scratch_ready = true;
}

/// Çıplak çekirdekte (FS tabanı kurulu değil: `threadlocal` erişimi #GP verir) düz global, diğer hedeflerde `threadlocal` depolama. Kullanım: `const Slot = shim_util.TlsSlot(bool, true);` ... `Slot.value`.
pub fn TlsSlot(comptime T: type, comptime init_value: T) type {
    return if (bare_kernel) struct {
        pub var value: T = init_value;
    } else struct {
        pub threadlocal var value: T = init_value;
    };
}

pub fn scratchAllocator() std.mem.Allocator {
    if (comptime bare_kernel) {
        if (!g_bare_scratch_ready) @panic("freestanding scratch allocator is not installed");
        return g_bare_scratch;
    }
    return std.heap.page_allocator;
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
