//! P1.4 (bkz. `lsp_main.zig`nin modül üstü notu): `noxlsp`nin gezinme
//! yetenekleri — `textDocument/completion`/`definition`/`hover`. `lsp_main.
//! zig`nin tanılama boru hattının AKSİNE (bkz. onun `resolveModuleForLsp`i),
//! bu dosya HER ZAMAN kullanıcının HAM (stdlib/proje ile BİRLEŞTİRİLMEMİŞ)
//! `ast.Module`ü üzerinde çalışır — ÇÜNKÜ konum bilgisi (`ast.Stmt.span`)
//! yalnızca KULLANICININ KENDİ kaynak metnine göre ANLAMLIDIR (birleştirme,
//! bkz. `module_loader.resolveImportsImpl`, stdlib deyimlerini KULLANICI
//! deyimlerinden ÖNCE ekler — birleştirilmiş modülün `Stmt.span`leri ARTIK
//! KULLANICININ dosyasındaki GERÇEK bayt konumlarıyla eşleşmez).
//!
//! **Bilinçli v1 kapsamı:** gezinme YALNIZCA AYNI dosya İÇİNDEDİR — `import`
//! edilen bir stdlib/proje-içi sembole (ör. `nox.http.get`) goto-definition
//! DESTEKLENMEZ (`resolveAt` böyle bir isim için `null` döner, `lsp_main.
//! zig`nin `handleDefinition`i bunu "sonuç yok" olarak ele alır). Yalnızca
//! ÜST-DÜZEY `func_def`/`class_def` + KAPSAYAN fonksiyon/metodun parametre/
//! yerel değişkenleri + sabit bir yerleşik(`builtin`)/anahtar-kelime listesi
//! çözülür — `checker.zig`nin GERÇEK tip çıkarım/sembol tablosu MOTORUNU
//! (2700+ satır, modülün TAMAMEN farklı bir amaçla — tip DENETİMİ İçin —
//! inşa edilmiş dahili durumu) YENİDEN KULLANMAZ/YENİDEN UYGULAMAZ; bunun
//! yerine yalnızca `ast.Stmt.span`in (Faz T.1/gerçek span sistemi) ZATEN
//! sağladığı konum bilgisine dayanan, kasıtlı olarak DAR bir statik gezinme
//! katmanıdır.

const std = @import("std");
const ast = @import("parser/ast.zig");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const token_mod = @import("lexer/token.zig");
const Token = token_mod.Token;
const Span = @import("span.zig").Span;

pub const ParsedNav = struct { tokens: []const Token, module: ast.Module };

/// `source`u (bkz. `lsp_main.zig`nin `handleCompletion`/`handleDefinition`/
/// `handleHover`ı) lex+parse eder; İKİSİNDEN BİRİ BAŞARISIZ olursa `null`
/// döner (ör. kullanıcı O AN geçersiz/eksik bir sözdizimi yazıyor — bu bir
/// HATA DEĞİLDİR, sadece o AN İçin gezinme verisi YOKTUR; tanılamalar ZATEN
/// AYRI bir yoldan — `computeDiagnostics` — kullanıcıya BUNU bildirir).
pub fn parseForNav(a: std.mem.Allocator, source: []const u8) ?ParsedNav {
    const tokens = lexer.tokenize(a, source) catch return null;
    var p = parser.Parser.init(a, tokens);
    const module = p.parseModule() catch return null;
    return .{ .tokens = tokens, .module = module };
}

pub const SymbolKind = enum { function, class, parameter, local_var, builtin, keyword };

pub const SymbolInfo = struct {
    name: []const u8,
    kind: SymbolKind,
    detail: []const u8,
    /// `.isNone()` — bu sembol İÇİN (ör. bir yerleşik/anahtar kelime)
    /// GEÇERLİ bir goto-definition HEDEFİ YOKTUR.
    span: Span = .{},
};

const BuiltinDoc = struct { name: []const u8, detail: []const u8 };

// Faz III + builtin genişletme fazının (bkz. proje belleği "Builtin
// genişletme") ZATEN uyguladığı yerleşik fonksiyonların statik dökümü —
// checker'ın KENDİ yerleşik listesiyle senkron TUTULMALIDIR (bu dosyanın
// TEK elle-bakım gerektiren yeri).
const builtins = [_]BuiltinDoc{
    .{ .name = "print", .detail = "def print(*args) -> None  (yerlesik)" },
    .{ .name = "len", .detail = "def len(x) -> int  (yerlesik)" },
    .{ .name = "input", .detail = "def input(prompt: str = \"\") -> str  (yerlesik)" },
    .{ .name = "abs", .detail = "def abs(x)  (yerlesik, sayisal tipi korur)" },
    .{ .name = "min", .detail = "def min(*args)  (yerlesik, sayisal tipi korur)" },
    .{ .name = "max", .detail = "def max(*args)  (yerlesik, sayisal tipi korur)" },
    .{ .name = "round", .detail = "def round(x: float) -> int  (yerlesik)" },
    .{ .name = "sum", .detail = "def sum(xs: list[...])  (yerlesik)" },
};

