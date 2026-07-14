//! Nox v0.1 recursive-descent / precedence-climbing parser.
//! AST düğümleri çağıranın verdiği allocator üzerinde tahsis edilir
//! (tipik kullanım: bir ArenaAllocator — bkz. testler).

const std = @import("std");
const token_mod = @import("../lexer/token.zig");
const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    InvalidNumberLiteral,
    OutOfMemory,
};

/// `İsim[TipArgs](args)` sözdizimi yalnızca bu AYRILMIŞ, yerleşik generic
/// tipler için tanınır (bkz. `ast.GenericConstruct`in belge notu) — `Task`
/// bu listede YOK, çünkü bir `Task[T]` asla doğrudan inşa edilmez (yalnızca
/// `spawn` ile üretilir).
fn isGenericConstructName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Channel");
}

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{ .allocator = allocator, .tokens = tokens, .pos = 0 };
    }

    fn cur(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn curKind(self: *const Parser) TokenKind {
        return self.tokens[self.pos].kind;
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn check(self: *const Parser, kind: TokenKind) bool {
        return self.curKind() == kind;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!Token {
        if (self.check(kind)) return self.advance();
        return error.UnexpectedToken;
    }

    fn box(self: *Parser, e: ast.Expr) ParseError!*ast.Expr {
        const p = try self.allocator.create(ast.Expr);
        p.* = e;
        return p;
    }

    /// Bir modülü (dosyanın tamamını) ayrıştırır.
    pub fn parseModule(self: *Parser) ParseError!ast.Module {
        var stmts = std.ArrayList(ast.Stmt).empty;
        while (!self.check(.eof)) {
            try stmts.append(self.allocator, try self.parseStmt());
        }
        return .{ .body = try stmts.toOwnedSlice(self.allocator) };
    }

    fn parseBlock(self: *Parser) ParseError![]ast.Stmt {
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);
        var stmts = std.ArrayList(ast.Stmt).empty;
        while (!self.check(.dedent)) {
            try stmts.append(self.allocator, try self.parseStmt());
        }
        _ = try self.expect(.dedent);
        return stmts.toOwnedSlice(self.allocator);
    }

    /// Faz T.1: TÜM deyim ayrıştırmasının TEK dağıtım noktası — `ast.Stmt`in
    /// belge notundaki SARMALAMA (`kind` + `line`) TAM OLARAK BURADA, bir
    /// KEZ yapılır (alt-ayrıştırıcıların (`parseIf` vb.) HİÇBİRİ kendi
    /// başına bir `line` eklemez, hepsi `ast.StmtKind` döner) — bu, kaynak
    /// satırının HER deyim İÇİN doğru/tutarlı biçimde, ayrıştırıcının
    /// HERHANGİ bir alt fonksiyonuna dokunmadan yakalanmasını sağlar.
    fn parseStmt(self: *Parser) ParseError!ast.Stmt {
        const line = self.cur().line;
        const kind: ast.StmtKind = switch (self.curKind()) {
            .kw_if => try self.parseIf(),
            .kw_while => try self.parseWhile(),
            .kw_for => try self.parseFor(),
            .kw_def, .kw_async => .{ .func_def = try self.parseFuncDef() },
            .kw_extern => try self.parseExternDef(),
            .kw_class => try self.parseClassDef(),
            .kw_protocol => try self.parseProtocolDef(),
            .kw_return => try self.parseReturn(),
            .kw_raise => try self.parseRaise(),
            .kw_try => try self.parseTry(),
            .kw_with => try self.parseWith(),
            .kw_lowlevel => try self.parseLowLevel(),
            .kw_import => try self.parseImport(),
            .kw_from => try self.parseFromImport(),
            .kw_pass => blk: {
                _ = self.advance();
                _ = try self.expect(.newline);
                break :blk .pass_stmt;
            },
            else => try self.parseSimpleStmt(),
        };
        return .{ .kind = kind, .line = line };
    }

    fn parseSimpleStmt(self: *Parser) ParseError!ast.StmtKind {
        if (self.check(.identifier) and self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].kind == .colon) {
            const name = self.advance().lexeme;
            _ = try self.expect(.colon);
            const type_expr = try self.parseTypeExpr();
            _ = try self.expect(.assign);
            const value = try self.parseExpr();
            _ = try self.expect(.newline);
            return .{ .var_decl = .{ .name = name, .type_expr = type_expr, .value = value } };
        }

        const expr = try self.parseExpr();
        if (self.match(.assign)) {
            const value = try self.parseExpr();
            _ = try self.expect(.newline);
            return .{ .assign = .{ .target = expr, .value = value } };
        }
        _ = try self.expect(.newline);
        return .{ .expr_stmt = expr };
    }

    fn parseTypeExpr(self: *Parser) ParseError!ast.TypeExpr {
        if (self.check(.kw_none)) {
            _ = self.advance();
            return .{ .simple = "None" };
        }
        // Faz U.4: `(int, int) -> int` — birinci-sınıf fonksiyon/closure tip
        // ifadesi (bkz. `ast.FuncTypeExpr`in belge notu). Bir tip ifadesi
        // ŞİMDİYE KADAR HİÇ `(` İLE BAŞLAMADIĞINDAN bu YENİ dal HİÇBİR
        // ÇAKIŞMA yaratmaz.
        if (self.match(.l_paren)) {
            var params = std.ArrayList(ast.TypeExpr).empty;
            if (!self.check(.r_paren)) {
                try params.append(self.allocator, try self.parseTypeExpr());
                while (self.match(.comma)) {
                    try params.append(self.allocator, try self.parseTypeExpr());
                }
            }
            _ = try self.expect(.r_paren);
            _ = try self.expect(.arrow);
            const ret = try self.allocator.create(ast.TypeExpr);
            ret.* = try self.parseTypeExpr();
            return .{ .func_type = .{ .params = try params.toOwnedSlice(self.allocator), .return_type = ret } };
        }
        const name = (try self.expect(.identifier)).lexeme;
        if (self.match(.l_bracket)) {
            var args = std.ArrayList(ast.TypeExpr).empty;
            try args.append(self.allocator, try self.parseTypeExpr());
            while (self.match(.comma)) {
                try args.append(self.allocator, try self.parseTypeExpr());
            }
            _ = try self.expect(.r_bracket);
            return .{ .generic = .{ .name = name, .args = try args.toOwnedSlice(self.allocator) } };
        }
        return .{ .simple = name };
    }

    fn parseIf(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_if);
        const cond = try self.parseExpr();
        _ = try self.expect(.colon);
        const then_body = try self.parseBlock();

        var elifs = std.ArrayList(ast.ElifClause).empty;
        while (self.check(.kw_elif)) {
            _ = self.advance();
            const econd = try self.parseExpr();
            _ = try self.expect(.colon);
            const ebody = try self.parseBlock();
            try elifs.append(self.allocator, .{ .cond = econd, .body = ebody });
        }

        var else_body: ?[]ast.Stmt = null;
        if (self.match(.kw_else)) {
            _ = try self.expect(.colon);
            else_body = try self.parseBlock();
        }

        return .{ .if_stmt = .{
            .cond = cond,
            .then_body = then_body,
            .elif_clauses = try elifs.toOwnedSlice(self.allocator),
            .else_body = else_body,
        } };
    }

    fn parseWhile(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_while);
        const cond = try self.parseExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return .{ .while_stmt = .{ .cond = cond, .body = body } };
    }

    fn parseFor(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_for);
        const name = (try self.expect(.identifier)).lexeme;
        _ = try self.expect(.kw_in);
        const iterable = try self.parseExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return .{ .for_stmt = .{ .var_name = name, .iterable = iterable, .body = body } };
    }

    fn parseFuncDef(self: *Parser) ParseError!ast.FuncDef {
        const is_async = self.match(.kw_async);
        _ = try self.expect(.kw_def);
        const name = (try self.expect(.identifier)).lexeme;

        var type_params = std.ArrayList([]const u8).empty;
        if (self.match(.l_bracket)) {
            try type_params.append(self.allocator, (try self.expect(.identifier)).lexeme);
            while (self.match(.comma)) {
                try type_params.append(self.allocator, (try self.expect(.identifier)).lexeme);
            }
            _ = try self.expect(.r_bracket);
        }

        _ = try self.expect(.l_paren);

        var params = std.ArrayList(ast.Param).empty;
        if (!self.check(.r_paren)) {
            try params.append(self.allocator, try self.parseParam());
            while (self.match(.comma)) {
                try params.append(self.allocator, try self.parseParam());
            }
        }
        _ = try self.expect(.r_paren);
        _ = try self.expect(.arrow);
        const return_type = try self.parseTypeExpr();
        _ = try self.expect(.colon);
        const body = try self.parseBlock();

        return .{
            .name = name,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
            .is_async = is_async,
        };
    }

    /// `extern def name(params) -> ReturnType from "lib"` — gövde/blok YOK
    /// (bkz. `ast.ExternDef`in belge notu); tek satırlık bir bildirim.
    fn parseExternDef(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_extern);
        _ = try self.expect(.kw_def);
        const name = (try self.expect(.identifier)).lexeme;
        _ = try self.expect(.l_paren);

        var params = std.ArrayList(ast.Param).empty;
        if (!self.check(.r_paren)) {
            try params.append(self.allocator, try self.parseParam());
            while (self.match(.comma)) {
                try params.append(self.allocator, try self.parseParam());
            }
        }
        _ = try self.expect(.r_paren);
        _ = try self.expect(.arrow);
        const return_type = try self.parseTypeExpr();
        _ = try self.expect(.kw_from);
        const from_lib_tok = try self.expect(.string_lit);
        const from_lib = try self.decodeString(from_lib_tok.lexeme);
        // `with_rt` — bkz. `ast.ExternDef.needs_rt`in belge notu (stdlib
        // fazı §D.1, Keşif 3). Opsiyonel, `from "lib"`den SONRA gelir.
        const needs_rt = self.match(.kw_with_rt);
        _ = try self.expect(.newline);

        return .{ .extern_def = .{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .from_lib = from_lib,
            .needs_rt = needs_rt,
        } };
    }

    fn parseParam(self: *Parser) ParseError!ast.Param {
        const name = (try self.expect(.identifier)).lexeme;
        _ = try self.expect(.colon);
        const type_expr = try self.parseTypeExpr();
        return .{ .name = name, .type_expr = type_expr };
    }

    fn parseClassDef(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_class);
        const name = (try self.expect(.identifier)).lexeme;
        _ = try self.expect(.colon);
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);

        var methods = std.ArrayList(ast.FuncDef).empty;
        while (!self.check(.dedent)) {
            try methods.append(self.allocator, try self.parseFuncDef());
        }
        _ = try self.expect(.dedent);

        return .{ .class_def = .{ .name = name, .methods = try methods.toOwnedSlice(self.allocator) } };
    }

    fn parseProtocolDef(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_protocol);
        const name = (try self.expect(.identifier)).lexeme;
        _ = try self.expect(.colon);
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);

        var methods = std.ArrayList(ast.FuncDef).empty;
        while (!self.check(.dedent)) {
            try methods.append(self.allocator, try self.parseFuncDef());
        }
        _ = try self.expect(.dedent);

        return .{ .protocol_def = .{ .name = name, .methods = try methods.toOwnedSlice(self.allocator) } };
    }

    fn parseReturn(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_return);
        if (self.match(.newline)) {
            return .{ .return_stmt = null };
        }
        const value = try self.parseExpr();
        _ = try self.expect(.newline);
        return .{ .return_stmt = value };
    }

    fn parseRaise(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_raise);
        const value = try self.parseExpr();
        _ = try self.expect(.newline);
        return .{ .raise_stmt = value };
    }

    fn parseTry(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_try);
        _ = try self.expect(.colon);
        const try_body = try self.parseBlock();

        var except_clauses = std.ArrayList(ast.ExceptClause).empty;
        while (self.check(.kw_except)) {
            _ = self.advance();
            const class_name = (try self.expect(.identifier)).lexeme;
            var bind_name: ?[]const u8 = null;
            if (self.match(.kw_as)) {
                bind_name = (try self.expect(.identifier)).lexeme;
            }
            _ = try self.expect(.colon);
            const body = try self.parseBlock();
            try except_clauses.append(self.allocator, .{ .class_name = class_name, .bind_name = bind_name, .body = body });
        }

        var finally_body: ?[]ast.Stmt = null;
        if (self.match(.kw_finally)) {
            _ = try self.expect(.colon);
            finally_body = try self.parseBlock();
        }

        return .{ .try_stmt = .{
            .try_body = try_body,
            .except_clauses = try except_clauses.toOwnedSlice(self.allocator),
            .finally_body = finally_body,
        } };
    }

    /// `with EXPR as NAME:` / `with EXPR:` — Faz U.5 (bkz. `ast.WithStmt`in
    /// belge notu). `as NAME` isteğe bağlıdır (bağlama olmadan yalnızca
    /// `__enter__`/`__exit__` yan etkileri İÇİN kullanılabilir).
    fn parseWith(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_with);
        const ctx_expr = try self.parseExpr();
        var binding: ?[]const u8 = null;
        if (self.match(.kw_as)) {
            binding = (try self.expect(.identifier)).lexeme;
        }
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return .{ .with_stmt = .{ .ctx_expr = ctx_expr, .binding = binding, .body = body } };
    }

    fn parseLowLevel(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_lowlevel);
        _ = try self.expect(.colon);
        const body = try self.parseBlock();
        return .{ .lowlevel_stmt = .{ .body = body } };
    }

    /// `import nox.http` — bir ya da daha fazla nokta-ayrılmış tanımlayıcı
    /// (bkz. `ast.ImportStmt`in belge notu). Faz U.3: isteğe bağlı `as
    /// <isim>` sonek — VERİLİRSE `<isim>` TAM yolun (`nox.http`) yerel
    /// takma adı olur.
    fn parseImport(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_import);
        var segments = std.ArrayList([]const u8).empty;
        try segments.append(self.allocator, (try self.expect(.identifier)).lexeme);
        while (self.match(.dot)) {
            try segments.append(self.allocator, (try self.expect(.identifier)).lexeme);
        }
        var alias: ?[]const u8 = null;
        if (self.match(.kw_as)) {
            alias = (try self.expect(.identifier)).lexeme;
        }
        _ = try self.expect(.newline);
        return .{ .import_stmt = .{ .segments = try segments.toOwnedSlice(self.allocator), .alias = alias } };
    }

    /// `from nox.http import get` / `from nox.http import get as g, post` —
    /// (bkz. `ast.FromImportStmt`in belge notu). Virgülle ayrılmış bir ya da
    /// daha fazla üye, HER biri isteğe bağlı KENDİ `as <isim>` sonekiyle.
    fn parseFromImport(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_from);
        var segments = std.ArrayList([]const u8).empty;
        try segments.append(self.allocator, (try self.expect(.identifier)).lexeme);
        while (self.match(.dot)) {
            try segments.append(self.allocator, (try self.expect(.identifier)).lexeme);
        }
        _ = try self.expect(.kw_import);
        var names = std.ArrayList(ast.FromImportName).empty;
        while (true) {
            const name = (try self.expect(.identifier)).lexeme;
            var name_alias: ?[]const u8 = null;
            if (self.match(.kw_as)) {
                name_alias = (try self.expect(.identifier)).lexeme;
            }
            try names.append(self.allocator, .{ .name = name, .alias = name_alias });
            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.newline);
        return .{ .from_import_stmt = .{
            .segments = try segments.toOwnedSlice(self.allocator),
            .names = try names.toOwnedSlice(self.allocator),
        } };
    }

    // ---- İfadeler: öncelik tırmanışı (precedence climbing) ----

    fn parseExpr(self: *Parser) ParseError!ast.Expr {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseAnd();
        while (self.match(.kw_or)) {
            const right = try self.parseAnd();
            const old_left = left;
            left = .{ .binary = .{ .op = .or_, .left = try self.box(old_left), .right = try self.box(right) } };
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseNot();
        while (self.match(.kw_and)) {
            const right = try self.parseNot();
            const old_left = left;
            left = .{ .binary = .{ .op = .and_, .left = try self.box(old_left), .right = try self.box(right) } };
        }
        return left;
    }

    fn parseNot(self: *Parser) ParseError!ast.Expr {
        if (self.match(.kw_not)) {
            const operand = try self.parseNot();
            return .{ .unary = .{ .op = .not_, .operand = try self.box(operand) } };
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseAddSub();
        while (true) {
            const op: ast.BinaryOp = switch (self.curKind()) {
                .eq_eq => .eq,
                .not_eq => .ne,
                .lt => .lt,
                .lt_eq => .le,
                .gt => .gt,
                .gt_eq => .ge,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseAddSub();
            const old_left = left;
            left = .{ .binary = .{ .op = op, .left = try self.box(old_left), .right = try self.box(right) } };
        }
        return left;
    }

    fn parseAddSub(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseMulDiv();
        while (true) {
            const op: ast.BinaryOp = switch (self.curKind()) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseMulDiv();
            const old_left = left;
            left = .{ .binary = .{ .op = op, .left = try self.box(old_left), .right = try self.box(right) } };
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) ParseError!ast.Expr {
        var left = try self.parseUnary();
        while (true) {
            const op: ast.BinaryOp = switch (self.curKind()) {
                .star => .mul,
                .slash => .div,
                .slash_slash => .floordiv,
                .percent => .mod,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseUnary();
            const old_left = left;
            left = .{ .binary = .{ .op = op, .left = try self.box(old_left), .right = try self.box(right) } };
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!ast.Expr {
        if (self.match(.minus)) {
            const operand = try self.parseUnary();
            return .{ .unary = .{ .op = .neg, .operand = try self.box(operand) } };
        }
        if (self.match(.kw_await)) {
            const operand = try self.parseUnary();
            return .{ .await_expr = try self.box(operand) };
        }
        if (self.match(.kw_spawn)) {
            const operand = try self.parseUnary();
            return .{ .spawn_expr = try self.box(operand) };
        }
        return self.parsePower();
    }

    fn parsePower(self: *Parser) ParseError!ast.Expr {
        const base = try self.parsePostfix();
        if (self.match(.star_star)) {
            const exponent = try self.parseUnary();
            return .{ .binary = .{ .op = .pow, .left = try self.box(base), .right = try self.box(exponent) } };
        }
        return base;
    }

    fn parsePostfix(self: *Parser) ParseError!ast.Expr {
        var expr = try self.parsePrimary();
        while (true) {
            if (self.match(.dot)) {
                const attr = (try self.expect(.identifier)).lexeme;
                const old_expr = expr;
                expr = .{ .attribute = .{ .obj = try self.box(old_expr), .attr = attr } };
            } else if (self.match(.l_paren)) {
                var args = std.ArrayList(ast.Expr).empty;
                if (!self.check(.r_paren)) {
                    try args.append(self.allocator, try self.parseExpr());
                    while (self.match(.comma)) {
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = try self.expect(.r_paren);
                const old_expr = expr;
                expr = .{ .call = .{ .callee = try self.box(old_expr), .args = try args.toOwnedSlice(self.allocator) } };
            } else if (self.check(.l_bracket) and expr == .identifier and isGenericConstructName(expr.identifier)) {
                // `Channel[T](capacity)` — dilde başka HİÇBİR yerde olmayan,
                // AÇIK tip argümanlı bir kurucu çağrısı (bkz. `ast.
                // GenericConstruct`in belge notu). Yalnızca ayrılmış
                // `Channel` adı için tanınır — normal indekslemeyle
                // (`xs[i]`) KARIŞMAZ çünkü `xs` bu ada eşit olamaz.
                // Not: isim ÖNCE bir yerel değişkene alınır — `expr`e
                // (bir tagged union) atama yaparken AYNI ifadenin sağ
                // tarafında `expr`in ESKİ etiketini okumak güvenli DEĞİLDİR
                // (bkz. bulunan gerçek çökme: "access of union field
                // 'identifier' while field 'generic_construct' is active").
                const construct_name = expr.identifier;
                _ = self.advance();
                var type_args = std.ArrayList(ast.TypeExpr).empty;
                try type_args.append(self.allocator, try self.parseTypeExpr());
                while (self.match(.comma)) {
                    try type_args.append(self.allocator, try self.parseTypeExpr());
                }
                _ = try self.expect(.r_bracket);
                _ = try self.expect(.l_paren);
                var args = std.ArrayList(ast.Expr).empty;
                if (!self.check(.r_paren)) {
                    try args.append(self.allocator, try self.parseExpr());
                    while (self.match(.comma)) {
                        try args.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = try self.expect(.r_paren);
                expr = .{ .generic_construct = .{
                    .name = construct_name,
                    .type_args = try type_args.toOwnedSlice(self.allocator),
                    .args = try args.toOwnedSlice(self.allocator),
                } };
            } else if (self.match(.l_bracket)) {
                const idx = try self.parseExpr();
                _ = try self.expect(.r_bracket);
                const old_expr = expr;
                expr = .{ .index = .{ .obj = try self.box(old_expr), .index = try self.box(idx) } };
            } else break;
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!ast.Expr {
        switch (self.curKind()) {
            .int_lit => {
                const t = self.advance();
                const v = std.fmt.parseInt(i64, t.lexeme, 10) catch return error.InvalidNumberLiteral;
                return .{ .int_lit = v };
            },
            .float_lit => {
                const t = self.advance();
                const v = std.fmt.parseFloat(f64, t.lexeme) catch return error.InvalidNumberLiteral;
                return .{ .float_lit = v };
            },
            .kw_true => {
                _ = self.advance();
                return .{ .bool_lit = true };
            },
            .kw_false => {
                _ = self.advance();
                return .{ .bool_lit = false };
            },
            .kw_none => {
                _ = self.advance();
                return .none_lit;
            },
            .string_lit => {
                const t = self.advance();
                return .{ .string_lit = try self.decodeString(t.lexeme) };
            },
            .identifier => {
                const t = self.advance();
                return .{ .identifier = t.lexeme };
            },
            .l_paren => {
                _ = self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.r_paren);
                return inner;
            },
            .l_bracket => {
                _ = self.advance();
                var elems = std.ArrayList(ast.Expr).empty;
                if (!self.check(.r_bracket)) {
                    try elems.append(self.allocator, try self.parseExpr());
                    while (self.match(.comma)) {
                        try elems.append(self.allocator, try self.parseExpr());
                    }
                }
                _ = try self.expect(.r_bracket);
                return .{ .list_lit = try elems.toOwnedSlice(self.allocator) };
            },
            .l_brace => {
                _ = self.advance();
                var pairs = std.ArrayList(ast.DictPair).empty;
                // Boş `{}` YOK (bkz. `ast.zig`'in `dict_lit` belge notu) —
                // parser burada zorlamaz (checker reddeder, `[]`la AYNI
                // desen), en az bir çift beklenir.
                const first_key = try self.parseExpr();
                _ = try self.expect(.colon);
                const first_value = try self.parseExpr();
                try pairs.append(self.allocator, .{ .key = first_key, .value = first_value });
                while (self.match(.comma)) {
                    const key = try self.parseExpr();
                    _ = try self.expect(.colon);
                    const value = try self.parseExpr();
                    try pairs.append(self.allocator, .{ .key = key, .value = value });
                }
                _ = try self.expect(.r_brace);
                return .{ .dict_lit = try pairs.toOwnedSlice(self.allocator) };
            },
            else => return error.UnexpectedToken,
        }
    }

    /// Tırnakları kaldırır ve temel kaçış dizilerini (\n \t \\ \' \") çözer.
    fn decodeString(self: *Parser, lexeme: []const u8) ParseError![]const u8 {
        const inner = lexeme[1 .. lexeme.len - 1];
        var out = std.ArrayList(u8).empty;
        var i: usize = 0;
        while (i < inner.len) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                const esc = inner[i + 1];
                const decoded: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '\'' => '\'',
                    '"' => '"',
                    else => esc,
                };
                try out.append(self.allocator, decoded);
                i += 2;
            } else {
                try out.append(self.allocator, inner[i]);
                i += 1;
            }
        }
        return out.toOwnedSlice(self.allocator);
    }
};

/// `.nox` kaynağından zaten üretilmiş token dizisini bir modüle ayrıştırır.
/// Sahiplik: dönen AST tamamen `allocator` üzerinde yaşar (öneri: bir arena).
pub fn parseModule(allocator: std.mem.Allocator, tokens: []const Token) ParseError!ast.Module {
    var parser = Parser.init(allocator, tokens);
    return parser.parseModule();
}

// ---- Testler ----

const lexer_mod = @import("../lexer/lexer.zig");

fn parseSource(allocator: std.mem.Allocator, source: []const u8) !ast.Module {
    const tokens = try lexer_mod.tokenize(allocator, source);
    return parseModule(allocator, tokens);
}

test "değişken tanımı ve aritmetik ifade ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseSource(arena.allocator(), "x: int = 1 + 2 * 3\n");
    try std.testing.expectEqual(@as(usize, 1), module.body.len);
    const decl = module.body[0].kind.var_decl;
    try std.testing.expectEqualStrings("x", decl.name);
    try std.testing.expectEqualStrings("int", decl.type_expr.simple);
    try std.testing.expectEqual(ast.BinaryOp.add, decl.value.binary.op);
}

test "fonksiyon tanımı parametre ve dönüş tipiyle ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseSource(arena.allocator(),
        \\def add(a: int, b: int) -> int:
        \\    return a + b
        \\
    );
    try std.testing.expectEqual(@as(usize, 1), module.body.len);
    const fd = module.body[0].kind.func_def;
    try std.testing.expectEqualStrings("add", fd.name);
    try std.testing.expectEqual(@as(usize, 2), fd.params.len);
    try std.testing.expectEqualStrings("int", fd.return_type.simple);
}

test "if/elif/else zinciri doğru şekilde iç içe ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseSource(arena.allocator(),
        \\if x < 0:
        \\    y = 1
        \\elif x == 0:
        \\    y = 2
        \\else:
        \\    y = 3
        \\
    );
    const ifs = module.body[0].kind.if_stmt;
    try std.testing.expectEqual(@as(usize, 1), ifs.elif_clauses.len);
    try std.testing.expect(ifs.else_body != null);
}

test "list[int] tipi ve liste literali ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parseSource(arena.allocator(), "xs: list[int] = [1, 2, 3]\n");
    const decl = module.body[0].kind.var_decl;
    try std.testing.expectEqualStrings("list", decl.type_expr.generic.name);
    try std.testing.expectEqual(@as(usize, 3), decl.value.list_lit.len);
}
