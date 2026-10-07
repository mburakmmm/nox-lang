//! Nox kaynak-kodu formatlayıcısı (Faz T.4b) — AST'yi kanonik bir
//! stile (4 boşluk girinti, operatörler etrafında tek boşluk, çift tırnaklı
//! string'ler) göre YENİDEN Nox söz dizimine yazar. T.4a'nın yakaladığı
//! `Trivia`yi (yorumlar + boş satırlar) en yakın deyime göre orijinal
//! konumlarına EN YAKIN şekilde geri yerleştirir — bu, `noxc fmt`in
//! kullanıcının GERÇEK yorumlarını SESSİZCE SİLMESİNİ engelleyen ÖN
//! KOŞULDU (bkz. T.4a'nın belge notu, kullanıcıyla netleşen karar).
//!
//! **Trivia yeniden-yerleştirme deseni:** `Trivia` (T.4a) kaynak sırasına
//! göre SIRALI bir liste; bu yazıcı AST'yi TAM OLARAK kaynaktaki gibi
//! (üstten-alta, soldan-sağa, iç içe gövdeler KARŞILAŞILDIKLARI ANDA)
//! GEZDİĞİNDEN, TEK bir monoton ilerleyen imleç (`trivia_idx`) YETERLİDİR —
//! `emitLeadingTrivia(upto_line)` şu ana kadar tüketilmemiş, VERİLEN
//! satırdan ÖNCEKİ TÜM trivia'yı (yorum+boş satır) basar; her deyimin
//! KENDİ "başlık satırı" (`line()` yardımcısı) yazıldıktan HEMEN SONRA
//! AYNI satırdaki bir `trailing` yorum (varsa) satırın SONUNA eklenir.
//!
//! **Bilinçli v1 sınırlamaları (KABUL EDİLDİ):**
//! - Satır-uzunluğu temelli SARMA (line wrapping) YOK — HER ifade/imza TEK
//!   satırda yazılır (kaynaktaki orijinal satır sayısından BAĞIMSIZ).
//! - `ElifClause`/`ExceptClause` KENDİ satır numarasını TAŞIMAZ (yalnızca
//!   üst-düzey `ast.Stmt` T.1'in `.line`ini taşır) — bu YÜZDEN `elif ...:`/
//!   `except ...:`/`finally:` başlıklarının AYNI satırındaki bir trailing
//!   yorum, o başlığa DEĞİL, o kolun İLK deyiminin ÖNÜNE (standalone gibi)
//!   düşer. Yorum METNİ KAYBOLMAZ, yalnızca TAM olarak AYNI satıra
//!   İĞNELENEMEZ.
//! - Bir bloğun SON deyiminden SONRA (dedent'ten ÖNCE) bırakılan bir
//!   yorumun GİRİNTİSİ, kaynaktaki KENDİ derinliği DEĞİL, YAZDIRILAN BİR
//!   SONRAKİ deyimin derinliğiyle eşleşir (trivia yalnızca SATIR taşır,
//!   SÜTUN/derinlik TAŞIMAZ) — metin KAYBOLMAZ, yalnızca girinti SEZGİSEL.
//! - Çok-dosyalı (stdlib import'ları GENİŞLETİLMİŞ) bir `ast.Module`
//!   formatlanırsa TÜM merge edilmiş içerik TEK bir dosyaymış GİBİ
//!   yazdırılır — `noxc fmt` yalnızca KULLANICININ KENDİ (import'ları
//!   ÇÖZÜLMEMİŞ, ham `parser.parseModule` çıktısı) modülüne uygulanmalıdır
//!   (bkz. `main.zig`nin `cmdFmt`i — `module_loader.resolveImports`
//!   HİÇ ÇAĞRILMAZ).

const std = @import("std");
const ast = @import("../parser/ast.zig");
const token = @import("../lexer/token.zig");

const INDENT = "    ";

pub const FormatError = std.Io.Writer.Error || error{NoSpaceLeft};

