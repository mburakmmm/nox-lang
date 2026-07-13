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
