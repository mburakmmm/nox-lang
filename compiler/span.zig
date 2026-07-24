//! Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
//! yapılandırılmış tanılamalar" — bağımsız bir dış incelemenin, tanılamaların
//! yalnızca deyim-seviyesinde satır numarası taşıdığını, sütun/bayt konumu/
//! bitiş konumu OLMADIĞINI işaret etmesi ÜZERİNE): lexer/parser/checker/LSP
//! genelinde paylaşılan, TEK bir konum-aralığı türü.
//!
//! **Sentinel kuralı (`?Span` DEĞİL):** tüm-sıfır DEĞER "span YOK" anlamına
//! gelir — bu, projenin KENDİ mevcut deyimiyle (`ast.Stmt.line: u32 = 0`,
//! `Checker.current_line: u32 = 0`, bkz. `checker.zig`nin `if (self.
//! current_line > 0)` kontrolü) TUTARLIDIR; İKİNCİ, farklı bir "yok" kuralı
//! (`?Span`) EKLENMEZ.

const Token = @import("lexer/token.zig").Token;

pub const Span = struct {
    start_byte: usize = 0,
    end_byte: usize = 0,
    start_line: u32 = 0,
    start_col: u32 = 0,
    end_line: u32 = 0,
    end_col: u32 = 0,

    /// Sıfır-DEĞER sentinel'i ile KARŞILAŞTIRIR — "span hiç ATANMADI" mı?
    pub fn isNone(self: Span) bool {
        return self.start_line == 0 and self.end_line == 0;
    }
};

/// Tek bir token'ın KENDİ (başlangıç == bitiş) span'ı.
pub fn fromToken(t: Token) Span {
    return .{
        .start_byte = t.start_byte,
        .end_byte = t.end_byte,
        .start_line = t.line,
        .start_col = t.col,
        .end_line = t.end_line,
        .end_col = t.end_col,
    };
}

/// `first`in BAŞLANGICINDAN `last`in BİTİŞİNE kadar olan span — ör. bir
/// deyimin İLK ve SON tükettiği token'lar, ya da bir argüman ifadesinin
/// İLK ve SON token'ı.
pub fn fromTokens(first: Token, last: Token) Span {
    return .{
        .start_byte = first.start_byte,
        .end_byte = last.end_byte,
        .start_line = first.line,
        .start_col = first.col,
        .end_line = last.end_line,
        .end_col = last.end_col,
    };
}

const std = @import("std");
const testing = std.testing;

test "Span.isNone: sıfır-değer sentinel'i doğru tanınır" {
    const none: Span = .{};
    try testing.expect(none.isNone());
    const some: Span = .{ .start_line = 1, .start_col = 1, .end_line = 1, .end_col = 2 };
    try testing.expect(!some.isNone());
}

test "fromToken: tek token'ın başlangıç==bitiş span'ı" {
    const t: Token = .{ .kind = .identifier, .lexeme = "x", .line = 3, .col = 5, .start_byte = 10, .end_byte = 11, .end_line = 3, .end_col = 6 };
    const s = fromToken(t);
    try testing.expectEqual(@as(usize, 10), s.start_byte);
    try testing.expectEqual(@as(usize, 11), s.end_byte);
    try testing.expectEqual(@as(u32, 3), s.start_line);
    try testing.expectEqual(@as(u32, 5), s.start_col);
    try testing.expectEqual(@as(u32, 3), s.end_line);
    try testing.expectEqual(@as(u32, 6), s.end_col);
}

test "fromTokens: ilk token'ın başlangıcı, son token'ın bitişi" {
    const first: Token = .{ .kind = .identifier, .lexeme = "foo", .line = 4, .col = 1, .start_byte = 20, .end_byte = 23, .end_line = 4, .end_col = 4 };
    const last: Token = .{ .kind = .r_paren, .lexeme = ")", .line = 4, .col = 30, .start_byte = 45, .end_byte = 46, .end_line = 4, .end_col = 31 };
    const s = fromTokens(first, last);
    try testing.expectEqual(@as(usize, 20), s.start_byte);
    try testing.expectEqual(@as(usize, 46), s.end_byte);
    try testing.expectEqual(@as(u32, 4), s.start_line);
    try testing.expectEqual(@as(u32, 1), s.start_col);
    try testing.expectEqual(@as(u32, 4), s.end_line);
    try testing.expectEqual(@as(u32, 31), s.end_col);
}
