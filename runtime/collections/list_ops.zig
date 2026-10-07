//! `list[T]` ek işlemleri — v1.150.0 (bkz. nox-teknik-spesifikasyon.md §3.267): `copy`, `+`, `*`, dilimleme, `reverse`,
//! `insert`, `remove`/`del`/`pop(i)`. Listenin ham düzeni `append`/`sort` ile aynıdır: 8 bayt uzunluk + 8 bayt kapasite +
//! `esz` baytlık elemanlar (`bool`/`u8`/`i8` 1, `u16`/`i16` 2, `i32`/`u32` 4, diğerleri 8).
//!
//! **Sahiplik (`kind`):** yeni liste üreten işlemler (`copy`/`concat`/`repeat`/`slice`) kopyalanan elemanları RETAIN eder (liste
//! başına bağımsız bir ikinci sahip, Python'un yüzeysel kopyası): `kind == 0` skaler (retain yok), `1` `str` (paketlenmiş
//! başlıklı: `nox_str_retain`), `2` düz ARC işaretçisi (sınıf/liste/dict/closure/kutulanmış skaler: `nox_rc_retain`).
//! `reverse`/`move_last`/`remove_at` yalnızca YERİNDE bayt taşır (elemanların refcount'u değişmez); silinen elemanı
//! serbest bırakmak ÇAĞIRANIN (codegen) işidir.

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");
const abi_layout = @import("abi_layout");
const HDR = abi_layout.LIST_HEADER_SIZE;

fn hdrLen(list: [*]u8) usize {
    return @intCast(@as(*align(1) i64, @ptrCast(list)).*);
}

fn setLen(list: [*]u8, n: usize) void {
    @as(*align(1) i64, @ptrCast(list)).* = @intCast(n);
}

fn retainElem(slot: [*]const u8, kind: i32) void {
    if (kind == 0) return;
    const v: i64 = @as(*align(1) const i64, @ptrCast(slot)).*;
    if (v == 0) return;
    const p: usize = @intCast(v);
    if (kind == 1) {
        str_mod.nox_str_retain(@ptrFromInt(p));
    } else {
        arc.nox_rc_retain(@ptrFromInt(p));
    }
}

fn newList(rt: ?*anyopaque, n: usize, esz: usize) ?[*]u8 {
    const raw = arc.nox_rc_alloc(rt, HDR + n * esz) orelse return null;
    const base: [*]u8 = @ptrCast(raw);
    setLen(base, n);
    @as(*align(1) i64, @ptrCast(base + 8)).* = @intCast(n);
    return base;
}

/// `[src.lo, src.hi)` aralığını yeni bir listeye kopyalar (retain'li). `lo <= hi <= len` çağıran tarafından sağlanır.
fn sliceRaw(rt: ?*anyopaque, src: [*]const u8, lo: usize, hi: usize, esz: usize, kind: i32) ?*anyopaque {
    const n = hi - lo;
    const out = newList(rt, n, esz) orelse return null;
    if (n > 0) @memcpy(out[HDR..][0 .. n * esz], src[HDR + lo * esz ..][0 .. n * esz]);
    var i: usize = 0;
    while (i < n) : (i += 1) retainElem(out + HDR + i * esz, kind);
    return @ptrCast(out);
}

pub export fn nox_list_copy(rt: ?*anyopaque, src: ?*anyopaque, esz: i64, kind: i32) ?*anyopaque {
    const s: [*]const u8 = @ptrCast(src orelse return null);
    return sliceRaw(rt, s, 0, hdrLen(@constCast(s)), @intCast(esz), kind);
}

pub export fn nox_list_concat(rt: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque, esz_i: i64, kind: i32) ?*anyopaque {
    const pa: [*]const u8 = @ptrCast(a orelse return null);
    const pb: [*]const u8 = @ptrCast(b orelse return null);
    const esz: usize = @intCast(esz_i);
    const la = hdrLen(@constCast(pa));
    const lb = hdrLen(@constCast(pb));
    const out = newList(rt, la + lb, esz) orelse return null;
    if (la > 0) @memcpy(out[HDR..][0 .. la * esz], pa[HDR..][0 .. la * esz]);
    if (lb > 0) @memcpy(out[HDR + la * esz ..][0 .. lb * esz], pb[HDR..][0 .. lb * esz]);
    var i: usize = 0;
    while (i < la + lb) : (i += 1) retainElem(out + HDR + i * esz, kind);
    return @ptrCast(out);
}

