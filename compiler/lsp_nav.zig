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
//! Aynı dosyadaki `resolveAt` üst düzey `func_def`/`class_def`, kapsayan
//! fonksiyonun parametre/yerelleri ve sabit yerleşik listesini çözer.
//! `import` / `from ... import` ile gelen bir sembolün tanımı, referansları
//! ve yeniden adlandırması `lsp_main.zig`de proje köküne ve açık belgelere
//! bakarak çapraz dosya yürür. Bu dosya `checker.zig`nin tip tablosunu
//! yeniden uygulamaz; konum `ast.Stmt.span` üzerindedir.

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
    .{ .name = "print", .detail = "def print(*args) -> None  (builtin)" },
    .{ .name = "len", .detail = "def len(x) -> int  (builtin)" },
    .{ .name = "input", .detail = "def input(prompt: str = \"\") -> str  (builtin)" },
    .{ .name = "abs", .detail = "def abs(x)  (builtin, keeps the numeric type)" },
    .{ .name = "min", .detail = "def min(*args)  (builtin, keeps the numeric type)" },
    .{ .name = "max", .detail = "def max(*args)  (builtin, keeps the numeric type)" },
    .{ .name = "round", .detail = "def round(x: float) -> int  (builtin)" },
    .{ .name = "sum", .detail = "def sum(xs: list[...])  (builtin)" },
    .{ .name = "sorted", .detail = "def sorted(xs, key=None, reverse=False) -> list  (builtin)" },
    .{ .name = "reversed", .detail = "def reversed(xs) -> list  (builtin)" },
    .{ .name = "list", .detail = "def list(iterable) -> list  (builtin: list/str/dict/range)" },
    .{ .name = "bool", .detail = "def bool(x) -> bool  (builtin)" },
    .{ .name = "any", .detail = "def any(xs: list[bool]) -> bool  (builtin)" },
    .{ .name = "all", .detail = "def all(xs: list[bool]) -> bool  (builtin)" },
    .{ .name = "divmod", .detail = "def divmod(a: int, b: int) -> tuple[int, int]  (builtin)" },
    .{ .name = "chr", .detail = "def chr(cp: int) -> str  (builtin)" },
    .{ .name = "ord", .detail = "def ord(s: str) -> int  (builtin)" },
    .{ .name = "map", .detail = "def map(f, xs) -> list  (builtin, not lazy)" },
    .{ .name = "filter", .detail = "def filter(f, xs) -> list  (builtin, not lazy)" },
    .{ .name = "enumerate", .detail = "def enumerate(xs) -> list[tuple[int, T]]  (builtin)" },
    .{ .name = "set", .detail = "def set(iterable) -> set[T]  (builtin; declare the type for set())" },
    .{ .name = "repr", .detail = "def repr(x) -> str  (builtin)" },
    .{ .name = "zip", .detail = "def zip(a, b) -> list[tuple]  (builtin)" },
};