/// `module`ü (`trivia`nin EŞLİK ETTİĞİ AYNI kaynaktan üretilmiş olması
/// ÖNKOŞULDUR — bkz. `lexer.tokenizeWithTrivia`) kanonik Nox kaynağına
/// formatlar.
pub fn formatModule(allocator: std.mem.Allocator, module: ast.Module, trivia: []const token.Trivia) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var p: Printer = .{ .writer = &aw.writer, .trivia = trivia };
    try p.printModule(module);
    return aw.toOwnedSlice();
}

/// İkili operatörün precedence'ı — SAYI BÜYÜDÜKÇE daha SIKI bağlanır.
/// `compiler/parser/parser.zig`nin precedence-climbing zincirinin (parseOr
/// → parseAnd → parseNot → parseComparison → parseBitOr → parseBitXor →
/// parseBitAnd → parseShift → parseAddSub → parseMulDiv → parseUnary →
/// parsePower → parsePostfix) TERS (yazdırma) yönüdür. v3 madde 2
/// (bitwise operatörler) İLE comparison(4)/add-sub(eski 5) ARASINA 4 yeni
/// kademe (bit_or/bit_xor/bit_and/shift) EKLENDİĞİNDEN TÜM sayılar
/// (eski göreli SIRA KORUNARAK) YENİDEN numaralandırıldı.
fn binPrec(op: ast.BinaryOp) u8 {
    return switch (op) {
        .or_ => 1,
        .and_ => 2,
        .eq, .ne, .lt, .le, .gt, .ge, .in_, .not_in => 4,
        .bit_or => 5,
        .bit_xor => 6,
        .bit_and => 7,
        .shl, .shr => 8,
        .add, .sub => 9,
        .mul, .div, .floordiv, .mod => 10,
        .pow => 12,
    };
}

fn unaryPrec(op: ast.UnaryOp) u8 {
    return switch (op) {
        .not_ => 3,
        .neg, .invert => 11,
    };
}

fn binOpStr(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .floordiv => "//",
        .mod => "%",
        .pow => "**",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .and_ => "and",
        .or_ => "or",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shl => "<<",
        .shr => ">>",
        .in_ => "in",
        .not_in => "not in",
    };
}

/// Bir ikili/tekli ifadenin, İÇİNDE bulunduğu ("ambient") bir üst
/// operatörün HANGİ operand yuvasında olduğunu belirtir — eşit precedence'ta
/// parens gerekip gerekmediğini (sağ-/sol-birleşimlilik) ayırt etmek için.
const Side = enum { loose, strict };

