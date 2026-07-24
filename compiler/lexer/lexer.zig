//! Nox indent-farkında lexer. Kaynak metni tek seferde token dizisine çevirir.
//! Python tokenizer'ındaki INDENT/DEDENT modeli referans alınmıştır.

const std = @import("std");
const token_mod = @import("token.zig");
pub const Token = token_mod.Token;
pub const TokenKind = token_mod.TokenKind;
pub const Trivia = token_mod.Trivia;
pub const TriviaKind = token_mod.TriviaKind;
const span_mod = @import("../span.zig");
pub const Span = span_mod.Span;

pub const LexError = error{
    UnexpectedCharacter,
    UnterminatedString,
    InconsistentIndentation,
    TabsNotAllowed,
    OutOfMemory,
};

/// `source`'u token dizisine çevirir. Allocator her zaman açık parametredir (İlke #6).
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) LexError![]Token {
    return tokenizeImpl(allocator, source, null, null);
}

/// Faz T.4a: `tokenize` İLE AYNI token akışını üretir, AMA AYRICA yorum/
/// boş-satır konumlarını (`Trivia`, bkz. `token.zig`nin belge notu) YAKALAR
/// — gelecekteki formatlayıcı (Faz T.4b) DIŞINDA HİÇBİR tüketici bunu
/// KULLANMAZ (`tokenize`nin KENDİSİ DEĞİŞMEDİ, davranışı/performansı AYNI).
pub fn tokenizeWithTrivia(allocator: std.mem.Allocator, source: []const u8) LexError!struct { tokens: []Token, trivia: []Trivia } {
    var trivia: std.ArrayList(Trivia) = .empty;
    errdefer trivia.deinit(allocator);
    const tokens = try tokenizeImpl(allocator, source, &trivia, null);
    return .{ .tokens = tokens, .trivia = try trivia.toOwnedSlice(allocator) };
}

/// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
/// yapılandırılmış tanılamalar"): `tokenize` İLE AYNI davranış, AMA bir
/// `LexError` OLUŞURSA hatanın TAM span'ını da YAKALAR — `tokenizeWithTrivia`
/// İLE AYNI "AYRI, opt-in sarmalayıcı" deseni (`tokenize`in KENDİ İMZASI/
/// çağrı siteleri HİÇ ETKİLENMEZ). Yalnızca `lsp_main.zig`nin (VE
/// gelecekte CLI'nin) GERÇEK tanılama ÜRETMESİ İÇİN kullanılır.
/// `error.OutOfMemory` İçin `err_span` HER ZAMAN sıfır-değerdir (`checker.
/// recordDiagnostic`nin AYNI "OOM bir tanılama DEĞİLDİR" istisnasıyla
/// TUTARLI — bellek yetersizliğinin ANLAMLI bir kaynak KONUMU YOKTUR).
pub fn tokenizeCapturingSpan(allocator: std.mem.Allocator, source: []const u8) struct { tokens: ?[]Token, err: ?LexError, err_span: Span } {
    var span: Span = .{};
    if (tokenizeImpl(allocator, source, null, &span)) |tokens| {
        return .{ .tokens = tokens, .err = null, .err_span = .{} };
    } else |err| {
        return .{ .tokens = null, .err = err, .err_span = span };
    }
}

/// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
/// yapılandırılmış tanılamalar"): TÜM token inşa noktalarının ORTAK
/// yardımcısı — `end_byte`/`end_col`i `start_byte`/`lexeme.len`den TÜRETİR
/// (HİÇBİR token türü BİRDEN FAZLA satıra YAYILMADIĞINDAN `end_line ==
/// line` HER ZAMAN doğrudur). Her çağıran YALNIZCA `start_byte`i
/// (lexeme'in TARANMAYA BAŞLADIĞI bayt konumu) doğru GEÇİRMEKLE
/// yükümlüdür — çok-karakterli operatörler/sayılar/tanımlayıcılar/
/// dizeler İÇİN bu, TARAMA öncesi kaydedilen `start` yerel değişkenidir;
/// tek-karakterli noktalama İÇİN (append ANINDA `i` HENÜZ artırılmadığından)
/// `i`nin KENDİSİDİR.
/// Bir `LexError`in oluştuğu ANDAKİ (tek baytlık, bilinen bir token'a HENÜZ
/// karşılık GELMEYEN) konumu tanımlayan bir `Span` üretir — bkz.
/// `tokenizeCapturingSpan`nin belge notu.
fn posSpan(byte: usize, ln: u32, line_start: usize) Span {
    const col: u32 = @intCast(byte - line_start + 1);
    return .{ .start_byte = byte, .end_byte = byte + 1, .start_line = ln, .start_col = col, .end_line = ln, .end_col = col + 1 };
}

