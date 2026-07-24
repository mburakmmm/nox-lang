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

// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
// yapılandırılmış tanılamalar") — Aşama 1 kabul kriteri: bir dize
// literali, çok-karakterli bir operatör VE bir satır-sonrası tanımlayıcı
// İçin TAM bayt/satır/sütun aralığı doğru hesaplanıyor mu?
test "Token bitiş-konumu (start_byte/end_byte/end_line/end_col) doğru hesaplanır" {
    const source = "x = \"hi\"\ny >= 2\n";
    const tokens = try nox.lexer.tokenize(std.testing.allocator, source);
    defer std.testing.allocator.free(tokens);

    // tokens: identifier(x) assign(=) string_lit("hi") newline identifier(y) gt_eq(>=) int_lit(2) newline eof
    const x = tokens[0];
    try std.testing.expectEqual(nox.token.TokenKind.identifier, x.kind);
    try std.testing.expectEqual(@as(usize, 0), x.start_byte);
    try std.testing.expectEqual(@as(usize, 1), x.end_byte);
    try std.testing.expectEqual(@as(u32, 1), x.line);
    try std.testing.expectEqual(@as(u32, 1), x.col);
    try std.testing.expectEqual(@as(u32, 1), x.end_line);
    try std.testing.expectEqual(@as(u32, 2), x.end_col);

    const str = tokens[2];
    try std.testing.expectEqual(nox.token.TokenKind.string_lit, str.kind);
    try std.testing.expectEqual(@as(usize, 4), str.start_byte);
    try std.testing.expectEqual(@as(usize, 8), str.end_byte);
    try std.testing.expectEqual(@as(u32, 5), str.col);
    try std.testing.expectEqual(@as(u32, 9), str.end_col);

    const y = tokens[4];
    try std.testing.expectEqual(nox.token.TokenKind.identifier, y.kind);
    try std.testing.expectEqual(@as(u32, 2), y.line);
    try std.testing.expectEqual(@as(u32, 1), y.col);
    try std.testing.expectEqual(@as(usize, 9), y.start_byte);
    try std.testing.expectEqual(@as(usize, 10), y.end_byte);

    const gt_eq = tokens[5];
    try std.testing.expectEqual(nox.token.TokenKind.gt_eq, gt_eq.kind);
    try std.testing.expectEqual(@as(usize, 11), gt_eq.start_byte);
    try std.testing.expectEqual(@as(usize, 13), gt_eq.end_byte);
    try std.testing.expectEqual(@as(u32, 3), gt_eq.col);
    try std.testing.expectEqual(@as(u32, 5), gt_eq.end_col);
}

test "sonlandırılmamış string hata döner" {
    const result = nox.lexer.tokenize(std.testing.allocator, "x = \"abc\n");
    try std.testing.expectError(error.UnterminatedString, result);
}

test "tab ile girinti hata döner" {
    const result = nox.lexer.tokenize(std.testing.allocator, "if x:\n\ty = 1\n");
    try std.testing.expectError(error.TabsNotAllowed, result);
}

// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
// yapılandırılmış tanılamalar") — Aşama 2 kabul kriteri: `tokenize`in
// KENDİSİ (İMZASI DEĞİŞMEDEN) HÂLÂ yalnızca bare `LexError` döner, ama
// YENİ `tokenizeCapturingSpan` AYNI hatanın TAM konumunu da yakalar.
test "tokenizeCapturingSpan: sonlandırılmamış string, açılış tırnağının span'ını yakalar" {
    const r = nox.lexer.tokenizeCapturingSpan(std.testing.allocator, "x = \"abc\n");
    try std.testing.expect(r.tokens == null);
    try std.testing.expectEqual(nox.lexer.LexError.UnterminatedString, r.err.?);
    try std.testing.expect(!r.err_span.isNone());
    try std.testing.expectEqual(@as(u32, 1), r.err_span.start_line);
    try std.testing.expectEqual(@as(u32, 5), r.err_span.start_col); // '"' konumu
}

