//! `nox.base64` Zig kabuğu (v2.1.56): önceden saf Nox'tu (bayt başına `char_from_byte` + dize birleştirme); 4 MiB'ta CPython'dan 26x (encode) / 36x (decode) yavaştı
//! (`project/stdlib-performans-analizi-2026-11.md`). Anlam AYNEN korunur:
//!   - `encode`: standart alfabe (`+/`), `=` dolgulu; `encode_url`: URL-safe alfabe (`-_`), dolgusuz.
//!   - `decode`: HER İKİ alfabeyi (ve dolgulu/dolgusuz girdiyi) kabul eder; sondaki TÜM `=` işaretleri atılır; ortadaki `=` ya da alfabe dışı bayt geçersizdir.
//!   - Hatalar `check` ile önceden sınıflanır (0 = geçerli, 1 = geçersiz karakter, 2 = geçersiz uzunluk) — durumsuz (thread-local bayrak YOK, freestanding'de de güvenli).
//! Çekirdek saf dilim işlevleridir (`encodedLen`, `encodeInto`, `check`, `decodedLen`, `decodeInto`); dışa aktarılanlar yalnızca Nox `str` ile sarmalar.

const std = @import("std");
const str_mod = @import("../str.zig");

const std_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const url_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Bayt -> 6 bit değeri (iki alfabe birden); geçersiz = 0xFF.
const decode_table: [256]u8 = blk: {
    var t: [256]u8 = @splat(0xFF);
    for (std_alphabet, 0..) |c, i| t[c] = @intCast(i);
    t['-'] = 62;
    t['_'] = 63;
    break :blk t;
};

pub fn encodedLen(n: usize, url_safe: bool) usize {
    const full = n / 3 * 4;
    const rem = n % 3;
    if (rem == 0) return full;
    return full + if (url_safe) rem + 1 else 4;
}

pub fn encodeInto(dst: []u8, src: []const u8, url_safe: bool) usize {
    const alpha = if (url_safe) url_alphabet else std_alphabet;
    var o: usize = 0;
    var i: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const b0 = src[i];
        const b1 = src[i + 1];
        const b2 = src[i + 2];
        dst[o] = alpha[b0 >> 2];
        dst[o + 1] = alpha[((b0 << 4) | (b1 >> 4)) & 63];
        dst[o + 2] = alpha[((b1 << 2) | (b2 >> 6)) & 63];
        dst[o + 3] = alpha[b2 & 63];
        o += 4;
    }
    const rem = src.len - i;
    if (rem == 1) {
        const b0 = src[i];
        dst[o] = alpha[b0 >> 2];
        dst[o + 1] = alpha[(b0 << 4) & 63];
        o += 2;
        if (!url_safe) {
            dst[o] = '=';
            dst[o + 1] = '=';
            o += 2;
        }
    } else if (rem == 2) {
        const b0 = src[i];
        const b1 = src[i + 1];
        dst[o] = alpha[b0 >> 2];
        dst[o + 1] = alpha[((b0 << 4) | (b1 >> 4)) & 63];
        dst[o + 2] = alpha[(b1 << 2) & 63];
        o += 3;
        if (!url_safe) {
            dst[o] = '=';
            o += 1;
        }
    }
    return o;
}

fn effLen(s: []const u8) usize {
    var n = s.len;
    while (n > 0 and s[n - 1] == '=') n -= 1;
    return n;
}

/// 0 = geçerli, 1 = geçersiz karakter, 2 = geçersiz uzunluk. Eski Nox uygulamasıyla AYNI sıra: tam gruplardaki geçersiz karakter önce, sonra tek artık karakter = uzunluk hatası
/// (o karakterin geçerliliği denetlenmez), 2-3 artık karakter denetlenir.
pub fn check(s: []const u8) u8 {
    const n = effLen(s);
    const full = n / 4 * 4;
    for (s[0..full]) |c| if (decode_table[c] == 0xFF) return 1;
    const rem = n - full;
    if (rem == 1) return 2;
    for (s[full..n]) |c| if (decode_table[c] == 0xFF) return 1;
    return 0;
}

pub fn decodedLen(s: []const u8) usize {
    const n = effLen(s);
    const full = n / 4 * 3;
    const rem = n % 4;
    return full + (if (rem == 2) @as(usize, 1) else if (rem == 3) @as(usize, 2) else 0);
}

/// `check(s) == 0` olmalı; `dst` en az `decodedLen(s)` bayt.
pub fn decodeInto(dst: []u8, s: []const u8) usize {
    const n = effLen(s);
    var o: usize = 0;
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const v0 = decode_table[s[i]];
        const v1 = decode_table[s[i + 1]];
        const v2 = decode_table[s[i + 2]];
        const v3 = decode_table[s[i + 3]];
        dst[o] = (v0 << 2) | (v1 >> 4);
        dst[o + 1] = (v1 << 4) | (v2 >> 2);
        dst[o + 2] = (v2 << 6) | v3;
        o += 3;
    }
    const rem = n - i;
    if (rem == 2) {
        const v0 = decode_table[s[i]];
        const v1 = decode_table[s[i + 1]];
        dst[o] = (v0 << 2) | (v1 >> 4);
        o += 1;
    } else if (rem == 3) {
        const v0 = decode_table[s[i]];
        const v1 = decode_table[s[i + 1]];
        const v2 = decode_table[s[i + 2]];
        dst[o] = (v0 << 2) | (v1 >> 4);
        dst[o + 1] = (v1 << 4) | (v2 >> 2);
        o += 2;
    }
    return o;
}