fn mkToken(kind: TokenKind, lexeme: []const u8, line: u32, col: u32, start_byte: usize) Token {
    return .{
        .kind = kind,
        .lexeme = lexeme,
        .line = line,
        .col = col,
        .start_byte = start_byte,
        .end_byte = start_byte + lexeme.len,
        .end_line = line,
        .end_col = col + @as(u32, @intCast(lexeme.len)),
    };
}

fn tokenizeImpl(allocator: std.mem.Allocator, source: []const u8, trivia_out: ?*std.ArrayList(Trivia), err_span_out: ?*Span) LexError![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var indent_stack = std.ArrayList(usize).empty;
    defer indent_stack.deinit(allocator);
    try indent_stack.append(allocator, 0);

    var i: usize = 0;
    var line: u32 = 1;
    var line_start: usize = 0;
    var paren_depth: i32 = 0;
    var at_line_start = true;
    var line_has_content = false;

    while (i < source.len) {
        if (at_line_start and paren_depth == 0) {
            var indent: usize = 0;
            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {
                if (source[i] == '\t') {
                    if (err_span_out) |so| so.* = posSpan(i, line, line_start);
                    return error.TabsNotAllowed;
                }
                indent += 1;
            }
            if (i >= source.len or source[i] == '\n' or source[i] == '\r' or source[i] == '#') {
                // Boş satır veya yalnızca yorum: INDENT/DEDENT/NEWLINE üretilmez.
                if (trivia_out) |t| {
                    if (i < source.len and source[i] == '#') {
                        const comment_start = i;
                        while (i < source.len and source[i] != '\n') : (i += 1) {}
                        try t.append(allocator, .{ .kind = .comment, .line = line, .text = try allocator.dupe(u8, source[comment_start..i]), .trailing = false });
                    } else {
                        try t.append(allocator, .{ .kind = .blank_line, .line = line });
                    }
                } else {
                    while (i < source.len and source[i] != '\n') : (i += 1) {}
                }
                if (i < source.len) {
                    i += 1;
                    line += 1;
                    line_start = i;
                }
                continue;
            }
            const top = indent_stack.items[indent_stack.items.len - 1];
            if (indent > top) {
                try indent_stack.append(allocator, indent);
                try tokens.append(allocator, mkToken(.indent, "", line, 1, i));
            } else if (indent < top) {
                while (indent_stack.items[indent_stack.items.len - 1] > indent) {
                    _ = indent_stack.pop();
                    try tokens.append(allocator, mkToken(.dedent, "", line, 1, i));
                }
                if (indent_stack.items[indent_stack.items.len - 1] != indent) {
                    if (err_span_out) |so| so.* = posSpan(i, line, line_start);
                    return error.InconsistentIndentation;
                }
            }
            at_line_start = false;
        }

        const c = source[i];
        const col: u32 = @intCast(i - line_start + 1);

        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }

        // Faz LL.1 devamı (bkz. nox-teknik-spesifikasyon.md §3.71): GERÇEK
        // Windows'ta yazılmış (native CRLF) bir `.nox` dosyası, `\r`yi
        // BAŞKA hiçbir dalın tanımadığı bir bayt olarak `UnexpectedCharacter`e
        // yol açardı (checkout-seviyesi `.gitattributes` düzeltmesi yalnızca
        // BU REPO'nun KENDİ dosyalarını kapsar, kullanıcının KENDİ editörüyle
        // yazdığı dosyaları DEĞİL). `\r`, HER ZAMAN (tek başına YA DA `\n`den
        // ÖNCE) sessizce ATLANIR — `\n`in KENDİSİ (satır SAYACI/NEWLINE
        // token'ı) HİÇ DEĞİŞMEDEN aşağıdaki mevcut yolu izler.
        if (c == '\r') {
            i += 1;
            continue;
        }

        if (c == '#') {
            if (trivia_out) |t| {
                const comment_start = i;
                while (i < source.len and source[i] != '\n') : (i += 1) {}
                try t.append(allocator, .{ .kind = .comment, .line = line, .text = try allocator.dupe(u8, source[comment_start..i]), .trailing = true });
            } else {
                while (i < source.len and source[i] != '\n') : (i += 1) {}
            }
            continue;
        }

        if (c == '\n') {
            i += 1;
            if (paren_depth == 0) {
                if (line_has_content) {
                    try tokens.append(allocator, mkToken(.newline, "", line, col, i - 1));
                    line_has_content = false;
                }
                at_line_start = true;
            }
            line += 1;
            line_start = i;
            continue;
        }

        if (c == '\\' and i + 1 < source.len and source[i + 1] == '\n') {
            // Ters eğik çizgi ile açık satır devamı.
            i += 2;
            line += 1;
            line_start = i;
            continue;
        }

        if (c == '\\' and i + 2 < source.len and source[i + 1] == '\r' and source[i + 2] == '\n') {
            // AYNI devam, CRLF satır sonu İLE.
            i += 3;
            line += 1;
            line_start = i;
            continue;
        }

        line_has_content = true;

        if (isDigit(c)) {
            const start = i;
            var is_float = false;
            while (i < source.len and isDigit(source[i])) : (i += 1) {}
            if (i < source.len and source[i] == '.' and i + 1 < source.len and isDigit(source[i + 1])) {
                is_float = true;
                i += 1;
                while (i < source.len and isDigit(source[i])) : (i += 1) {}
            }
            const lexeme = source[start..i];
            try tokens.append(allocator, mkToken(if (is_float) .float_lit else .int_lit, lexeme, line, col, start));
            continue;
        }

        // Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
        // `f`/`F` HEMEN ARDINDAN (boşluksuz) bir tırnak GELİYORSA bu bir
        // f-string önekidir — `isIdentStart` denetiminden ÖNCE ele alınır
        // (aksi halde `f` düz bir `identifier` olarak tüketilir, `f"..."`
        // İKİ AYRI/ANLAMSIZ token olarak lexlenirdi). HAM metin (öneki/
        // tırnakları/`{...}` interpolasyonlarını OLDUĞU GİBİ İÇEREN) TEK
        // bir `.fstring_lit` token'ı olarak tutulur — segment'lere bölme
        // (literal/ifade) VE kaçış çözme parser'a bırakılır (bkz.
        // `parsePrimary`in `.fstring_lit` dalı). Kullanıcının (AskUserQuestion)
        // SEÇTİĞİ Python'ın KLASİK (<3.12) iç-içe-tırnak kuralı: `{}` İÇİNDE
        // bir string DIŞ tırnaktan FARKLI bir tırnak KULLANMALIDIR (`f"{d
        // ['key']}"` ÇALIŞIR, `f"{d["key"]}"` ÇALIŞMAZ — Python'ın KENDİSİ
        // de ayırt EDEMEZ). `{{`/`}}` düz metin bölgesinde KAÇAN literal
        // `{`/`}` (Python'ın AYNI konvansiyonu).
        if ((c == 'f' or c == 'F') and i + 1 < source.len and (source[i + 1] == '\'' or source[i + 1] == '"')) {
            const quote = source[i + 1];
            const start = i;
            i += 2;
            var brace_depth: u32 = 0;
            var nested_quote: ?u8 = null;
            while (i < source.len) {
                const ch = source[i];
                if (nested_quote) |nq| {
                    if (ch == '\\' and i + 1 < source.len) {
                        i += 2;
                        continue;
                    }
                    if (ch == nq) nested_quote = null;
                    i += 1;
                    continue;
                }
                if (brace_depth == 0) {
                    if (ch == quote) break;
                    if (ch == '\\' and i + 1 < source.len) {
                        i += 2;
                        continue;
                    }
                    if (ch == '{') {
                        if (peek(source, i + 1) == '{') {
                            i += 2;
                            continue;
                        }
                        brace_depth = 1;
                        i += 1;
                        continue;
                    }
                    if (ch == '}') {
                        if (peek(source, i + 1) == '}') {
                            i += 2;
                            continue;
                        }
                        if (err_span_out) |so| so.* = posSpan(i, line, line_start);
                        return error.UnexpectedCharacter;
                    }
                    i += 1;
                    continue;
                }
                // `brace_depth > 0` — bir `{...}` interpolasyonunun İÇİNDEYİZ.
                if (ch == '\'' or ch == '"') {
                    if (ch == quote) {
                        // Python'ın KLASİK kısıtı: iç string DIŞ tırnakla
                        // AYNI OLAMAZ (ayırt edilemez olurdu).
                        if (err_span_out) |so| so.* = posSpan(i, line, line_start);
                        return error.UnexpectedCharacter;
                    }
                    nested_quote = ch;
                    i += 1;
                    continue;
                }
                if (ch == '{') {
                    brace_depth += 1;
                    i += 1;
                    continue;
                }
                if (ch == '}') {
                    brace_depth -= 1;
                    i += 1;
                    continue;
                }
                i += 1;
            }
            if (i >= source.len or brace_depth != 0 or nested_quote != null) {
                if (err_span_out) |so| so.* = posSpan(start, line, line_start);
                return error.UnterminatedString;
            }
            i += 1; // kapanış tırnağı
            try tokens.append(allocator, mkToken(.fstring_lit, source[start..i], line, col, start));
            continue;
        }

        if (isIdentStart(c)) {
            const start = i;
            while (i < source.len and isIdentCont(source[i])) : (i += 1) {}
            const word = source[start..i];
            const kind = token_mod.lookupKeyword(word) orelse .identifier;
            try tokens.append(allocator, mkToken(kind, word, line, col, start));
            continue;
        }

        if (c == '\'' or c == '"') {
            const quote = c;
            const start = i;
            i += 1;
            while (i < source.len and source[i] != quote) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if (i >= source.len) {
                // Açılış tırnağını İŞARET ET (`start`) — "bu dize HİÇ
                // kapanmadı" tanılaması İçin en ANLAMLI konum, kaynağın
                // SONU (`i`) DEĞİL.
                if (err_span_out) |so| so.* = posSpan(start, line, line_start);
                return error.UnterminatedString;
            }
            i += 1; // kapanış tırnağı
            try tokens.append(allocator, mkToken(.string_lit, source[start..i], line, col, start));
            continue;
        }

        switch (c) {
            '(' => {
                paren_depth += 1;
                try tokens.append(allocator, mkToken(.l_paren, "(", line, col, i));
                i += 1;
            },
            ')' => {
                paren_depth -= 1;
                try tokens.append(allocator, mkToken(.r_paren, ")", line, col, i));
                i += 1;
            },
            '[' => {
                paren_depth += 1;
                try tokens.append(allocator, mkToken(.l_bracket, "[", line, col, i));
                i += 1;
            },
            ']' => {
                paren_depth -= 1;
                try tokens.append(allocator, mkToken(.r_bracket, "]", line, col, i));
                i += 1;
            },
            '{' => {
                paren_depth += 1;
                try tokens.append(allocator, mkToken(.l_brace, "{", line, col, i));
                i += 1;
            },
            '}' => {
                paren_depth -= 1;
                try tokens.append(allocator, mkToken(.r_brace, "}", line, col, i));
                i += 1;
            },
            ':' => {
                try tokens.append(allocator, mkToken(.colon, ":", line, col, i));
                i += 1;
            },
            ',' => {
                try tokens.append(allocator, mkToken(.comma, ",", line, col, i));
                i += 1;
            },
            '.' => {
                try tokens.append(allocator, mkToken(.dot, ".", line, col, i));
                i += 1;
            },
            '+' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.plus_eq, "+=", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.plus, "+", line, col, i));
                    i += 1;
                }
            },
            '-' => {
                if (peek(source, i + 1) == '>') {
                    try tokens.append(allocator, mkToken(.arrow, "->", line, col, i));
                    i += 2;
                } else if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.minus_eq, "-=", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.minus, "-", line, col, i));
                    i += 1;
                }
            },
            '*' => {
                if (peek(source, i + 1) == '*') {
                    if (peek(source, i + 2) == '=') {
                        try tokens.append(allocator, mkToken(.star_star_eq, "**=", line, col, i));
                        i += 3;
                    } else {
                        try tokens.append(allocator, mkToken(.star_star, "**", line, col, i));
                        i += 2;
                    }
                } else if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.star_eq, "*=", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.star, "*", line, col, i));
                    i += 1;
                }
            },
            '/' => {
                if (peek(source, i + 1) == '/') {
                    if (peek(source, i + 2) == '=') {
                        try tokens.append(allocator, mkToken(.slash_slash_eq, "//=", line, col, i));
                        i += 3;
                    } else {
                        try tokens.append(allocator, mkToken(.slash_slash, "//", line, col, i));
                        i += 2;
                    }
                } else if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.slash_eq, "/=", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.slash, "/", line, col, i));
                    i += 1;
                }
            },
            '%' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.percent_eq, "%=", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.percent, "%", line, col, i));
                    i += 1;
                }
            },
            '|' => {
                try tokens.append(allocator, mkToken(.pipe, "|", line, col, i));
                i += 1;
            },
            '=' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.eq_eq, "==", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.assign, "=", line, col, i));
                    i += 1;
                }
            },
            '!' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.not_eq, "!=", line, col, i));
                    i += 2;
                } else {
                    if (err_span_out) |so| so.* = posSpan(i, line, line_start);
                    return error.UnexpectedCharacter;
                }
            },
            '<' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.lt_eq, "<=", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.lt, "<", line, col, i));
                    i += 1;
                }
            },
            '>' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, mkToken(.gt_eq, ">=", line, col, i));
                    i += 2;
                } else {
                    try tokens.append(allocator, mkToken(.gt, ">", line, col, i));
                    i += 1;
                }
            },
            else => {
                if (err_span_out) |so| so.* = posSpan(i, line, line_start);
                return error.UnexpectedCharacter;
            },
        }
    }

    if (line_has_content) {
        try tokens.append(allocator, mkToken(.newline, "", line, 1, i));
    }
    while (indent_stack.items.len > 1) {
        _ = indent_stack.pop();
        try tokens.append(allocator, mkToken(.dedent, "", line, 1, i));
    }
    try tokens.append(allocator, mkToken(.eof, "", line, 1, i));

    return tokens.toOwnedSlice(allocator);
}