const keywords = [_][]const u8{
    "def",      "class", "if",       "elif",    "else", "while",    "for",    "in",
    "return",   "pass",  "and",      "or",      "not",  "True",     "False",  "None",
    "raise",    "try",   "except",   "finally", "as",   "protocol", "extern", "from",
    "async",    "await", "spawn",    "import",  "with", "defer",    "lambda", "is",
    "lowlevel", "break", "continue", "assert",
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
        .qualified => |segments| {
            var parts: std.ArrayListUnmanaged(u8) = .empty;
            for (segments, 0..) |seg, i| {
                if (i > 0) try parts.append(a, '.');
                try parts.appendSlice(a, seg);
            }
            return parts.toOwnedSlice(a);
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
                const detail = try std.fmt.allocPrint(a, "class {s}  ({d} methods)", .{ cd.name, cd.methods.len });
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
                        const detail = try std.fmt.allocPrint(a, "{s}: {s}  (parameter)", .{ p.name, try typeExprToString(a, p.type_expr) });
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
                            const detail = try std.fmt.allocPrint(a, "{s}: {s}  (parameter)", .{ p.name, try typeExprToString(a, p.type_expr) });
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
                const detail = try std.fmt.allocPrint(a, "{s}  (for variable)", .{f.var_name});
                try syms.put(a, f.var_name, .{ .name = f.var_name, .kind = .local_var, .detail = detail, .span = s.span });
                try collectScopeAt(a, f.body, line1, syms);
            },
            .try_stmt => |t| {
                try collectScopeAt(a, t.try_body, line1, syms);
                for (t.except_clauses) |ec| {
                    if (ec.bind_name) |bn| {
                        const detail = try std.fmt.allocPrint(a, "{s}  (except variable)", .{bn});
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
        if (std.mem.eql(u8, kw, name)) return .{ .detail = "keyword", .span = .{} };
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
    for (keywords) |kw| try out.append(a, .{ .name = kw, .kind = .keyword, .detail = "keyword" });
    return out.toOwnedSlice(a);
}

// ---- Anahat, imza, anlamsal belirteç, parametre ipucu, referans ----
//
// Hepsi AYNI dosyanın ayrıştırılmış modülü üzerinde çalışır. Çapraz dosya
// (`import` hedefi) `lsp_main.zig`de, birleşik modülün span'leri
// KULLANILMADAN, hedef dosya AYRI ayrıştırılarak çözülür.

pub const DocSymbol = struct {
    name: []const u8,
    /// LSP SymbolKind: Class=5, Method=6, Function=12.
    kind: u32,
    span: Span,
    children: []const DocSymbol = &.{},
};

pub fn outline(a: std.mem.Allocator, module: ast.Module) std.mem.Allocator.Error![]const DocSymbol {
    var out: std.ArrayListUnmanaged(DocSymbol) = .empty;
    for (module.body) |s| {
        switch (s.kind) {
            .func_def => |fd| {
                if (s.span.isNone()) continue;
                try out.append(a, .{ .name = fd.name, .kind = 12, .span = s.span });
            },
            .class_def => |cd| {
                if (s.span.isNone()) continue;
                var kids: std.ArrayListUnmanaged(DocSymbol) = .empty;
                for (cd.methods) |m| {
                    const sp = spanOfBody(m.body);
                    if (sp.isNone()) continue;
                    try kids.append(a, .{ .name = m.name, .kind = 6, .span = sp });
                }
                try out.append(a, .{
                    .name = cd.name,
                    .kind = 5,
                    .span = s.span,
                    .children = try kids.toOwnedSlice(a),
                });
            },
            else => {},
        }
    }
    return out.toOwnedSlice(a);
}

pub const SigParam = struct { name: []const u8 };

pub const SignatureInfo = struct {
    label: []const u8,
    params: []const SigParam,
    active: u32,
};

pub fn functionByName(module: ast.Module, name: []const u8) ?ast.FuncDef {
    for (module.body) |s| {
        switch (s.kind) {
            .func_def => |fd| if (std.mem.eql(u8, fd.name, name)) return fd,
            .class_def => |cd| {
                for (cd.methods) |m| {
                    if (std.mem.eql(u8, m.name, name)) return m;
                }
            },
            else => {},
        }
    }
    return null;
}

fn constructorOf(module: ast.Module, class_name: []const u8) ?ast.FuncDef {
    for (module.body) |s| {
        switch (s.kind) {
            .class_def => |cd| {
                if (!std.mem.eql(u8, cd.name, class_name)) continue;
                for (cd.methods) |m| {
                    if (std.mem.eql(u8, m.name, "__init__")) return m;
                }
            },
            else => {},
        }
    }
    return null;
}

fn tokenIndexAt(tokens: []const Token, line1: u32, col1: u32) ?usize {
    var before: ?usize = null;
    for (tokens, 0..) |t, i| {
        if (t.kind == .newline or t.kind == .indent or t.kind == .dedent or t.kind == .eof) continue;
        if (t.line == line1 and col1 >= t.col and col1 <= t.end_col) return i;
        if (t.line < line1 or (t.line == line1 and t.end_col < col1)) before = i;
    }
    return before;
}

fn enclosingParen(tokens: []const Token, from: usize) ?usize {
    var depth: i32 = 0;
    var i = from;
    while (true) {
        const t = tokens[i];
        if (t.kind == .r_paren) depth += 1;
        if (t.kind == .l_paren) {
            if (depth == 0) return i;
            depth -= 1;
        }
        if (i == 0) return null;
        i -= 1;
    }
}

fn calleeChain(a: std.mem.Allocator, tokens: []const Token, paren: usize) std.mem.Allocator.Error![]const []const u8 {
    if (paren == 0) return &.{};
    var i: usize = paren - 1;
    while (tokens[i].kind == .newline or tokens[i].kind == .indent or tokens[i].kind == .dedent) {
        if (i == 0) return &.{};
        i -= 1;
    }
    var rev: std.ArrayListUnmanaged([]const u8) = .empty;
    while (tokens[i].kind == .identifier) {
        try rev.append(a, tokens[i].lexeme);
        if (i == 0) break;
        if (tokens[i - 1].kind != .dot) break;
        if (i < 2) break;
        i -= 2;
    }
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var n = rev.items.len;
    while (n > 0) {
        n -= 1;
        try out.append(a, rev.items[n]);
    }
    return out.items;
}

fn activeParam(tokens: []const Token, paren: usize, cursor: usize) u32 {
    var depth: i32 = 0;
    var commas: u32 = 0;
    var i = paren + 1;
    while (i <= cursor and i < tokens.len) : (i += 1) {
        if (tokens[i].kind == .l_paren) depth += 1;
        if (tokens[i].kind == .r_paren and depth == 0) break;
        if (tokens[i].kind == .r_paren and depth > 0) depth -= 1;
        if (depth == 0 and tokens[i].kind == .comma) commas += 1;
    }
    return commas;
}

fn paramsOf(a: std.mem.Allocator, fd: ast.FuncDef, skip_self: bool) std.mem.Allocator.Error![]const SigParam {
    var out: std.ArrayListUnmanaged(SigParam) = .empty;
    for (fd.params) |p| {
        if (skip_self and std.mem.eql(u8, p.name, "self")) continue;
        try out.append(a, .{ .name = p.name });
    }
    return out.toOwnedSlice(a);
}

fn signatureLabel(a: std.mem.Allocator, name: []const u8, params: []const SigParam) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, name);
    try buf.append(a, '(');
    for (params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, p.name);
    }
    try buf.append(a, ')');
    return buf.toOwnedSlice(a);
}