const keywords = [_][]const u8{
    "def",     "class", "if",     "elif",  "else",   "while", "for",   "in",
    "return",  "pass",  "and",    "or",    "not",    "True",  "False", "None",
    "raise",   "try",   "except", "finally", "as",    "protocol", "extern", "from",
    "async",   "await", "spawn",  "import", "with",  "defer", "lowlevel",
};

/// `tokens` İÇİNDE (1-tabanlı) `line1`/`col1` konumunu KAPSAYAN bir
/// `.identifier` token'ının lexeme'ini döner — bulunamazsa `null`
/// (ör. cursor bir anahtar kelime/noktalama/boşluk üzerindeyse; anahtar
/// kelimeler AYRI token türleriyle temsil edildiğinden — bkz. `token.zig`nin
/// `keyword_map`i — burada YAKALANMAZ, bu BİLİNÇLİDİR: `resolveAt`in
/// `keywords` listesi zaten AYRI, isim-tabanlı bir eşleştirmedir).
pub fn identifierAt(tokens: []const Token, line1: u32, col1: u32) ?[]const u8 {
    for (tokens) |t| {
        if (t.kind != .identifier) continue;
        if (t.line != line1) continue;
        if (col1 >= t.col and col1 <= t.end_col) return t.lexeme;
    }
    return null;
}

fn typeExprToString(a: std.mem.Allocator, te: ast.TypeExpr) std.mem.Allocator.Error![]const u8 {
    switch (te) {
        .simple => |s| return a.dupe(u8, s),
        .generic => |g| {
            var parts: std.ArrayListUnmanaged(u8) = .empty;
            try parts.appendSlice(a, g.name);
            try parts.append(a, '[');
            for (g.args, 0..) |arg, i| {
                if (i > 0) try parts.appendSlice(a, ", ");
                try parts.appendSlice(a, try typeExprToString(a, arg));
            }
            try parts.append(a, ']');
            return parts.toOwnedSlice(a);
        },
        .func_type => |ft| {
            var parts: std.ArrayListUnmanaged(u8) = .empty;
            try parts.append(a, '(');
            for (ft.params, 0..) |p, i| {
                if (i > 0) try parts.appendSlice(a, ", ");
                try parts.appendSlice(a, try typeExprToString(a, p));
            }
            try parts.appendSlice(a, ") -> ");
            try parts.appendSlice(a, try typeExprToString(a, ft.return_type.*));
            return parts.toOwnedSlice(a);
        },
        .optional => |inner| {
            const base = try typeExprToString(a, inner.*);
            return std.fmt.allocPrint(a, "{s} | None", .{base});
        },
    }
}

fn funcSignature(a: std.mem.Allocator, fd: ast.FuncDef) std.mem.Allocator.Error![]const u8 {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    if (fd.is_async) try parts.appendSlice(a, "async ");
    try parts.appendSlice(a, "def ");
    try parts.appendSlice(a, fd.name);
    try parts.append(a, '(');
    for (fd.params, 0..) |p, i| {
        if (i > 0) try parts.appendSlice(a, ", ");
        try parts.appendSlice(a, p.name);
        try parts.appendSlice(a, ": ");
        try parts.appendSlice(a, try typeExprToString(a, p.type_expr));
    }
    try parts.appendSlice(a, ") -> ");
    try parts.appendSlice(a, try typeExprToString(a, fd.return_type));
    return parts.toOwnedSlice(a);
}

/// Bir metodun (`ast.ClassDef.methods`teki, `ast.Stmt` İLE SARILMAMIŞ —
/// bkz. modül üstü not) yaklaşık kapsayan span'ı: GÖVDESİNİN İLK deyiminin
/// BAŞLANGICINDAN SON deyiminin BİTİŞİNE kadar (`def foo(...):` BAŞLIK
/// satırının KENDİSİ bu ARALIĞA dahil DEĞİLDİR — kabul edilebilir bir v1
/// yaklaşıklığı). Gövde BOŞSA (yalnızca `pass`) YA DA HERHANGİ bir uçtaki
/// deyimin span'ı hiç YAKALANAMADIYSA `Span{}` (none) döner.
fn spanOfBody(body: []const ast.Stmt) Span {
    if (body.len == 0) return .{};
    const first = body[0].span;
    const last = body[body.len - 1].span;
    if (first.isNone() or last.isNone()) return .{};
    return .{
        .start_byte = first.start_byte,
        .start_line = first.start_line,
        .start_col = first.start_col,
        .end_byte = last.end_byte,
        .end_line = last.end_line,
        .end_col = last.end_col,
    };
}

