//! `noxc run` / `noxc test` ikilisi proje klasörüne yazılmaz.
//! Anahtar, kaynak yolu + içerik + derleyici sürümü ve bayraklardır.
//! Dizin `$NOX_HOME/cache/run/` altındadır. Aynı kaynak değişince önceki
//! özet dizini silinir; her kaynak yolu tek canlı ikili tutar.

const std = @import("std");

pub fn digest(parts: []const []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, part.len, .little);
        hasher.update(&len_bytes);
        hasher.update(part);
    }
    return hasher.finalResult();
}

pub fn hex16(sum: [32]u8) [16]u8 {
    const digits = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (sum[0..8], 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0xf];
    }
    return out;
}

/// Dosya adı (veya yol parçası) bu isimle eşleşirse test seçilir.
/// Sorgu `/` içeriyorsa yolun içinde aranır; aksi halde yalnızca
/// `*_test.nox` dosya adında. Kısa bir ev-dizini öneki bütün ağacı seçmesin.
pub fn matchesTestName(path: []const u8, query: []const u8) bool {
    if (query.len == 0) return false;
    const base = std.fs.path.basename(path);
    if (std.mem.indexOf(u8, base, query) != null) return true;
    if (std.mem.indexOfScalar(u8, query, '/') != null or std.mem.indexOfScalar(u8, query, '\\') != null) {
        return std.mem.indexOf(u8, path, query) != null;
    }
    return false;
}

pub fn shouldSkipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".nox") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-cache") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.startsWith(u8, name, ".");
}

test "test ismi dosya adinda aranir, ev dizini oneki secilmez" {
    try std.testing.expect(matchesTestName("/tmp/proj/tests/v18_smtp_test.nox", "smtp"));
    try std.testing.expect(matchesTestName("/tmp/proj/tests/v18_smtp_test.nox", "v18_smtp_test.nox"));
    try std.testing.expect(!matchesTestName("/Users/melih/proj/tests/v18_smtp_test.nox", "Users"));
    try std.testing.expect(matchesTestName("/tmp/proj/tests/v18_smtp_test.nox", "tests/v18"));
    try std.testing.expect(!matchesTestName("/tmp/proj/tests/other_test.nox", "smtp"));
}

test "ozet parcalarin sirasina baglidir" {
    const a = digest(&.{ "a", "b" });
    const b = digest(&.{ "b", "a" });
    const c = digest(&.{ "a", "b" });
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expect(std.mem.eql(u8, &a, &c));
    const hex = hex16(a);
    try std.testing.expectEqual(@as(usize, 16), hex.len);
}