test "tokenizeCapturingSpan: tab girintisi, tab karakterinin span'ını yakalar" {
    const r = nox.lexer.tokenizeCapturingSpan(std.testing.allocator, "if x:\n\ty = 1\n");
    try std.testing.expect(r.tokens == null);
    try std.testing.expectEqual(nox.lexer.LexError.TabsNotAllowed, r.err.?);
    try std.testing.expect(!r.err_span.isNone());
    try std.testing.expectEqual(@as(u32, 2), r.err_span.start_line);
    try std.testing.expectEqual(@as(u32, 1), r.err_span.start_col);
}

test "tokenizeCapturingSpan: hatasız girdide err/err_span boş, tokens dolu döner" {
    const r = nox.lexer.tokenizeCapturingSpan(std.testing.allocator, "x = 1\n");
    defer if (r.tokens) |t| std.testing.allocator.free(t);
    try std.testing.expect(r.tokens != null);
    try std.testing.expect(r.err == null);
    try std.testing.expect(r.err_span.isNone());
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

// Bulundu (bkz. proje belleği "f-string + augmented atama" görevi) —
// 7 augmented-atama operatörünün HEPSİ doğru tokenlenir (`**=`/`//=`
// İKİ karakterlik temel operatörün ÜZERİNE bir ÜÇÜNCÜ `=` gerektirir).
test "augmented atama operatörleri (+= -= *= /= //= %= **=) doğru tokenlenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try kinds(arena.allocator(), "x += 1\nx -= 1\nx *= 1\nx /= 1\nx //= 1\nx %= 1\nx **= 1\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, &.{
        .identifier, .plus_eq,        .int_lit, .newline,
        .identifier, .minus_eq,       .int_lit, .newline,
        .identifier, .star_eq,        .int_lit, .newline,
        .identifier, .slash_eq,       .int_lit, .newline,
        .identifier, .slash_slash_eq, .int_lit, .newline,
        .identifier, .percent_eq,     .int_lit, .newline,
        .identifier, .star_star_eq,   .int_lit, .newline,
        .eof,
    }, got);
}

// `+`/`-`/`*`/`/`/`%`/`**`/`//`nin KENDİSİ (augmented OLMAYAN) hâlâ doğru
// tokenlenir — YENİ `peek`-tabanlı dallar mevcut davranışı BOZMAMALI.
test "augmented atama EKLENDİKTEN SONRA düz aritmetik operatörler değişmedi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try kinds(arena.allocator(), "1 + 1 - 1 * 1 / 1 % 1 ** 1 // 1\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, &.{
        .int_lit, .plus,  .int_lit, .minus,      .int_lit, .star, .int_lit,
        .slash,   .int_lit, .percent, .int_lit,  .star_star, .int_lit,
        .slash_slash, .int_lit, .newline, .eof,
    }, got);
}

test "f-string: interpolasyonsuz duz metin TEK bir fstring_lit token'i" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try kinds(arena.allocator(), "f\"hello world\"\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, &.{ .fstring_lit, .newline, .eof }, got);
}

test "f-string: {{ }} kacan literal parantezle karisik derinlik dogru izlenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `{{`/`}}` KAÇAN literal, `{x}` GERÇEK bir interpolasyon — İKİSİ AYNI
    // f-string'de karışık geçtiğinde derinlik SAYACI şaşırmamalı.
    const got = try kinds(arena.allocator(), "f\"{{lit}} {x} {{more}}\"\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, &.{ .fstring_lit, .newline, .eof }, got);
}

test "f-string: Python klasik ic-ice tirnak kurali (farkli tirnak KABUL, ayni tirnak REDDEDILIR)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Dış `"`, iç `'` — KABUL edilmeli (tek bir fstring_lit token'ı).
    const ok = try kinds(arena.allocator(), "f\"{d['key']}\"\n");
    try std.testing.expectEqualSlices(nox.token.TokenKind, &.{ .fstring_lit, .newline, .eof }, ok);

    // Dış `"`, iç DE `"` — Python'ın KENDİSİ de ayırt edemediğinden REDDEDİLİR.
    try std.testing.expectError(error.UnexpectedCharacter, nox.lexer.tokenize(arena.allocator(), "f\"{d[\"key\"]}\"\n"));
}

test "f-string: sonlandirilmamis f-string hata doner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnterminatedString, nox.lexer.tokenize(arena.allocator(), "f\"hello {name}\n"));
}