const Printer = struct {
    writer: *std.Io.Writer,
    trivia: []const token.Trivia,
    trivia_idx: usize = 0,
    last_was_blank: bool = true, // dosya BAŞINDA baştaki boş satırı BASTIRIR

    fn indentTo(self: *Printer, depth: usize) FormatError!void {
        var i: usize = 0;
        while (i < depth) : (i += 1) try self.writer.writeAll(INDENT);
    }

    /// `upto_line`DAN (HARİÇ) önceki TÜM tüketilmemiş trivia'yı basar —
    /// ardışık boş satırlar TEK bir boş satıra düşürülür (standart fmt
    /// davranışı).
    fn emitLeadingTrivia(self: *Printer, depth: usize, upto_line: u32) FormatError!void {
        while (self.trivia_idx < self.trivia.len and self.trivia[self.trivia_idx].line < upto_line) {
            const t = self.trivia[self.trivia_idx];
            switch (t.kind) {
                .blank_line => {
                    if (!self.last_was_blank) {
                        try self.writer.writeAll("\n");
                        self.last_was_blank = true;
                    }
                },
                .comment => {
                    try self.indentTo(depth);
                    try self.writer.print("{s}\n", .{t.text});
                    self.last_was_blank = false;
                },
            }
            self.trivia_idx += 1;
        }
    }

    fn emitRemainingTrivia(self: *Printer) FormatError!void {
        try self.emitLeadingTrivia(0, std.math.maxInt(u32));
    }

    /// Şu ana kadar YAZILAN (satır sonu HARİÇ) bir deyim/yan-tümce başlığını
    /// kapatır: AYNI satırda bir `trailing` yorum VARSA satırın SONUNA
    /// ekler, sonra satırı bitirir.
    fn line(self: *Printer, source_line: u32) FormatError!void {
        if (self.trivia_idx < self.trivia.len) {
            const t = self.trivia[self.trivia_idx];
            if (t.kind == .comment and t.trailing and t.line == source_line) {
                try self.writer.print("  {s}", .{t.text});
                self.trivia_idx += 1;
            }
        }
        try self.writer.writeAll("\n");
        self.last_was_blank = false;
    }

    fn printModule(self: *Printer, module: ast.Module) FormatError!void {
        try self.printStmts(module.body, 0);
        try self.emitRemainingTrivia();
    }

    fn printStmts(self: *Printer, stmts: []const ast.Stmt, depth: usize) FormatError!void {
        for (stmts) |stmt| {
            try self.emitLeadingTrivia(depth, stmt.line);
            try self.printStmt(stmt, depth);
        }
    }

    fn printStmt(self: *Printer, stmt: ast.Stmt, depth: usize) FormatError!void {
        switch (stmt.kind) {
            .expr_stmt => |e| {
                try self.indentTo(depth);
                try self.printExpr(e);
                try self.line(stmt.line);
            },
            .var_decl => |v| {
                try self.indentTo(depth);
                try self.writer.print("{s}: ", .{v.name});
                try self.printType(v.type_expr);
                try self.writer.writeAll(" = ");
                try self.printExpr(v.value);
                try self.line(stmt.line);
            },
            .assign => |a| {
                try self.indentTo(depth);
                try self.printExpr(a.target);
                try self.writer.writeAll(" = ");
                try self.printExpr(a.value);
                try self.line(stmt.line);
            },
            .if_stmt => |f| {
                try self.indentTo(depth);
                try self.writer.writeAll("if ");
                try self.printExpr(f.cond);
                try self.writer.writeAll(":");
                try self.line(stmt.line);
                try self.printStmts(f.then_body, depth + 1);
                for (f.elif_clauses) |ec| {
                    try self.indentTo(depth);
                    try self.writer.writeAll("elif ");
                    try self.printExpr(ec.cond);
                    try self.writer.writeAll(":\n");
                    self.last_was_blank = false;
                    try self.printStmts(ec.body, depth + 1);
                }
                if (f.else_body) |eb| {
                    try self.indentTo(depth);
                    try self.writer.writeAll("else:\n");
                    self.last_was_blank = false;
                    try self.printStmts(eb, depth + 1);
                }
            },
            .while_stmt => |w| {
                try self.indentTo(depth);
                try self.writer.writeAll("while ");
                try self.printExpr(w.cond);
                try self.writer.writeAll(":");
                try self.line(stmt.line);
                try self.printStmts(w.body, depth + 1);
            },
            .for_stmt => |f| {
                try self.indentTo(depth);
                try self.writer.print("for {s} in ", .{f.var_name});
                try self.printExpr(f.iterable);
                try self.writer.writeAll(":");
                try self.line(stmt.line);
                try self.printStmts(f.body, depth + 1);
            },
            .func_def => |fd| try self.printFuncDef(fd, depth, stmt.line),
            .class_def => |c| {
                try self.indentTo(depth);
                if (c.base) |b| {
                    try self.writer.print("class {s}({s}):", .{ c.name, b });
                } else {
                    try self.writer.print("class {s}:", .{c.name});
                }
                try self.line(stmt.line);
                // Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): AÇIKÇA
                // bildirilen alanlar (varsa) metodlardan ÖNCE, her biri
                // KENDİ satırında `ad: Tip` olarak basılır — BURADA
                // BASILMAZLARSA `nox fmt`in KENDİSİ kullanıcının alan
                // bildirimlerini SESSİZCE SİLERDİ (dosya HÂLÂ parse OLURDU,
                // yalnızca çıkarım-only semantiğe SESSİZCE geri dönerdi) —
                // bu yüzden bu dal BLOCKING'dir, isteğe bağlı DEĞİL.
                for (c.fields) |fd| {
                    try self.emitLeadingTrivia(depth + 1, fd.line);
                    try self.indentTo(depth + 1);
                    try self.writer.print("{s}: ", .{fd.name});
                    try self.printType(fd.type_expr);
                    try self.line(fd.line);
                }
                // Alanlar VARSA VE en az bir metod TAKİP EDİYORSA: alan/metod
                // GEÇİŞ bölgesindeki (kaynakta orada OLABİLECEK boş satır/
                // yorum) tüketilmemiş trivia'yı, AŞAĞIDAKİ döngünün ZATEN
                // KOŞULSUZ eklediği TEK ayırıcı boş satırla ÇAKIŞMAMASI İçin
                // SESSİZCE (basmadan) İLERİ SARAR — metodlar ARASI boşluğun
                // (bkz. aşağıdaki `idx > 0` dalı) KENDİSİ de trivia'ya HİÇ
                // bakmadan HER ZAMAN TEK bir boş satır ZORLADIĞINDAN, bu
                // TUTARLI bir davranıştır (bkz. `printStmts`in AKSİNE, metod
                // listesi ZATEN trivia-duyarlı DEĞİLDİR). `fd.line`in
                // `ast.Stmt`ten BAĞIMSIZ, SENTETİK bir alan olması nedeniyle
                // (bkz. `ast.FieldDecl`nin belge notu) BU BURADA GEREKİR —
                // aksi halde bu trivia, `__init__`in gövdesindeki İLK
                // deyimin KENDİ `emitLeadingTrivia`sına SIZAR (GERÇEKTEN
                // gözlemlenen bir biçimlendirme hatasıydı).
                if (c.fields.len > 0 and c.methods.len > 0 and c.methods[0].body.len > 0) {
                    const next_line = c.methods[0].body[0].line;
                    while (self.trivia_idx < self.trivia.len and self.trivia[self.trivia_idx].line < next_line) {
                        self.trivia_idx += 1;
                    }
                }
                for (c.methods, 0..) |m, idx| {
                    if (idx > 0 or c.fields.len > 0) {
                        try self.writer.writeAll("\n");
                        self.last_was_blank = true;
                    }
                    try self.printFuncDefNoLeading(m, depth + 1);
                }
            },
            .protocol_def => |pd| {
                try self.indentTo(depth);
                try self.writer.print("protocol {s}:", .{pd.name});
                try self.line(stmt.line);
                for (pd.methods, 0..) |m, idx| {
                    if (idx > 0) {
                        try self.writer.writeAll("\n");
                        self.last_was_blank = true;
                    }
                    try self.printFuncDefNoLeading(m, depth + 1);
                }
            },
            .extern_def => |ed| {
                try self.indentTo(depth);
                try self.writer.print("extern def {s}(", .{ed.name});
                try self.printParams(ed.params);
                try self.writer.writeAll(") -> ");
                try self.printType(ed.return_type);
                try self.writer.print(" from \"{s}\"", .{ed.from_lib});
                if (ed.needs_rt) try self.writer.writeAll(" with_rt");
                if (ed.retains.len > 0) {
                    try self.writer.writeAll(" retains(");
                    for (ed.retains, 0..) |r, idx| {
                        if (idx != 0) try self.writer.writeAll(", ");
                        try self.writer.writeAll(r);
                    }
                    try self.writer.writeAll(")");
                }
                try self.line(stmt.line);
            },
            .return_stmt => |r| {
                try self.indentTo(depth);
                if (r) |e| {
                    try self.writer.writeAll("return ");
                    try self.printExpr(e);
                } else {
                    try self.writer.writeAll("return");
                }
                try self.line(stmt.line);
            },
            .raise_stmt => |e| {
                try self.indentTo(depth);
                try self.writer.writeAll("raise ");
                try self.printExpr(e);
                try self.line(stmt.line);
            },
            .try_stmt => |t| {
                try self.indentTo(depth);
                try self.writer.writeAll("try:");
                try self.line(stmt.line);
                try self.printStmts(t.try_body, depth + 1);
                for (t.except_clauses) |ec| {
                    try self.indentTo(depth);
                    if (ec.class_name) |cn| {
                        if (ec.bind_name) |bn| {
                            try self.writer.print("except {s} as {s}:\n", .{ cn, bn });
                        } else {
                            try self.writer.print("except {s}:\n", .{cn});
                        }
                    } else {
                        // Bulundu (nyx framework — bkz. proje belleği
                        // "NOX_LIMITATIONS.md incelemesi", P5): ÇIPLAK
                        // `except:`.
                        try self.writer.writeAll("except:\n");
                    }
                    self.last_was_blank = false;
                    try self.printStmts(ec.body, depth + 1);
                }
                if (t.finally_body) |fb| {
                    try self.indentTo(depth);
                    try self.writer.writeAll("finally:\n");
                    self.last_was_blank = false;
                    try self.printStmts(fb, depth + 1);
                }
            },
            .lowlevel_stmt => |ll| {
                try self.indentTo(depth);
                try self.writer.writeAll("lowlevel:");
                try self.line(stmt.line);
                try self.printStmts(ll.body, depth + 1);
            },
            .import_stmt => |imp| {
                try self.indentTo(depth);
                try self.writer.writeAll("import ");
                for (imp.segments, 0..) |seg, idx| {
                    if (idx > 0) try self.writer.writeAll(".");
                    try self.writer.writeAll(seg);
                }
                if (imp.alias) |alias| try self.writer.print(" as {s}", .{alias});
                try self.line(stmt.line);
            },
            .from_import_stmt => |fi| {
                try self.indentTo(depth);
                try self.writer.writeAll("from ");
                for (fi.segments, 0..) |seg, idx| {
                    if (idx > 0) try self.writer.writeAll(".");
                    try self.writer.writeAll(seg);
                }
                try self.writer.writeAll(" import ");
                for (fi.names, 0..) |nm, idx| {
                    if (idx > 0) try self.writer.writeAll(", ");
                    try self.writer.writeAll(nm.name);
                    if (nm.alias) |alias| try self.writer.print(" as {s}", .{alias});
                }
                try self.line(stmt.line);
            },
            .pass_stmt => {
                try self.indentTo(depth);
                try self.writer.writeAll("pass");
                try self.line(stmt.line);
            },
            .del_stmt => |e| {
                try self.indentTo(depth);
                try self.writer.writeAll("del ");
                try self.printExpr(e);
                try self.line(stmt.line);
            },
            .break_stmt => {
                try self.indentTo(depth);
                try self.writer.writeAll("break");
                try self.line(stmt.line);
            },
            .continue_stmt => {
                try self.indentTo(depth);
                try self.writer.writeAll("continue");
                try self.line(stmt.line);
            },
            .with_stmt => |w| {
                try self.indentTo(depth);
                try self.writer.writeAll("with ");
                try self.printExpr(w.ctx_expr);
                if (w.binding) |bn| try self.writer.print(" as {s}", .{bn});
                try self.writer.writeAll(":");
                try self.line(stmt.line);
                try self.printStmts(w.body, depth + 1);
            },
            .defer_stmt => |d| {
                try self.indentTo(depth);
                try self.writer.writeAll("defer ");
                try self.printExpr(.{ .call = d.call });
                try self.line(stmt.line);
            },
        }
    }

    fn printFuncDef(self: *Printer, fd: ast.FuncDef, depth: usize, source_line: u32) FormatError!void {
        try self.indentTo(depth);
        try self.printFuncHeader(fd);
        try self.line(source_line);
        try self.printStmts(fd.body, depth + 1);
    }

    /// `class_def`/`protocol_def` içindeki metodlar KENDİ `ast.Stmt`
    /// SARMALAYICISINA sahip DEĞİLDİR (`ast.FuncDef` çıplak, bkz.
    /// `ClassDef.methods: []FuncDef`) — bu yüzden metod başlığının satırı
    /// BİLİNMEZ, `line()`in trailing-yorum eşleştirmesi bu YOLDAN
    /// ATLANIR (metod gövdesinin İLK deyiminin ÖNÜNDEKİ trivia YİNE DE
    /// standalone olarak doğru basılır).
    fn printFuncDefNoLeading(self: *Printer, fd: ast.FuncDef, depth: usize) FormatError!void {
        try self.indentTo(depth);
        try self.printFuncHeader(fd);
        try self.writer.writeAll("\n");
        self.last_was_blank = false;
        try self.printStmts(fd.body, depth + 1);
    }

    fn printFuncHeader(self: *Printer, fd: ast.FuncDef) FormatError!void {
        if (fd.is_async) try self.writer.writeAll("async ");
        try self.writer.print("def {s}", .{fd.name});
        if (fd.type_params.len > 0) {
            try self.writer.writeAll("[");
            for (fd.type_params, 0..) |tp, idx| {
                if (idx > 0) try self.writer.writeAll(", ");
                try self.writer.writeAll(tp);
            }
            try self.writer.writeAll("]");
        }
        try self.writer.writeAll("(");
        try self.printParams(fd.params);
        try self.writer.writeAll(") -> ");
        try self.printType(fd.return_type);
        try self.writer.writeAll(":");
    }

    fn printParams(self: *Printer, params: []const ast.Param) FormatError!void {
        for (params, 0..) |p, idx| {
            if (idx > 0) try self.writer.writeAll(", ");
            // Faz FF.4 (bkz. nox-teknik-spesifikasyon.md §3.63): kullanıcı
            // çıplak `self` YAZDIYSA (`self_inferred`), formatlayıcı bunu
            // `self: ClassName`e "GENİŞLETMEZ" — `type_expr` parser
            // tarafından ZATEN doldurulmuş olsa da (checker/codegen İçin),
            // YÜZEY sözdizimi SADIK biçimde yeniden üretilir.
            if (p.self_inferred) {
                try self.writer.print("{s}", .{p.name});
                continue;
            }
            try self.writer.print("{s}: ", .{p.name});
            try self.printType(p.type_expr);
            if (p.default) |d| {
                try self.writer.writeAll(" = ");
                try self.printExpr(d);
            }
        }
    }

    fn printType(self: *Printer, t: ast.TypeExpr) FormatError!void {
        switch (t) {
            .simple => |s| try self.writer.writeAll(s),
            .generic => |g| {
                try self.writer.print("{s}[", .{g.name});
                for (g.args, 0..) |a, idx| {
                    if (idx > 0) try self.writer.writeAll(", ");
                    try self.printType(a);
                }
                try self.writer.writeAll("]");
            },
            .func_type => |ft| {
                try self.writer.writeAll("(");
                for (ft.params, 0..) |p, idx| {
                    if (idx > 0) try self.writer.writeAll(", ");
                    try self.printType(p);
                }
                try self.writer.writeAll(") -> ");
                try self.printType(ft.return_type.*);
            },
            // Faz FF.6 (bkz. nox-teknik-spesifikasyon.md §3.65): `T | None`.
            .optional => |inner| {
                try self.printType(inner.*);
                try self.writer.writeAll(" | None");
            },
            // Faz NN.2: `pkg.module.ClassName` — segmentleri kaynak
            // sözdizimiyle AYNI (`.`-ayrılmış) biçimde yeniden yaz.
            .qualified => |segments| {
                for (segments, 0..) |seg, idx| {
                    if (idx > 0) try self.writer.writeAll(".");
                    try self.writer.writeAll(seg);
                }
            },
        }
    }

    /// Ambient precedence KISITI OLMAYAN bağlamlar (atama sağ tarafı,
    /// çağrı argümanı, liste/dict elemanı, `return`/`raise` değeri, ...)
    /// İÇİN — hiçbir zaman parens EKLEMEZ (en gevşek precedence, 0, ile
    /// çağırır).
    fn printExpr(self: *Printer, e: ast.Expr) FormatError!void {
        try self.printExprAt(e, 0, .loose);
    }

    fn printExprAt(self: *Printer, e: ast.Expr, ctx_prec: u8, side: Side) FormatError!void {
        switch (e) {
            .binary => |b| {
                const my_prec = binPrec(b.op);
                const need_parens = my_prec < ctx_prec or (my_prec == ctx_prec and side == .strict);
                if (need_parens) try self.writer.writeAll("(");
                const right_assoc = b.op == .pow;
                const left_side: Side = if (right_assoc) .strict else .loose;
                const right_side: Side = if (right_assoc) .loose else .strict;
                try self.printExprAt(b.left.*, my_prec, left_side);
                if (b.is_form and b.right.* == .none_lit and (b.op == .eq or b.op == .ne)) {
                    try self.writer.writeAll(if (b.op == .eq) " is None" else " is not None");
                    if (need_parens) try self.writer.writeAll(")");
                    return;
                }
                try self.writer.print(" {s} ", .{binOpStr(b.op)});
                try self.printExprAt(b.right.*, my_prec, right_side);
                if (need_parens) try self.writer.writeAll(")");
            },
            .kwarg => |k| {
                try self.writer.print("{s}=", .{k.name});
                try self.printExpr(k.value.*);
            },
            .ternary => |t| {
                // Üçlü ifade en gevşek bağlanır: herhangi bir operatör bağlamında parantez gerekir; `then` ve
                // `cond` `or`-seviyesi (iç içe üçlü parantezlenir), `else` sağ-birleşimli.
                const need_parens = ctx_prec > 0;
                if (need_parens) try self.writer.writeAll("(");
                try self.printExprAt(t.then_expr.*, 1, .loose);
                try self.writer.writeAll(" if ");
                try self.printExprAt(t.cond.*, 1, .loose);
                try self.writer.writeAll(" else ");
                try self.printExprAt(t.else_expr.*, 0, .loose);
                if (need_parens) try self.writer.writeAll(")");
            },
            .unary => |u| {
                const my_prec = unaryPrec(u.op);
                const need_parens = my_prec < ctx_prec or (my_prec == ctx_prec and side == .strict);
                if (need_parens) try self.writer.writeAll("(");
                switch (u.op) {
                    .neg => try self.writer.writeAll("-"),
                    .not_ => try self.writer.writeAll("not "),
                    .invert => try self.writer.writeAll("~"),
                }
                try self.printExprAt(u.operand.*, my_prec, .loose);
                if (need_parens) try self.writer.writeAll(")");
            },
            else => try self.printPrimary(e),
        }
    }

    fn printPrimary(self: *Printer, e: ast.Expr) FormatError!void {
        switch (e) {
            .int_lit => |v| try self.writer.print("{d}", .{v}),
            .float_lit => |v| try self.printFloat(v),
            .bool_lit => |v| try self.writer.writeAll(if (v) "True" else "False"),
            .string_lit => |s| try self.printStringLit(s),
            .none_lit => try self.writer.writeAll("None"),
            .identifier => |name| try self.writer.writeAll(name),
            .call => |c| {
                try self.printExprAt(c.callee.*, 0, .loose);
                try self.writer.writeAll("(");
                for (c.args, 0..) |a, idx| {
                    if (idx > 0) try self.writer.writeAll(", ");
                    try self.printExpr(a);
                }
                try self.writer.writeAll(")");
            },
            .attribute => |a| {
                try self.printExprAt(a.obj.*, 0, .loose);
                try self.writer.print(".{s}", .{a.attr});
            },
            .list_comp => |lc| {
                try self.writer.writeAll("[");
                try self.printExpr(lc.elem.*);
                try self.printCompClauses(lc.clauses);
                try self.writer.writeAll("]");
            },
            .dict_comp => |dc| {
                try self.writer.writeAll("{");
                try self.printExpr(dc.key.*);
                try self.writer.writeAll(": ");
                try self.printExpr(dc.value.*);
                try self.printCompClauses(dc.clauses);
                try self.writer.writeAll("}");
            },
            .lambda => |lam| {
                try self.writer.writeAll("lambda");
                for (lam.params, 0..) |pn, i| {
                    try self.writer.writeAll(if (i == 0) " " else ", ");
                    try self.writer.writeAll(pn);
                }
                try self.writer.writeAll(": ");
                try self.printExpr(lam.body.*);
            },
            .slice => |sl| {
                try self.printExprAt(sl.obj.*, 0, .loose);
                try self.writer.writeAll("[");
                if (sl.lo) |x| try self.printExpr(x.*);
                try self.writer.writeAll(":");
                if (sl.hi) |x| try self.printExpr(x.*);
                if (sl.step) |x| {
                    try self.writer.writeAll(":");
                    try self.printExpr(x.*);
                }
                try self.writer.writeAll("]");
            },
            .index => |idx| {
                try self.printExprAt(idx.obj.*, 0, .loose);
                try self.writer.writeAll("[");
                try self.printExpr(idx.index.*);
                try self.writer.writeAll("]");
            },
            .list_lit => |elems| {
                try self.writer.writeAll("[");
                for (elems, 0..) |el, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.printExpr(el);
                }
                try self.writer.writeAll("]");
            },
            .dict_lit => |pairs| {
                try self.writer.writeAll("{");
                for (pairs, 0..) |p, i| {
                    if (i > 0) try self.writer.writeAll(", ");
                    try self.printExpr(p.key);
                    try self.writer.writeAll(": ");
                    try self.printExpr(p.value);
                }
                try self.writer.writeAll("}");
            },
            .await_expr => |operand| {
                try self.writer.writeAll("await ");
                try self.printExprAt(operand.*, unaryPrec(.neg), .loose);
            },
            .spawn_expr => |operand| {
                try self.writer.writeAll("spawn ");
                try self.printExprAt(operand.*, unaryPrec(.neg), .loose);
            },
            .generic_construct => |g| {
                try self.writer.print("{s}[", .{g.name});
                for (g.type_args, 0..) |ta, idx| {
                    if (idx > 0) try self.writer.writeAll(", ");
                    try self.printType(ta);
                }
                try self.writer.writeAll("](");
                for (g.args, 0..) |a, idx| {
                    if (idx > 0) try self.writer.writeAll(", ");
                    try self.printExpr(a);
                }
                try self.writer.writeAll(")");
            },
            .binary, .unary, .ternary, .kwarg => unreachable, // yukarıda printExprAt'ta ele alındı
        }
    }

    /// v1.154.0: comprehension yan tümceleri (` for x in it`, ` if cond`); iterable/koşul `or`-seviyesinde (üçlü ifade parantezlenir).
    fn printCompClauses(self: *Printer, clauses: []const ast.CompClause) FormatError!void {
        for (clauses) |cl| {
            switch (cl) {
                .for_clause => |fc| {
                    try self.writer.print(" for {s} in ", .{fc.var_name});
                    try self.printExprAt(fc.iterable, 1, .loose);
                },
                .if_clause => |ce| {
                    try self.writer.writeAll(" if ");
                    try self.printExprAt(ce, 1, .loose);
                },
            }
        }
    }

    /// Float literalleri HER ZAMAN bir ondalık nokta TAŞIYACAK şekilde
    /// yazdırır (`3.0` DEĞİL `3` yazılırsa, yeniden lex edildiğinde bir
    /// `int_lit`e DÖNÜŞÜR — AST'nin `float`/`int` AYRIMINI BOZAR).
    fn printFloat(self: *Printer, v: f64) FormatError!void {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
        try self.writer.writeAll(s);
        if (std.mem.indexOfScalar(u8, s, '.') == null) try self.writer.writeAll(".0");
    }

    /// `ast.Expr.string_lit` ZATEN ÇÖZÜLMÜŞ (kaçış dizileri YORUMLANMIŞ)
    /// ham İÇERİĞİ tutar (bkz. `parser.zig`nin `decodeString`i) — burada
    /// TERSİ (yeniden kaçışlama) yapılır. Kanonik stil: HER ZAMAN çift
    /// tırnak (kaynakta tek tırnak kullanılmış olsa BİLE).
    fn printStringLit(self: *Printer, s: []const u8) FormatError!void {
        try self.writer.writeAll("\"");
        for (s) |c| {
            switch (c) {
                '"' => try self.writer.writeAll("\\\""),
                '\\' => try self.writer.writeAll("\\\\"),
                '\n' => try self.writer.writeAll("\\n"),
                '\t' => try self.writer.writeAll("\\t"),
                else => try self.writer.writeByte(c),
            }
        }
        try self.writer.writeAll("\"");
    }
};
