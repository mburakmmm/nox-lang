//! Aether NOX_LIMITATIONS.md yol haritası, Faz C.6 (bkz. nox-teknik-
//! spesifikasyon.md ilgili bölüm, madde 14): `name[i](args)` belirsizliği.
//!
//! Parser (`parser.zig`nin `tryParseGenericConstructTail`ı) `name[...](...)`
//! kalıbını — `name` bir sembol tablosu OLMADAN ayırt EDİLEMEDİĞİNDEN —
//! HER ZAMAN `generic_construct` (`Box[int](3)` gibi) olarak ayrıştırır;
//! `funcs[i](y)` (bir closure listesini indeksleyip SONUCU çağırmak) bu
//! yüzden "bilinmeyen generic kurucu" hatasıyla reddediliyordu.
//!
//! Çözüm (checker geri-düşüşü, kullanıcı seçimi (b)): checker'ın sembol
//! tabloları (`generic_classes`) kurulduktan SONRA, asıl denetimden ÖNCE
//! bu geçiş AST'yi YERİNDE yeniden yazar — böylece sahiplik/kaçış/closure
//! analizi DAHİL aşağı akıştaki HİÇBİR geçiş yeniden yorumlamayı bilmek
//! ZORUNDA KALMAZ, hepsi sıradan bir `call(index(identifier, ...), args)`
//! görür.
//!
//! **Bir `generic_construct` YALNIZCA şu üç koşul BİRLİKTE sağlanırsa yeniden
//! yazılır** (aksi halde ESKİ davranış — ve hata mesajı — AYNEN korunur):
//!   1. TEK bir tip argümanı var VE bu bir indeks İFADESİNE çevrilebilir
//!      (çıplak isim, `a.b` yolu, ya da iç içe `idx[j]`) — `Box[int, str](..)`
//!      gibi virgüllü biçimler GERÇEK generic'tir (parser ZATEN `committed`),
//!   2. `name` TANINAN bir generic kurucu DEĞİL (`ptr`/`Channel`/
//!      `ThreadChannel`/`TaskLocal` + kullanıcı generic sınıfları),
//!   3. `name` modülde bir DEĞİŞKEN olarak bildirilmiş (var_decl/parametre/
//!      for/with/except bağlaması) — böylece bir generic sınıf adındaki
//!      YAZIM HATASI (`Boxx[int](3)`) "tanımsız değişken" yerine ESKİ,
//!      daha net "bilinmeyen generic kurucu" hatasını VERMEYE devam eder.

const std = @import("std");
const ast = @import("../parser/ast.zig");

/// `checkGenericConstruct`in `.generic_classes`e BAKMADAN tanıdığı
/// yerleşik generic kurucu adları — o fonksiyondaki `std.mem.eql(g.name,
/// ...)` kontrolleriyle AYNI küme.
const BUILTIN_GENERIC_NAMES = [_][]const u8{ "ptr", "Channel", "ThreadChannel", "TaskLocal" };

