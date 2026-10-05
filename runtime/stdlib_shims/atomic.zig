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

const Cell = std.atomic.Value(i64);

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