pub fn signatureFor(a: std.mem.Allocator, module: ast.Module, chain: []const []const u8, active: u32) std.mem.Allocator.Error!?SignatureInfo {
    if (chain.len == 0) return null;
    const name = chain[chain.len - 1];
    const fd = functionByName(module, name) orelse constructorOf(module, name) orelse return null;
    const skip_self = std.mem.eql(u8, fd.name, "__init__") or chain.len > 1;
    const params = try paramsOf(a, fd, skip_self and std.mem.eql(u8, fd.name, "__init__"));
    const shown: u32 = if (params.len > 0 and active >= params.len) @intCast(params.len - 1) else active;
    return .{
        .label = try signatureLabel(a, name, params),
        .params = params,
        .active = shown,
    };
}

pub fn signatureAt(a: std.mem.Allocator, tokens: []const Token, module: ast.Module, line1: u32, col1: u32) std.mem.Allocator.Error!?SignatureInfo {
    const site = try callSiteAt(a, tokens, line1, col1) orelse return null;
    return signatureFor(a, module, site.chain, site.active);
}

pub const CallSite = struct {
    chain: []const []const u8,
    active: u32,
};

/// İmlecin içindeki çağrının hedef adı ve etkin parametre sırası.
/// Hedef bu dosyada yoksa `signatureAt` `null` döner; çağıran import
/// dosyasını ayrıca açabilir.
pub fn callSiteAt(a: std.mem.Allocator, tokens: []const Token, line1: u32, col1: u32) std.mem.Allocator.Error!?CallSite {
    const at = tokenIndexAt(tokens, line1, col1) orelse return null;
    const paren = enclosingParen(tokens, at) orelse return null;
    return .{
        .chain = try calleeChain(a, tokens, paren),
        .active = activeParam(tokens, paren, at),
    };
}