fn lineInSpan(span: Span, line1: u32) bool {
    return !span.isNone() and line1 >= span.start_line and line1 <= span.end_line;
}

/// Modülün ÜST-DÜZEY `func_def`/`class_def`lerini (VE sınıfların metodlarını
/// — `spanOfBody` yaklaşıklığıyla) toplar. `out`, isimle anahtarlanır — AYNI
/// isimde birden fazla sembol OLURSA (ör. iki farklı sınıfın AYNI adlı
/// metodu) SONUNCUSU KAZANIR (bilinçli basitleştirme, bkz. modül üstü not).
fn collectTopLevel(a: std.mem.Allocator, module: ast.Module, out: *std.StringHashMapUnmanaged(SymbolInfo)) !void {
    for (module.body) |s| {
        switch (s.kind) {
            .func_def => |fd| {
                try out.put(a, fd.name, .{ .name = fd.name, .kind = .function, .detail = try funcSignature(a, fd), .span = s.span });
            },
            .class_def => |cd| {
                const detail = try std.fmt.allocPrint(a, "class {s}  ({d} metod)", .{ cd.name, cd.methods.len });
                try out.put(a, cd.name, .{ .name = cd.name, .kind = .class, .detail = detail, .span = s.span });
                for (cd.methods) |m| {
                    try out.put(a, m.name, .{ .name = m.name, .kind = .function, .detail = try funcSignature(a, m), .span = spanOfBody(m.body) });
                }
            },
            else => {},
        }
    }
}

/// `line1` (1-tabanlı) konumunu KAPSAYAN EN İÇTEKİ fonksiyon/metod
/// kapsamının (VARSA, `def`/`class` dışındaki bir üst-düzey deyimdeyse
/// module-düzeyi kapsam kullanılır) parametrelerini VE yerel değişkenlerini
/// (`var_decl`/`for` döngü değişkeni/`except`in bağladığı ad/`with`in
/// `as`ı) toplar. İç içe (nested) fonksiyonlar/metodlar İÇİN, `line1`
/// GERÇEKTEN o iç fonksiyonun İÇİNDEYSE dış kapsamın sembolleri de (closure
/// yakalaması İLE TUTARLI biçimde) korunur — yalnızca AYNI isimde bir iç
/// sembol varsa ÜZERİNE YAZILIR (doğru gölgeleme/shadowing).
fn collectScopeAt(a: std.mem.Allocator, body: []const ast.Stmt, line1: u32, syms: *std.StringHashMapUnmanaged(SymbolInfo)) std.mem.Allocator.Error!void {
    for (body) |s| {
        switch (s.kind) {
            .var_decl => |vd| {
                const detail = try std.fmt.allocPrint(a, "{s}: {s}", .{ vd.name, try typeExprToString(a, vd.type_expr) });
                try syms.put(a, vd.name, .{ .name = vd.name, .kind = .local_var, .detail = detail, .span = s.span });
            },
            .func_def => |fd| {
                if (lineInSpan(s.span, line1)) {
                    for (fd.params) |p| {
                        const detail = try std.fmt.allocPrint(a, "{s}: {s}  (parametre)", .{ p.name, try typeExprToString(a, p.type_expr) });
                        try syms.put(a, p.name, .{ .name = p.name, .kind = .parameter, .detail = detail, .span = s.span });
                    }
                    try collectScopeAt(a, fd.body, line1, syms);
                }
            },
            .class_def => |cd| {
                for (cd.methods) |m| {
                    const mspan = spanOfBody(m.body);
                    if (lineInSpan(mspan, line1)) {
                        for (m.params) |p| {
                            const detail = try std.fmt.allocPrint(a, "{s}: {s}  (parametre)", .{ p.name, try typeExprToString(a, p.type_expr) });
                            try syms.put(a, p.name, .{ .name = p.name, .kind = .parameter, .detail = detail, .span = mspan });
                        }
                        try collectScopeAt(a, m.body, line1, syms);
                    }
                }
            },
            .if_stmt => |f| {
                try collectScopeAt(a, f.then_body, line1, syms);
                for (f.elif_clauses) |ec| try collectScopeAt(a, ec.body, line1, syms);
                if (f.else_body) |eb| try collectScopeAt(a, eb, line1, syms);
            },
            .while_stmt => |w| try collectScopeAt(a, w.body, line1, syms),
            .for_stmt => |f| {
                const detail = try std.fmt.allocPrint(a, "{s}  (for degiskeni)", .{f.var_name});
                try syms.put(a, f.var_name, .{ .name = f.var_name, .kind = .local_var, .detail = detail, .span = s.span });
                try collectScopeAt(a, f.body, line1, syms);
            },
            .try_stmt => |t| {
                try collectScopeAt(a, t.try_body, line1, syms);
                for (t.except_clauses) |ec| {
                    if (ec.bind_name) |bn| {
                        const detail = try std.fmt.allocPrint(a, "{s}  (except degiskeni)", .{bn});
                        try syms.put(a, bn, .{ .name = bn, .kind = .local_var, .detail = detail, .span = s.span });
                    }
                    try collectScopeAt(a, ec.body, line1, syms);
                }
                if (t.finally_body) |fb| try collectScopeAt(a, fb, line1, syms);
            },
            .with_stmt => |w| {
                if (w.binding) |bn| {
                    const detail = try std.fmt.allocPrint(a, "{s}  (with baglami)", .{bn});
                    try syms.put(a, bn, .{ .name = bn, .kind = .local_var, .detail = detail, .span = s.span });
                }
                try collectScopeAt(a, w.body, line1, syms);
            },
            .lowlevel_stmt => |ll| try collectScopeAt(a, ll.body, line1, syms),
            else => {},
        }
    }
}

