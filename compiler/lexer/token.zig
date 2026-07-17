//! Nox token tanımları.

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
    kw_with,

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
    /// Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `T | None`
    /// (Optional) tip ifadesinin ayracı. `|` dilde BAŞKA HİÇBİR yerde
    /// (ne değer ne tip pozisyonunda) kullanılmadığından bu YENİ token
    /// SIFIR çakışma riski taşır.
    pipe, // |

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

/// Faz T.4a: normal token akışının ATTIĞI (bkz. `lexer.zig`nin `tokenize`i)
/// yorum/boş-satır bilgisini KORUYAN ayrı bir "trivia" akışı — gelecekteki
/// bir formatlayıcının (Faz T.4b) yorumları/boş satırları en yakın `ast.Stmt`
/// (bkz. `ast.Stmt.line`, Faz T.1) ile hizalayarak YENİDEN yerleştirebilmesi
/// İÇİNDİR. `lexer.tokenize` (ÇOĞU tüketici — parser/checker/codegen/testler)
/// BUNU HİÇ ÜRETMEZ (davranış/performans DEĞİŞMEZ); yalnızca YENİ
/// `lexer.tokenizeWithTrivia` doldurur.
pub const TriviaKind = enum { comment, blank_line };

pub const Trivia = struct {
    kind: TriviaKind,
    /// 1-tabanlı kaynak satırı (bkz. `Token.line`/`ast.Stmt.line` İLE AYNI ölçek).
    line: u32,
    /// yalnızca `.comment` İÇİN: `#` DAHİL, satır sonuna kadar ham metin
    /// (baştaki girinti/boşluk DAHİL DEĞİL — formatlayıcı girintiyi KENDİSİ
    /// yeniden hesaplar, bkz. modül üstü not).
    text: []const u8 = "",
    /// `.comment` İÇİN: `true` İSE bu yorumdan ÖNCE AYNI satırda kod
    /// VARDI ("trailing" — ör. `x = 1  # açıklama`); `false` İSE satır
    /// TAMAMEN yorumdan oluşuyordu ("standalone").
    trailing: bool = false,
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
    .{ "with", TokenKind.kw_with },
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