/// `list * n` (n <= 0 → boş liste).
pub export fn nox_list_repeat(rt: ?*anyopaque, a: ?*anyopaque, n_i: i64, esz_i: i64, kind: i32) ?*anyopaque {
    const pa: [*]const u8 = @ptrCast(a orelse return null);
    const esz: usize = @intCast(esz_i);
    const la = hdrLen(@constCast(pa));
    const reps: usize = if (n_i <= 0) 0 else @intCast(n_i);
    const out = newList(rt, la * reps, esz) orelse return null;
    var r: usize = 0;
    while (r < reps) : (r += 1) {
        if (la > 0) @memcpy(out[HDR + r * la * esz ..][0 .. la * esz], pa[HDR..][0 .. la * esz]);
    }
    var i: usize = 0;
    while (i < la * reps) : (i += 1) retainElem(out + HDR + i * esz, kind);
    return @ptrCast(out);
}

/// Python dilimi `a[lo:hi]` (adım 1): negatif sınırlar sondan sayılır, aralık dışı sınırlar sıkıştırılır, hata fırlatmaz.
/// `has_lo`/`has_hi` yanlışsa ilgili sınır atlanmıştır (`a[:hi]`, `a[lo:]`).
pub export fn nox_list_slice(rt: ?*anyopaque, a: ?*anyopaque, lo_i: i64, has_lo: i32, hi_i: i64, has_hi: i32, esz_i: i64, kind: i32) ?*anyopaque {
    const pa: [*]const u8 = @ptrCast(a orelse return null);
    const len: i64 = @intCast(hdrLen(@constCast(pa)));
    var lo: i64 = if (has_lo != 0) lo_i else 0;
    var hi: i64 = if (has_hi != 0) hi_i else len;
    if (lo < 0) lo += len;
    if (hi < 0) hi += len;
    lo = std.math.clamp(lo, 0, len);
    hi = std.math.clamp(hi, 0, len);
    if (hi < lo) hi = lo;
    return sliceRaw(rt, pa, @intCast(lo), @intCast(hi), @intCast(esz_i), kind);
}

pub export fn nox_list_reverse(list: ?*anyopaque, esz_i: i64) void {
    const base: [*]u8 = @ptrCast(list orelse return);
    const esz: usize = @intCast(esz_i);
    const n = hdrLen(base);
    if (n < 2) return;
    var i: usize = 0;
    var j: usize = n - 1;
    while (i < j) : ({
        i += 1;
        j -= 1;
    }) {
        var k: usize = 0;
        while (k < esz) : (k += 1) {
            const tmp = base[HDR + i * esz + k];
            base[HDR + i * esz + k] = base[HDR + j * esz + k];
            base[HDR + j * esz + k] = tmp;
        }
    }
}

/// `insert` için: eleman ZATEN sona eklenmiştir (`append` büyütme yolunu paylaşır); son elemanı Python `list.insert(i, x)`
/// semantiğiyle `i` konumuna taşır (negatif `i` sondan sayılır, sınırlar `[0, eski_uzunluk]`e sıkıştırılır).
pub export fn nox_list_move_last(list: ?*anyopaque, idx: i64, esz_i: i64) void {
    const base: [*]u8 = @ptrCast(list orelse return);
    const esz: usize = @intCast(esz_i);
    const n = hdrLen(base);
    if (n < 2) return;
    const orig: i64 = @intCast(n - 1);
    var i: i64 = idx;
    if (i < 0) i += orig;
    i = std.math.clamp(i, 0, orig);
    const pos: usize = @intCast(i);
    if (pos == n - 1) return;
    var tmp: [8]u8 = undefined;
    @memcpy(tmp[0..esz], base[HDR + (n - 1) * esz ..][0..esz]);
    std.mem.copyBackwards(u8, base[HDR + (pos + 1) * esz ..][0 .. (n - 1 - pos) * esz], base[HDR + pos * esz ..][0 .. (n - 1 - pos) * esz]);
    @memcpy(base[HDR + pos * esz ..][0..esz], tmp[0..esz]);
}

/// `idx`indeki elemanı kaldırır: sonrakileri bir aşağı kaydırır, uzunluğu bir azaltır. Elemanı serbest bırakmak (ya da
/// sonucu devralmak) çağıranın işidir; `idx` geçerli olmalıdır.
pub export fn nox_list_remove_at(list: ?*anyopaque, idx_i: i64, esz_i: i64) void {
    const base: [*]u8 = @ptrCast(list orelse return);
    const esz: usize = @intCast(esz_i);
    const n = hdrLen(base);
    const idx: usize = @intCast(idx_i);
    if (idx >= n) return;
    if (idx + 1 < n) std.mem.copyForwards(u8, base[HDR + idx * esz ..][0 .. (n - 1 - idx) * esz], base[HDR + (idx + 1) * esz ..][0 .. (n - 1 - idx) * esz]);
    setLen(base, n - 1);
}