fn peek(source: []const u8, idx: usize) u8 {
    if (idx >= source.len) return 0;
    return source[idx];
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

fn tokenizeExpectKinds(source: []const u8, expected: []const TokenKind) !void {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, source);
    defer allocator.free(tokens);
    var kinds = std.ArrayList(TokenKind).empty;
    defer kinds.deinit(allocator);
    for (tokens) |t| try kinds.append(allocator, t.kind);
    try std.testing.expectEqualSlices(TokenKind, expected, kinds.items);
}

test "basit atama: identifier colon type assign int newline eof" {
    try tokenizeExpectKinds("x: int = 5\n", &.{
        .identifier, .colon, .identifier, .assign, .int_lit, .newline, .eof,
    });
}

test "indent/dedent bir if bloğu için doğru üretilir" {
    try tokenizeExpectKinds(
        \\if x:
        \\    y = 1
        \\z = 2
        \\
    , &.{
        .kw_if,   .identifier, .colon,      .newline,
        .indent,  .identifier, .assign,     .int_lit,
        .newline, .dedent,     .identifier, .assign,
        .int_lit, .newline,    .eof,
    });
}

test "yorum satırları ve boş satırlar token üretmez" {
    try tokenizeExpectKinds(
        \\x = 1
        \\# bu bir yorum
        \\
        \\y = 2
        \\
    , &.{
        .identifier, .assign, .int_lit, .newline,
        .identifier, .assign, .int_lit, .newline,
        .eof,
    });
}

