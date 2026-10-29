//! TODO 8.7: Unicode normalizasyonu (UAX #15) — NFC / NFD / NFKC / NFKD.
//!
//! Veri `unicode_norm_data.zig`den gelir (scripts/gen_unicode_tables.py norm: Python `unicodedata` sürümü). Hangul heceleri algoritmiktir
//! (tabloda yoktur). Geçersiz UTF-8 baytları dokunulmadan geçer ve komşu karakterlerle birleşmeyi engeller.

const std = @import("std");
const data = @import("unicode_norm_data.zig");

pub const Form = enum(i32) { nfc = 0, nfd = 1, nfkc = 2, nfkd = 3 };

const S_BASE: u32 = 0xAC00;
const L_BASE: u32 = 0x1100;
const V_BASE: u32 = 0x1161;
const T_BASE: u32 = 0x11A7;
const L_COUNT: u32 = 19;
const V_COUNT: u32 = 21;
const T_COUNT: u32 = 28;
const N_COUNT: u32 = V_COUNT * T_COUNT;
const S_COUNT: u32 = L_COUNT * N_COUNT;

/// Geçersiz bayt: `RAW_BASE + bayt` olarak taşınır, çıktıda tek bayt olarak yazılır.
const RAW_BASE: u32 = 0x110000;

fn ccc(cp: u32) u8 {
    if (cp >= RAW_BASE) return 0;
    return data.combiningClass(cp);
}

fn decomposeInto(list: *std.ArrayList(u32), a: std.mem.Allocator, cp: u32, compat: bool) std.mem.Allocator.Error!void {
    if (cp >= S_BASE and cp < S_BASE + S_COUNT) {
        const s = cp - S_BASE;
        try list.append(a, L_BASE + s / N_COUNT);
        try list.append(a, V_BASE + (s % N_COUNT) / T_COUNT);
        if (s % T_COUNT != 0) try list.append(a, T_BASE + s % T_COUNT);
        return;
    }
    if (cp < RAW_BASE) if (data.decomposition(cp, compat)) |d| {
        try list.appendSlice(a, d);
        return;
    };
    try list.append(a, cp);
}

fn composeCp(first: u32, second: u32) ?u32 {
    if (first >= L_BASE and first < L_BASE + L_COUNT and second >= V_BASE and second < V_BASE + V_COUNT) {
        return S_BASE + ((first - L_BASE) * V_COUNT + (second - V_BASE)) * T_COUNT;
    }
    if (first >= S_BASE and first < S_BASE + S_COUNT and (first - S_BASE) % T_COUNT == 0 and second > T_BASE and second < T_BASE + T_COUNT) {
        return first + (second - T_BASE);
    }
    if (first >= RAW_BASE or second >= RAW_BASE) return null;
    return data.composePair(first, second);
}

fn reorder(cps: []u32) void {
    var i: usize = 0;
    while (i < cps.len) {
        if (ccc(cps[i]) == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < cps.len and ccc(cps[j]) != 0) j += 1;
        // [i, j) aynı ccc≠0 koşusu: kararlı ekleme sıralaması
        var k = i + 1;
        while (k < j) : (k += 1) {
            const v = cps[k];
            const vc = ccc(v);
            var m = k;
            while (m > i and ccc(cps[m - 1]) > vc) : (m -= 1) cps[m] = cps[m - 1];
            cps[m] = v;
        }
        i = j;
    }
}

fn compose(cps: []u32) usize {
    if (cps.len == 0) return 0;
    var out: usize = 0; // yazma konumu
    var starter: ?usize = null;
    var last_class: u32 = 0;
    for (cps, 0..) |ch, idx| {
        const cc: u32 = ccc(ch);
        if (idx == 0) {
            cps[0] = ch;
            out = 1;
            if (cc == 0) {
                starter = 0;
                last_class = 0;
            } else last_class = 256;
            continue;
        }
        if (starter) |sp| {
            if (composeCp(cps[sp], ch)) |comp| {
                if (last_class < cc or last_class == 0) {
                    cps[sp] = comp;
                    continue;
                }
            }
        }
        if (cc == 0) {
            starter = out;
        }
        last_class = cc;
        cps[out] = ch;
        out += 1;
    }
    return out;
}

/// `s`yi `form`a göre normalleştirip UTF-8 olarak `out`a ekler.
pub fn normalize(a: std.mem.Allocator, s: []const u8, form: Form, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    const compat = form == .nfkc or form == .nfkd;
    var cps: std.ArrayList(u32) = .empty;
    defer cps.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            try cps.append(a, b);
            i += 1;
            continue;
        }
        const l = std.unicode.utf8ByteSequenceLength(b) catch {
            try cps.append(a, RAW_BASE + b);
            i += 1;
            continue;
        };
        if (i + l > s.len) {
            try cps.append(a, RAW_BASE + b);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i..][0..l]) catch {
            try cps.append(a, RAW_BASE + b);
            i += 1;
            continue;
        };
        try decomposeInto(&cps, a, cp, compat);
        i += l;
    }
    reorder(cps.items);
    var n = cps.items.len;
    if (form == .nfc or form == .nfkc) n = compose(cps.items);
    for (cps.items[0..n]) |cp| {
        if (cp >= RAW_BASE) {
            try out.append(a, @intCast(cp - RAW_BASE));
            continue;
        }
        var buf: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(@intCast(cp), &buf) catch continue;
        try out.appendSlice(a, buf[0..l]);
    }
}

test "NFC/NFD/NFKC/NFKD temel örnekler" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try normalize(a, "e\u{301}", .nfc, &out);
    try std.testing.expectEqualStrings("\u{E9}", out.items);
    out.clearRetainingCapacity();
    try normalize(a, "\u{E9}", .nfd, &out);
    try std.testing.expectEqualStrings("e\u{301}", out.items);
    out.clearRetainingCapacity();
    try normalize(a, "\u{FB01}", .nfkc, &out);
    try std.testing.expectEqualStrings("fi", out.items);
    out.clearRetainingCapacity();
    try normalize(a, "\u{AC01}", .nfd, &out);
    try std.testing.expectEqualStrings("\u{1100}\u{1161}\u{11A8}", out.items);
    out.clearRetainingCapacity();
    try normalize(a, "\u{1100}\u{1161}\u{11A8}", .nfc, &out);
    try std.testing.expectEqualStrings("\u{AC01}", out.items);
    out.clearRetainingCapacity();
    // kanonik sıralama: ccc 220 < 230
    try normalize(a, "a\u{301}\u{323}", .nfd, &out);
    try std.testing.expectEqualStrings("a\u{323}\u{301}", out.items);
}