pub const ImportRef = struct {
    segments: []const []const u8,
    symbol: []const u8,
    local: []const u8,
    span: Span,
};

pub fn importBinding(module: ast.Module, name: []const u8) ?ImportRef {
    for (module.body) |s| {
        switch (s.kind) {
            .from_import_stmt => |fi| {
                for (fi.names) |n| {
                    const local = n.alias orelse n.name;
                    if (std.mem.eql(u8, local, name)) {
                        return .{ .segments = fi.segments, .symbol = n.name, .local = local, .span = s.span };
                    }
                }
            },
            .import_stmt => |imp| {
                const local = imp.alias orelse if (imp.segments.len > 0) imp.segments[0] else continue;
                if (std.mem.eql(u8, local, name)) {
                    return .{ .segments = imp.segments, .symbol = "", .local = local, .span = s.span };
                }
            },
            else => {},
        }
    }
    return null;
}

/// İmlecin üstündeki noktalı ad (`nox.http.get` içinde `get`). Tek parçaysa
/// düz tanımlayıcıdır.
pub fn chainAt(a: std.mem.Allocator, tokens: []const Token, line1: u32, col1: u32) std.mem.Allocator.Error!?[]const []const u8 {
    const at = tokenIndexAt(tokens, line1, col1) orelse return null;
    if (tokens[at].kind != .identifier) return null;
    var i = at;
    var rev: std.ArrayListUnmanaged([]const u8) = .empty;
    while (tokens[i].kind == .identifier) {
        try rev.append(a, tokens[i].lexeme);
        if (i == 0 or tokens[i - 1].kind != .dot or i < 2) break;
        i -= 2;
    }
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var n = rev.items.len;
    while (n > 0) {
        n -= 1;
        try out.append(a, rev.items[n]);
    }
    if (out.items.len == 0) return null;
    return out.items;
}

fn spansMatch(a: Span, b: Span) bool {
    return !a.isNone() and a.start_line == b.start_line and a.start_col == b.start_col and a.end_line == b.end_line and a.end_col == b.end_col;
}

pub fn usesOfSpan(a: std.mem.Allocator, tokens: []const Token, module: ast.Module, def: Span) std.mem.Allocator.Error![]const Span {
    var out: std.ArrayListUnmanaged(Span) = .empty;
    for (tokens) |t| {
        if (t.kind != .identifier) continue;
        const resolved = resolveAt(a, module, t.line, t.lexeme) catch continue;
        if (resolved) |r| {
            if (spansMatch(r.span, def)) try out.append(a, span_of_token(t));
        }
    }
    return out.toOwnedSlice(a);
}

fn span_of_token(t: Token) Span {
    return .{
        .start_byte = t.start_byte,
        .end_byte = t.end_byte,
        .start_line = t.line,
        .start_col = t.col,
        .end_line = t.end_line,
        .end_col = t.end_col,
    };
}

pub fn usesOfName(a: std.mem.Allocator, tokens: []const Token, name: []const u8) std.mem.Allocator.Error![]const Span {
    var out: std.ArrayListUnmanaged(Span) = .empty;
    for (tokens) |t| {
        if (t.kind == .identifier and std.mem.eql(u8, t.lexeme, name)) try out.append(a, span_of_token(t));
    }
    return out.toOwnedSlice(a);
}

