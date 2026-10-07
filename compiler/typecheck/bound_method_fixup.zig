//! Aether NOX_LIMITATIONS.md yol haritası, Faz C.1b (bkz. nox-teknik-
//! spesifikasyon.md ilgili bölüm, madde 1): bağlı-metod değeri —
//! `handler: (Context) -> HttpResponse = ctl.show`.
//!
//! **Neden bir AST ön geçişi (ve neden bir çağrıya yeniden yazma):** sahiplik/
//! kaçış analizleri (`local_escape.zig`, `inlining.zig`, `ownership/
//! analysis.zig`) çıplak bir `obj.alan` OKUMASINI "kaçış DEĞİL" sayar —
//! bağlı bir metod DEĞERİ ise alıcıyı (`obj`) bir closure'a YAKALAR
//! (retain eder). Analizler `obj.ad`ın bir METOD olduğunu bilemez (tip
//! bilgisi YOK); `obj`in stack'e terfi ettirilmesi (ARC başlığı OLMAYAN
//! bir nesneyi closure'ın retain etmesi → bellek bozulması) GERÇEK bir
//! risktir. Bunu ~10 analiz noktasına "metod mu?" bilgisi taşıyarak
//! çözmek yerine, değer konumundaki `ident.ad`ı SIRADAN bir çağrıya
//! (`__nox_bind_method(ident, "ad")`) yeniden yazarız — alıcı bir ÇAĞRI
//! ARGÜMANI olduğundan TÜM analizler onu ZATEN muhafazakâr (kaçış)
//! sayar. Gerçek ayrım (alan mı metod mu) checker VE codegen'de, tip
//! bilgisiyle yapılır: `ad` alanysa `__nox_bind_method` DÜZ alan okumasına
//! düşer (davranış AYNI, yalnızca alıcı daha muhafazakâr işlenir).
//!
//! **Yeniden yazılan şekil — DAR:** YALNIZCA değeri TÜKETİLEN bir konumdaki
//! (çağrı argümanı, atamanın sağı, `var_decl` değeri, `return`, liste/dict
//! elemanı, koşul, ...) `identifier.ad` ve `ad`, modüldeki HERHANGİ bir
//! sınıfın (`__` ile BAŞLAMAYAN) metod adı VE hiçbir sınıfın AÇIKÇA
//! bildirilmiş alan adı DEĞİL. Çağrının callee'si (`obj.m(...)`), başka bir
//! `.attribute`/`.index`nin alıcısı (`self.items.append(x)`: B.4'ün
//! şekli BOZULMAMALI) ve atama HEDEFİ ASLA yeniden yazılmaz.

const std = @import("std");
const ast = @import("../parser/ast.zig");

