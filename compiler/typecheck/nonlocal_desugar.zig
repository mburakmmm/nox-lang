//! TODO 8.5: `nonlocal` — iç içe `def`in çevreleyen fonksiyonun değişkenine YAZMASI.
//!
//! Nox closure'ları değişkenleri DEĞER olarak yakalar (bkz. `ClosureInfo`); yazma bu yüzden desteklenmiyordu. `nonlocal x` gören
//! fonksiyonun sahibi (x'i parametre ya da `var_decl` ile bildiren en yakın çevreleyen fonksiyon) için `x` bir HÜCREYE
//! (tek elemanlı liste `__nl_x: list[T] = [v]`) çevrilir ve `x`in her kullanımı `__nl_x[0]` olur. Liste referansla yakalandığından
//! iç fonksiyonun yazması dışarıdan görünür; checker, sahiplik ve iki backend hiçbir yeni şey bilmez (sıradan liste + indeks).
//!
//! Kapsam: yalnızca iç içe `def`ler (sınıf metodları closure değildir). Hücreye alınan değişken `for` döngü değişkeni olamaz.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Diagnostic = struct { message: []const u8, line: u32 };

const Names = std.StringHashMapUnmanaged(void);

const Pass = struct {
    a: std.mem.Allocator,
    diag: ?Diagnostic = null,
    line: u32 = 0,

    fn fail(self: *Pass, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        if (self.diag == null) self.diag = .{ .message = try std.fmt.allocPrint(self.a, fmt, args), .line = self.line };
    }

    // ---- bildirilen adlar ----

    fn declaredStmts(self: *Pass, stmts: []const ast.Stmt, out: *Names) std.mem.Allocator.Error!void {
        for (stmts) |st| switch (st.kind) {
            .var_decl => |v| try out.put(self.a, v.name, {}),
            .for_stmt => |f| {
                try out.put(self.a, f.var_name, {});
                try self.declaredStmts(f.body, out);
            },
            .func_def => |fd| try out.put(self.a, fd.name, {}),
            .if_stmt => |s| {
                try self.declaredStmts(s.then_body, out);
                for (s.elif_clauses) |ec| try self.declaredStmts(ec.body, out);
                if (s.else_body) |eb| try self.declaredStmts(eb, out);
            },
            .while_stmt => |s| try self.declaredStmts(s.body, out),
            .try_stmt => |s| {
                try self.declaredStmts(s.try_body, out);
                for (s.except_clauses) |ec| {
                    if (ec.bind_name) |b| try out.put(self.a, b, {});
                    try self.declaredStmts(ec.body, out);
                }
                if (s.finally_body) |fb| try self.declaredStmts(fb, out);
            },
            .with_stmt => |s| {
                if (s.binding) |b| try out.put(self.a, b, {});
                try self.declaredStmts(s.body, out);
            },
            .lowlevel_stmt => |s| try self.declaredStmts(s.body, out),
            else => {},
        };
    }

    fn declared(self: *Pass, fd: *const ast.FuncDef) std.mem.Allocator.Error!Names {
        var out: Names = .empty;
        for (fd.params) |p| try out.put(self.a, p.name, {});
        try self.declaredStmts(fd.body, &out);
        // `nonlocal` ile bildirilen ad bu fonksiyonun YEREL değişkeni değildir (örn. `for x in ...` onu yeniden bağlamaz, hata verir).
        for (fd.nonlocals) |n| _ = out.remove(n);
        return out;
    }

    // ---- iç içe fonksiyonları bulma ----

    fn nestedDefs(self: *Pass, stmts: []ast.Stmt, out: *std.ArrayListUnmanaged(*ast.FuncDef)) std.mem.Allocator.Error!void {
        for (stmts) |*st| switch (st.kind) {
            .func_def => |*fd| try out.append(self.a, fd),
            .if_stmt => |*s| {
                try self.nestedDefs(s.then_body, out);
                for (s.elif_clauses) |*ec| try self.nestedDefs(ec.body, out);
                if (s.else_body) |eb| try self.nestedDefs(eb, out);
            },
            .while_stmt => |*s| try self.nestedDefs(s.body, out),
            .for_stmt => |*s| try self.nestedDefs(s.body, out),
            .try_stmt => |*s| {
                try self.nestedDefs(s.try_body, out);
                for (s.except_clauses) |*ec| try self.nestedDefs(ec.body, out);
                if (s.finally_body) |fb| try self.nestedDefs(fb, out);
            },
            .with_stmt => |*s| try self.nestedDefs(s.body, out),
            .lowlevel_stmt => |*s| try self.nestedDefs(s.body, out),
            else => {},
        };
    }

    /// `d`nin (kendi `nonlocal`ları + torunlarınınkiler) çözülmemiş adları; `d`nin kendi bildirdiği adlar düşülür.
    fn unresolved(self: *Pass, d: *ast.FuncDef, out: *Names) std.mem.Allocator.Error!void {
        var tmp: Names = .empty;
        for (d.nonlocals) |n| try tmp.put(self.a, n, {});
        var kids: std.ArrayListUnmanaged(*ast.FuncDef) = .empty;
        try self.nestedDefs(d.body, &kids);
        for (kids.items) |k| try self.unresolved(k, &tmp);
        const own = try self.declared(d);
        var it = tmp.keyIterator();
        while (it.next()) |k| {
            if (!own.contains(k.*)) try out.put(self.a, k.*, {});
        }
    }

    // ---- ana işlem ----

    fn processFunc(self: *Pass, fd: *ast.FuncDef, nested: bool) std.mem.Allocator.Error!void {
        var kids: std.ArrayListUnmanaged(*ast.FuncDef) = .empty;
        try self.nestedDefs(fd.body, &kids);
        var unres: Names = .empty;
        for (kids.items) |k| try self.unresolved(k, &unres);
        if (!nested) for (fd.nonlocals) |n| try unres.put(self.a, n, {});
        const own = try self.declared(fd);
        var it = unres.keyIterator();
        while (it.next()) |kp| {
            const x = kp.*;
            if (!own.contains(x)) {
                if (!nested) try self.fail("nonlocal '{s}': no binding for it was found in an enclosing function", .{x});
                continue;
            }
            const te = (try self.findType(fd, x)) orelse {
                try self.fail("the nonlocal variable '{s}' must be declared with an explicit type ('{s}: T = ...') or be a typed parameter", .{ x, x });
                continue;
            };
            try self.convertCell(fd, x, te);
        }
        if (self.diag != null) return;
        for (kids.items) |k| try self.processFunc(k, true);
    }

    fn findTypeIn(stmts: []const ast.Stmt, x: []const u8) ?ast.TypeExpr {
        for (stmts) |st| switch (st.kind) {
            .var_decl => |v| if (std.mem.eql(u8, v.name, x)) return v.type_expr,
            .if_stmt => |s| {
                if (findTypeIn(s.then_body, x)) |t| return t;
                for (s.elif_clauses) |ec| if (findTypeIn(ec.body, x)) |t| return t;
                if (s.else_body) |eb| if (findTypeIn(eb, x)) |t| return t;
            },
            .while_stmt => |s| if (findTypeIn(s.body, x)) |t| return t,
            .for_stmt => |s| if (findTypeIn(s.body, x)) |t| return t,
            .try_stmt => |s| {
                if (findTypeIn(s.try_body, x)) |t| return t;
                for (s.except_clauses) |ec| if (findTypeIn(ec.body, x)) |t| return t;
                if (s.finally_body) |fb| if (findTypeIn(fb, x)) |t| return t;
            },
            .with_stmt => |s| if (findTypeIn(s.body, x)) |t| return t,
            else => {},
        };
        return null;
    }

    fn findType(self: *Pass, fd: *const ast.FuncDef, x: []const u8) std.mem.Allocator.Error!?ast.TypeExpr {
        _ = self;
        for (fd.params) |p| if (std.mem.eql(u8, p.name, x)) return p.type_expr;
        const t = findTypeIn(fd.body, x) orelse return null;
        if (t == .simple and std.mem.eql(u8, t.simple, "__infer")) return null;
        return t;
    }

    fn cellName(self: *Pass, x: []const u8) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.a, "__nl_{s}", .{x});
    }

    fn listOf(self: *Pass, t: ast.TypeExpr) std.mem.Allocator.Error!ast.TypeExpr {
        const args = try self.a.alloc(ast.TypeExpr, 1);
        args[0] = t;
        return .{ .generic = .{ .name = "list", .args = args } };
    }

    fn convertCell(self: *Pass, fd: *ast.FuncDef, x: []const u8, te: ast.TypeExpr) std.mem.Allocator.Error!void {
        const cell = try self.cellName(x);
        var is_param = false;
        for (fd.params) |p| if (std.mem.eql(u8, p.name, x)) {
            is_param = true;
        };
        try self.rewriteStmts(fd.body, x, cell, te);
        if (is_param) {
            const items = try self.a.alloc(ast.Expr, 1);
            items[0] = .{ .identifier = x };
            const first = if (fd.body.len > 0) fd.body[0] else ast.Stmt{ .kind = .pass_stmt };
            const body = try self.a.alloc(ast.Stmt, fd.body.len + 1);
            body[0] = .{ .kind = .{ .var_decl = .{ .name = cell, .type_expr = try self.listOf(te), .value = .{ .list_lit = items } } }, .line = first.line, .span = first.span };
            @memcpy(body[1..], fd.body);
            fd.body = body;
        }
    }

    // ---- yeniden yazma ----

    fn box(self: *Pass, e: ast.Expr) std.mem.Allocator.Error!*ast.Expr {
        const p = try self.a.create(ast.Expr);
        p.* = e;
        return p;
    }

    fn shadows(self: *Pass, fd: *const ast.FuncDef, x: []const u8) std.mem.Allocator.Error!bool {
        const own = try self.declared(fd);
        return own.contains(x);
    }

    fn rewriteStmts(self: *Pass, stmts: []ast.Stmt, x: []const u8, cell: []const u8, te: ast.TypeExpr) std.mem.Allocator.Error!void {
        for (stmts) |*st| {
            self.line = st.line;
            switch (st.kind) {
                .expr_stmt => |*e| try self.rewriteExpr(e, x, cell),
                .var_decl => |*v| {
                    try self.rewriteExpr(&v.value, x, cell);
                    if (std.mem.eql(u8, v.name, x)) {
                        const items = try self.a.alloc(ast.Expr, 1);
                        items[0] = v.value;
                        v.name = cell;
                        v.type_expr = try self.listOf(te);
                        v.value = .{ .list_lit = items };
                    }
                },
                .assign => |*a| {
                    try self.rewriteExpr(&a.target, x, cell);
                    try self.rewriteExpr(&a.value, x, cell);
                },
                .if_stmt => |*s| {
                    try self.rewriteExpr(&s.cond, x, cell);
                    try self.rewriteStmts(s.then_body, x, cell, te);
                    for (s.elif_clauses) |*ec| {
                        try self.rewriteExpr(&ec.cond, x, cell);
                        try self.rewriteStmts(ec.body, x, cell, te);
                    }
                    if (s.else_body) |eb| try self.rewriteStmts(eb, x, cell, te);
                },
                .while_stmt => |*s| {
                    try self.rewriteExpr(&s.cond, x, cell);
                    try self.rewriteStmts(s.body, x, cell, te);
                },
                .for_stmt => |*s| {
                    if (std.mem.eql(u8, s.var_name, x)) {
                        try self.fail("the nonlocal variable '{s}' cannot also be a 'for' loop variable", .{x});
                        return;
                    }
                    try self.rewriteExpr(&s.iterable, x, cell);
                    try self.rewriteStmts(s.body, x, cell, te);
                },
                .func_def => |*fd| {
                    if (std.mem.eql(u8, fd.name, x) or try self.shadows(fd, x)) continue;
                    // Bu `def`in `nonlocal x` bildirimi çözüldü (hücre artık sahibinde): listeden düşer.
                    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
                    for (fd.nonlocals) |n| if (!std.mem.eql(u8, n, x)) try kept.append(self.a, n);
                    fd.nonlocals = try kept.toOwnedSlice(self.a);
                    try self.rewriteStmts(fd.body, x, cell, te);
                },
                .return_stmt => |*maybe| if (maybe.*) |*e| try self.rewriteExpr(e, x, cell),
                .raise_stmt => |*e| try self.rewriteExpr(e, x, cell),
                .del_stmt => |*e| try self.rewriteExpr(e, x, cell),
                .try_stmt => |*s| {
                    try self.rewriteStmts(s.try_body, x, cell, te);
                    for (s.except_clauses) |*ec| try self.rewriteStmts(ec.body, x, cell, te);
                    if (s.finally_body) |fb| try self.rewriteStmts(fb, x, cell, te);
                },
                .lowlevel_stmt => |*s| try self.rewriteStmts(s.body, x, cell, te),
                .with_stmt => |*s| {
                    try self.rewriteExpr(&s.ctx_expr, x, cell);
                    try self.rewriteStmts(s.body, x, cell, te);
                },
                .defer_stmt => |*d| {
                    try self.rewriteExpr(d.call.callee, x, cell);
                    for (d.call.args) |*a| try self.rewriteExpr(a, x, cell);
                },
                .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
            }
        }
    }

    fn rewriteExpr(self: *Pass, e: *ast.Expr, x: []const u8, cell: []const u8) std.mem.Allocator.Error!void {
        switch (e.*) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => {},
            .identifier => |n| if (std.mem.eql(u8, n, x)) {
                e.* = .{ .index = .{ .obj = try self.box(.{ .identifier = cell }), .index = try self.box(.{ .int_lit = 0 }) } };
            },
            .unary => |*u| try self.rewriteExpr(u.operand, x, cell),
            .kwarg => |*k| try self.rewriteExpr(k.value, x, cell),
            .ternary => |*t| {
                try self.rewriteExpr(t.cond, x, cell);
                try self.rewriteExpr(t.then_expr, x, cell);
                try self.rewriteExpr(t.else_expr, x, cell);
            },
            .binary => |*b| {
                try self.rewriteExpr(b.left, x, cell);
                try self.rewriteExpr(b.right, x, cell);
            },
            .call => |*c| {
                try self.rewriteExpr(c.callee, x, cell);
                for (c.args) |*a| try self.rewriteExpr(a, x, cell);
            },
            .attribute => |*a| try self.rewriteExpr(a.obj, x, cell),
            .list_comp => |*lc| {
                if (compShadows(lc.clauses, x)) return;
                try self.rewriteExpr(lc.elem, x, cell);
                for (lc.clauses) |*cl| switch (cl.*) {
                    .for_clause => |*fc| try self.rewriteExpr(&fc.iterable, x, cell),
                    .if_clause => |*ce| try self.rewriteExpr(ce, x, cell),
                };
            },
            .dict_comp => |*dc| {
                if (compShadows(dc.clauses, x)) return;
                try self.rewriteExpr(dc.key, x, cell);
                try self.rewriteExpr(dc.value, x, cell);
                for (dc.clauses) |*cl| switch (cl.*) {
                    .for_clause => |*fc| try self.rewriteExpr(&fc.iterable, x, cell),
                    .if_clause => |*ce| try self.rewriteExpr(ce, x, cell),
                };
            },
            .lambda => |*lam| {
                for (lam.params) |p| if (std.mem.eql(u8, p, x)) return;
                try self.rewriteExpr(lam.body, x, cell);
            },
            .slice => |*sl| {
                try self.rewriteExpr(sl.obj, x, cell);
                if (sl.lo) |v| try self.rewriteExpr(v, x, cell);
                if (sl.hi) |v| try self.rewriteExpr(v, x, cell);
                if (sl.step) |v| try self.rewriteExpr(v, x, cell);
            },
            .index => |*ix| {
                try self.rewriteExpr(ix.obj, x, cell);
                try self.rewriteExpr(ix.index, x, cell);
            },
            .list_lit => |items| for (items) |*it| try self.rewriteExpr(it, x, cell),
            .tuple_lit => |items| for (items) |*it| try self.rewriteExpr(it, x, cell),
            .dict_lit => |pairs| for (pairs) |*p| {
                try self.rewriteExpr(&p.key, x, cell);
                try self.rewriteExpr(&p.value, x, cell);
            },
            .await_expr => |op| try self.rewriteExpr(op, x, cell),
            .spawn_expr => |op| try self.rewriteExpr(op, x, cell),
            .generic_construct => |*g| for (g.args) |*a| try self.rewriteExpr(a, x, cell),
        }
    }

    fn compShadows(clauses: []const ast.CompClause, x: []const u8) bool {
        for (clauses) |cl| switch (cl) {
            .for_clause => |fc| if (std.mem.eql(u8, fc.var_name, x)) return true,
            .if_clause => {},
        };
        return false;
    }
};

/// Modülün TÜM fonksiyonlarını (üst-düzey + sınıf metodları) YERİNDE dönüştürür; hata varsa tanılamayı döner.
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt) std.mem.Allocator.Error!?Diagnostic {
    var pass: Pass = .{ .a = allocator };
    for (body) |*st| {
        pass.line = st.line;
        switch (st.kind) {
            .func_def => |*fd| try pass.processFunc(fd, false),
            .class_def => |*cd| for (cd.methods) |*m| try pass.processFunc(m, false),
            else => {},
        }
        if (pass.diag) |d| return d;
    }
    return null;
}
