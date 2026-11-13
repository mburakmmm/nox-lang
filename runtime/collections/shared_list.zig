//! Faz 9.0 dilim 3 (v2.1.122): işçiler arasında PAYLAŞILAN modül düzeyi `list[T]` global'inin çalışma zamanı hücresi.
//!
//! Sorun: `list[T]` tek bir bloktur (başlık + elemanlar) ve büyürken YENİDEN TAHSİS edilir; global yuvası yeni işaretçiyle güncellenir. Bu yüzden nesne başına kilit anlamsızdır. Çözüm: derleyici, listeyi
//! yalnız ad üzerinden ve izinli biçimlerde kullanan bir global için yuvaya listenin kendisini değil bu HÜCREYİ koyar. Hücre, standart liste bloğunu (len@0, cap@8, elemanlar@16..) tek sahip olarak tutar
//! ve her işlem kendi önbellek satırındaki kilit altında çalışır. Okuma sonucu `str` ise RETAIN edilmiş (çağırana ait) döner; salt-okunur toplu kullanımlar (`for`, `in`, dilim, `print`) için `snapshot`
//! bağımsız bir kopya verir. Tek işlemler atomiktir, bileşik işlemler değildir (karar A).
//!
//! Eleman türleri: `esz` 8 (int/float/`str` işaretçisi) ya da 1 (bool); `kind`: 0 skaler, 1 `str` (paketlenmiş başlıklı: `nox_str_retain/release`).
//! Tek işçili havuzda (`RuntimeState.main_pool_workers <= 1`) kilit alınmaz.

const std = @import("std");
const asap = @import("../alloc/asap.zig");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");
const list_ops = @import("list_ops.zig");
const abi_layout = @import("abi_layout");
const SpinLock = @import("../async_rt/spinlock.zig").SpinLock;

const HDR = abi_layout.LIST_HEADER_SIZE;

pub const Cell = struct {
    /// Sahip olunan liste bloğu (refcount 1).
    block: [*]u8,
    shared: bool,
    _pad: [64]u8 = undefined,
    lock: SpinLock = .{},
};

inline fn lockCell(c: *Cell) bool {
    if (!c.shared) return false;
    c.lock.lockBackoff();
    return true;
}

inline fn unlockCell(c: *Cell, held: bool) void {
    if (held) c.lock.unlock();
}

inline fn hdrLen(b: [*]u8) i64 {
    return @as(*align(1) i64, @ptrCast(b)).*;
}
inline fn setLen(b: [*]u8, n: i64) void {
    @as(*align(1) i64, @ptrCast(b)).* = n;
}
inline fn hdrCap(b: [*]u8) i64 {
    return @as(*align(1) i64, @ptrCast(b + 8)).*;
}
inline fn setCap(b: [*]u8, n: i64) void {
    @as(*align(1) i64, @ptrCast(b + 8)).* = n;
}

inline fn slot(b: [*]u8, i: usize, esz: usize) [*]u8 {
    return b + HDR + i * esz;
}

inline fn loadElem(b: [*]u8, i: usize, esz: i64) i64 {
    const p = slot(b, i, @intCast(esz));
    if (esz == 1) return p[0];
    return @as(*align(1) i64, @ptrCast(p)).*;
}

inline fn storeElem(b: [*]u8, i: usize, esz: i64, v: i64) void {
    const p = slot(b, i, @intCast(esz));
    if (esz == 1) {
        p[0] = @truncate(@as(u64, @bitCast(v)));
    } else {
        @as(*align(1) i64, @ptrCast(p)).* = v;
    }
}

inline fn strPtr(v: i64) ?[*:0]u8 {
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(v)))));
}

/// `block` (refcount 1, standart liste bloğu) sahipliğini devralan bir hücre kurar. Eş zamanlı erişim BAŞLAMADAN önce çağrılır; havuzda birden çok işçi yoksa kilit hiç alınmaz.
pub export fn nox_slist_new(rt: ?*anyopaque, block: ?*anyopaque) ?*anyopaque {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const c = std.heap.page_allocator.create(Cell) catch return null;
    c.* = .{ .block = @ptrCast(block orelse return null), .shared = state.main_pool_workers > 1 };
    return c;
}

