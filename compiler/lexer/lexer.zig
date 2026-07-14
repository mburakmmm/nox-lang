//! Nox v0.1 indent-farkında lexer. Kaynak metni tek seferde token dizisine çevirir.
//! Python tokenizer'ındaki INDENT/DEDENT modeli referans alınmıştır.

const std = @import("std");
const token_mod = @import("token.zig");
pub const Token = token_mod.Token;
pub const TokenKind = token_mod.TokenKind;
pub const Trivia = token_mod.Trivia;
pub const TriviaKind = token_mod.TriviaKind;

pub const LexError = error{
    UnexpectedCharacter,
    UnterminatedString,
    InconsistentIndentation,
    TabsNotAllowed,
    OutOfMemory,
};

/// `source`'u token dizisine çevirir. Allocator her zaman açık parametredir (İlke #6).
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) LexError![]Token {
    return tokenizeImpl(allocator, source, null);
}

/// Faz T.4a: `tokenize` İLE AYNI token akışını üretir, AMA AYRICA yorum/
/// boş-satır konumlarını (`Trivia`, bkz. `token.zig`nin belge notu) YAKALAR
/// — gelecekteki formatlayıcı (Faz T.4b) DIŞINDA HİÇBİR tüketici bunu
/// KULLANMAZ (`tokenize`nin KENDİSİ DEĞİŞMEDİ, davranışı/performansı AYNI).
pub fn tokenizeWithTrivia(allocator: std.mem.Allocator, source: []const u8) LexError!struct { tokens: []Token, trivia: []Trivia } {
    var trivia: std.ArrayList(Trivia) = .empty;
    errdefer trivia.deinit(allocator);
    const tokens = try tokenizeImpl(allocator, source, &trivia);
    return .{ .tokens = tokens, .trivia = try trivia.toOwnedSlice(allocator) };
}