fn testFree(rt: ?*anyopaque, p: ?*anyopaque) void {
    const b: [*]u8 = @ptrCast(p.?);
    const cap: usize = @intCast(@as(*align(1) i64, @ptrCast(b + 8)).*);
    arc.nox_rc_release(rt, p, HDR + cap * 8);
}

test "nox_list_ops: copy/concat/repeat/slice/reverse/move_last/remove_at (int elemanlar)" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const l = newList(rt, 4, 8) orelse return error.AllocFailed;
    defer testFree(rt, l);
    for (0..4) |i| @as(*align(1) i64, @ptrCast(l + HDR + i * 8)).* = @intCast(i + 1); // 1 2 3 4
    const rd = struct {
        fn at(p: ?*anyopaque, i: usize) i64 {
            const b: [*]const u8 = @ptrCast(p.?);
            return @as(*align(1) const i64, @ptrCast(b + HDR + i * 8)).*;
        }
        fn len(p: ?*anyopaque) usize {
            const b: [*]u8 = @ptrCast(p.?);
            return hdrLen(b);
        }
    };
    const c = nox_list_copy(rt, l, 8, 0);
    defer testFree(rt, c);
    try std.testing.expectEqual(@as(usize, 4), rd.len(c));
    try std.testing.expectEqual(@as(i64, 3), rd.at(c, 2));
    const cc = nox_list_concat(rt, l, c, 8, 0);
    defer testFree(rt, cc);
    try std.testing.expectEqual(@as(usize, 8), rd.len(cc));
    try std.testing.expectEqual(@as(i64, 1), rd.at(cc, 4));
    const rp = nox_list_repeat(rt, l, 3, 8, 0);
    defer testFree(rt, rp);
    try std.testing.expectEqual(@as(usize, 12), rd.len(rp));
    try std.testing.expectEqual(@as(i64, 2), rd.at(rp, 9));
    const z = nox_list_repeat(rt, l, 0, 8, 0);
    defer testFree(rt, z);
    try std.testing.expectEqual(@as(usize, 0), rd.len(z));
    const sl = nox_list_slice(rt, l, 1, 1, 3, 1, 8, 0); // [2,3]
    defer testFree(rt, sl);
    try std.testing.expectEqual(@as(usize, 2), rd.len(sl));
    try std.testing.expectEqual(@as(i64, 2), rd.at(sl, 0));
    const neg = nox_list_slice(rt, l, -2, 1, 0, 0, 8, 0); // [3,4]
    defer testFree(rt, neg);
    try std.testing.expectEqual(@as(usize, 2), rd.len(neg));
    try std.testing.expectEqual(@as(i64, 3), rd.at(neg, 0));
    const empty = nox_list_slice(rt, l, 3, 1, 1, 1, 8, 0);
    defer testFree(rt, empty);
    try std.testing.expectEqual(@as(usize, 0), rd.len(empty));
    nox_list_reverse(c, 8);
    try std.testing.expectEqual(@as(i64, 4), rd.at(c, 0));
    try std.testing.expectEqual(@as(i64, 1), rd.at(c, 3));
    nox_list_remove_at(c, 1, 8); // 4 2 1 (3 silindi)
    try std.testing.expectEqual(@as(usize, 3), rd.len(c));
    try std.testing.expectEqual(@as(i64, 2), rd.at(c, 1));
    // move_last: [1,2,3,4] + sona 99 eklenmiş gibi
    const m = newList(rt, 5, 8) orelse return error.AllocFailed;
    defer testFree(rt, m);
    for (0..4) |i| @as(*align(1) i64, @ptrCast(m + HDR + i * 8)).* = @intCast(i + 1);
    @as(*align(1) i64, @ptrCast(m + HDR + 4 * 8)).* = 99;
    nox_list_move_last(m, 1, 8);
    try std.testing.expectEqual(@as(i64, 99), rd.at(m, 1));
    try std.testing.expectEqual(@as(i64, 2), rd.at(m, 2));
    try std.testing.expectEqual(@as(i64, 4), rd.at(m, 4));
}
