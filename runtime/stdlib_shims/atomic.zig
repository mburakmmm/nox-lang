//! `nox.atomic` Zig kabuğu — Aether NOX_LIMITATIONS.md yol haritası, Faz B.1
//! (madde 12'nin SINIRLI/güvenli çözümü): multicore worker'lar arasında
//! paylaşılan basit sayaç/bayrak.
//!
//! **Neden genel bir "paylaşılan nesne grafiği" DEĞİL:** `globals_blocks`un
//! worker-başına izolasyonu M:N zamanlayıcının kendi thread-safety
//! temelidir — onu kaldırmak büyük bir veri-yarışı riski açar. Bu modül
//! YALNIZCA tek bir 64-bit hücreyi (`std.atomic.Value(i64)`) paylaşır.
//!
//! **Gizli global durum YOK (AGENTS.md §2 madde 6):** her atomik, AÇIKÇA
//! `nox_atomic_new` ile yaratılan, `page_allocator`dan tahsis edilmiş AYRI
//! bir hücredir; Nox tarafına HAM ADRESİ bir `int` handle olarak verilir
//! (`nox_http_listen_fd`nin fd'yi `int` olarak dağıtmasıyla AYNI desen) —
//! bu `int`, `nox.thread`in zaten desteklediği aktarım tiplerinden
//! biridir, bu yüzden worker'lara argüman olarak geçirilebilir.
//!
//! **Ömür:** `nox_atomic_free` AÇIKÇA çağrılmalıdır; hiçbir ARC/ASAP
//! otomatik serbest bırakma YOKTUR (hücre birden çok worker'ın ortak
//! malıdır, tek bir sahibi yoktur). `0` handle'ı "geçersiz"dir ve tüm
//! erişimciler onu güvenle yok sayar (`load` → 0, diğerleri no-op).

const std = @import("std");
const builtin = @import("builtin");
const str_mod = @import("../str.zig");
const shim_util = @import("shim_util.zig");

/// wasm32-wasi tek iş parçacıklıdır ve 64-bit atomik işlem yoktur: düz bir hücre aynı arayüzü verir.
const PlainCell = struct {
    v: i64,

    fn init(x: i64) PlainCell {
        return .{ .v = x };
    }
    fn load(self: *const PlainCell, _: std.builtin.AtomicOrder) i64 {
        return self.v;
    }
    fn store(self: *PlainCell, x: i64, _: std.builtin.AtomicOrder) void {
        self.v = x;
    }
    fn fetchAdd(self: *PlainCell, d: i64, _: std.builtin.AtomicOrder) i64 {
        const old = self.v;
        self.v = old +% d;
        return old;
    }
    fn cmpxchgStrong(self: *PlainCell, expected: i64, desired: i64, _: std.builtin.AtomicOrder, _: std.builtin.AtomicOrder) ?i64 {
        if (self.v != expected) return self.v;
        self.v = desired;
        return null;
    }
};

const Cell = if (builtin.cpu.arch.isWasm()) PlainCell else std.atomic.Value(i64);