fn tokenizeImpl(allocator: std.mem.Allocator, source: []const u8, trivia_out: ?*std.ArrayList(Trivia)) LexError![]Token {
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
                if (source[i] == '\t') return error.TabsNotAllowed;
                indent += 1;
            }
            if (i >= source.len or source[i] == '\n' or source[i] == '#') {
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
                try tokens.append(allocator, .{ .kind = .indent, .lexeme = "", .line = line, .col = 1 });
            } else if (indent < top) {
                while (indent_stack.items[indent_stack.items.len - 1] > indent) {
                    _ = indent_stack.pop();
                    try tokens.append(allocator, .{ .kind = .dedent, .lexeme = "", .line = line, .col = 1 });
                }
                if (indent_stack.items[indent_stack.items.len - 1] != indent) {
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
                    try tokens.append(allocator, .{ .kind = .newline, .lexeme = "", .line = line, .col = col });
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
            try tokens.append(allocator, .{
                .kind = if (is_float) .float_lit else .int_lit,
                .lexeme = lexeme,
                .line = line,
                .col = col,
            });
            continue;
        }

        if (isIdentStart(c)) {
            const start = i;
            while (i < source.len and isIdentCont(source[i])) : (i += 1) {}
            const word = source[start..i];
            const kind = token_mod.lookupKeyword(word) orelse .identifier;
            try tokens.append(allocator, .{ .kind = kind, .lexeme = word, .line = line, .col = col });
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
            if (i >= source.len) return error.UnterminatedString;
            i += 1; // kapanış tırnağı
            try tokens.append(allocator, .{ .kind = .string_lit, .lexeme = source[start..i], .line = line, .col = col });
            continue;
        }

        switch (c) {
            '(' => {
                paren_depth += 1;
                try tokens.append(allocator, .{ .kind = .l_paren, .lexeme = "(", .line = line, .col = col });
                i += 1;
            },
            ')' => {
                paren_depth -= 1;
                try tokens.append(allocator, .{ .kind = .r_paren, .lexeme = ")", .line = line, .col = col });
                i += 1;
            },
            '[' => {
                paren_depth += 1;
                try tokens.append(allocator, .{ .kind = .l_bracket, .lexeme = "[", .line = line, .col = col });
                i += 1;
            },
            ']' => {
                paren_depth -= 1;
                try tokens.append(allocator, .{ .kind = .r_bracket, .lexeme = "]", .line = line, .col = col });
                i += 1;
            },
            '{' => {
                paren_depth += 1;
                try tokens.append(allocator, .{ .kind = .l_brace, .lexeme = "{", .line = line, .col = col });
                i += 1;
            },
            '}' => {
                paren_depth -= 1;
                try tokens.append(allocator, .{ .kind = .r_brace, .lexeme = "}", .line = line, .col = col });
                i += 1;
            },
            ':' => {
                try tokens.append(allocator, .{ .kind = .colon, .lexeme = ":", .line = line, .col = col });
                i += 1;
            },
            ',' => {
                try tokens.append(allocator, .{ .kind = .comma, .lexeme = ",", .line = line, .col = col });
                i += 1;
            },
            '.' => {
                try tokens.append(allocator, .{ .kind = .dot, .lexeme = ".", .line = line, .col = col });
                i += 1;
            },
            '+' => {
                try tokens.append(allocator, .{ .kind = .plus, .lexeme = "+", .line = line, .col = col });
                i += 1;
            },
            '-' => {
                if (peek(source, i + 1) == '>') {
                    try tokens.append(allocator, .{ .kind = .arrow, .lexeme = "->", .line = line, .col = col });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .kind = .minus, .lexeme = "-", .line = line, .col = col });
                    i += 1;
                }
            },
            '*' => {
                if (peek(source, i + 1) == '*') {
                    try tokens.append(allocator, .{ .kind = .star_star, .lexeme = "**", .line = line, .col = col });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .kind = .star, .lexeme = "*", .line = line, .col = col });
                    i += 1;
                }
            },
            '/' => {
                if (peek(source, i + 1) == '/') {
                    try tokens.append(allocator, .{ .kind = .slash_slash, .lexeme = "//", .line = line, .col = col });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .kind = .slash, .lexeme = "/", .line = line, .col = col });
                    i += 1;
                }
            },
            '%' => {
                try tokens.append(allocator, .{ .kind = .percent, .lexeme = "%", .line = line, .col = col });
                i += 1;
            },
            '=' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, .{ .kind = .eq_eq, .lexeme = "==", .line = line, .col = col });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .kind = .assign, .lexeme = "=", .line = line, .col = col });
                    i += 1;
                }
            },
            '!' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, .{ .kind = .not_eq, .lexeme = "!=", .line = line, .col = col });
                    i += 2;
                } else {
                    return error.UnexpectedCharacter;
                }
            },
            '<' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, .{ .kind = .lt_eq, .lexeme = "<=", .line = line, .col = col });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .kind = .lt, .lexeme = "<", .line = line, .col = col });
                    i += 1;
                }
            },
            '>' => {
                if (peek(source, i + 1) == '=') {
                    try tokens.append(allocator, .{ .kind = .gt_eq, .lexeme = ">=", .line = line, .col = col });
                    i += 2;
                } else {
                    try tokens.append(allocator, .{ .kind = .gt, .lexeme = ">", .line = line, .col = col });
                    i += 1;
                }
            },
            else => return error.UnexpectedCharacter,
        }
    }

    if (line_has_content) {
        try tokens.append(allocator, .{ .kind = .newline, .lexeme = "", .line = line, .col = 1 });
    }
    while (indent_stack.items.len > 1) {
        _ = indent_stack.pop();
        try tokens.append(allocator, .{ .kind = .dedent, .lexeme = "", .line = line, .col = 1 });
    }
    try tokens.append(allocator, .{ .kind = .eof, .lexeme = "", .line = line, .col = 1 });

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