/// Hücreyi ve elemanlarını serbest bırakır (program çıkışı).
pub export fn nox_slist_free(rt: ?*anyopaque, cp: ?*anyopaque, kind: i32, esz: i64) void {
    const c: *Cell = @ptrCast(@alignCast(cp orelse return));
    const n: usize = @intCast(hdrLen(c.block));
    if (kind == 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) str_mod.nox_str_release(rt, strPtr(loadElem(c.block, i, esz)));
    }
    const cap: usize = @intCast(hdrCap(c.block));
    arc.nox_rc_free_payload(rt, c.block, HDR + cap * @as(usize, @intCast(esz)));
    std.heap.page_allocator.destroy(c);
}

pub export fn nox_slist_len(cp: ?*anyopaque) i64 {
    const c: *Cell = @ptrCast(@alignCast(cp orelse return 0));
    const held = lockCell(c);
    defer unlockCell(c, held);
    return hdrLen(c.block);
}

/// `i` negatifse `len` eklenir. Dönüş: eleman (`kind == 1` ise RETAIN edilmiş, çağırana ait); `*ok` 1 başarı, 0 aralık dışı.
pub export fn nox_slist_get(cp: ?*anyopaque, i: i64, esz: i64, kind: i32, ok: *i64) i64 {
    const c: *Cell = @ptrCast(@alignCast(cp orelse {
        ok.* = 0;
        return 0;
    }));
    const held = lockCell(c);
    defer unlockCell(c, held);
    const n = hdrLen(c.block);
    const idx = if (i < 0) i + n else i;
    if (idx < 0 or idx >= n) {
        ok.* = 0;
        return 0;
    }
    const v = loadElem(c.block, @intCast(idx), esz);
    if (kind == 1 and v != 0) str_mod.nox_str_retain(strPtr(v));
    ok.* = 1;
    return v;
}

/// `xs[i] = v`: `v` çağıran tarafından zaten retain edilmiştir (sahiplik listeye geçer); eski `str` eleman burada bırakılır. Dönüş 1 başarı, 0 aralık dışı (bu durumda `v` listeye geçmez: çağıran bırakır).
pub export fn nox_slist_set(rt: ?*anyopaque, cp: ?*anyopaque, i: i64, esz: i64, kind: i32, v: i64) i64 {
    const c: *Cell = @ptrCast(@alignCast(cp orelse return 0));
    const held = lockCell(c);
    defer unlockCell(c, held);
    const n = hdrLen(c.block);
    const idx = if (i < 0) i + n else i;
    if (idx < 0 or idx >= n) return 0;
    const old = loadElem(c.block, @intCast(idx), esz);
    storeElem(c.block, @intCast(idx), esz, v);
    if (kind == 1) str_mod.nox_str_release(rt, strPtr(old));
    return 1;
}

/// `xs.append(v)`: `v` zaten retain edilmiştir (sahiplik listeye geçer). Büyütme tek sahipli `nox_list_realloc` yoludur. Dönüş 1 başarı, 0 bellek yok.
pub export fn nox_slist_append(rt: ?*anyopaque, cp: ?*anyopaque, esz: i64, kind: i32, v: i64) i64 {
    _ = kind;
    const c: *Cell = @ptrCast(@alignCast(cp orelse return 0));
    const held = lockCell(c);
    defer unlockCell(c, held);
    const n = hdrLen(c.block);
    const cap = hdrCap(c.block);
    if (n >= cap) {
        const new_cap: i64 = if (cap == 0) 1 else cap * 2;
        const e: usize = @intCast(esz);
        const nb = arc.nox_list_realloc(rt, c.block, HDR + @as(usize, @intCast(cap)) * e, HDR + @as(usize, @intCast(new_cap)) * e) orelse return 0;
        c.block = @ptrCast(nb);
        setCap(c.block, new_cap);
    }
    storeElem(c.block, @intCast(n), esz, v);
    setLen(c.block, n + 1);
    return 1;
}

