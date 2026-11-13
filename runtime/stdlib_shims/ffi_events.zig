//! `nox.ffi.EventQueue` (v2.1.118, TODO 8.8): kütüphanenin KENDİ iş parçacığından çağırdığı C callback'lerini Nox'a güvenle taşır.
//!
//! Sorun: Nox kodu (ARC, işçi yuvası, zamanlayıcı) yalnızca Nox'un başlattığı iş parçacıklarında güvenlidir; bir C kütüphanesi (ses, ağ, olay döngüsü) callback'i kendi iş
//! parçacığından çağırırsa Nox kodu orada ÇALIŞTIRILAMAZ. Çözüm: callback, argümanlarını kilitli bir kuyruğa yazan, Nox'tan bağımsız (ARC/`rt` kullanmayan) küçük bir C-ABI
//! "trampoline"idir; Nox tarafı (`EventQueue.wait`) olayları normal bir görevde okur.
//!
//! Trampoline'lar işlev işaretçisi imzasını BİLMEZ; çağrı kuralının kayıt sınıflandırmasına dayanır (System V x86-64 ve AAPCS64: tamsayı/işaretçi sınıfı argümanlar sırayla
//! `a0..a5`, kayan nokta argümanlar sırayla `d0..d3`): olaya `ints[]` (tamsayı/işaretçi/bool/enum, userdata HARİÇ) ve `floats[]` (double) olarak yazılır. `float` (f32) için
//! `float32_arg`. Sınırlar: en çok 6 tamsayı + 4 kayan nokta argüman, struct-değerle argüman yok, Windows x64'te (pozisyonel kayıtlar) desteklenmez. Userdata `ud_index`.
//! inci TAMSAYI-sınıfı argümandır (0..5) ve kuyruk tutamağını taşır. Dönüş: `set_return` ile ayarlanan `i64` (void callback'lerde yok sayılır).
//!
//! Kuyruk dolarsa en yeni olay atılır ve `dropped` artar (kütüphane iş parçacığı ASLA bloklanmaz). Kuyruk başlığı `close`dan sonra da (küçük bir yapı) bellekte kalır, olay tamponu ise kapanışta bırakılır:
//! kütüphane iş parçacığı kapanıştan sonra çağırsa bile geçerli belleğe dokunur (olay atılır). Bellek `page_allocator`dan alınır (İlke 6: yalnızca bu kuyruğa özgü durum).

const std = @import("std");
const builtin = @import("builtin");
const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;

pub const supported = switch (builtin.os.tag) {
    .macos, .linux => !builtin.cpu.arch.isWasm(),
    else => false,
};

const Event = struct { ints: [6]i64 = @splat(0), floats: [4]f64 = @splat(0) };

const Queue = struct {
    lock: SpinLock = .{},
    buf: []Event,
    head: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,
    closed: bool = false,
    ret: i64 = 0,
    /// `pop`un son çektiği olay (Nox tarafı `int_arg`/`float_arg` ile okur; tek tüketici).
    current: Event = .{},
    /// `userdata` tamsayı sınıfı argüman konumu doğrulaması için sihirli sayı (yanlış `ud_index` ile gelen çağrı belleği bozmasın).
    magic: u64 = MAGIC,
};
const MAGIC: u64 = 0x4e4f58_45565131; // "NOXEVQ1"

fn asQueue(p: ?*anyopaque) ?*Queue {
    const q: *Queue = @ptrCast(@alignCast(p orelse return null));
    return if (q.magic == MAGIC) q else null;
}

/// Kuyruk oluşturur (`capacity` olay, en az 1). Başarısızlıkta null.
pub export fn nox_evq_new(capacity: i64) callconv(.c) ?*anyopaque {
    if (comptime !supported) return null;
    const cap: usize = @intCast(std.math.clamp(capacity, 1, 1 << 20));
    const q = std.heap.page_allocator.create(Queue) catch return null;
    const buf = std.heap.page_allocator.alloc(Event, cap) catch {
        std.heap.page_allocator.destroy(q);
        return null;
    };
    q.* = .{ .buf = buf };
    return q;
}