const Fixer = struct {
    allocator: std.mem.Allocator,
    method_names: std.StringHashMapUnmanaged(void) = .empty,
    field_names: std.StringHashMapUnmanaged(void) = .empty,
    rewrites: usize = 0,

    fn collect(self: *Fixer, stmts: []const ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |stmt| {
            switch (stmt.kind) {
                .class_def => |cd| {
                    for (cd.methods) |m| {
                        if (std.mem.startsWith(u8, m.name, "__")) continue;
                        try self.method_names.put(self.allocator, m.name, {});
                    }
                    for (cd.fields) |f| try self.field_names.put(self.allocator, f.name, {});
                },
                else => {},
            }
        }
    }

    /// Atama HEDEFİ olarak görülen HER `x.ad = ...` adı (`__init__`deki
    /// `self.ad = ...` ÇIKARSANAN alanları DAHİL) `field_names`e eklenir —
    /// bir ad herhangi bir yerde alan olarak atanıyorsa değer konumundaki
    /// `obj.ad` bir alan okuması OLABİLİR, yeniden YAZILMAZ. Bu sayede
    /// yeniden yazma YALNIZCA ad HİÇBİR YERDE alan olmayan (yani YALNIZCA
    /// metod olan) durumlarda olur.
    fn collectAssignedAttrs(self: *Fixer, stmts: []const ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |stmt| {
            switch (stmt.kind) {
                .assign => |a| if (a.target == .attribute) try self.field_names.put(self.allocator, a.target.attribute.attr, {}),
                .if_stmt => |s| {
                    try self.collectAssignedAttrs(s.then_body);
                    for (s.elif_clauses) |ec| try self.collectAssignedAttrs(ec.body);
                    if (s.else_body) |eb| try self.collectAssignedAttrs(eb);
                },
                .while_stmt => |s| try self.collectAssignedAttrs(s.body),
                .for_stmt => |s| try self.collectAssignedAttrs(s.body),
                .func_def => |fd| try self.collectAssignedAttrs(fd.body),
                .class_def => |cd| for (cd.methods) |m| try self.collectAssignedAttrs(m.body),
                .try_stmt => |s| {
                    try self.collectAssignedAttrs(s.try_body);
                    for (s.except_clauses) |ec| try self.collectAssignedAttrs(ec.body);
                    if (s.finally_body) |fb| try self.collectAssignedAttrs(fb);
                },
                .lowlevel_stmt => |s| try self.collectAssignedAttrs(s.body),
                .with_stmt => |s| try self.collectAssignedAttrs(s.body),
                else => {},
            }
        }
    }

    fn isMethodCandidate(self: *Fixer, name: []const u8) bool {
        // v1.142.11 (GPT-5.6 red-team): modül-global `field_names` dışlaması
        // KALDIRILDI — ilgisiz bir sınıfın aynı adlı ALANI, başka bir sınıfın
        // metodunun bağlı-değer olarak kullanımını reddettiriyordu
        // (`a.value` → "'A' sınıfının 'value' alanı yok"). Ayrım zaten
        // checker/codegen'de tip bilgisiyle yapılır: `ad` alanysa
        // `__nox_bind_method` düz alan okumasına düşer (bkz. üst belge notu).
        return self.method_names.contains(name);
    }

    fn fixStmts(self: *Fixer, stmts: []ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |*stmt| {
            switch (stmt.kind) {
                .expr_stmt => |*e| try self.fixExpr(e, false),
                .var_decl => |*v| try self.fixExpr(&v.value, true),
                .assign => |*a| {
                    try self.fixExpr(&a.target, false);
                    try self.fixExpr(&a.value, true);
                },
                .if_stmt => |*s| {
                    try self.fixExpr(&s.cond, true);
                    try self.fixStmts(s.then_body);
                    for (s.elif_clauses) |*ec| {
                        try self.fixExpr(&ec.cond, true);
                        try self.fixStmts(ec.body);
                    }
                    if (s.else_body) |eb| try self.fixStmts(eb);
                },
                .while_stmt => |*s| {
                    try self.fixExpr(&s.cond, true);
                    try self.fixStmts(s.body);
                },
                .for_stmt => |*s| {
                    try self.fixExpr(&s.iterable, true);
                    try self.fixStmts(s.body);
                },
                .func_def => |fd| try self.fixStmts(fd.body),
                .class_def => |cd| for (cd.methods) |m| try self.fixStmts(m.body),
                .return_stmt => |*maybe| if (maybe.*) |*e| try self.fixExpr(e, true),
                .raise_stmt => |*e| try self.fixExpr(e, true),
                .del_stmt => |*e| try self.fixExpr(e, true),
                .try_stmt => |*s| {
                    try self.fixStmts(s.try_body);
                    for (s.except_clauses) |ec| try self.fixStmts(ec.body);
                    if (s.finally_body) |fb| try self.fixStmts(fb);
                },
                .lowlevel_stmt => |s| try self.fixStmts(s.body),
                .with_stmt => |*s| {
                    try self.fixExpr(&s.ctx_expr, false);
                    try self.fixStmts(s.body);
                },
                .defer_stmt => |*d| for (d.call.args) |*a| try self.fixExpr(a, true),
                .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
            }
        }
    }

    /// `value_pos`: bu ifadenin DEĞERİ tüketiliyor mu (callee/alıcı/hedef
    /// DEĞİL).
    fn fixExpr(self: *Fixer, e: *ast.Expr, value_pos: bool) std.mem.Allocator.Error!void {
        switch (e.*) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |*u| try self.fixExpr(u.operand, true),
            .kwarg => |*k| try self.fixExpr(k.value, true),
            .ternary => |*t| {
                try self.fixExpr(t.cond, true);
                try self.fixExpr(t.then_expr, true);
                try self.fixExpr(t.else_expr, true);
            },
            .binary => |*b| {
                try self.fixExpr(b.left, true);
                try self.fixExpr(b.right, true);
            },
            .call => |*c| {
                try self.fixExpr(c.callee, false);
                for (c.args) |*a| try self.fixExpr(a, true);
            },
            .attribute => |*a| {
                try self.fixExpr(a.obj, false);
                if (value_pos and a.obj.* == .identifier and self.isMethodCandidate(a.attr)) {
                    const callee = try self.allocator.create(ast.Expr);
                    callee.* = .{ .identifier = "__nox_bind_method" };
                    const args = try self.allocator.alloc(ast.Expr, 2);
                    args[0] = a.obj.*;
                    args[1] = .{ .string_lit = a.attr };
                    self.rewrites += 1;
                    e.* = .{ .call = .{ .callee = callee, .args = args } };
                }
            },
            .index => |*ix| {
                try self.fixExpr(ix.obj, false);
                try self.fixExpr(ix.index, true);
            },
            .list_lit => |items| for (items) |*it| try self.fixExpr(it, true),
            .dict_lit => |pairs| for (pairs) |*p| {
                try self.fixExpr(&p.key, true);
                try self.fixExpr(&p.value, true);
            },
            .await_expr => |op| try self.fixExpr(op, false),
            .spawn_expr => |op| try self.fixExpr(op, false),
            .generic_construct => |*g| for (g.args) |*a| try self.fixExpr(a, true),
        }
    }
};

/// `body`yi YERİNDE yeniden yazar, yeniden yazılan ifade sayısını döner.
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt) std.mem.Allocator.Error!usize {
    var fixer: Fixer = .{ .allocator = allocator };
    defer fixer.method_names.deinit(allocator);
    defer fixer.field_names.deinit(allocator);
    try fixer.collect(body);
    try fixer.collectAssignedAttrs(body);
    if (fixer.method_names.count() == 0) return 0;
    try fixer.fixStmts(body);
    return fixer.rewrites;
}
