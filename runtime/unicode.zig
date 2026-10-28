//! TODO 8.7: `str` yöntemleri için Unicode farkındalığı (tam büyük/küçük harf eşlemesi + sınıflandırma).
//!
//! Veri `unicode_data.zig`den gelir (scripts/gen_unicode_tables.py: Python'un `str` semantiği, dosya başlığında Unicode sürümü).
//! Kapsam: `upper`/`lower`/`casefold` (tam eşlemeler: `ß`→`SS`, `İ`→`i̇`, son-sigma kuralı) ve `isalpha/isdigit/isdecimal/isnumeric/
//! isspace/isupper/islower`. Kapsam DIŞI: normalizasyon (NFC/NFD), locale'e özgü eşleme (Türkçe `i`), şekillendirme (Arapça vb.).
//! Geçersiz UTF-8 baytları olduğu gibi geçirilir. Yalnızca ayırma gerektirmeyen saf fonksiyonlar içerir.

const std = @import("std");
const data = @import("unicode_data.zig");

pub const Mode = enum { upper, lower, casefold };

/// `char_class` türleri (`nox_str_char_class` ile aynı numaralama; 6/7 yeni).
pub const Kind = enum(i32) { digit = 0, alpha = 1, alnum = 2, space = 3, upper = 4, lower = 5, decimal = 6, numeric = 7 };

fn inRanges(table: []const data.Range, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (cp < r.lo) {
            hi = mid;
        } else if (cp > r.hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

fn lookup(table: []const data.Case, cp: u32) ?[3]u32 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const c = table[mid].cp;
        if (cp < c) {
            hi = mid;
        } else if (cp > c) {
            lo = mid + 1;
        } else return table[mid].out;
    }
    return null;
}

fn isCased(cp: u32) bool {
    return inRanges(&data.upper, cp) or inRanges(&data.lower, cp) or inRanges(&data.titlecase, cp);
}

const Decoded = struct { cp: u32, len: usize, valid: bool };

fn decodeAt(s: []const u8, i: usize) Decoded {
    const b = s[i];
    if (b < 0x80) return .{ .cp = b, .len = 1, .valid = true };
    const l = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = b, .len = 1, .valid = false };
    if (i + l > s.len) return .{ .cp = b, .len = 1, .valid = false };
    const cp = std.unicode.utf8Decode(s[i..][0..l]) catch return .{ .cp = b, .len = 1, .valid = false };
    return .{ .cp = cp, .len = l, .valid = true };
}

/// `s`yi `mode`a göre eşler; `buf` verilirse sonucu oraya yazar (yeterli büyüklükte olmalı). Sonuç bayt uzunluğunu döner.
pub fn mapInto(s: []const u8, mode: Mode, buf: ?[]u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    var prev_cased = false;
    while (i < s.len) {
        const d = decodeAt(s, i);
        if (!d.valid) {
            if (buf) |b| b[n] = s[i];
            n += 1;
            i += 1;
            prev_cased = false;
            continue;
        }
        var out: [3]u32 = .{ d.cp, 0, 0 };
        var cnt: usize = 1;
        if (d.cp < 0x80) {
            const c: u8 = @intCast(d.cp);
            out[0] = switch (mode) {
                .upper => std.ascii.toUpper(c),
                .lower, .casefold => std.ascii.toLower(c),
            };
        } else if (mode == .lower and d.cp == 0x3A3) {
            // Son sigma: öncesinde büyük/küçük harfli bir karakter, sonrasında yoksa `ς`, aksi halde `σ`.
            const next_cased = i + d.len < s.len and blk: {
                const nd = decodeAt(s, i + d.len);
                break :blk nd.valid and isCased(nd.cp);
            };
            out[0] = if (prev_cased and !next_cased) 0x3C2 else 0x3C3;
        } else {
            const table: []const data.Case = switch (mode) {
                .upper => &data.upper_map,
                .lower => &data.lower_map,
                .casefold => &data.casefold_map,
            };
            if (lookup(table, d.cp)) |m| {
                out = m;
                cnt = if (m[1] == 0) 1 else if (m[2] == 0) 2 else 3;
            }
        }
        for (out[0..cnt]) |cp| {
            const l = std.unicode.utf8CodepointSequenceLength(@intCast(cp)) catch 1;
            if (buf) |b| _ = std.unicode.utf8Encode(@intCast(cp), b[n..][0..l]) catch {};
            n += l;
        }
        prev_cased = isCased(d.cp);
        i += d.len;
    }
    return n;
}