pub const ResolveResult = struct {
    detail: []const u8,
    /// `.isNone()` — bu sembol İÇİN geçerli bir goto-definition HEDEFİ YOK
    /// (bkz. `SymbolInfo.span`in AYNI notu).
    span: Span,
};

/// `name`i (bkz. `identifierAt`) `line1` konumundaki kapsama göre çözer —
/// ÖNCE kapsayan fonksiyon/metodun parametre/yerelleri, SONRA modülün
/// üst-düzey `func_def`/`class_def`leri, SON OLARAK sabit yerleşik/anahtar-
/// kelime listesi denenir (bkz. modül üstü not, "yalnızca AYNI dosya").
pub fn resolveAt(a: std.mem.Allocator, module: ast.Module, line1: u32, name: []const u8) !?ResolveResult {
    var scope: std.StringHashMapUnmanaged(SymbolInfo) = .empty;
    try collectScopeAt(a, module.body, line1, &scope);
    if (scope.get(name)) |sym| return .{ .detail = sym.detail, .span = sym.span };

    var top: std.StringHashMapUnmanaged(SymbolInfo) = .empty;
    try collectTopLevel(a, module, &top);
    if (top.get(name)) |sym| return .{ .detail = sym.detail, .span = sym.span };

    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, name)) return .{ .detail = b.detail, .span = .{} };
    }
    for (keywords) |kw| {
        if (std.mem.eql(u8, kw, name)) return .{ .detail = "anahtar kelime", .span = .{} };
    }
    return null;
}

/// `line1` konumunda GEÇERLİ TÜM tamamlama adaylarını (kapsayan fonksiyon/
/// metodun parametre/yerelleri + modülün üst-düzey `func_def`/`class_def`
/// leri + yerleşikler/anahtar kelimeler) döner — istemcinin (bkz. `lsp_main.
/// zig`nin `handleCompletion`i) KENDİ ÖNEK/fuzzy FİLTRELEMESİNE bırakılır
/// (standart LSP istemci davranışı, bu sunucu KENDİ filtrelemesini yapmaz).
pub fn completionItems(a: std.mem.Allocator, module: ast.Module, line1: u32) ![]const SymbolInfo {
    var scope: std.StringHashMapUnmanaged(SymbolInfo) = .empty;
    try collectScopeAt(a, module.body, line1, &scope);
    var top: std.StringHashMapUnmanaged(SymbolInfo) = .empty;
    try collectTopLevel(a, module, &top);

    var out: std.ArrayListUnmanaged(SymbolInfo) = .empty;
    var scope_it = scope.valueIterator();
    while (scope_it.next()) |v| try out.append(a, v.*);
    var top_it = top.iterator();
    while (top_it.next()) |entry| {
        if (!scope.contains(entry.key_ptr.*)) try out.append(a, entry.value_ptr.*);
    }
    for (builtins) |b| try out.append(a, .{ .name = b.name, .kind = .builtin, .detail = b.detail });
    for (keywords) |kw| try out.append(a, .{ .name = kw, .kind = .keyword, .detail = "anahtar kelime" });
    return out.toOwnedSlice(a);
}