/// Kuyruğu kapatır: bekleyen olaylar atılır, yeni olaylar yok sayılır. Başlık bellekte kalır (bkz. modül notu).
pub export fn nox_evq_close(p: ?*anyopaque) callconv(.c) void {
    const q = asQueue(p) orelse return;
    q.lock.lock();
    defer q.lock.unlock();
    if (q.closed) return;
    q.closed = true;
    q.len = 0;
    // Olay tamponu (kapasite × ~80 B, en çok ~80 MiB) kapanışta bırakılır; yalnız küçük başlık kalır. `push`/`pop` `closed`/`len == 0` denetiminden önce tampona dokunmaz.
    std.heap.page_allocator.free(q.buf);
    q.buf = q.buf[0..0];
}

fn push(q: *Queue, ud_index: usize, ints: [6]i64, floats: [4]f64) i64 {
    q.lock.lock();
    defer q.lock.unlock();
    if (q.closed) return q.ret;
    if (q.len >= q.buf.len) {
        q.dropped += 1;
        return q.ret;
    }
    var ev: Event = .{ .floats = floats };
    var n: usize = 0;
    for (ints, 0..) |v, i| {
        if (i == ud_index) continue;
        ev.ints[n] = v;
        n += 1;
    }
    q.buf[(q.head + q.len) % q.buf.len] = ev;
    q.len += 1;
    return q.ret;
}

fn Tramp(comptime k: usize) type {
    return struct {
        fn f(a0: i64, a1: i64, a2: i64, a3: i64, a4: i64, a5: i64, d0: f64, d1: f64, d2: f64, d3: f64) callconv(.c) i64 {
            const ints = [6]i64{ a0, a1, a2, a3, a4, a5 };
            const q = asQueue(@ptrFromInt(@as(usize, @bitCast(ints[k])))) orelse return 0;
            return push(q, k, ints, .{ d0, d1, d2, d3 });
        }
    };
}

const Fn = *const fn (i64, i64, i64, i64, i64, i64, f64, f64, f64, f64) callconv(.c) i64;
const trampolines = [6]Fn{ Tramp(0).f, Tramp(1).f, Tramp(2).f, Tramp(3).f, Tramp(4).f, Tramp(5).f };

/// `ud_index` (0..5): userdata'nın kaçıncı tamsayı-sınıfı argüman olduğu. Dönen işlev işaretçisi C'ye callback olarak verilir.
pub export fn nox_evq_fn(ud_index: i64) callconv(.c) ?*anyopaque {
    if (comptime !supported) return null;
    if (ud_index < 0 or ud_index > 5) return null;
    return @ptrCast(@constCast(trampolines[@intCast(ud_index)]));
}

/// Sıradaki olayı `current`e çeker; `1` olay var, `0` kuyruk boş.
pub export fn nox_evq_pop(p: ?*anyopaque) callconv(.c) i64 {
    const q = asQueue(p) orelse return 0;
    q.lock.lock();
    defer q.lock.unlock();
    if (q.len == 0) return 0;
    q.current = q.buf[q.head];
    q.head = (q.head + 1) % q.buf.len;
    q.len -= 1;
    return 1;
}

pub export fn nox_evq_int_arg(p: ?*anyopaque, i: i64) callconv(.c) i64 {
    const q = asQueue(p) orelse return 0;
    if (i < 0 or i > 5) return 0;
    return q.current.ints[@intCast(i)];
}

pub export fn nox_evq_float_arg(p: ?*anyopaque, i: i64) callconv(.c) f64 {
    const q = asQueue(p) orelse return 0;
    if (i < 0 or i > 3) return 0;
    return q.current.floats[@intCast(i)];
}

/// `float` (f32) argüman: FP kaydının alt 32 biti.
pub export fn nox_evq_float32_arg(p: ?*anyopaque, i: i64) callconv(.c) f64 {
    const q = asQueue(p) orelse return 0;
    if (i < 0 or i > 3) return 0;
    const bits: u64 = @bitCast(q.current.floats[@intCast(i)]);
    const f: f32 = @bitCast(@as(u32, @truncate(bits)));
    return f;
}

pub export fn nox_evq_pending(p: ?*anyopaque) callconv(.c) i64 {
    const q = asQueue(p) orelse return 0;
    q.lock.lock();
    defer q.lock.unlock();
    return @intCast(q.len);
}

pub export fn nox_evq_dropped(p: ?*anyopaque) callconv(.c) i64 {
    const q = asQueue(p) orelse return 0;
    q.lock.lock();
    defer q.lock.unlock();
    return @intCast(q.dropped);
}

