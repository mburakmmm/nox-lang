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
/// `genListLit`in ÜRETTİĞİ AYNI bayt düzeninde (Faz U.1'den beri: 8 bayt
/// uzunluk + 8 bayt kapasite başlığı + `str` işaretçileri, bkz. codegen_qbe/
/// codegen.zig'in `list[T]` başlık düzeni notu) bir payload'ı EL İLE inşa
/// eder — kapasite BURADA HER ZAMAN uzunluğa EŞİTTİR (tam-oturan, büyüme
/// SLACK'i YOK — `.append()` GEREKTİĞİNDE KENDİSİ büyütür). `sep` BOŞSA (v1
/// bilinçli basitleştirmesi — `std.mem.splitSequence`in boş bir ayraçla
/// TANIMSIZ/kullanışsız davranışına GÜVENMEK YERİNE), TÜM `s`i TEK elemanlı
/// bir liste olarak döner.
export fn nox_strings_split_raw(rt: ?*anyopaque, s: ?[*:0]const u8, sep: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s_slice = std.mem.span(s orelse return null);
    const sep_slice = std.mem.span(sep orelse return null);

    if (sep_slice.len == 0) {
        const raw = arc.nox_rc_alloc(rt, 16 + 8) orelse return null;
        const bytes: [*]u8 = @ptrCast(raw);
        @as(*align(1) i64, @ptrCast(bytes)).* = 1;
        @as(*align(1) i64, @ptrCast(bytes + 8)).* = 1;
        const dup = dupeToNoxStr(rt, s_slice) orelse return null;
        @as(*align(1) i64, @ptrCast(bytes + 16)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
        return @ptrCast(bytes);
    }

    var count: usize = 0;
    {
        var it = std.mem.splitSequence(u8, s_slice, sep_slice);
        while (it.next()) |_| count += 1;
    }

    const raw = arc.nox_rc_alloc(rt, 16 + 8 * count) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(count);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(count);

    var it = std.mem.splitSequence(u8, s_slice, sep_slice);
    var i: usize = 0;
    while (it.next()) |part| {
        const dup = dupeToNoxStr(rt, part) orelse return null;
        const slot = bytes + 16 + 8 * i;
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

/// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) — `join`nin ÖNCEKİ
/// saf-Nox uygulaması `result = result + sep + p` döngüsüydü: `nox_str_
/// concat` (bkz. `str.zig`) HER ÇAĞRIDA TAM bir kopya yaptığından bu O(n²)
/// idi (`split`/`trim`/vb.'nin ZATEN izlediği "değişken uzunluklu sonuç →
/// Zig'e sar" gerekçesiyle AYNI, ama `join` bu düzene UYMUYORDU). Burada
/// TEK geçişte toplam uzunluk hesaplanır, TEK `nox_rc_alloc` yapılır, TÜM
/// parçalar/ayırıcılar KOPYALANIR — O(n). `parts`in ham bayt düzeni
/// `nox_strings_split_raw`nin ÜRETTİĞİYLE (8 bayt uzunluk + 8 bayt
/// kapasite + `str` işaretçileri) AYNIDIR — bkz. onun belge notu.
export fn nox_strings_join_raw(rt: ?*anyopaque, parts: ?*anyopaque, sep: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const bytes: [*]u8 = @ptrCast(parts orelse return null);
    const sep_slice = std.mem.span(sep orelse return null);
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);

    if (count == 0) return dupeToNoxStr(rt, "");

    var total_len: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + 16 + 8 * i)).*);
        const p: [*:0]const u8 = @ptrFromInt(addr);
        total_len += std.mem.len(p);
        if (i + 1 < count) total_len += sep_slice.len;
    }

    const raw = arc.nox_rc_alloc(rt, total_len + 1) orelse return null;
    const out: [*]u8 = @ptrCast(raw);
    var off: usize = 0;
    i = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + 16 + 8 * i)).*);
        const p: [*:0]const u8 = @ptrFromInt(addr);
        const slice = std.mem.span(p);
        @memcpy(out[off..][0..slice.len], slice);
        off += slice.len;
        if (i + 1 < count) {
            @memcpy(out[off..][0..sep_slice.len], sep_slice);
            off += sep_slice.len;
        }
    }
    out[total_len] = 0;
    return @ptrCast(out);
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
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + 16 + 8 * i)).*);
        const p: [*:0]u8 = @ptrFromInt(addr);
        defer str.nox_str_release(rt, p);
        if (i == 0) try std.testing.expectEqualStrings("a", std.mem.sliceTo(p, 0));
        if (i == 2) try std.testing.expectEqualStrings("c", std.mem.sliceTo(p, 0));
    }
    arc.nox_rc_release(rt, list_ptr, 16 + 8 * 3);
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

/// `nox_strings_split_raw`nin TERSİ: bir Zig `[]const []const u8`ten
/// `nox_strings_join_raw`nin BEKLEDİĞİ ham `list[str]` payload'ını EL İLE
/// inşa eder — `nox_strings_split_raw`nin KENDİSİNİN inşa mantığıyla AYNI
/// (bkz. onun belge notu).
fn buildStrList(rt: ?*anyopaque, parts: []const []const u8) ?*anyopaque {
    const raw = arc.nox_rc_alloc(rt, 16 + 8 * parts.len) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(parts.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(parts.len);
    for (parts, 0..) |part, i| {
        const dup = dupeToNoxStr(rt, part) orelse return null;
        const slot = bytes + 16 + 8 * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
    }
    return @ptrCast(bytes);
}

test "nox_strings_join_raw parcalari ayiraçla dogru birlestirir (tek gecis, O(n))" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const parts = buildStrList(rt, &.{ "a", "bb", "ccc" }) orelse return error.BuildFailed;
    const parts_bytes: [*]u8 = @ptrCast(parts);
    defer {
        // `nox_rc_release` (bkz. `nox_strings_split_raw`nin AYNI notu) yalnızca
        // liste kabının KENDİ belleğini serbest bırakır — ELEMANLARIN kendi
        // refcount'larını AYRI AYRI (`str.nox_str_release`) düşürmek gerekir.
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(parts_bytes + 16 + 8 * i)).*);
            str.nox_str_release(rt, @ptrFromInt(addr));
        }
        arc.nox_rc_release(rt, parts, 16 + 8 * 3);
    }

    const joined = nox_strings_join_raw(rt, parts, ", ") orelse return error.JoinFailed;
    defer str.nox_str_release(rt, joined);
    try std.testing.expectEqualStrings("a, bb, ccc", std.mem.sliceTo(joined, 0));
}

test "nox_strings_join_raw bos liste bos dize doner" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const parts = buildStrList(rt, &.{}) orelse return error.BuildFailed;
    defer arc.nox_rc_release(rt, parts, 16);

    const joined = nox_strings_join_raw(rt, parts, ", ") orelse return error.JoinFailed;
    defer str.nox_str_release(rt, joined);
    try std.testing.expectEqualStrings("", std.mem.sliceTo(joined, 0));
}
