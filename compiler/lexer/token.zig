//! Nox v0.1 token tanımları.

pub const TokenKind = enum {
    // literals
    int_lit,
    float_lit,
    string_lit,
    identifier,

    // keywords
    kw_def,
    kw_class,
    kw_if,
    kw_elif,
    kw_else,
    kw_while,
    kw_for,
    kw_in,
    kw_return,
    kw_pass,
    kw_and,
    kw_or,
    kw_not,
    kw_true,
    kw_false,
    kw_none,
    kw_raise,
    kw_try,
    kw_except,
    kw_finally,
    kw_as,
    kw_lowlevel,
    kw_protocol,
    kw_extern,
    kw_from,
    kw_async,
    kw_await,
    kw_spawn,
    kw_import,
    kw_with_rt,

    // punctuation
    colon,
    comma,
    dot,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    arrow, // ->

    // operators
    plus,
    minus,
    star,
    slash,
    slash_slash, // //
    percent,
    star_star, // **
    eq_eq,
    not_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,
    assign, // =

    // structure
    newline,
    indent,
    dedent,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: u32,
    col: u32,
};

const keyword_table = .{
    .{ "def", TokenKind.kw_def },
    .{ "class", TokenKind.kw_class },
    .{ "if", TokenKind.kw_if },
    .{ "elif", TokenKind.kw_elif },
    .{ "else", TokenKind.kw_else },
    .{ "while", TokenKind.kw_while },
    .{ "for", TokenKind.kw_for },
    .{ "in", TokenKind.kw_in },
    .{ "return", TokenKind.kw_return },
    .{ "pass", TokenKind.kw_pass },
    .{ "and", TokenKind.kw_and },
    .{ "or", TokenKind.kw_or },
    .{ "not", TokenKind.kw_not },
    .{ "True", TokenKind.kw_true },
    .{ "False", TokenKind.kw_false },
    .{ "None", TokenKind.kw_none },
    .{ "raise", TokenKind.kw_raise },
    .{ "try", TokenKind.kw_try },
    .{ "except", TokenKind.kw_except },
    .{ "finally", TokenKind.kw_finally },
    .{ "as", TokenKind.kw_as },
    .{ "lowlevel", TokenKind.kw_lowlevel },
    .{ "protocol", TokenKind.kw_protocol },
    .{ "extern", TokenKind.kw_extern },
    .{ "from", TokenKind.kw_from },
    .{ "async", TokenKind.kw_async },
    .{ "await", TokenKind.kw_await },
    .{ "spawn", TokenKind.kw_spawn },
    .{ "import", TokenKind.kw_import },
    .{ "with_rt", TokenKind.kw_with_rt },
};

/// Bir tanımlayıcı sözcüğün anahtar kelime olup olmadığını denetler.
pub fn lookupKeyword(word: []const u8) ?TokenKind {
    inline for (keyword_table) |entry| {
        if (@import("std").mem.eql(u8, word, entry[0])) return entry[1];
    }
    return null;
}

const std = @import("std");

test "lookupKeyword tanınan anahtar kelimeleri bulur" {
    try std.testing.expectEqual(TokenKind.kw_def, lookupKeyword("def").?);
    try std.testing.expectEqual(TokenKind.kw_none, lookupKeyword("None").?);
}

test "lookupKeyword anahtar kelime olmayan sözcükte null döner" {
    try std.testing.expectEqual(@as(?TokenKind, null), lookupKeyword("foo"));
}