/// Anlamsal belirteçler, LSP'nin göreli kodlaması: her belirteç 5 tamsayı
/// (deltaLine, deltaStart, length, tokenType, tokenModifiers). Türler:
/// 0 fonksiyon, 1 sınıf, 2 parametre, 3 değişken.
pub fn semanticTokens(a: std.mem.Allocator, tokens: []const Token, module: ast.Module) std.mem.Allocator.Error![]u32 {
    var data: std.ArrayListUnmanaged(u32) = .empty;
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    var first = true;
    for (tokens) |t| {
        if (t.kind != .identifier) continue;
        const sk = (symbolKindOfDetail(a, module, t.lexeme, t.line) catch continue) orelse continue;
        const kind: u32 = switch (sk) {
            .function, .builtin => 0,
            .class => 1,
            .parameter => 2,
            .local_var => 3,
            .keyword => continue,
        };
        const line0 = t.line - 1;
        const char0 = t.col - 1;
        const length: u32 = if (t.end_col >= t.col) t.end_col - t.col + 1 else 1;
        const dline = if (first) line0 else line0 - prev_line;
        const dchar = if (first or dline != 0) char0 else char0 - prev_char;
        first = false;
        prev_line = line0;
        prev_char = char0;
        try data.append(a, dline);
        try data.append(a, dchar);
        try data.append(a, length);
        try data.append(a, kind);
        try data.append(a, 0);
    }
    return data.toOwnedSlice(a);
}

fn symbolKindOfDetail(a: std.mem.Allocator, module: ast.Module, name: []const u8, line1: u32) std.mem.Allocator.Error!?SymbolKind {
    var scope: std.StringHashMapUnmanaged(SymbolInfo) = .empty;
    try collectScopeAt(a, module.body, line1, &scope);
    if (scope.get(name)) |s| return s.kind;
    var top: std.StringHashMapUnmanaged(SymbolInfo) = .empty;
    try collectTopLevel(a, module, &top);
    if (top.get(name)) |s| return s.kind;
    return null;
}

pub const InlayHint = struct {
    line0: u32,
    character0: u32,
    label: []const u8,
};

pub fn parameterInlays(a: std.mem.Allocator, tokens: []const Token, module: ast.Module) std.mem.Allocator.Error![]const InlayHint {
    var out: std.ArrayListUnmanaged(InlayHint) = .empty;
    for (tokens, 0..) |t, paren| {
        if (t.kind != .l_paren) continue;
        const chain = try calleeChain(a, tokens, paren);
        const sig = (try signatureFor(a, module, chain, 0)) orelse continue;
        var depth: i32 = 0;
        var arg_i: usize = 0;
        var expect_arg = true;
        var i = paren + 1;
        while (i < tokens.len) : (i += 1) {
            const tok = tokens[i];
            if (tok.kind == .newline or tok.kind == .indent or tok.kind == .dedent) continue;
            if (tok.kind == .l_paren) {
                depth += 1;
                expect_arg = false;
                continue;
            }
            if (tok.kind == .r_paren) {
                if (depth == 0) break;
                depth -= 1;
                continue;
            }
            if (depth != 0) continue;
            if (tok.kind == .comma) {
                arg_i += 1;
                expect_arg = true;
                continue;
            }
            if (!expect_arg) continue;
            expect_arg = false;
            if (arg_i >= sig.params.len) continue;
            if (tok.kind == .identifier and i + 1 < tokens.len and tokens[i + 1].kind == .assign) continue;
            const label = try std.fmt.allocPrint(a, "{s}:", .{sig.params[arg_i].name});
            try out.append(a, .{ .line0 = tok.line - 1, .character0 = tok.col - 1, .label = label });
        }
    }
    return out.toOwnedSlice(a);
}
