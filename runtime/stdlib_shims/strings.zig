//! `nox.strings` Zig kabuğu — stdlib fazı §H (bkz. nox-teknik-spesifikasyon.md).
//! `split`/`trim`/`upper`/`lower`/`replace` DEĞİŞKEN uzunluklu sonuç
//! üretir/byte-seviyeli tarama gerektirir, bu yüzden Zig'de yazılır (`join`/
//! `contains`/`starts_with`/`ends_with`/`index_of` İSE TAMAMEN saf Nox'ta,
//! `stdlib/nox/strings.nox`da — bkz. onun belge notu). `split`, Alt-Faz
//! F'nin `list[str]` DÖNÜŞ tipi FFI-güvenliğinin GERÇEK ihtiyaç sahibidir.
//!
//! ASCII v1 kapsamı (bilinçli) — Unicode/UTF-8 büyük/küçük harf dönüşümü
//! ERTELENDİ (`std.ascii.toUpper`/`toLower` yalnızca ASCII baytları etkiler,
//! çok baytlı UTF-8 dizileri OLDUĞU GİBİ bırakılır — hatalı değil, sadece
//! büyük/küçük harfe duyarsız).

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");

const dupeToNoxStr = http_client.dupeToNoxStr;

/// Stdlib fazı §F'nin `list[str]` DÖNÜŞ desteğinin GERÇEK ihtiyaç sahibi —
/// `genListLit`in ÜRETTİĞİ AYNI bayt düzeninde (8 bayt uzunluk başlığı +
/// `str` işaretçileri) bir payload'ı EL İLE inşa eder. `sep` BOŞSA (v1
/// bilinçli basitleştirmesi — `std.mem.splitSequence`in boş bir ayraçla
/// TANIMSIZ/kullanışsız davranışına GÜVENMEK YERİNE), TÜM `s`i TEK elemanlı
/// bir liste olarak döner.
export fn nox_strings_split_raw(rt: ?*anyopaque, s: ?[*:0]const u8, sep: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s_slice = std.mem.span(s orelse return null);
    const sep_slice = std.mem.span(sep orelse return null);

    if (sep_slice.len == 0) {
        const raw = arc.nox_rc_alloc(rt, 8 + 8) orelse return null;
        const bytes: [*]u8 = @ptrCast(raw);
        @as(*align(1) i64, @ptrCast(bytes)).* = 1;
        const dup = dupeToNoxStr(rt, s_slice) orelse return null;
        @as(*align(1) i64, @ptrCast(bytes + 8)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
        return @ptrCast(bytes);
    }

    var count: usize = 0;
    {
        var it = std.mem.splitSequence(u8, s_slice, sep_slice);
        while (it.next()) |_| count += 1;
    }

    const raw = arc.nox_rc_alloc(rt, 8 + 8 * count) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(count);

    var it = std.mem.splitSequence(u8, s_slice, sep_slice);
    var i: usize = 0;
    while (it.next()) |part| {
        const dup = dupeToNoxStr(rt, part) orelse return null;
        const slot = bytes + 8 + 8 * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
        i += 1;
    }
    return @ptrCast(bytes);
}

export fn nox_strings_trim_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = std.mem.span(s orelse return null);
    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    return dupeToNoxStr(rt, trimmed);
}

export fn nox_strings_upper_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = std.mem.span(s orelse return null);
    const raw = arc.nox_rc_alloc(rt, slice.len + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    for (slice, 0..) |c, i| bytes[i] = std.ascii.toUpper(c);
    bytes[slice.len] = 0;
    return @ptrCast(bytes);
}

export fn nox_strings_lower_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const slice = std.mem.span(s orelse return null);
    const raw = arc.nox_rc_alloc(rt, slice.len + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    for (slice, 0..) |c, i| bytes[i] = std.ascii.toLower(c);
    bytes[slice.len] = 0;
    return @ptrCast(bytes);
}

/// `old` BOŞSA (v1 bilinçli basitleştirmesi — sonsuz/anlamsız bir
/// eşleştirme sayısına yol AÇMAMAK İÇİN) `s`nin DEĞİŞMEMİŞ bir kopyasını
/// döner.
export fn nox_strings_replace_raw(rt: ?*anyopaque, s: ?[*:0]const u8, old: ?[*:0]const u8, new: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const s_slice = std.mem.span(s orelse return null);
    const old_slice = std.mem.span(old orelse return null);
    const new_slice = std.mem.span(new orelse return null);
    if (old_slice.len == 0) return dupeToNoxStr(rt, s_slice);

    const out_len = std.mem.replacementSize(u8, s_slice, old_slice, new_slice);
    const raw = arc.nox_rc_alloc(rt, out_len + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    _ = std.mem.replace(u8, s_slice, old_slice, new_slice, bytes[0..out_len]);
    bytes[out_len] = 0;
    return @ptrCast(bytes);
}

test "nox_strings_split_raw temel bolme" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const list_ptr = nox_strings_split_raw(rt, "a,b,c", ",") orelse return error.SplitFailed;
    const bytes: [*]u8 = @ptrCast(list_ptr);
    const count: i64 = @as(*align(1) i64, @ptrCast(bytes)).*;
    try std.testing.expectEqual(@as(i64, 3), count);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + 8 + 8 * i)).*);
        const p: [*:0]u8 = @ptrFromInt(addr);
        defer str.nox_str_release(rt, p);
        if (i == 0) try std.testing.expectEqualStrings("a", std.mem.sliceTo(p, 0));
        if (i == 2) try std.testing.expectEqualStrings("c", std.mem.sliceTo(p, 0));
    }
    arc.nox_rc_release(rt, list_ptr, 8 + 8 * 3);
}

test "nox_strings_trim/upper/lower/replace_raw dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const t = nox_strings_trim_raw(rt, "  hi  ") orelse return error.Failed;
    defer str.nox_str_release(rt, t);
    try std.testing.expectEqualStrings("hi", std.mem.sliceTo(t, 0));

    const u = nox_strings_upper_raw(rt, "hi") orelse return error.Failed;
    defer str.nox_str_release(rt, u);
    try std.testing.expectEqualStrings("HI", std.mem.sliceTo(u, 0));

    const l = nox_strings_lower_raw(rt, "HI") orelse return error.Failed;
    defer str.nox_str_release(rt, l);
    try std.testing.expectEqualStrings("hi", std.mem.sliceTo(l, 0));

    const r = nox_strings_replace_raw(rt, "foo bar foo", "foo", "x") orelse return error.Failed;
    defer str.nox_str_release(rt, r);
    try std.testing.expectEqualStrings("x bar x", std.mem.sliceTo(r, 0));
}
