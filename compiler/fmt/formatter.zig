//! Nox v0.1 kaynak-kodu formatlayıcısı (Faz T.4b) — AST'yi kanonik bir
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
/// → parseAnd → parseNot → parseComparison → parseAddSub → parseMulDiv →
/// parseUnary → parsePower → parsePostfix) TERS (yazdırma) yönüdür.
fn binPrec(op: ast.BinaryOp) u8 {
    return switch (op) {
        .or_ => 1,
        .and_ => 2,
        .eq, .ne, .lt, .le, .gt, .ge => 4,
        .add, .sub => 5,
        .mul, .div, .floordiv, .mod => 6,
        .pow => 8,
    };
}

fn unaryPrec(op: ast.UnaryOp) u8 {
    return switch (op) {
        .not_ => 3,
        .neg => 7,
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
                try self.writer.print("class {s}:", .{c.name});
                try self.line(stmt.line);
                for (c.methods, 0..) |m, idx| {
                    if (idx > 0) {
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
                    if (ec.bind_name) |bn| {
                        try self.writer.print("except {s} as {s}:\n", .{ ec.class_name, bn });
                    } else {
                        try self.writer.print("except {s}:\n", .{ec.class_name});
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
            .with_stmt => |w| {
                try self.indentTo(depth);
                try self.writer.writeAll("with ");
                try self.printExpr(w.ctx_expr);
                if (w.binding) |bn| try self.writer.print(" as {s}", .{bn});
                try self.writer.writeAll(":");
                try self.line(stmt.line);
                try self.printStmts(w.body, depth + 1);
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
            try self.writer.print("{s}: ", .{p.name});
            try self.printType(p.type_expr);
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
                try self.writer.print(" {s} ", .{binOpStr(b.op)});
                try self.printExprAt(b.right.*, my_prec, right_side);
                if (need_parens) try self.writer.writeAll(")");
            },
            .unary => |u| {
                const my_prec = unaryPrec(u.op);
                const need_parens = my_prec < ctx_prec or (my_prec == ctx_prec and side == .strict);
                if (need_parens) try self.writer.writeAll("(");
                switch (u.op) {
                    .neg => try self.writer.writeAll("-"),
                    .not_ => try self.writer.writeAll("not "),
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
            .binary, .unary => unreachable, // yukarıda printExprAt'ta ele alındı
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