pub fn isAlpha(cp: u32) bool {
    return inRanges(&data.alpha, cp);
}

pub fn isDecimal(cp: u32) bool {
    return inRanges(&data.decimal, cp);
}

pub fn isNumeric(cp: u32) bool {
    return inRanges(&data.numeric, cp);
}

pub fn isSpace(cp: u32) bool {
    return inRanges(&data.space, cp);
}

/// Tek kod noktasına basit katlama (regex büyük/küçük harf duyarsız eşleşme); çok karakterli katlamalar kendisini döner.
pub fn foldSimple(cp: u32) u32 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    if (lookup(&data.casefold_map, cp)) |m| if (m[1] == 0) return m[0];
    return cp;
}

/// Tek kod noktasına basit büyük harf eşlemesi.
pub fn upperSimple(cp: u32) u32 {
    if (cp < 0x80) return std.ascii.toUpper(@intCast(cp));
    if (lookup(&data.upper_map, cp)) |m| if (m[1] == 0) return m[0];
    return cp;
}

/// `nox_str_char_class` Unicode yolu: `true` ise tüm koşullar sağlanır (boş dize → `false`).
pub fn charClass(s: []const u8, kind: Kind) bool {
    if (s.len == 0) return false;
    var cased = false;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        i += d.len;
        if (!d.valid) return false;
        const cp = d.cp;
        const ok = switch (kind) {
            .digit => inRanges(&data.digit, cp),
            .alpha => inRanges(&data.alpha, cp),
            .decimal => inRanges(&data.decimal, cp),
            .numeric => inRanges(&data.numeric, cp),
            .alnum => inRanges(&data.alpha, cp) or inRanges(&data.decimal, cp) or inRanges(&data.digit, cp) or inRanges(&data.numeric, cp),
            .space => inRanges(&data.space, cp),
            .upper => blk: {
                if (inRanges(&data.lower, cp) or inRanges(&data.titlecase, cp)) break :blk false;
                if (inRanges(&data.upper, cp)) cased = true;
                break :blk true;
            },
            .lower => blk: {
                if (inRanges(&data.upper, cp) or inRanges(&data.titlecase, cp)) break :blk false;
                if (inRanges(&data.lower, cp)) cased = true;
                break :blk true;
            },
        };
        if (!ok) return false;
    }
    if (kind == .upper or kind == .lower) return cased;
    return true;
}

test "upper/lower/casefold tam eşleme" {
    var buf: [64]u8 = undefined;
    const n = mapInto("Straße", .upper, null);
    try std.testing.expectEqual(@as(usize, 7), n);
    _ = mapInto("Straße", .upper, buf[0..n]);
    try std.testing.expectEqualStrings("STRASSE", buf[0..n]);
    const m = mapInto("ÇAĞRI ΟΔΟΣ", .lower, null);
    _ = mapInto("ÇAĞRI ΟΔΟΣ", .lower, buf[0..m]);
    try std.testing.expectEqualStrings("çağri οδος", buf[0..m]);
    const k = mapInto("Straße", .casefold, null);
    _ = mapInto("Straße", .casefold, buf[0..k]);
    try std.testing.expectEqualStrings("strasse", buf[0..k]);
}

test "sınıflandırma" {
    try std.testing.expect(charClass("héllo", .alpha));
    try std.testing.expect(!charClass("héllo1", .alpha));
    try std.testing.expect(charClass("٣", .decimal));
    try std.testing.expect(charClass("²", .digit));
    try std.testing.expect(charClass("ÇAĞ", .upper));
    try std.testing.expect(!charClass("Çağ", .upper));
    try std.testing.expect(charClass("ǅ", .alpha) and !charClass("ǅ", .upper) and !charClass("ǅ", .lower));
    try std.testing.expect(charClass("\u{3000}", .space));
}