fn cellFromHandle(h: i64) ?*Cell {
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

/// Yeni bir hücre yaratır; başarısızlıkta `0` döner.
export fn nox_atomic_new(initial: i64) callconv(.c) i64 {
    const cell = std.heap.page_allocator.create(Cell) catch return 0;
    cell.* = Cell.init(initial);
    return @intCast(@intFromPtr(cell));
}

export fn nox_atomic_load(h: i64) callconv(.c) i64 {
    const cell = cellFromHandle(h) orelse return 0;
    return cell.load(.seq_cst);
}

export fn nox_atomic_store(h: i64, value: i64) callconv(.c) void {
    const cell = cellFromHandle(h) orelse return;
    cell.store(value, .seq_cst);
}

/// `delta`yı atomik olarak ekler, YENİ değeri döner.
export fn nox_atomic_add(h: i64, delta: i64) callconv(.c) i64 {
    const cell = cellFromHandle(h) orelse return 0;
    return cell.fetchAdd(delta, .seq_cst) +% delta;
}

/// Değer `expected` ise `desired` yapar; takas olduysa `1`, olmadıysa `0`.
export fn nox_atomic_cas(h: i64, expected: i64, desired: i64) callconv(.c) i64 {
    const cell = cellFromHandle(h) orelse return 0;
    return if (cell.cmpxchgStrong(expected, desired, .seq_cst, .seq_cst) == null) 1 else 0;
}

export fn nox_atomic_free(h: i64) callconv(.c) void {
    const cell = cellFromHandle(h) orelse return;
    std.heap.page_allocator.destroy(cell);
}

/// `AtomicRef`: worker'lar arası paylaşılan DEĞİŞMEZ bir bayt anlık görüntüsü (örn. serileştirilmiş yapılandırma/rota tablosu). Worker'ların ARC yığınları ayrı olduğundan nesne değil BAYTLAR
/// paylaşılır: `set` yeni bir tampon kurup kilit altında takas eder, `get` kilit altında kopyalar (okuyucu eski tamponun serbest bırakılmasıyla yarışmaz). Sürüm sayacı her `set`te artar.
const SnapshotCell = struct {
    lock: std.atomic.Value(u32) = .init(0),
    version: i64 = 0,
    data: []u8 = &.{},

    fn acquire(self: *SnapshotCell) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn release(self: *SnapshotCell) void {
        self.lock.store(0, .release);
    }
};

fn snapFromHandle(h: i64) ?*SnapshotCell {
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

/// Yeni bir anlık görüntü hücresi (ilk değer `initial`); başarısızlıkta 0.
export fn nox_atomic_ref_new(initial: ?[*:0]const u8) callconv(.c) i64 {
    const cell = std.heap.page_allocator.create(SnapshotCell) catch return 0;
    cell.* = .{};
    if (initial) |p| {
        const bytes = str_mod.nox_str_slice(p);
        cell.data = std.heap.page_allocator.dupe(u8, bytes) catch {
            std.heap.page_allocator.destroy(cell);
            return 0;
        };
    }
    return @intCast(@intFromPtr(cell));
}

/// Anlık görüntüyü `value` ile değiştirir ve YENİ sürümü döner (bellek yetersizse -1).
export fn nox_atomic_ref_set(h: i64, value: ?[*:0]const u8) callconv(.c) i64 {
    const cell = snapFromHandle(h) orelse return -1;
    const bytes = if (value) |p| str_mod.nox_str_slice(p) else "";
    const copy = std.heap.page_allocator.dupe(u8, bytes) catch return -1;
    cell.acquire();
    const old = cell.data;
    cell.data = copy;
    cell.version += 1;
    const v = cell.version;
    cell.release();
    if (old.len > 0) std.heap.page_allocator.free(old);
    return v;
}

/// Anlık görüntünün KOPYASINI çağıranın `RuntimeState`inde yeni bir `str` olarak döner.
export fn nox_atomic_ref_get(rt: ?*anyopaque, h: i64) callconv(.c) ?[*:0]u8 {
    const cell = snapFromHandle(h) orelse return shim_util.dupeToNoxStr(rt, "");
    cell.acquire();
    defer cell.release();
    return shim_util.dupeToNoxStr(rt, cell.data);
}

pub export fn nox_atomic_ref_version(h: i64) callconv(.c) i64 {
    const cell = snapFromHandle(h) orelse return 0;
    cell.acquire();
    defer cell.release();
    return cell.version;
}

export fn nox_atomic_ref_free(h: i64) callconv(.c) void {
    const cell = snapFromHandle(h) orelse return;
    if (cell.data.len > 0) std.heap.page_allocator.free(cell.data);
    std.heap.page_allocator.destroy(cell);
}

test "nox_atomic: new/load/store/add/cas/free" {
    const h = nox_atomic_new(5);
    try std.testing.expect(h != 0);
    try std.testing.expectEqual(@as(i64, 5), nox_atomic_load(h));
    nox_atomic_store(h, 10);
    try std.testing.expectEqual(@as(i64, 10), nox_atomic_load(h));
    try std.testing.expectEqual(@as(i64, 13), nox_atomic_add(h, 3));
    try std.testing.expectEqual(@as(i64, 12), nox_atomic_add(h, -1));
    try std.testing.expectEqual(@as(i64, 1), nox_atomic_cas(h, 12, 100));
    try std.testing.expectEqual(@as(i64, 0), nox_atomic_cas(h, 12, 200));
    try std.testing.expectEqual(@as(i64, 100), nox_atomic_load(h));
    nox_atomic_free(h);
}

test "nox_atomic: 0 handle'i guvenle yok sayilir" {
    try std.testing.expectEqual(@as(i64, 0), nox_atomic_load(0));
    nox_atomic_store(0, 1);
    try std.testing.expectEqual(@as(i64, 0), nox_atomic_add(0, 1));
    try std.testing.expectEqual(@as(i64, 0), nox_atomic_cas(0, 0, 1));
    nox_atomic_free(0);
}

test "nox_atomic: gercek OS thread'leri arasinda kayip guncelleme yok" {
    const h = nox_atomic_new(0);
    defer nox_atomic_free(h);
    const worker = struct {
        fn run(handle: i64) void {
            var i: usize = 0;
            while (i < 10_000) : (i += 1) _ = nox_atomic_add(handle, 1);
        }
    }.run;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{h});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(i64, 40_000), nox_atomic_load(h));
}

test "nox_atomic_ref: set/version/free (str yardimcisi olmadan, bayt kopyasi)" {
    const h = nox_atomic_ref_new(null);
    try std.testing.expect(h != 0);
    try std.testing.expectEqual(@as(i64, 0), nox_atomic_ref_version(h));
    // set/get Nox str başlığı gerektirir; sürüm sayacı ve boş değer burada doğrulanır, bayt yolu Nox goldeninde.
    nox_atomic_ref_free(h);
    nox_atomic_ref_free(0);
    try std.testing.expectEqual(@as(i64, 0), nox_atomic_ref_version(0));
}