test "parantez içinde satır atlaması NEWLINE üretmez" {
    try tokenizeExpectKinds(
        \\f(1,
        \\  2)
        \\
    , &.{
        .identifier, .l_paren, .int_lit, .comma, .int_lit, .r_paren, .newline, .eof,
    });
}

test "string literal kaçış karakteriyle doğru tokenlenir" {
    try tokenizeExpectKinds(
        \\s = "a\"b"
        \\
    , &.{ .identifier, .assign, .string_lit, .newline, .eof });
}

test "CRLF (Windows) satır sonları LF ile BİREBİR AYNI token akışını üretir" {
    // Faz LL.1 devamı: gerçek Windows editörleriyle yazılmış dosyalar İçin
    // — Zig'in çok satırlı `\\` string sözdizimi yalnızca LF ekleyebildiğinden
    // burada AÇIKÇA `\r\n` baytları İÇEREN düz bir dize birleştirmesi kullanılır.
    try tokenizeExpectKinds("if x:\r\n    y = 1\r\nz = 2\r\n", &.{
        .kw_if,   .identifier, .colon,      .newline,
        .indent,  .identifier, .assign,     .int_lit,
        .newline, .dedent,     .identifier, .assign,
        .int_lit, .newline,    .eof,
    });
}

test "CRLF: bos satirlar VE yorumlar LF ile AYNI sekilde token uretmez" {
    try tokenizeExpectKinds("x = 1\r\n# yorum\r\n\r\ny = 2\r\n", &.{
        .identifier, .assign, .int_lit, .newline,
        .identifier, .assign, .int_lit, .newline,
        .eof,
    });
}

test "CRLF: ters egik cizgi ile satir devami CRLF ile de calisir" {
    try tokenizeExpectKinds("x = 1 + \\\r\n    2\r\n", &.{
        .identifier, .assign, .int_lit, .plus, .int_lit, .newline, .eof,
    });
}

test "tutarsız girinti hata üretir" {
    const allocator = std.testing.allocator;
    const result = tokenize(allocator,
        \\if x:
        \\    y = 1
        \\  z = 2
        \\
    );
    try std.testing.expectError(error.InconsistentIndentation, result);
}
