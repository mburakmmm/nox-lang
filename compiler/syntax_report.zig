//! Sözdizimi hatalarını kullanıcıya OKUNAKLI biçimde bildirir (v1.160.0).
//!
//! Önceden `noxc check/build/run` bir lex/parse hatasında yalnızca Zig'in
//! varsayılan `error: UnexpectedToken` + yığın izini basıyordu (satır/sütun
//! YOKTU). `Parser.last_diagnostic` ve `lexer.tokenizeCapturingSpan` (LSP için
//! yazılmıştı) zaten tam span taşıyor — bu dosya aynı bilgiyi CLI'ye bağlar:
//!
//!     dosya.nox:2:9: sözdizimi hatası: beklenmeyen simge '2' (beklenen ')')
//!         print(1 2)
//!                 ^
//!
//! Hata YAZILDIKTAN sonra `error.SyntaxError` döner; çağıran süreci sonlandırır
//! (CLI) ya da hatayı yukarı taşır (LSP kendi tanılamasını üretir, burayı
//! kullanmaz).

const std = @import("std");
const ast = @import("parser/ast.zig");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const token_mod = @import("lexer/token.zig");
const span_mod = @import("span.zig");
const TokenKind = token_mod.TokenKind;

pub const Error = error{ SyntaxError, OutOfMemory };

/// Bir simge türünün kullanıcıya gösterilen adı (`beklenen ...` kısmı için).
fn kindName(kind: TokenKind) []const u8 {
    return switch (kind) {
        .int_lit => "tamsayı",
        .float_lit => "ondalık sayı",
        .string_lit => "dize",
        .fstring_lit => "f-dize",
        .identifier => "tanımlayıcı",
        .colon => "':'",
        .comma => "','",
        .dot => "'.'",
        .l_paren => "'('",
        .r_paren => "')'",
        .l_bracket => "'['",
        .r_bracket => "']'",
        .l_brace => "'{'",
        .r_brace => "'}'",
        .arrow => "'->'",
        .assign => "'='",
        .newline => "satır sonu",
        .indent => "girinti",
        .dedent => "girinti azalması",
        .eof => "dosya sonu",
        .kw_in => "'in'",
        .kw_else => "'else'",
        .kw_import => "'import'",
        .kw_def => "'def'",
        .kw_class => "'class'",
        .kw_except => "'except'",
        .kw_as => "'as'",
        else => @tagName(kind),
    };
}

fn lineText(source: []const u8, line: u32) []const u8 {
    var cur: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len and cur < line) : (i += 1) {
        if (source[i] == '\n') {
            cur += 1;
            start = i + 1;
        }
    }
    var end = start;
    while (end < source.len and source[end] != '\n') end += 1;
    if (end > start and source[end - 1] == '\r') end -= 1;
    return source[start..end];
}

fn report(source: []const u8, label: []const u8, line: u32, col: u32, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("{s}:{d}:{d}: sözdizimi hatası: " ++ fmt ++ "\n", .{ label, line, col } ++ args);
    if (line == 0) return;
    const text = lineText(source, line);
    std.debug.print("    {s}\n", .{text});
    var pad_buf: [256]u8 = undefined;
    const pad = @min(if (col > 0) col - 1 else 0, pad_buf.len);
    @memset(pad_buf[0..pad], ' ');
    std.debug.print("    {s}^\n", .{pad_buf[0..pad]});
}

/// `source`'u ayrıştırır; lex/parse hatasında okunaklı bir tanılama basıp `error.SyntaxError` döner.
/// `label`: tanılamada gösterilecek dosya adı.
pub fn parseSource(a: std.mem.Allocator, source: []const u8, label: []const u8) Error!ast.Module {
    const lexed = lexer.tokenizeCapturingSpan(a, source);
    const tokens = lexed.tokens orelse {
        const err = lexed.err.?;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const msg: []const u8 = switch (err) {
            error.UnexpectedCharacter => "beklenmeyen karakter",
            error.UnterminatedString => "kapanmamış dize",
            error.InconsistentIndentation => "tutarsız girinti",
            error.TabsNotAllowed => "girintide sekme (tab) kullanılamaz — boşluk kullanın",
            error.OutOfMemory => unreachable,
        };
        report(source, label, lexed.err_span.start_line, lexed.err_span.start_col, "{s}", .{msg});
        return error.SyntaxError;
    };
    var p = parser.Parser.init(a, tokens);
    return p.parseModule() catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        // `last_diagnostic` geri-izlemeli (backtracking) bir denemeden kalma BAYAT bir konum taşıyabilir: gerçek hata konumu hata anındaki
        // geçerli simgedir; yalnızca tanılama o simgeyle tutarlıysa onun `expected` bilgisi kullanılır.
        var diag: ?parser.ParserDiagnostic = p.last_diagnostic;
        if (e == error.UnexpectedToken) {
            const cur = p.tokens[@min(p.pos, p.tokens.len - 1)];
            if (diag == null or diag.?.span.start_byte != cur.start_byte) {
                diag = .{ .found = cur.kind, .span = span_mod.fromToken(cur), .note = if (diag) |old| old.note else null };
            }
        }
        if (diag) |d| {
            const found: []const u8 = switch (d.found) {
                .newline, .indent, .dedent, .eof => kindName(d.found),
                else => if (d.span.end_byte <= source.len and d.span.start_byte < d.span.end_byte) source[d.span.start_byte..d.span.end_byte] else kindName(d.found),
            };
            const quote: []const u8 = switch (d.found) {
                .newline, .indent, .dedent, .eof => "",
                else => "'",
            };
            if (d.note) |note| {
                report(source, label, d.span.start_line, d.span.start_col, "{s}", .{note});
            } else if (d.expected) |exp| {
                report(source, label, d.span.start_line, d.span.start_col, "beklenmeyen {s}{s}{s} (beklenen {s})", .{ quote, found, quote, kindName(exp) });
            } else {
                report(source, label, d.span.start_line, d.span.start_col, "beklenmeyen {s}{s}{s}", .{ quote, found, quote });
            }
        } else switch (e) {
            error.InvalidNumberLiteral => report(source, label, 0, 0, "geçersiz sayı değişmezi", .{}),
            error.RecursionLimitExceeded => report(source, label, 0, 0, "ifade çok derin iç içe", .{}),
            else => report(source, label, 0, 0, "ayrıştırma hatası ({t})", .{e}),
        }
        return error.SyntaxError;
    };
}

test "parseSource geçerli kaynağı ayrıştırır, bozukta SyntaxError döner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try parseSource(a, "x: int = 1\nprint(x)\n", "ok.nox");
    try std.testing.expectError(error.SyntaxError, parseSource(a, "print(1 2)\n", "bad.nox"));
    try std.testing.expectError(error.SyntaxError, parseSource(a, "if x > 1\n    pass\n", "bad2.nox"));
    try std.testing.expectError(error.SyntaxError, parseSource(a, "x: str = \"abc\n", "bad3.nox"));
    try std.testing.expectError(error.SyntaxError, parseSource(a, "\tx: int = 1\n", "bad4.nox"));
}
