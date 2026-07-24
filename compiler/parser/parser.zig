//! Nox recursive-descent / precedence-climbing parser.
//! AST düğümleri çağıranın verdiği allocator üzerinde tahsis edilir
//! (tipik kullanım: bir ArenaAllocator — bkz. testler).

const std = @import("std");
const token_mod = @import("../lexer/token.zig");
const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;
const ast = @import("ast.zig");
const span_mod = @import("../span.zig");
const Span = span_mod.Span;

/// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
/// yapılandırılmış tanılamalar"): `ParseError` kümesinin KENDİSİ (bkz.
/// AŞAĞIDAKİ, mevcut `expectError(error.UnexpectedToken, ...)` gibi
/// testlerin DEĞİŞMEDEN geçmesi İçin) DEĞİŞTİRİLMEDEN, `Parser`ın KENDİSİNE
/// EK bir `last_diagnostic` alanı — hatanın OLUŞTUĞU ANDAKİ `expected`/
/// `found`/`span` bilgisini TUTAR, çağıran (LSP) hata YAYILDIKTAN SONRA
/// bunu okuyabilir. `error.OutOfMemory` sitelerinde HİÇ DOLDURULMAZ
/// (`checker.recordDiagnostic`nin AYNI "OOM bir tanılama DEĞİLDİR"
/// istisnasıyla TUTARLI).
pub const ParserDiagnostic = struct {
    expected: ?TokenKind = null,
    found: TokenKind,
    span: Span,
};

pub const ParseError = error{
    UnexpectedToken,
    InvalidNumberLiteral,
    OutOfMemory,
    RecursionLimitExceeded,
};


pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    pos: usize,
    /// Güvenlik bulgusu H-3 (bkz. güvenlik raporu) — canlı özyineleme
    /// derinliği (bkz. `enterRecursion`in belge notu). `init`in anonim
    /// struct literali BUNU BELİRTMEZ, alan varsayılanı (`= 0`) OTOMATİK
    /// doldurur.
    depth: usize = 0,
    /// Bkz. `ParserDiagnostic`in belge notu.
    last_diagnostic: ?ParserDiagnostic = null,
    /// Bkz. `ast.Module.expr_spans`nin belge notu — `parseModule` SONUNDA
    /// döndürülen `Module`a TAŞINIR.
    expr_spans: std.AutoHashMapUnmanaged(usize, Span) = .empty,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{ .allocator = allocator, .tokens = tokens, .pos = 0 };
    }

    /// Güvenlik bulgusu H-3 (bkz. güvenlik raporu) — DÜZELTİLDİ: özyinelemeli-
    /// iniş (recursive-descent) ayrıştırıcının HİÇBİR derinlik sınırı YOKTU,
    /// bu YÜZDEN aşırı iç içe bir ifade (ör. 50.000 iç içe parantez, KENDİM
    /// doğruladım) `noxc`nin KENDİSİNİ (derlediği programı DEĞİL) yığın
    /// taşmasıyla ÇÖKERTİYORDU — Nox kaynağı güvenilmeyen bir yerden
    /// derleniyorsa (çevrimiçi oyun alanı, CI) trivial bir DoS vektörü.
    /// `parseExpr`/`parseNot`/`parseUnary`nin HER İKİSİ de KENDİ (ya da
    /// birbirlerinin) İÇİNE özyineleyen AYRI giriş noktaları OLDUĞUNDAN
    /// (`(...)`, `not not ...`, `- - ...`, `await await ...`, `spawn spawn
    /// ...`), TEK bir PAYLAŞILAN sayaç bunların ÜÇÜNÜN de GİRİŞİNDE
    /// çağrılır — sayaç yalnızca CANLI (şu an yığında olan) derinliği
    /// ölçer, SIRALI (kardeş) çağrılar arasında SIFIRLANIR (`defer` İLE).
    /// `MAX_EXPR_DEPTH` (500), GERÇEKÇİ HERHANGİ bir Nox programının asla
    /// yaklaşmayacağı ama macOS'un varsayılan 8MB yığınında GÜVENLE BOL
    /// PAY bırakan bir sınırdır.
    const MAX_EXPR_DEPTH: usize = 500;

    fn enterRecursion(self: *Parser) ParseError!void {
        self.depth += 1;
        if (self.depth > MAX_EXPR_DEPTH) {
            self.last_diagnostic = .{ .found = self.curKind(), .span = span_mod.fromToken(self.cur()) };
            return error.RecursionLimitExceeded;
        }
    }

    fn exitRecursion(self: *Parser) void {
        self.depth -= 1;
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
        self.last_diagnostic = .{ .expected = kind, .found = self.curKind(), .span = span_mod.fromToken(self.cur()) };
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
        return .{ .body = try stmts.toOwnedSlice(self.allocator), .expr_spans = self.expr_spans };
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
        const start_tok = self.cur();
        const kind: ast.StmtKind = switch (self.curKind()) {
            .kw_if => try self.parseIf(),
            .kw_while => try self.parseWhile(),
            .kw_for => try self.parseFor(),
            .kw_def, .kw_async => .{ .func_def = try self.parseFuncDef(null) },
            .kw_extern => try self.parseExternDef(),
            .kw_class => try self.parseClassDef(),
            .kw_protocol => try self.parseProtocolDef(),
            .kw_return => try self.parseReturn(),
            .kw_raise => try self.parseRaise(),
            .kw_try => try self.parseTry(),
            .kw_with => try self.parseWith(),
            .kw_defer => try self.parseDefer(),
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
        // Gerçek span sistemi: bu deyimin TÜKETTİĞİ SON token, `self.pos - 1`
        // (dispatch EN AZ bir token TÜKETİR, bu YÜZDEN `self.pos > 0` HER
        // ZAMAN doğrudur burada) — bileşik deyimlerde bu, İÇ İÇE gövdenin
        // SON `dedent`ine kadar UZANIR (bkz. `ast.Stmt.span`nin belge notu).
        const end_tok = self.tokens[self.pos - 1];
        return .{ .kind = kind, .line = line, .span = span_mod.fromTokens(start_tok, end_tok) };
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
        // Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
        // `target OP= value` → `target = target OP value` parse-zamanı
        // desugarı. YALNIZCA `.identifier` hedefler İçin GÜVENLİDİR —
        // `.attribute`/`.index` hedeflerde `target`i (receiver'ı) İKİ KEZ
        // ÇOĞALTMAK, `genAssign`in KENDİ "receiver TEK SEFER değerlendirilir"
        // değişmezini (bkz. `stmt.zig`in `.attribute`/`.index` dallarının
        // belge notları) BOZAR — yan-etkili bir receiver İçin (`get_list()[i]
        // += 1`) GERÇEK bir çiftleme hatası olurdu. v1 bilinçli kapsamı:
        // yalnızca değişken hedefler.
        const aug_op: ?ast.BinaryOp = switch (self.curKind()) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .slash_slash_eq => .floordiv,
            .percent_eq => .mod,
            .star_star_eq => .pow,
            else => null,
        };
        if (aug_op) |op| {
            if (expr != .identifier) {
                self.last_diagnostic = .{ .found = self.curKind(), .span = span_mod.fromToken(self.cur()) };
                return error.UnexpectedToken;
            }
            _ = self.advance();
            const value = try self.parseExpr();
            _ = try self.expect(.newline);
            const left_copy = try self.allocator.create(ast.Expr);
            left_copy.* = expr; // `.identifier` bir dilimdir, sığ kopya GÜVENLİDİR
            const right = try self.allocator.create(ast.Expr);
            right.* = value;
            return .{ .assign = .{ .target = expr, .value = .{ .binary = .{ .op = op, .left = left_copy, .right = right } } } };
        }
        _ = try self.expect(.newline);
        return .{ .expr_stmt = expr };
    }

    fn parseTypeExpr(self: *Parser) ParseError!ast.TypeExpr {
        const base = try self.parseBaseTypeExpr();
        // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `T | None`.
        // Yalnızca TEK bir `| None` soneki kabul edilir (döngü YOK) —
        // `T | None | None` bu yüzden bir sonraki token'ın `pipe` OLMAMASI
        // beklendiğinden parse hatası verir (`parseParam`/`parseTypeExpr`in
        // ÇAĞIRANI `newline`/`,`/`)` bekler, `pipe` DEĞİL).
        if (self.match(.pipe)) {
            _ = try self.expect(.kw_none);
            const boxed = try self.allocator.create(ast.TypeExpr);
            boxed.* = base;
            return .{ .optional = boxed };
        }
        return base;
    }

    fn parseBaseTypeExpr(self: *Parser) ParseError!ast.TypeExpr {
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

    /// `enclosing_name`: `parseClassDef`/`parseProtocolDef`in KENDİ adını
    /// geçirdiği (üst-düzey/iç-içe `def`ler İÇİN `null` — bkz. `parseStmt`in
    /// `.kw_def`/`.kw_async` dalı) bağlam — YALNIZCA İLK parametrenin çıplak
    /// `self` OLUP OLAMAYACAĞINI belirlemek İçin kullanılır (bkz.
    /// `parseFirstParam`, Faz FF.4, nox-teknik-spesifikasyon.md §3.63).
    fn parseFuncDef(self: *Parser, enclosing_name: ?[]const u8) ParseError!ast.FuncDef {
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
            try params.append(self.allocator, try self.parseFirstParam(enclosing_name));
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

    /// Faz FF.4 (bkz. nox-teknik-spesifikasyon.md §3.63): bir metodun İLK
    /// parametresi İÇİN — `enclosing_name` MEVCUTSA (bir sınıf/protokol
    /// gövdesi İÇİNDEYİZ) VE geçerli token TAM OLARAK `self` lexeme'li bir
    /// `.identifier` İSE VE bir SONRAKİ token `.colon` DEĞİLSE, `self:
    /// <Tip>` YAZMAK YERİNE çıplak `self` KABUL EDİLİR — tipi kapsayan
    /// sınıf/protokol adı olarak (`self: <enclosing_name>` AÇIKÇA
    /// YAZILMIŞ GİBİ) DOĞRUDAN sentezlenir. BİLEREK DAR: `self` DIŞINDA
    /// bir isimle çıplak İLK parametreye İZİN VERİLMEZ (ör. `def foo(this):`
    /// hâlâ bir parse hatası verir, checker'ın "self almalı" mesajına
    /// DÜŞMEZ) — gramerin dar/öngörülebilir kalması BİLİNÇLİ bir tercihtir.
    /// Her İKİ koşul da SAĞLANMAZSA (üst-düzey/iç-içe `def`, ya da AÇIKÇA
    /// tiplenmiş `self: X`, ya da `self` DIŞINDA bir isim) mevcut
    /// `parseParam()`e (kolon + tip ZORUNLU) DÜŞÜLÜR — DEĞİŞMEYEN yol.
    fn parseFirstParam(self: *Parser, enclosing_name: ?[]const u8) ParseError!ast.Param {
        if (enclosing_name) |en| {
            if (self.check(.identifier) and std.mem.eql(u8, self.cur().lexeme, "self") and self.tokens[self.pos + 1].kind != .colon) {
                _ = self.advance();
                return .{ .name = "self", .type_expr = .{ .simple = en }, .self_inferred = true };
            }
        }
        return self.parseParam();
    }

    fn parseClassDef(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_class);
        const name = (try self.expect(.identifier)).lexeme;

        // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı):
        // `parseFuncDef`in `[T, U]` ayrıştırmasıyla BİREBİR AYNI desen —
        // yalnızca isimler toplanır, `T`nin KENDİSİ `parseTypeExpr`de
        // (alan/metod tip ifadelerinde) sıradan bir `.simple` tanımlayıcı
        // olarak ayrıştırılmaya DEVAM eder; niteliği (bir sınıf adı mı,
        // bir tip parametresi mi) checker'ın işidir (bkz. `checker.zig`nin
        // `instantiateGenericClass`ı).
        var type_params = std.ArrayList([]const u8).empty;
        if (self.match(.l_bracket)) {
            try type_params.append(self.allocator, (try self.expect(.identifier)).lexeme);
            while (self.match(.comma)) {
                try type_params.append(self.allocator, (try self.expect(.identifier)).lexeme);
            }
            _ = try self.expect(.r_bracket);
        }

        _ = try self.expect(.colon);
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);

        var methods = std.ArrayList(ast.FuncDef).empty;
        var fields = std.ArrayList(ast.FieldDecl).empty;
        // Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): sınıf gövdesi
        // ARTIK deyim-BAŞINA dispatch eder — `parseSimpleStmt`in AYNI
        // ileriye-bakma deseni (`.identifier` + bir SONRAKİ token `.colon`)
        // bir alan bildirimini (initializer YOK, `parseSimpleStmt`nin
        // `var_decl`ından FARKLI olarak) TANIR; AKSİ HALDE mevcut
        // `parseFuncDef(name)` yoluna (metodlar) DÜŞÜLÜR. Bildirimler/
        // metodlar HERHANGİ bir SIRADA karışabilir (Python'da OLDUĞU GİBİ).
        while (!self.check(.dedent)) {
            if (self.check(.identifier) and self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].kind == .colon) {
                try fields.append(self.allocator, try self.parseClassFieldDecl());
            } else {
                try methods.append(self.allocator, try self.parseFuncDef(name));
            }
        }
        _ = try self.expect(.dedent);

        return .{ .class_def = .{
            .name = name,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .fields = try fields.toOwnedSlice(self.allocator),
        } };
    }

    /// Faz FF.5: bir sınıf gövdesinde çıplak `<ad>: <tip>` — `parseSimpleStmt`
    /// İLE AYNI ileriye-bakma deseninden ÇAĞRILIR (bkz. `parseClassDef`),
    /// ama `parseSimpleStmt`nin AKSİNE `=`/initializer BEKLEMEZ (bkz.
    /// `ast.FieldDecl`nin belge notu — atama HÂLÂ `__init__`de yapılır).
    fn parseClassFieldDecl(self: *Parser) ParseError!ast.FieldDecl {
        const line = self.cur().line;
        const name = self.advance().lexeme;
        _ = try self.expect(.colon);
        const type_expr = try self.parseTypeExpr();
        _ = try self.expect(.newline);
        return .{ .name = name, .type_expr = type_expr, .line = line };
    }

    fn parseProtocolDef(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_protocol);
        const name = (try self.expect(.identifier)).lexeme;
        _ = try self.expect(.colon);
        _ = try self.expect(.newline);
        _ = try self.expect(.indent);

        var methods = std.ArrayList(ast.FuncDef).empty;
        while (!self.check(.dedent)) {
            try methods.append(self.allocator, try self.parseFuncDef(name));
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

    /// `defer CALL` — Go'nun AYNI sözdizimsel KISITI: `CALL` bir fonksiyon/
    /// metod/closure-değişkeni ÇAĞRISI OLMAK ZORUNDADIR (rastgele bir ifade
    /// DEĞİL — ör. `defer x + 1` GRAMER SEVİYESİNDE reddedilir). Bkz.
    /// `ast.DeferStmt`in belge notu.
    fn parseDefer(self: *Parser) ParseError!ast.StmtKind {
        _ = try self.expect(.kw_defer);
        const expr = try self.parseExpr();
        if (expr != .call) {
            self.last_diagnostic = .{ .found = self.curKind(), .span = span_mod.fromToken(self.cur()) };
            return error.UnexpectedToken;
        }
        _ = try self.expect(.newline);
        return .{ .defer_stmt = .{ .call = expr.call } };
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
        try self.enterRecursion();
        defer self.exitRecursion();
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
            try self.enterRecursion();
            defer self.exitRecursion();
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
            try self.enterRecursion();
            defer self.exitRecursion();
            const operand = try self.parseUnary();
            return .{ .unary = .{ .op = .neg, .operand = try self.box(operand) } };
        }
        if (self.match(.kw_await)) {
            try self.enterRecursion();
            defer self.exitRecursion();
            const operand = try self.parseUnary();
            return .{ .await_expr = try self.box(operand) };
        }
        if (self.match(.kw_spawn)) {
            try self.enterRecursion();
            defer self.exitRecursion();
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

    /// Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `İsim
    /// [TipArgs](args)`in AÇIK tip argümanlı bir kurucu çağrısı OLARAK mı,
    /// YOKSA sıradan bir indeksleme (`xs[i]`) OLARAK mı ayrıştırılacağını
    /// belirleyen GERİYE-İZLEMELİ (backtracking) yardımcı. `[` HENÜZ
    /// tüketilmemiş OLMALIDIR (bu fonksiyon ONU da tüketir) — BAŞARISIZLIK
    /// (`null` dönüşü) durumunda `self.pos`, `[`DEN ÖNCEKİ konuma GERİ
    /// ALINIR (çağıran `[`i sanki HİÇ denenmemiş gibi YENİDEN ayrıştırabilir).
    ///
    /// **Ayrım kuralı:** parantez İÇİNDE bir VİRGÜL görülürse (2+ tip
    /// argümanı, ör. `Pair[int, str](...)`) bu ASLA sıradan bir indeksleme
    /// OLAMAZ (`ast.Index` TEK bir ifade alır) — bu noktadan SONRA bir
    /// ayrıştırma hatası GERİ ALINMAZ, GERÇEK bir sözdizimi hatası olarak
    /// YAYILIR. TEK bir parantez-içi öğe İÇİN: `parseTypeExpr` BAŞARISIZ
    /// olursa (`xs[i+1]`, `xs["k"]`, `xs[f()]` gibi GEÇERLİ bir `TypeExpr`
    /// OLMAYAN durumlar — YALNIZCA `error.UnexpectedToken`/
    /// `error.InvalidNumberLiteral` GERİ ALINABİLİR türdendir,
    /// `error.OutOfMemory`/`error.RecursionLimitExceeded` HER ZAMAN
    /// YAYILIR) YA DA `]`DEN SONRA `(` GELMEZSE (`xs[i]` — sıradan bir
    /// tanımlayıcı indeksi) GERİ ALINIR.
    ///
    /// **Bilinçli, KALICI bir belirsizlik:** `name[i](y)` (TEK bir çıplak
    /// tanımlayıcı + HEMEN ARDINDAN bir çağrı, ör. bir closure listesini
    /// indeksleyip SONUCU çağırmak: `funcs[i](y)`) HER ZAMAN generic-kurucu
    /// olarak YORUMLANIR — `name`in GERÇEKTEN bir generic sınıf/yerleşik
    /// OLUP OLMADIĞINI parser BİLEMEZ (sembol tablosu YOK), bu YÜZDEN
    /// checker'a BIRAKILIR (`checkGenericConstruct`nin "bilinmeyen generic
    /// kurucu" dalı ÇÖZER). Bu KALICI bir dilbilgisi ÖNCELİĞİDİR, bir
    /// UYGULAMA detayı DEĞİL — bu tam kalıbın (`tests/`, `stdlib/`,
    /// `examples/`) hiçbirinde BULUNMADIĞI doğrulanmıştır.
    fn tryParseGenericConstructTail(self: *Parser, construct_name: []const u8) ParseError!?ast.Expr {
        const checkpoint = self.pos;
        _ = try self.expect(.l_bracket);

        var type_args = std.ArrayList(ast.TypeExpr).empty;
        const first = self.parseTypeExpr() catch |e| switch (e) {
            error.UnexpectedToken, error.InvalidNumberLiteral => {
                self.pos = checkpoint;
                return null;
            },
            else => return e,
        };
        try type_args.append(self.allocator, first);

        var committed = false;
        while (self.match(.comma)) {
            committed = true;
            try type_args.append(self.allocator, try self.parseTypeExpr());
        }

        if (!self.check(.r_bracket)) {
            if (committed) return error.UnexpectedToken;
            self.pos = checkpoint;
            return null;
        }
        _ = self.advance(); // `]`

        if (!self.check(.l_paren)) {
            if (committed) return error.UnexpectedToken;
            self.pos = checkpoint;
            return null;
        }
        _ = try self.expect(.l_paren);

        var args = std.ArrayList(ast.Expr).empty;
        if (!self.check(.r_paren)) {
            try args.append(self.allocator, try self.parseExpr());
            while (self.match(.comma)) {
                try args.append(self.allocator, try self.parseExpr());
            }
        }
        _ = try self.expect(.r_paren);

        const resolved_class_name = try self.allocator.create(?[]const u8);
        resolved_class_name.* = null;
        return .{ .generic_construct = .{
            .name = construct_name,
            .type_args = try type_args.toOwnedSlice(self.allocator),
            .args = try args.toOwnedSlice(self.allocator),
            .resolved_class_name = resolved_class_name,
        } };
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
                // Gerçek span sistemi (bkz. plan dosyası "Gerçek span
                // sistemi + yapılandırılmış tanılamalar", Bulgu #1): `args`
                // (bir `std.ArrayList`) BÜYÜRKEN YENİDEN TAHSİS edebilir, bu
                // YÜZDEN `args.items[i]`e bir POINTER, `toOwnedSlice()`
                // ÇAĞRILMADAN ÖNCE alınırsa GEÇERSİZLEŞEBİLİR — span'lar
                // AYRI bir paralel dizide (İNDEKS bazında EŞLEŞECEK şekilde)
                // toplanır, `@intFromPtr` yalnızca KALICI (yeniden
                // tahsis edilmeyecek) son dizi ELDE EDİLDİKTEN SONRA alınır.
                var arg_spans: std.ArrayList(Span) = .empty;
                if (!self.check(.r_paren)) {
                    {
                        const arg_start = self.cur();
                        try args.append(self.allocator, try self.parseExpr());
                        try arg_spans.append(self.allocator, span_mod.fromTokens(arg_start, self.tokens[self.pos - 1]));
                    }
                    while (self.match(.comma)) {
                        const arg_start = self.cur();
                        try args.append(self.allocator, try self.parseExpr());
                        try arg_spans.append(self.allocator, span_mod.fromTokens(arg_start, self.tokens[self.pos - 1]));
                    }
                }
                _ = try self.expect(.r_paren);
                const old_expr = expr;
                const final_args = try args.toOwnedSlice(self.allocator);
                for (final_args, arg_spans.items) |*arg, sp| {
                    try self.expr_spans.put(self.allocator, @intFromPtr(arg), sp);
                }
                arg_spans.deinit(self.allocator);
                expr = .{ .call = .{ .callee = try self.box(old_expr), .args = final_args } };
            } else if (self.check(.l_bracket) and expr == .identifier) {
                // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı):
                // `İsim[TipArgs](args)` ARTIK HERHANGİ bir tanımlayıcı İçin
                // denenir (ÖNCEDEN yalnızca `Channel`/`ThreadChannel`) — bkz.
                // `tryParseGenericConstructTail`in belge notu, geriye-izlemeli
                // ayrım MANTIĞI VE bilinçli kalıcı belirsizlik KARARI orada
                // AÇIKLANIR. Not: isim ÖNCE bir yerel değişkene alınır —
                // `expr`e (bir tagged union) atama yaparken AYNI ifadenin sağ
                // tarafında `expr`in ESKİ etiketini okumak güvenli DEĞİLDİR
                // (bkz. bulunan gerçek çökme: "access of union field
                // 'identifier' while field 'generic_construct' is active").
                const construct_name = expr.identifier;
                if (try self.tryParseGenericConstructTail(construct_name)) |ge| {
                    expr = ge;
                } else {
                    // Generic-kurucu OLMADIĞI belirlendi (`[` ÖNCESİ konuma
                    // geri alındı) — sıradan indeksleme yolu, AŞAĞIDAKİ
                    // `self.match(.l_bracket)` dalıyla BİREBİR AYNI.
                    _ = try self.expect(.l_bracket);
                    const idx = try self.parseExpr();
                    _ = try self.expect(.r_bracket);
                    const old_expr = expr;
                    expr = .{ .index = .{ .obj = try self.box(old_expr), .index = try self.box(idx) } };
                }
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
                const v = std.fmt.parseInt(i64, t.lexeme, 10) catch {
                    self.last_diagnostic = .{ .found = t.kind, .span = span_mod.fromToken(t) };
                    return error.InvalidNumberLiteral;
                };
                return .{ .int_lit = v };
            },
            .float_lit => {
                const t = self.advance();
                const v = std.fmt.parseFloat(f64, t.lexeme) catch {
                    self.last_diagnostic = .{ .found = t.kind, .span = span_mod.fromToken(t) };
                    return error.InvalidNumberLiteral;
                };
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
            .fstring_lit => {
                const t = self.advance();
                return self.parseFStringLit(t.lexeme);
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
                // `{}` (boş sözlük) — `[]`nin (bkz. yukarıdaki `.l_bracket`
                // dalı) AYNI "kapanışı hemen kontrol et" deseni. Checker'ın
                // `checkExprExpected`i (bkz. o dosyanın belge notu) bunu YALNIZCA
                // bir BEKLENEN `dict[K,V]` tipi biliniyorsa kabul eder.
                if (!self.check(.r_brace)) {
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
                }
                _ = try self.expect(.r_brace);
                return .{ .dict_lit = try pairs.toOwnedSlice(self.allocator) };
            },
            else => {
                self.last_diagnostic = .{ .found = self.curKind(), .span = span_mod.fromToken(self.cur()) };
                return error.UnexpectedToken;
            },
        }
    }

    /// Tırnakları kaldırır ve temel kaçış dizilerini (\n \t \\ \' \") çözer.
    fn decodeString(self: *Parser, lexeme: []const u8) ParseError![]const u8 {
        return self.decodeEscapes(lexeme[1 .. lexeme.len - 1]);
    }

    /// `decodeString`in ÇEKİRDEK döngüsü — ZATEN tırnaksız (`inner`) bir
    /// dilim üzerinde çalışır. `decodeString` (düz string literalleri) VE
    /// `parseFStringLit` (f-string literal segment'leri, bkz. onun belge
    /// notu) TARAFINDAN PAYLAŞILIR — İKİSİ de AYNI kaçış çözümünü kullanmalı.
    fn decodeEscapes(self: *Parser, inner: []const u8) ParseError![]const u8 {
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

    /// Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
    /// `lexer.zig`nin ÜRETTİĞİ HAM `.fstring_lit` metnini (`f"..."`, tam
    /// öneki/tırnakları/kaçışları/`{...}` interpolasyonlarını İÇEREN) parse-
    /// ZAMANINDA literal/ifade segment'lerine BÖLÜP `.binary{.add}`/
    /// `.call{str}`/`.string_lit` zincirine DESUGAR eder — YENİ bir AST türü
    /// GEREKMEZ (bkz. plan dosyası). `{expr}` segment'leri `lexer.tokenize`
    /// İLE AYRI tokenlenip YENİ bir `Parser` örneğiyle `.parseExpr()`
    /// çağrılarak çözülür (bu dosyanın KENDİ `parseSource` test yardımcısıyla
    /// AYNI "yeniden lex+parse" deseni). **Bilinen v1 sınırlaması:** `{}`
    /// içindeki bir ifadenin hata span'ı alt-diziye GÖREDİR, orijinal dosya
    /// konumuna GÖRE DEĞİL (`lexer.tokenize`nin bir başlangıç-ofseti
    /// parametresi YOK) — tanılama kalitesinde küçük, dokümante edilen bir
    /// sınırlama.
    fn parseFStringLit(self: *Parser, lexeme: []const u8) ParseError!ast.Expr {
        // `lexeme[0]` = 'f'/'F', `lexeme[1]` = açılış tırnağı, `lexeme[len-1]`
        // = kapanış tırnağı (lexer ZATEN dengelenmiş/geçerli olduğunu
        // doğruladı — bkz. `lexer.zig`nin f-string durum makinesi).
        const inner = lexeme[2 .. lexeme.len - 1];

        const Segment = union(enum) { literal: []const u8, expr: ast.Expr };
        var segments = std.ArrayList(Segment).empty;
        var literal_buf = std.ArrayList(u8).empty;

        var i: usize = 0;
        while (i < inner.len) {
            const ch = inner[i];
            if (ch == '\\' and i + 1 < inner.len) {
                const esc = inner[i + 1];
                const decoded: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '\'' => '\'',
                    '"' => '"',
                    else => esc,
                };
                try literal_buf.append(self.allocator, decoded);
                i += 2;
                continue;
            }
            if (ch == '{') {
                if (i + 1 < inner.len and inner[i + 1] == '{') {
                    try literal_buf.append(self.allocator, '{');
                    i += 2;
                    continue;
                }
                if (literal_buf.items.len > 0) {
                    try segments.append(self.allocator, .{ .literal = try literal_buf.toOwnedSlice(self.allocator) });
                    literal_buf = .empty;
                }
                // `{...}` ifadesinin SINIRINI bul — Python'ın KLASİK iç-içe-
                // tırnak kuralı burada TEKRAR uygulanmaz (lexer ZATEN
                // doğruladı); yalnızca `{`/`}` derinliği VE İÇ string'lerin
                // (herhangi bir tırnakla) SINIRLARI izlenir.
                const expr_start = i + 1;
                var depth: u32 = 1;
                var nested_quote: ?u8 = null;
                var j = expr_start;
                while (j < inner.len and depth > 0) {
                    const cj = inner[j];
                    if (nested_quote) |nq| {
                        if (cj == '\\' and j + 1 < inner.len) {
                            j += 2;
                            continue;
                        }
                        if (cj == nq) nested_quote = null;
                        j += 1;
                        continue;
                    }
                    if (cj == '\'' or cj == '"') {
                        nested_quote = cj;
                        j += 1;
                        continue;
                    }
                    if (cj == '{') {
                        depth += 1;
                        j += 1;
                        continue;
                    }
                    if (cj == '}') {
                        depth -= 1;
                        j += 1;
                        continue;
                    }
                    j += 1;
                }
                const expr_text = inner[expr_start .. j - 1];
                const sub_tokens = lexer_mod.tokenize(self.allocator, expr_text) catch {
                    self.last_diagnostic = .{ .found = .fstring_lit, .span = span_mod.fromToken(self.tokens[self.pos - 1]) };
                    return error.UnexpectedToken;
                };
                var sub_parser = Parser.init(self.allocator, sub_tokens);
                const sub_expr = try sub_parser.parseExpr();
                try segments.append(self.allocator, .{ .expr = sub_expr });
                i = j;
                continue;
            }
            if (ch == '}') {
                // Lexer ZATEN eşleşmemiş tek bir `}`yi reddetti — buraya
                // yalnızca KAÇAN `}}` düşer.
                try literal_buf.append(self.allocator, '}');
                i += 2;
                continue;
            }
            try literal_buf.append(self.allocator, ch);
            i += 1;
        }
        if (literal_buf.items.len > 0) {
            try segments.append(self.allocator, .{ .literal = try literal_buf.toOwnedSlice(self.allocator) });
        }

        if (segments.items.len == 0) return .{ .string_lit = "" };
        if (segments.items.len == 1 and segments.items[0] == .literal) {
            return .{ .string_lit = segments.items[0].literal };
        }

        var acc: ?ast.Expr = null;
        for (segments.items) |seg| {
            const piece: ast.Expr = switch (seg) {
                .literal => |lit| .{ .string_lit = lit },
                .expr => |e| blk: {
                    const args = try self.allocator.alloc(ast.Expr, 1);
                    args[0] = e;
                    const callee = try self.allocator.create(ast.Expr);
                    callee.* = .{ .identifier = "str" };
                    break :blk .{ .call = .{ .callee = callee, .args = args } };
                },
            };
            if (acc) |a| {
                const left = try self.allocator.create(ast.Expr);
                left.* = a;
                const right = try self.allocator.create(ast.Expr);
                right.* = piece;
                acc = .{ .binary = .{ .op = .add, .left = left, .right = right } };
            } else {
                acc = piece;
            }
        }
        return acc.?;
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