const Fixer = struct {
    allocator: std.mem.Allocator,
    generic_names: *const std.StringHashMapUnmanaged(void),
    var_names: std.StringHashMapUnmanaged(void) = .empty,
    rewrites: usize = 0,

    // ---- Geçiş 1: modülde değişken olarak bildirilen adlar ----------------

    fn collectParams(self: *Fixer, params: []const ast.Param) std.mem.Allocator.Error!void {
        for (params) |p| try self.var_names.put(self.allocator, p.name, {});
    }

    fn collectFunc(self: *Fixer, fd: ast.FuncDef) std.mem.Allocator.Error!void {
        try self.collectParams(fd.params);
        try self.collectVars(fd.body);
    }

    fn collectVars(self: *Fixer, stmts: []const ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |stmt| {
            switch (stmt.kind) {
                .var_decl => |v| try self.var_names.put(self.allocator, v.name, {}),
                .for_stmt => |s| {
                    try self.var_names.put(self.allocator, s.var_name, {});
                    try self.collectVars(s.body);
                },
                .with_stmt => |s| {
                    if (s.binding) |b| try self.var_names.put(self.allocator, b, {});
                    try self.collectVars(s.body);
                },
                .try_stmt => |s| {
                    try self.collectVars(s.try_body);
                    for (s.except_clauses) |ec| {
                        if (ec.bind_name) |b| try self.var_names.put(self.allocator, b, {});
                        try self.collectVars(ec.body);
                    }
                    if (s.finally_body) |fb| try self.collectVars(fb);
                },
                .if_stmt => |s| {
                    try self.collectVars(s.then_body);
                    for (s.elif_clauses) |ec| try self.collectVars(ec.body);
                    if (s.else_body) |eb| try self.collectVars(eb);
                },
                .while_stmt => |s| try self.collectVars(s.body),
                .lowlevel_stmt => |s| try self.collectVars(s.body),
                .func_def => |fd| try self.collectFunc(fd),
                .class_def => |cd| for (cd.methods) |m| try self.collectFunc(m),
                .expr_stmt, .assign, .protocol_def, .extern_def, .return_stmt, .raise_stmt, .del_stmt, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt, .defer_stmt => {},
            }
        }
    }

    // ---- Geçiş 2: yerinde yeniden yazma --------------------------------

    fn fixStmts(self: *Fixer, stmts: []ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |*stmt| {
            switch (stmt.kind) {
                .expr_stmt => |*e| try self.fixExpr(e),
                .var_decl => |*v| try self.fixExpr(&v.value),
                .assign => |*a| {
                    try self.fixExpr(&a.target);
                    try self.fixExpr(&a.value);
                },
                .if_stmt => |*s| {
                    try self.fixExpr(&s.cond);
                    try self.fixStmts(s.then_body);
                    for (s.elif_clauses) |*ec| {
                        try self.fixExpr(&ec.cond);
                        try self.fixStmts(ec.body);
                    }
                    if (s.else_body) |eb| try self.fixStmts(eb);
                },
                .while_stmt => |*s| {
                    try self.fixExpr(&s.cond);
                    try self.fixStmts(s.body);
                },
                .for_stmt => |*s| {
                    try self.fixExpr(&s.iterable);
                    try self.fixStmts(s.body);
                },
                .func_def => |fd| try self.fixStmts(fd.body),
                .class_def => |cd| for (cd.methods) |m| try self.fixStmts(m.body),
                .return_stmt => |*maybe| if (maybe.*) |*e| try self.fixExpr(e),
                .raise_stmt => |*e| try self.fixExpr(e),
                .del_stmt => |*e| try self.fixExpr(e),
                .try_stmt => |*s| {
                    try self.fixStmts(s.try_body);
                    for (s.except_clauses) |ec| try self.fixStmts(ec.body);
                    if (s.finally_body) |fb| try self.fixStmts(fb);
                },
                .lowlevel_stmt => |s| try self.fixStmts(s.body),
                .with_stmt => |*s| {
                    try self.fixExpr(&s.ctx_expr);
                    try self.fixStmts(s.body);
                },
                // `defer f(x)`: `call.callee` pointer kimliği `defer_synthetic_names`
                // anahtarıdır — YENİDEN YAZILMAZ; argümanları gezilir.
                .defer_stmt => |*d| for (d.call.args) |*a| try self.fixExpr(a),
                .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
            }
        }
    }

    fn fixExpr(self: *Fixer, e: *ast.Expr) std.mem.Allocator.Error!void {
        switch (e.*) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |*u| try self.fixExpr(u.operand),
            .kwarg => |*k| try self.fixExpr(k.value),
            .ternary => |*t| {
                try self.fixExpr(t.cond);
                try self.fixExpr(t.then_expr);
                try self.fixExpr(t.else_expr);
            },
            .binary => |*b| {
                try self.fixExpr(b.left);
                try self.fixExpr(b.right);
            },
            .call => |*c| {
                try self.fixExpr(c.callee);
                for (c.args) |*a| try self.fixExpr(a);
            },
            .attribute => |*a| try self.fixExpr(a.obj),
            .list_comp => |*lc| {
                try self.fixExpr(lc.elem);
                for (lc.clauses) |*cl| switch (cl.*) {
                    .for_clause => |*fc| try self.fixExpr(&fc.iterable),
                    .if_clause => |*ce| try self.fixExpr(ce),
                };
            },
            .dict_comp => |*dc| {
                try self.fixExpr(dc.key);
                try self.fixExpr(dc.value);
                for (dc.clauses) |*cl| switch (cl.*) {
                    .for_clause => |*fc| try self.fixExpr(&fc.iterable),
                    .if_clause => |*ce| try self.fixExpr(ce),
                };
            },
            .lambda => |*lam| {
                try self.fixExpr(lam.body);
            },
            .slice => |*sl| {
                try self.fixExpr(sl.obj);
                if (sl.lo) |x| try self.fixExpr(x);
                if (sl.hi) |x| try self.fixExpr(x);
                if (sl.step) |x| try self.fixExpr(x);
            },
            .index => |*ix| {
                try self.fixExpr(ix.obj);
                try self.fixExpr(ix.index);
            },
            .list_lit => |items| for (items) |*it| try self.fixExpr(it),
            .dict_lit => |pairs| for (pairs) |*p| {
                try self.fixExpr(&p.key);
                try self.fixExpr(&p.value);
            },
            .await_expr => |op| try self.fixExpr(op),
            .spawn_expr => |op| try self.fixExpr(op),
            .generic_construct => |*g| {
                for (g.args) |*a| try self.fixExpr(a);
                if (try self.rewrite(g.*)) |new_expr| {
                    self.rewrites += 1;
                    e.* = new_expr;
                }
            },
        }
    }

    /// Üç koşul sağlanırsa `call(index(identifier(name), idx), args)` döner.
    fn rewrite(self: *Fixer, g: ast.GenericConstruct) std.mem.Allocator.Error!?ast.Expr {
        if (g.type_args.len != 1) return null;
        for (BUILTIN_GENERIC_NAMES) |b| {
            if (std.mem.eql(u8, g.name, b)) return null;
        }
        if (self.generic_names.contains(g.name)) return null;
        if (!self.var_names.contains(g.name)) return null;
        const idx_expr = (try self.typeExprToIndexExpr(g.type_args[0])) orelse return null;

        const obj = try self.allocator.create(ast.Expr);
        obj.* = .{ .identifier = g.name };
        const idx = try self.allocator.create(ast.Expr);
        idx.* = idx_expr;
        const callee = try self.allocator.create(ast.Expr);
        callee.* = .{ .index = .{ .obj = obj, .index = idx } };
        return .{ .call = .{ .callee = callee, .args = g.args } };
    }

    /// Parser'ın bir indeks İFADESİNİ (`i`, `a.b`, `idx[j]`) tip ifadesi
    /// olarak ayrıştırdığı şekli, tekrar bir ifadeye çevirir; başka
    /// şekiller (`list[int, str]`, `(int) -> int`, `T | None`) için `null`.
    fn typeExprToIndexExpr(self: *Fixer, te: ast.TypeExpr) std.mem.Allocator.Error!?ast.Expr {
        switch (te) {
            .simple => |n| return .{ .identifier = n },
            .qualified => |segs| {
                if (segs.len < 2) return null;
                var cur: ast.Expr = .{ .identifier = segs[0] };
                for (segs[1..]) |seg| {
                    const obj = try self.allocator.create(ast.Expr);
                    obj.* = cur;
                    cur = .{ .attribute = .{ .obj = obj, .attr = seg } };
                }
                return cur;
            },
            .generic => |g| {
                if (g.args.len != 1) return null;
                const inner = (try self.typeExprToIndexExpr(g.args[0])) orelse return null;
                const obj = try self.allocator.create(ast.Expr);
                obj.* = .{ .identifier = g.name };
                const idx = try self.allocator.create(ast.Expr);
                idx.* = inner;
                return .{ .index = .{ .obj = obj, .index = idx } };
            },
            .func_type, .optional => return null,
        }
    }
};

/// `body`yi YERİNDE yeniden yazar, yeniden yazılan `generic_construct`
/// sayısını döner. `generic_names`: tanınan kullanıcı generic sınıf adları
/// (from-import takma adları DAHİL).
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt, generic_names: *const std.StringHashMapUnmanaged(void)) std.mem.Allocator.Error!usize {
    var fixer: Fixer = .{ .allocator = allocator, .generic_names = generic_names };
    defer fixer.var_names.deinit(allocator);
    try fixer.collectVars(body);
    try fixer.fixStmts(body);
    return fixer.rewrites;
}
