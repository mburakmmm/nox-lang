//! `TaskLocal[T]` depolamasının paylaşılan türleri (bkz. `task_local.zig`, `fiber.zig`, `bridge_wasm.zig`).
//!
//! Pulse NOX-TASKLOCAL-001: çalışma zamanı TaskLocal değerlerinin Nox türünü bilmez; bu yüzden
//! `TaskLocal[T]()` kurulurken codegen türe uygun bırakma işlevini (`ReleaseFn`) ve `rt`yi tutamağa
//! (`Handle`) yazar, her `set` bu ikisini girdiye (`Entry`) kopyalar. Fiber/görev bittiğinde kalan
//! değerler `drain` ile BU işlevlerle bırakılır — `clear()` çağırmayan kod artık sızdırmaz. İşlev ve
//! `rt` girdinin kendisinde durduğu için tutamak (ör. yerel bir `TaskLocal`) fiberdan önce yok
//! edilse bile sarkan işaretçi OKUNMAZ. Fiber/zamanlayıcı katmanı `RuntimeState`ten bağımsız kalır
//! (İlke #6): `rt` yalnızca opak bir argüman olarak geri verilir.

const std = @import("std");
const builtin = @import("builtin");

// `runtime/abi_ptr.zig`nin geri-çağrı argümanı kuralının küçük kopyası: bu dosya `fiber.zig` gibi tek başına
// (`../` modül yolu DIŞINA çıkamayan) derlenen kardeşlerle birlikte yüklenir, bu yüzden `abi_ptr`ı içe aktaramaz.
// 64-bit hedeflerde `?*anyopaque`, wasm32'de `u64` (derlenmiş kodun geri-çağrılarında işaretçi `i64`dür).
const is_wasm = builtin.cpu.arch.isWasm();
const Arg = if (is_wasm) u64 else ?*anyopaque;
inline fn toArg(p: anytype) Arg {
    if (comptime is_wasm) return @as(u64, @intFromPtr(p));
    return @ptrCast(@constCast(p));
}
inline fn fromArg(a: Arg) ?*anyopaque {
    if (comptime is_wasm) return @ptrFromInt(@as(usize, @intCast(a)));
    return a;
}

pub const ReleaseFn = *const fn (Arg, Arg) callconv(.c) void;

pub const Handle = struct {
    rt: ?*anyopaque,
    release: ?ReleaseFn,
};

pub const Entry = struct {
    value: ?*anyopaque,
    rt: ?*anyopaque,
    release: ?ReleaseFn,
};

pub const Map = std.AutoHashMapUnmanaged(*anyopaque, Entry);

/// Haritadaki TÜM değerleri bırakır ve haritayı boşaltır. Bırakma kodu (kullanıcının `__del__`i dahil)
/// aynı haritaya dokunabileceğinden harita önce yerel bir kopyaya taşınır.
pub fn drain(map: *Map, allocator: std.mem.Allocator) void {
    if (map.count() == 0) return;
    var local = map.*;
    map.* = .empty;
    var it = local.iterator();
    while (it.next()) |kv| {
        const e = kv.value_ptr.*;
        const f = e.release orelse continue;
        const v = e.value orelse continue;
        f(toArg(e.rt), toArg(v));
    }
    local.deinit(allocator);
}

test "drain her değeri girdinin kendi işleviyle bırakır ve haritayı boşaltır" {
    const S = struct {
        var calls: usize = 0;
        var last_rt: usize = 0;
        fn rel(rt: Arg, p: Arg) callconv(.c) void {
            _ = p;
            calls += 1;
            last_rt = @intFromPtr(fromArg(rt));
        }
    };
    S.calls = 0;
    var map: Map = .empty;
    var k1: u8 = 0;
    var k2: u8 = 0;
    var v1: u8 = 0;
    var rt_dummy: u8 = 0;
    try map.put(std.testing.allocator, &k1, .{ .value = &v1, .rt = &rt_dummy, .release = &S.rel });
    try map.put(std.testing.allocator, &k2, .{ .value = null, .rt = &rt_dummy, .release = &S.rel }); // değer yok: atlanır
    drain(&map, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), S.calls);
    try std.testing.expectEqual(@intFromPtr(&rt_dummy), S.last_rt);
    try std.testing.expectEqual(@as(u32, 0), map.count());
    drain(&map, std.testing.allocator); // boş: no-op
    try std.testing.expectEqual(@as(usize, 1), S.calls);
}