pub export fn nox_evq_set_return(p: ?*anyopaque, v: i64) callconv(.c) void {
    const q = asQueue(p) orelse return;
    q.lock.lock();
    defer q.lock.unlock();
    q.ret = v;
}

pub export fn nox_evq_supported() callconv(.c) i64 {
    return if (supported) 1 else 0;
}

test "evq: trampoline userdata'yı ayıklar, tamsayı ve kayan nokta argümanlarını sırayla kuyruğa yazar; tutamaç denetlenir" {
    if (!supported) return error.SkipZigTest;
    const q = nox_evq_new(2) orelse return error.OutOfMemory;
    const tr: Fn = @ptrCast(@alignCast(nox_evq_fn(1).?));
    nox_evq_set_return(q, 7);
    const qi: i64 = @bitCast(@as(usize, @intFromPtr(q)));
    // C imzası: cb(int a, void *ud, int b, double x)
    try std.testing.expectEqual(@as(i64, 7), tr(11, qi, 22, 0, 0, 0, 1.5, 0, 0, 0));
    try std.testing.expectEqual(@as(i64, 7), tr(33, qi, 44, 0, 0, 0, 2.5, 0, 0, 0));
    _ = tr(55, qi, 66, 0, 0, 0, 3.5, 0, 0, 0); // kuyruk 2: bu olay atılır
    try std.testing.expectEqual(@as(i64, 2), nox_evq_pending(q));
    try std.testing.expectEqual(@as(i64, 1), nox_evq_dropped(q));
    try std.testing.expectEqual(@as(i64, 1), nox_evq_pop(q));
    try std.testing.expectEqual(@as(i64, 11), nox_evq_int_arg(q, 0));
    try std.testing.expectEqual(@as(i64, 22), nox_evq_int_arg(q, 1));
    try std.testing.expectEqual(@as(f64, 1.5), nox_evq_float_arg(q, 0));
    try std.testing.expectEqual(@as(i64, 1), nox_evq_pop(q));
    try std.testing.expectEqual(@as(i64, 33), nox_evq_int_arg(q, 0));
    try std.testing.expectEqual(@as(i64, 0), nox_evq_pop(q));
    // yanlış tutamaç (sihirli sayı) belleği bozmaz
    var junk = [_]u64{0} ** 16;
    try std.testing.expectEqual(@as(i64, 0), tr(1, @bitCast(@as(usize, @intFromPtr(&junk))), 0, 0, 0, 0, 0, 0, 0, 0));
    nox_evq_close(q);
    _ = tr(9, qi, 9, 0, 0, 0, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, 0), nox_evq_pending(q));
    // v2.1.124 (9.17): olay tamponu kapanışta bırakıldı; geç gelen callback/pop güvenli (sıfır uzunluklu dilim).
    const qq: *Queue = @ptrCast(@alignCast(q));
    try std.testing.expectEqual(@as(usize, 0), qq.buf.len);
    try std.testing.expectEqual(@as(i64, 0), nox_evq_pop(q));
    _ = tr(10, qi, 10, 0, 0, 0, 0, 0, 0, 0);
}

test "evq: gerçek bir yabancı iş parçacığı callback'i çağırır" {
    if (!supported) return error.SkipZigTest;
    const q = nox_evq_new(1000) orelse return error.OutOfMemory;
    const tr: Fn = @ptrCast(@alignCast(nox_evq_fn(0).?));
    const T = struct {
        fn run(f: Fn, qq: ?*anyopaque) void {
            const qi: i64 = @bitCast(@as(usize, @intFromPtr(qq)));
            var i: i64 = 0;
            while (i < 500) : (i += 1) _ = f(qi, i, 0, 0, 0, 0, @floatFromInt(i), 0, 0, 0);
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{ tr, q });
    var got: i64 = 0;
    var next: i64 = 0;
    while (got < 500) {
        if (nox_evq_pop(q) == 1) {
            try std.testing.expectEqual(next, nox_evq_int_arg(q, 0));
            try std.testing.expectEqual(@as(f64, @floatFromInt(next)), nox_evq_float_arg(q, 0));
            next += 1;
            got += 1;
        } else std.Thread.yield() catch {};
    }
    t.join();
    try std.testing.expectEqual(@as(i64, 0), nox_evq_dropped(q));
    nox_evq_close(q);
}