/// `xs.pop()`: son eleman çıkarılır, sahiplik çağırana geçer (str RETAIN/RELEASE edilmez). `*ok` 1 başarı, 0 boş liste.
pub export fn nox_slist_pop(cp: ?*anyopaque, esz: i64, ok: *i64) i64 {
    const c: *Cell = @ptrCast(@alignCast(cp orelse {
        ok.* = 0;
        return 0;
    }));
    const held = lockCell(c);
    defer unlockCell(c, held);
    const n = hdrLen(c.block);
    if (n == 0) {
        ok.* = 0;
        return 0;
    }
    const v = loadElem(c.block, @intCast(n - 1), esz);
    setLen(c.block, n - 1);
    ok.* = 1;
    return v;
}

/// `xs.clear()`: tüm elemanlar bırakılır, kapasite korunur.
pub export fn nox_slist_clear(rt: ?*anyopaque, cp: ?*anyopaque, esz: i64, kind: i32) void {
    const c: *Cell = @ptrCast(@alignCast(cp orelse return));
    const held = lockCell(c);
    defer unlockCell(c, held);
    const n: usize = @intCast(hdrLen(c.block));
    if (kind == 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) str_mod.nox_str_release(rt, strPtr(loadElem(c.block, i, esz)));
    }
    setLen(c.block, 0);
}

/// Salt-okunur toplu kullanımlar için: listenin O ANKİ içeriğinin bağımsız bir kopyası (`str` elemanlar retain edilir; çağırana ait taze liste).
pub export fn nox_slist_snapshot(rt: ?*anyopaque, cp: ?*anyopaque, esz: i64, kind: i32) ?*anyopaque {
    const c: *Cell = @ptrCast(@alignCast(cp orelse return null));
    const held = lockCell(c);
    defer unlockCell(c, held);
    return list_ops.nox_list_copy(rt, c.block, esz, kind);
}

// ---- Birim testleri ----------------------------------------------------------------------------------------------------------------------------------------------

const testing = std.testing;

fn newBlock(rt: ?*anyopaque, cap: usize, esz: usize) [*]u8 {
    const raw = arc.nox_rc_alloc(rt, HDR + cap * esz).?;
    const b: [*]u8 = @ptrCast(raw);
    setLen(b, 0);
    setCap(b, @intCast(cap));
    return b;
}

test "slist: append/get/set/pop/len/clear/snapshot tek işçide doğru; büyütme; aralık dışı; negatif indeks" {
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    const cell = nox_slist_new(rt, newBlock(rt, 0, 8)).?;
    var ok: i64 = 0;
    var i: i64 = 0;
    while (i < 100) : (i += 1) try testing.expectEqual(@as(i64, 1), nox_slist_append(rt, cell, 8, 0, i * 3));
    try testing.expectEqual(@as(i64, 100), nox_slist_len(cell));
    try testing.expectEqual(@as(i64, 150), nox_slist_get(cell, 50, 8, 0, &ok));
    try testing.expectEqual(@as(i64, 1), ok);
    try testing.expectEqual(@as(i64, 297), nox_slist_get(cell, -1, 8, 0, &ok));
    _ = nox_slist_get(cell, 100, 8, 0, &ok);
    try testing.expectEqual(@as(i64, 0), ok);
    try testing.expectEqual(@as(i64, 1), nox_slist_set(rt, cell, 5, 8, 0, 999));
    try testing.expectEqual(@as(i64, 0), nox_slist_set(rt, cell, 100, 8, 0, 1));
    try testing.expectEqual(@as(i64, 999), nox_slist_get(cell, 5, 8, 0, &ok));
    const snap: [*]u8 = @ptrCast(nox_slist_snapshot(rt, cell, 8, 0).?);
    try testing.expectEqual(@as(i64, 100), hdrLen(snap));
    try testing.expectEqual(@as(i64, 999), loadElem(snap, 5, 8));
    arc.nox_rc_free_payload(rt, snap, HDR + 100 * 8);
    try testing.expectEqual(@as(i64, 297), nox_slist_pop(cell, 8, &ok));
    try testing.expectEqual(@as(i64, 99), nox_slist_len(cell));
    nox_slist_clear(rt, cell, 8, 0);
    try testing.expectEqual(@as(i64, 0), nox_slist_len(cell));
    _ = nox_slist_pop(cell, 8, &ok);
    try testing.expectEqual(@as(i64, 0), ok);
    nox_slist_free(rt, cell, 0, 8);
}