pub export fn nox_base64_encode_raw(rt: ?*anyopaque, s: ?[*:0]const u8, url_safe: i64) callconv(.c) ?[*:0]u8 {
    const src = str_mod.nox_str_slice(s orelse return null);
    const url = url_safe != 0;
    const buf = str_mod.nox_str_alloc_buf(rt, encodedLen(src.len, url)) orelse return null;
    _ = encodeInto(buf[0..encodedLen(src.len, url)], src, url);
    return @ptrCast(buf);
}

pub export fn nox_base64_check_raw(s: ?[*:0]const u8) callconv(.c) i64 {
    const src = str_mod.nox_str_slice(s orelse return 1);
    return check(src);
}

pub export fn nox_base64_decode_raw(rt: ?*anyopaque, s: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const src = str_mod.nox_str_slice(s orelse return null);
    const n = decodedLen(src);
    const buf = str_mod.nox_str_alloc_buf(rt, n) orelse return null;
    _ = decodeInto(buf[0..n], src);
    return @ptrCast(buf);
}

fn encodeAlloc(a: std.mem.Allocator, src: []const u8, url: bool) ![]u8 {
    const out = try a.alloc(u8, encodedLen(src.len, url));
    const n = encodeInto(out, src, url);
    std.debug.assert(n == out.len);
    return out;
}

test "RFC 4648 vektörleri (standart, dolgulu)" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{ .{ "", "" }, .{ "f", "Zg==" }, .{ "fo", "Zm8=" }, .{ "foo", "Zm9v" }, .{ "foob", "Zm9vYg==" }, .{ "fooba", "Zm9vYmE=" }, .{ "foobar", "Zm9vYmFy" } };
    for (cases) |c| {
        const enc = try encodeAlloc(a, c[0], false);
        defer a.free(enc);
        try std.testing.expectEqualStrings(c[1], enc);
        try std.testing.expectEqual(@as(u8, 0), check(enc));
        const dec = try a.alloc(u8, decodedLen(enc));
        defer a.free(dec);
        try std.testing.expectEqual(c[0].len, decodeInto(dec, enc));
        try std.testing.expectEqualStrings(c[0], dec);
    }
}

test "URL-safe: dolgusuz, - ve _ alfabesi; çözücü iki alfabeyi de kabul eder" {
    const a = std.testing.allocator;
    const raw = [_]u8{ 0xfb, 0xff, 0xfe, 0x00, 0x01 };
    const enc = try encodeAlloc(a, &raw, true);
    defer a.free(enc);
    try std.testing.expectEqualStrings("-__-AAE", enc);
    const std_enc = try encodeAlloc(a, &raw, false);
    defer a.free(std_enc);
    try std.testing.expectEqualStrings("+//+AAE=", std_enc);
    // karışık alfabe + dolgusuz girdi
    try std.testing.expectEqual(@as(u8, 0), check("+__-AAE"));
    const dec = try a.alloc(u8, decodedLen("-__-AAE"));
    defer a.free(dec);
    _ = decodeInto(dec, "-__-AAE");
    try std.testing.expectEqualSlices(u8, &raw, dec);
}

test "hata sınıfları: geçersiz karakter (1), geçersiz uzunluk (2); eski Nox anlamı" {
    try std.testing.expectEqual(@as(u8, 1), check("Zm9v!A=="));
    try std.testing.expectEqual(@as(u8, 1), check("Zm=v")); // ortadaki '='
    try std.testing.expectEqual(@as(u8, 2), check("Zm9vY")); // tek artık karakter
    try std.testing.expectEqual(@as(u8, 2), check("Zm9vY===")); // sondaki '='ler atılır, sonra tek artık
    try std.testing.expectEqual(@as(u8, 0), check("Zg"));
    try std.testing.expectEqual(@as(u8, 0), check("Zg=="));
    try std.testing.expectEqual(@as(u8, 0), check("Zg======")); // fazla dolgu da atılır
    try std.testing.expectEqual(@as(u8, 0), check(""));
    try std.testing.expectEqual(@as(u8, 1), check("Z*"));
}

test "ikili veri (NUL ve yüksek baytlar) gidiş-dönüş, büyük girdi" {
    const a = std.testing.allocator;
    const src = try a.alloc(u8, 100_003);
    defer a.free(src);
    for (src, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    for ([_]bool{ false, true }) |url| {
        const enc = try encodeAlloc(a, src, url);
        defer a.free(enc);
        try std.testing.expectEqual(@as(u8, 0), check(enc));
        const dec = try a.alloc(u8, decodedLen(enc));
        defer a.free(dec);
        try std.testing.expectEqual(src.len, decodeInto(dec, enc));
        try std.testing.expectEqualSlices(u8, src, dec);
    }
}
