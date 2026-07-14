//! `nox` modülünün lexer'ı için dıştan (public API üzerinden) ek testler.
//! compiler/lexer/lexer.zig içindeki testlerle çakışmayan durumlar hedeflenir.

const std = @import("std");
const nox = @import("nox");

fn kinds(allocator: std.mem.Allocator, source: []const u8) ![]nox.token.TokenKind {
    const tokens = try nox.lexer.tokenize(allocator, source);
    const out = try allocator.alloc(nox.token.TokenKind, tokens.len);
    for (tokens, 0..) |t, i| out[i] = t.kind;
    return out;
}

test "float literal ve karşılaştırma operatörleri doğru tokenlenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try kinds(arena.allocator(), "x: float = 3.14\ny: bool = x >= 1.0\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, &.{
        .identifier, .colon,   .identifier, .assign, .float_lit,  .newline,
        .identifier, .colon,   .identifier, .assign, .identifier, .gt_eq,
        .float_lit,  .newline, .eof,
    }, got);
}

test "sonlandırılmamış string hata döner" {
    const result = nox.lexer.tokenize(std.testing.allocator, "x = \"abc\n");
    try std.testing.expectError(error.UnterminatedString, result);
}

test "tab ile girinti hata döner" {
    const result = nox.lexer.tokenize(std.testing.allocator, "if x:\n\ty = 1\n");
    try std.testing.expectError(error.TabsNotAllowed, result);
}

test "üs ve mod operatörleri tokenlenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try kinds(arena.allocator(), "z: int = a ** b % c\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, &.{
        .identifier, .colon,     .identifier, .assign,
        .identifier, .star_star, .identifier, .percent,
        .identifier, .newline,   .eof,
    }, got);
}

test "Faz T.4a: normal tokenize() trivia ÜRETMEZ (opt-in, davranış değişmez)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `tokenize`in KENDİSİNİN yorum/boş-satır BİLGİSİ tutmadığını (yalnızca
    // `tokenizeWithTrivia` tutuyor) dolaylı kanıt: aynı kaynak İÇİN token
    // SAYISI/türleri, yorum/boş-satır İÇEREN bir kaynakta da yorum-SUZ
    // eşdeğeriyle BİREBİR AYNI olmalı.
    const with_comments = try kinds(arena.allocator(), "x: int = 1  # açıklama\n\n# ayrı satır\ny: int = 2\n");
    const without_comments = try kinds(arena.allocator(), "x: int = 1\ny: int = 2\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, without_comments, with_comments);
}

test "Faz T.4a: tokenizeWithTrivia — trailing yorum, standalone yorum, boş satır doğru yakalanır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "x: int = 1  # trailing\n\n# standalone\ny: int = 2\n";
    const result = try nox.lexer.tokenizeWithTrivia(allocator, source);

    try std.testing.expectEqual(@as(usize, 3), result.trivia.len);

    try std.testing.expectEqual(nox.token.TriviaKind.comment, result.trivia[0].kind);
    try std.testing.expectEqual(@as(u32, 1), result.trivia[0].line);
    try std.testing.expectEqualStrings("# trailing", result.trivia[0].text);
    try std.testing.expect(result.trivia[0].trailing);

    try std.testing.expectEqual(nox.token.TriviaKind.blank_line, result.trivia[1].kind);
    try std.testing.expectEqual(@as(u32, 2), result.trivia[1].line);

    try std.testing.expectEqual(nox.token.TriviaKind.comment, result.trivia[2].kind);
    try std.testing.expectEqual(@as(u32, 3), result.trivia[2].line);
    try std.testing.expectEqualStrings("# standalone", result.trivia[2].text);
    try std.testing.expect(!result.trivia[2].trailing);

    // Token akışının KENDİSİ `tokenize()` İLE AYNI kalmalı (trivia yakalama
    // token üretimini ETKİLEMEMELİ).
    const plain = try nox.lexer.tokenize(allocator, source);
    try std.testing.expectEqual(plain.len, result.tokens.len);
    for (plain, result.tokens) |p, w| try std.testing.expectEqual(p.kind, w.kind);
}
