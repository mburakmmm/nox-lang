//! TODO 8.6: `yield` / `yield from` — TEMBEL jeneratörler (checker'dan ÖNCE, AST üzerinde durum makinesine dönüşüm).
//!
//! İçinde `yield` geçen bir fonksiyon (`-> Iterator[T]` / `Generator[T]`, prelude'daki `__nox_Gen[T]`) şuna çevrilir:
//!
//!     def f(params) -> Iterator[T]:
//!         <hücreler>                       # yields boyunca yaşayan yerel değişkenler, program sayaçları (pc), seçiciler
//!         def __nox_step() -> T | None:    # her çağrı bir SONRAKİ değeri üretir (bitince None)
//!             ...durum makinesi...
//!         return __nox_gen_from_step(__nox_step)
//!
//! Hücre = tek elemanlı liste (`[v]`): kapanışlar listeyi referansla yakaladığından adımlar arası durum korunur. Sayaçlar yeniden-giriş
//! protokolünü taşır: her "yield içeren deyim listesi" kendi `pc` hücresine sahiptir; `pc == 0` taze başlangıç, `2*i+1` "i. deyimin
//! İÇİNDE sürdür", `2*i+2` "i. deyimden SONRA sürdür" demektir. Her deyim `pc <= 2*i+1` ile korunur; `yield` çevreleyen listelerin
//! sayaçlarını yazıp `return değer` eder. `while`/`for` döngüleri gövde sayacı sıfırdan farklıyken koşulu/yineleyiciyi YENİDEN
//! değerlendirmeden gövdeye girer; `if` seçili kolu bir seçici hücresinde tutar. `break`/`continue` çıktıkları listelerin sayaçlarını sıfırlar.
//!
//! Adım başında `done` işaretlenir ve yalnızca `yield` temizler: istisna fırlatan ya da biten bir jeneratör bir daha değer üretmez.
//! Yerel değişkenin tipi biliniyorsa (`x: T = ...`) tipli hücre; bilinmiyorsa (`for` değişkeni, tuple açma) checker'a `__nox_cell_of` ile
//! sorulur. Sınırlar (hata verir): `try`/`with`/`lowlevel` içinde `yield`, `async def`, generic jeneratör, `return değer`.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Diagnostic = struct { message: []const u8, line: u32 };

const Error = std.mem.Allocator.Error;

/// `slot`: hücre `list[__nox_Slot[T]]`; değer `hücre[0].v` ile okunur/yazılır (`T | None` skaler yereller için).
const Binding = struct { cell: []const u8, boxed: bool, slot: bool = false };
const Scope = std.StringHashMapUnmanaged(?Binding);

const Frame = struct {
    pc: ?[]const u8,
    sel: ?[]const u8 = null,
    is_loop: bool = false,
};

const Ctx = struct { top: bool, loop_depth: u32 = 0 };

const Pass = struct {
    a: std.mem.Allocator,
    diag: ?Diagnostic = null,
    line: u32 = 0,
    uid: u32 = 0,
    prelude: std.ArrayListUnmanaged(ast.Stmt) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    idxs: std.ArrayListUnmanaged(usize) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    ytype: ast.TypeExpr = .{ .simple = "int" },
    done: []const u8 = "",
    /// Etkin listelerin doğrudan elemanı olan iç içe `def`ler: her adımda tanımlı olmaları için adım başına taşınır.
    lifted: std.ArrayListUnmanaged(ast.Stmt) = .empty,

    fn fail(self: *Pass, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.diag == null) self.diag = .{ .message = try std.fmt.allocPrint(self.a, fmt, args), .line = self.line };
    }

    // ---- yield tespiti ----

    fn isYield(e: ast.Expr) ?[]const u8 {
        if (e == .call and e.call.callee.* == .identifier and e.call.args.len == 1) {
            const n = e.call.callee.identifier;
            if (std.mem.eql(u8, n, "__nox_yield") or std.mem.eql(u8, n, "__nox_yield_from")) return n;
        }
        return null;
    }

    fn listHasYield(stmts: []const ast.Stmt) bool {
        for (stmts) |st| if (stmtHasYield(st)) return true;
        return false;
    }

    fn stmtHasYield(st: ast.Stmt) bool {
        return switch (st.kind) {
            .expr_stmt => |e| isYield(e) != null,
            .if_stmt => |s| blk: {
                if (listHasYield(s.then_body)) break :blk true;
                for (s.elif_clauses) |ec| if (listHasYield(ec.body)) break :blk true;
                if (s.else_body) |eb| if (listHasYield(eb)) break :blk true;
                break :blk false;
            },
            .while_stmt => |s| listHasYield(s.body),
            .for_stmt => |s| listHasYield(s.body),
            .try_stmt => |s| blk: {
                if (listHasYield(s.try_body)) break :blk true;
                for (s.except_clauses) |ec| if (listHasYield(ec.body)) break :blk true;
                if (s.finally_body) |fb| if (listHasYield(fb)) break :blk true;
                break :blk false;
            },
            .with_stmt => |s| listHasYield(s.body),
            .lowlevel_stmt => |s| listHasYield(s.body),
            else => false,
        };
    }

    /// `try`/`with`/`lowlevel` içinde yield var mı (desteklenmez)?
    fn unsupportedYield(self: *Pass, stmts: []const ast.Stmt) Error!void {
        for (stmts) |st| {
            self.line = st.line;
            switch (st.kind) {
                .try_stmt => |s| if (stmtHasYield(st)) {
                    _ = s;
                    try self.fail("'yield' inside 'try' is not supported in a generator (it runs as a resumable state machine); move the 'try' around code without 'yield'", .{});
                },
                .with_stmt => if (stmtHasYield(st)) try self.fail("'yield' inside 'with' is not supported in a generator; move the 'with' around code without 'yield'", .{}),
                .lowlevel_stmt => if (stmtHasYield(st)) try self.fail("'yield' inside 'lowlevel' is not supported in a generator", .{}),
                .if_stmt => |s| {
                    try self.unsupportedYield(s.then_body);
                    for (s.elif_clauses) |ec| try self.unsupportedYield(ec.body);
                    if (s.else_body) |eb| try self.unsupportedYield(eb);
                },
                .while_stmt => |s| try self.unsupportedYield(s.body),
                .for_stmt => |s| try self.unsupportedYield(s.body),
                else => {},
            }
        }
    }

    // ---- AST kurucuları ----

    fn box(self: *Pass, e: ast.Expr) Error!*ast.Expr {
        const p = try self.a.create(ast.Expr);
        p.* = e;
        return p;
    }

    fn id(name: []const u8) ast.Expr {
        return .{ .identifier = name };
    }

    fn idx0(self: *Pass, cell: []const u8) Error!ast.Expr {
        return .{ .index = .{ .obj = try self.box(id(cell)), .index = try self.box(.{ .int_lit = 0 }) } };
    }

    fn call1(self: *Pass, name: []const u8, arg: ast.Expr) Error!ast.Expr {
        const args = try self.a.alloc(ast.Expr, 1);
        args[0] = arg;
        return .{ .call = .{ .callee = try self.box(id(name)), .args = args } };
    }

    fn bin(self: *Pass, op: ast.BinaryOp, l: ast.Expr, r: ast.Expr) Error!ast.Expr {
        return .{ .binary = .{ .op = op, .left = try self.box(l), .right = try self.box(r) } };
    }

    fn stmt(self: *Pass, kind: ast.StmtKind) ast.Stmt {
        return .{ .kind = kind, .line = self.line };
    }

    fn assign(self: *Pass, target: ast.Expr, value: ast.Expr) ast.Stmt {
        return self.stmt(.{ .assign = .{ .target = target, .value = value } });
    }

    fn setCell(self: *Pass, cell: []const u8, v: i64) Error!ast.Stmt {
        return self.assign(try self.idx0(cell), .{ .int_lit = v });
    }

    fn ifStmt(self: *Pass, cond: ast.Expr, body: []ast.Stmt) ast.Stmt {
        return self.stmt(.{ .if_stmt = .{ .cond = cond, .then_body = body, .elif_clauses = &.{}, .else_body = null } });
    }

    fn newName(self: *Pass, base: []const u8) Error![]const u8 {
        self.uid += 1;
        return std.fmt.allocPrint(self.a, "__g_{s}_{d}", .{ base, self.uid });
    }

    fn listOf(self: *Pass, t: ast.TypeExpr) Error!ast.TypeExpr {
        const args = try self.a.alloc(ast.TypeExpr, 1);
        args[0] = t;
        return .{ .generic = .{ .name = "list", .args = args } };
    }

    fn optionalOf(self: *Pass, t: ast.TypeExpr) Error!ast.TypeExpr {
        const p = try self.a.create(ast.TypeExpr);
        p.* = t;
        return .{ .optional = p };
    }

    // ---- hücreler ----

    /// `name: list[int] = [v]` hücresini önbilgiye ekler.
    fn intCell(self: *Pass, base: []const u8, v: i64) Error![]const u8 {
        const name = try self.newName(base);
        const items = try self.a.alloc(ast.Expr, 1);
        items[0] = .{ .int_lit = v };
        try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = name, .type_expr = try self.listOf(.{ .simple = "int" }), .value = .{ .list_lit = items } } }));
        return name;
    }

    fn boolCell(self: *Pass, base: []const u8, v: bool) Error![]const u8 {
        const name = try self.newName(base);
        const items = try self.a.alloc(ast.Expr, 1);
        items[0] = .{ .bool_lit = v };
        try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = name, .type_expr = try self.listOf(.{ .simple = "bool" }), .value = .{ .list_lit = items } } }));
        return name;
    }

    fn isFixedIntName(n: []const u8) bool {
        const names = [_][]const u8{ "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64" };
        for (names) |x| if (std.mem.eql(u8, x, n)) return true;
        return false;
    }

    fn zeroFor(t: ast.TypeExpr) ?ast.Expr {
        if (t != .simple) return null;
        const n = t.simple;
        if (std.mem.eql(u8, n, "int")) return .{ .int_lit = 0 };
        if (std.mem.eql(u8, n, "float")) return .{ .float_lit = 0.0 };
        if (std.mem.eql(u8, n, "bool")) return .{ .bool_lit = false };
        if (std.mem.eql(u8, n, "str")) return .{ .string_lit = "" };
        return null;
    }

    /// Tipi bilinen bir değişken için hücre: ilkel tipler düz, Optional olanlar doğrudan, diğerleri `T | None` kutulu.
    fn typedCell(self: *Pass, name: []const u8, t: ast.TypeExpr) Error!Binding {
        const cell = try self.newName(name);
        if (t == .func_type) {
            try self.fail("variable '{s}' has a function type and cannot be kept across a 'yield'", .{name});
            return .{ .cell = cell, .boxed = false };
        }
        if (t == .generic and (std.mem.eql(u8, t.generic.name, "list") or std.mem.eql(u8, t.generic.name, "dict"))) {
            // `append`/indeksli yazma alıcısı bir değişken ya da `hücre[0]` olmalı: düz hücre, iç içe boş literal başlangıcı
            const items = try self.a.alloc(ast.Expr, 1);
            items[0] = if (std.mem.eql(u8, t.generic.name, "list")) .{ .list_lit = &.{} } else .{ .dict_lit = &.{} };
            try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = cell, .type_expr = try self.listOf(t), .value = .{ .list_lit = items } } }));
            return .{ .cell = cell, .boxed = false };
        }
        if (zeroFor(t)) |z| {
            const items = try self.a.alloc(ast.Expr, 1);
            items[0] = z;
            try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = cell, .type_expr = try self.listOf(t), .value = .{ .list_lit = items } } }));
            return .{ .cell = cell, .boxed = false };
        }
        if (t == .optional and zeroFor(t.optional.*) != null or (t == .optional and t.optional.* == .simple and isFixedIntName(t.optional.simple))) {
            // `T | None` skaler: yuva sınıfı (liste elemanı olarak kutulu skaler desteklenmez)
            const nn0 = try self.newName("none");
            try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = nn0, .type_expr = t, .value = .none_lit } }));
            const inner = try self.a.alloc(ast.TypeExpr, 1);
            inner[0] = t.optional.*;
            const slot_t: ast.TypeExpr = .{ .generic = .{ .name = "__nox_Slot", .args = inner } };
            const ctor_args = try self.a.alloc(ast.Expr, 1);
            ctor_args[0] = id(nn0);
            const resolved = try self.a.create(?[]const u8);
            resolved.* = null;
            const ctor: ast.Expr = .{ .generic_construct = .{ .name = "__nox_Slot", .type_args = inner, .args = ctor_args, .resolved_class_name = resolved } };
            const items0 = try self.a.alloc(ast.Expr, 1);
            items0[0] = ctor;
            try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = cell, .type_expr = try self.listOf(slot_t), .value = .{ .list_lit = items0 } } }));
            return .{ .cell = cell, .boxed = false, .slot = true };
        }
        const opt_t = if (t == .optional) t else try self.optionalOf(t);
        const nn = try self.newName("none");
        try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = nn, .type_expr = opt_t, .value = .none_lit } }));
        const items = try self.a.alloc(ast.Expr, 1);
        items[0] = id(nn);
        try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = cell, .type_expr = try self.listOf(opt_t), .value = .{ .list_lit = items } } }));
        return .{ .cell = cell, .boxed = t != .optional };
    }

    /// Tipi YALNIZCA checker'ın bildiği değişken (döngü değişkeni, tuple açma): `__nox_cell_of(kaynak)` ile kutulu hücre.
    fn inferredCell(self: *Pass, name: []const u8, source: ast.Expr) Error!Binding {
        const cell = try self.newName(name);
        try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = cell, .type_expr = .{ .simple = "__infer" }, .value = try self.call1("__nox_cell_of", source) } }));
        return .{ .cell = cell, .boxed = true };
    }

    // ---- kapsamlar ----

    fn pushScope(self: *Pass) Error!void {
        try self.scopes.append(self.a, .empty);
    }

    fn popScope(self: *Pass) void {
        _ = self.scopes.pop();
    }

    fn bind(self: *Pass, name: []const u8, b: ?Binding) Error!void {
        try self.scopes.items[self.scopes.items.len - 1].put(self.a, name, b);
    }

    fn lookup(self: *Pass, name: []const u8) ?Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |b| return b;
        }
        return null;
    }

    // ---- ifade yeniden adlandırma ----

    fn readOf(self: *Pass, b: Binding) Error!ast.Expr {
        // kutulu hücre: okuma, hücre elemanının Optional olup olmadığına göre checker'da (`__nox_get`) çözülür
        if (b.slot) return self.slotValue(b);
        return if (b.boxed) try self.call1("__nox_get", id(b.cell)) else try self.idx0(b.cell);
    }

    fn slotValue(self: *Pass, b: Binding) Error!ast.Expr {
        return .{ .attribute = .{ .obj = try self.box(try self.idx0(b.cell)), .attr = "v" } };
    }

    /// Bir değişkene ATAMA hedefi (`x = v` → `hücre[0]` ya da yuva için `hücre[0].v`).
    fn writeTarget(self: *Pass, b: Binding) Error!ast.Expr {
        return if (b.slot) try self.slotValue(b) else try self.idx0(b.cell);
    }

    fn rename(self: *Pass, e: *ast.Expr) Error!void {
        switch (e.*) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => {},
            .identifier => |n| if (self.lookup(n)) |b| {
                e.* = try self.readOf(b);
            },
            .unary => |*u| try self.rename(u.operand),
            .kwarg => |*k| try self.rename(k.value),
            .ternary => |*t| {
                try self.rename(t.cond);
                try self.rename(t.then_expr);
                try self.rename(t.else_expr);
            },
            .binary => |*b| {
                try self.rename(b.left);
                try self.rename(b.right);
            },
            .call => |*c| {
                try self.rename(c.callee);
                for (c.args) |*a| try self.rename(a);
            },
            .attribute => |*a| try self.rename(a.obj),
            .list_comp => |*lc| try self.renameComp(lc.clauses, &.{lc.elem}),
            .dict_comp => |*dc| try self.renameComp(dc.clauses, &.{ dc.key, dc.value }),
            .lambda => |*lam| {
                try self.pushScope();
                defer self.popScope();
                for (lam.params) |p| try self.bind(p, null);
                try self.rename(lam.body);
            },
            .slice => |*sl| {
                try self.rename(sl.obj);
                if (sl.lo) |v| try self.rename(v);
                if (sl.hi) |v| try self.rename(v);
                if (sl.step) |v| try self.rename(v);
            },
            .index => |*ix| {
                try self.rename(ix.obj);
                try self.rename(ix.index);
            },
            .list_lit => |items| for (items) |*it| try self.rename(it),
            .tuple_lit => |items| for (items) |*it| try self.rename(it),
            .dict_lit => |pairs| for (pairs) |*p| {
                try self.rename(&p.key);
                try self.rename(&p.value);
            },
            .await_expr => |op| try self.rename(op),
            .spawn_expr => |op| try self.rename(op),
            .generic_construct => |*g| for (g.args) |*a| try self.rename(a),
        }
    }

    fn renameComp(self: *Pass, clauses: []ast.CompClause, bodies: []const *ast.Expr) Error!void {
        try self.pushScope();
        defer self.popScope();
        for (clauses) |*cl| switch (cl.*) {
            .for_clause => |*fc| {
                try self.rename(&fc.iterable);
                try self.bind(fc.var_name, null);
            },
            .if_clause => |*ce| try self.rename(ce),
        };
        for (bodies) |b| try self.rename(b);
    }

    // ---- düz (yield içermeyen) deyimler ----

    /// `break`/`continue` çıkışında sıfırlanacak sayaç/seçiciler (en içteki döngü çerçevesine kadar, o dahil).
    fn jumpResets(self: *Pass, out: *std.ArrayListUnmanaged(ast.Stmt)) Error!void {
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const f = self.frames.items[i];
            if (f.pc) |pc| try out.append(self.a, try self.setCell(pc, 0));
            if (f.sel) |sel| try out.append(self.a, try self.setCell(sel, 0));
            if (f.is_loop) return;
        }
    }

    fn plainBlock(self: *Pass, stmts: []ast.Stmt, ctx: Ctx) Error![]ast.Stmt {
        try self.pushScope();
        defer self.popScope();
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        for (stmts) |st| try self.plainStmt(st, ctx, &out, false);
        return out.toOwnedSlice(self.a);
    }

    /// `hoist`: bu deyim aktif bir listenin DOĞRUDAN elemanı (var_decl'ler yields boyunca yaşasın diye hücreye alınır).
    fn plainStmt(self: *Pass, st_in: ast.Stmt, ctx: Ctx, out: *std.ArrayListUnmanaged(ast.Stmt), hoist: bool) Error!void {
        var st = st_in;
        self.line = st.line;
        switch (st.kind) {
            .expr_stmt => |*e| try self.rename(e),
            .var_decl => |*v| {
                try self.rename(&v.value);
                if (hoist) {
                    const b = if (v.type_expr == .simple and std.mem.eql(u8, v.type_expr.simple, "__infer"))
                        try self.inferredCell(v.name, v.value)
                    else
                        try self.typedCell(v.name, v.type_expr);
                    try self.bind(v.name, b);
                    if (v.type_expr == .simple and std.mem.eql(u8, v.type_expr.simple, "__infer")) {
                        try out.append(self.a, .{ .kind = .{ .assign = .{ .target = try self.writeTarget(b), .value = v.value } }, .line = st.line, .span = st.span });
                    } else {
                        // beklenen tip gereken değerler (`[]`, `{}`, `None`, lambda) için tipli geçici üzerinden atama
                        const tmp = try self.newName("tmp");
                        try out.append(self.a, .{ .kind = .{ .var_decl = .{ .name = tmp, .type_expr = v.type_expr, .value = v.value } }, .line = st.line, .span = st.span });
                        try out.append(self.a, .{ .kind = .{ .assign = .{ .target = try self.writeTarget(b), .value = id(tmp) } }, .line = st.line, .span = st.span });
                    }
                    return;
                }
                try self.bind(v.name, null);
            },
            .assign => |*a| {
                if (a.target == .identifier) {
                    if (self.lookup(a.target.identifier)) |b| a.target = try self.writeTarget(b);
                } else try self.rename(&a.target);
                try self.rename(&a.value);
            },
            .if_stmt => |*s| {
                try self.rename(&s.cond);
                s.then_body = try self.plainBlock(s.then_body, ctx);
                for (s.elif_clauses) |*ec| {
                    try self.rename(&ec.cond);
                    ec.body = try self.plainBlock(ec.body, ctx);
                }
                if (s.else_body) |eb| s.else_body = try self.plainBlock(eb, ctx);
            },
            .while_stmt => |*s| {
                try self.rename(&s.cond);
                s.body = try self.plainBlock(s.body, .{ .top = ctx.top, .loop_depth = ctx.loop_depth + 1 });
            },
            .for_stmt => |*s| {
                try self.rename(&s.iterable);
                try self.pushScope();
                defer self.popScope();
                try self.bind(s.var_name, null);
                s.body = try self.plainBlock(s.body, .{ .top = ctx.top, .loop_depth = ctx.loop_depth + 1 });
            },
            .break_stmt, .continue_stmt => {
                if (ctx.top and ctx.loop_depth == 0) try self.jumpResets(out);
            },
            .return_stmt => |*maybe| {
                if (ctx.top) {
                    if (maybe.* != null) {
                        try self.fail("a generator ('yield') cannot 'return' a value", .{});
                        return;
                    }
                    maybe.* = .none_lit;
                } else if (maybe.*) |*e| try self.rename(e);
            },
            .raise_stmt => |*e| try self.rename(e),
            .del_stmt => |*e| try self.rename(e),
            .try_stmt => |*s| {
                s.try_body = try self.plainBlock(s.try_body, ctx);
                for (s.except_clauses) |*ec| {
                    try self.pushScope();
                    defer self.popScope();
                    if (ec.bind_name) |bn| try self.bind(bn, null);
                    ec.body = try self.plainBlock(ec.body, ctx);
                }
                if (s.finally_body) |fb| s.finally_body = try self.plainBlock(fb, ctx);
            },
            .with_stmt => |*s| {
                try self.rename(&s.ctx_expr);
                try self.pushScope();
                defer self.popScope();
                if (s.binding) |bn| try self.bind(bn, null);
                s.body = try self.plainBlock(s.body, ctx);
            },
            .lowlevel_stmt => |*s| s.body = try self.plainBlock(s.body, ctx),
            .defer_stmt => |*d| {
                try self.rename(d.call.callee);
                for (d.call.args) |*a| try self.rename(a);
            },
            .func_def => |*fd| {
                try self.bind(fd.name, null);
                try self.pushScope();
                defer self.popScope();
                for (fd.params) |p| try self.bind(p.name, null);
                fd.body = try self.plainBlock(fd.body, .{ .top = false });
            },
            .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt => {},
        }
        try out.append(self.a, st);
    }

    // ---- aktif (yield içeren) listeler ----

    fn guard(self: *Pass, pc: []const u8, threshold: usize, body: []ast.Stmt, line: u32) Error!ast.Stmt {
        const cond = try self.bin(.le, try self.idx0(pc), .{ .int_lit = @intCast(threshold) });
        var s = self.ifStmt(cond, body);
        s.line = line;
        return s;
    }

    /// Yield içeren bir deyim listesini durum makinesine çevirir. `loop`: bu liste bir döngü gövdesi; `sel`: bir `if` kolu.
    fn emitList(self: *Pass, stmts: []ast.Stmt, loop: bool, sel: ?[]const u8) Error!struct { pc: []const u8, code: []ast.Stmt } {
        const pc = try self.intCell("pc", 0);
        try self.frames.append(self.a, .{ .pc = pc, .sel = sel, .is_loop = loop });
        try self.idxs.append(self.a, 0);
        try self.pushScope();
        defer {
            self.popScope();
            _ = self.idxs.pop();
            _ = self.frames.pop();
        }
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        var i: usize = 0;
        while (i < stmts.len) {
            self.line = stmts[i].line;
            if (!stmtHasYield(stmts[i])) {
                const first = i;
                var grp: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                while (i < stmts.len and !stmtHasYield(stmts[i])) : (i += 1) {
                    if (stmts[i].kind == .func_def) {
                        try self.plainStmt(stmts[i], .{ .top = true }, &self.prelude, true);
                    } else try self.plainStmt(stmts[i], .{ .top = true }, &grp, true);
                }
                try out.append(self.a, try self.guard(pc, 2 * first + 1, try grp.toOwnedSlice(self.a), stmts[first].line));
                continue;
            }
            self.idxs.items[self.idxs.items.len - 1] = i;
            const code = try self.emitActive(stmts[i], i, pc);
            try out.append(self.a, try self.guard(pc, 2 * i + 1, code, stmts[i].line));
            i += 1;
        }
        try out.append(self.a, try self.setCell(pc, 0));
        return .{ .pc = pc, .code = try out.toOwnedSlice(self.a) };
    }

    fn emitActive(self: *Pass, st: ast.Stmt, i: usize, pc: []const u8) Error![]ast.Stmt {
        self.line = st.line;
        switch (st.kind) {
            .expr_stmt => |e| {
                const name = isYield(e).?;
                var arg = e.call.args[0];
                if (std.mem.eql(u8, name, "__nox_yield_from")) {
                    // `yield from X` ≡ `for v in X: yield v`
                    self.uid += 1;
                    const v = try std.fmt.allocPrint(self.a, "__nox_yf_{d}", .{self.uid});
                    const yb = try self.a.alloc(ast.Stmt, 1);
                    yb[0] = .{ .kind = .{ .expr_stmt = try self.call1("__nox_yield", id(v)) }, .line = st.line };
                    return self.emitFor(.{ .var_name = v, .iterable = arg, .body = yb }, i, pc, st);
                }
                try self.rename(&arg);
                var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                // çevreleyen listelerin sayaçları: "i. deyimin İÇİNDE sürdür"
                var k: usize = 0;
                while (k + 1 < self.frames.items.len) : (k += 1) {
                    if (self.frames.items[k].pc) |fpc| try out.append(self.a, try self.setCell(fpc, @intCast(2 * self.idxs.items[k] + 1)));
                }
                try out.append(self.a, try self.setCell(pc, @intCast(2 * i + 2)));
                try out.append(self.a, self.assign(try self.idx0(self.done), .{ .bool_lit = false }));
                try out.append(self.a, .{ .kind = .{ .return_stmt = arg }, .line = st.line });
                return out.toOwnedSlice(self.a);
            },
            .if_stmt => |s| return self.emitIf(s, st),
            .while_stmt => |s| return self.emitWhile(s, st),
            .for_stmt => |s| return self.emitFor(s, i, pc, st),
            else => {
                try self.fail("internal error: unexpected statement kind in a generator", .{});
                return &.{};
            },
        }
    }

    fn emitIf(self: *Pass, s: ast.IfStmt, st: ast.Stmt) Error![]ast.Stmt {
        const sel = try self.intCell("sel", 0);
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        // seçim (yalnızca taze girişte): koşullar bir kez değerlendirilir
        var cond0 = s.cond;
        try self.rename(&cond0);
        var pick = ast.IfStmt{ .cond = cond0, .then_body = try self.single(try self.setCell(sel, 1)), .elif_clauses = &.{}, .else_body = null };
        if (s.elif_clauses.len > 0) {
            const ecs = try self.a.alloc(ast.ElifClause, s.elif_clauses.len);
            for (s.elif_clauses, 0..) |ec, k| {
                var c = ec.cond;
                try self.rename(&c);
                ecs[k] = .{ .cond = c, .body = try self.single(try self.setCell(sel, @intCast(k + 2))) };
            }
            pick.elif_clauses = ecs;
        }
        if (s.else_body != null) pick.else_body = try self.single(try self.setCell(sel, @intCast(s.elif_clauses.len + 2)));
        const fresh = try self.bin(.eq, try self.idx0(sel), .{ .int_lit = 0 });
        var fresh_if = self.ifStmt(fresh, try self.single(self.stmt(.{ .if_stmt = pick })));
        fresh_if.line = st.line;
        try out.append(self.a, fresh_if);
        // kollar
        try out.append(self.a, try self.branch(sel, 1, s.then_body));
        for (s.elif_clauses, 0..) |ec, k| try out.append(self.a, try self.branch(sel, @intCast(k + 2), ec.body));
        if (s.else_body) |eb| try out.append(self.a, try self.branch(sel, @intCast(s.elif_clauses.len + 2), eb));
        try out.append(self.a, try self.setCell(sel, 0));
        return out.toOwnedSlice(self.a);
    }

    fn single(self: *Pass, s: ast.Stmt) Error![]ast.Stmt {
        const b = try self.a.alloc(ast.Stmt, 1);
        b[0] = s;
        return b;
    }

    /// `if sel == k: <kol>`; kol yield içeriyorsa aktif liste, içermiyorsa düz blok (ikisinde de seçici çıkışlarda sıfırlanır).
    fn branch(self: *Pass, sel: []const u8, k: i64, body: []ast.Stmt) Error!ast.Stmt {
        var code: []ast.Stmt = undefined;
        if (listHasYield(body)) {
            const r = try self.emitList(body, false, sel);
            code = r.code;
        } else {
            try self.frames.append(self.a, .{ .pc = null, .sel = sel });
            defer _ = self.frames.pop();
            code = try self.plainBlock(body, .{ .top = true });
        }
        const cond = try self.bin(.eq, try self.idx0(sel), .{ .int_lit = k });
        return self.ifStmt(cond, code);
    }

    fn emitWhile(self: *Pass, s: ast.WhileStmt, st: ast.Stmt) Error![]ast.Stmt {
        var cond = s.cond;
        try self.rename(&cond);
        const r = try self.emitList(s.body, true, null);
        // gövde sayacı != 0 ise sürdürülüyoruz: koşulu atla
        const resume_or_cond = try self.bin(.or_, try self.bin(.ne, try self.idx0(r.pc), .{ .int_lit = 0 }), cond);
        const loop: ast.Stmt = .{ .kind = .{ .while_stmt = .{ .cond = resume_or_cond, .body = r.code } }, .line = st.line };
        return self.single(loop);
    }

    fn isRangeCall(self: *Pass, e: ast.Expr) bool {
        return e == .call and e.call.callee.* == .identifier and std.mem.eql(u8, e.call.callee.identifier, "range") and
            e.call.args.len >= 1 and e.call.args.len <= 3 and self.lookup("range") == null;
    }

    fn emitFor(self: *Pass, s: ast.ForStmt, i: usize, pc: []const u8, st: ast.Stmt) Error![]ast.Stmt {
        _ = i;
        _ = pc;
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        var iterable = s.iterable;
        try self.rename(&iterable);
        try self.pushScope();
        defer self.popScope();
        if (self.isRangeCall(s.iterable)) {
            // sayaçlı `range`: tamsayı hücreleri, yineleyici nesnesi yok
            const cur = try self.intCell("cur", 0);
            const stop = try self.intCell("stop", 0);
            const step = try self.intCell("step", 1);
            const started = try self.boolCell("started", false);
            const var_cell = try self.intCell(s.var_name, 0);
            try self.bind(s.var_name, .{ .cell = var_cell, .boxed = false });
            const args = iterable.call.args;
            const start_e: ast.Expr = if (args.len >= 2) args[0] else .{ .int_lit = 0 };
            const stop_e: ast.Expr = if (args.len >= 2) args[1] else args[0];
            var init_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            try init_body.append(self.a, self.assign(try self.idx0(cur), start_e));
            try init_body.append(self.a, self.assign(try self.idx0(stop), stop_e));
            if (args.len == 3) try init_body.append(self.a, self.assign(try self.idx0(step), args[2]));
            try init_body.append(self.a, self.assign(try self.idx0(started), .{ .bool_lit = true }));
            const not_started = try self.bin(.eq, try self.idx0(started), .{ .bool_lit = false });
            var init_if = self.ifStmt(not_started, try init_body.toOwnedSlice(self.a));
            init_if.line = st.line;
            try out.append(self.a, init_if);
            const body = try self.emitList(s.body, true, null);
            // taze yineleme: bitiş denetimi, değişken ata, sayacı ilerlet
            const pos = try self.bin(.and_, try self.bin(.gt, try self.idx0(step), .{ .int_lit = 0 }), try self.bin(.ge, try self.idx0(cur), try self.idx0(stop)));
            const neg = try self.bin(.and_, try self.bin(.lt, try self.idx0(step), .{ .int_lit = 0 }), try self.bin(.le, try self.idx0(cur), try self.idx0(stop)));
            const finished = try self.bin(.or_, pos, neg);
            var fresh_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            try fresh_body.append(self.a, self.ifStmt(finished, try self.single(self.stmt(.break_stmt))));
            try fresh_body.append(self.a, self.assign(try self.idx0(var_cell), try self.idx0(cur)));
            try fresh_body.append(self.a, self.assign(try self.idx0(cur), try self.bin(.add, try self.idx0(cur), try self.idx0(step))));
            const is_fresh = try self.bin(.eq, try self.idx0(body.pc), .{ .int_lit = 0 });
            var loop_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            try loop_body.append(self.a, self.ifStmt(is_fresh, try fresh_body.toOwnedSlice(self.a)));
            try loop_body.appendSlice(self.a, body.code);
            try out.append(self.a, .{ .kind = .{ .while_stmt = .{ .cond = .{ .bool_lit = true }, .body = try loop_body.toOwnedSlice(self.a) } }, .line = st.line });
            try out.append(self.a, self.assign(try self.idx0(started), .{ .bool_lit = false }));
            return out.toOwnedSlice(self.a);
        }
        // genel yinelenebilir: tembel `__nox_Gen[E]` yineleyicisi + kutulu döngü değişkeni (tipleri checker bulur)
        const it_b = try self.inferredCell("it", try self.call1("__nox_for_iter", iterable));
        const elem_src = try self.call1("__nox_elem_of", iterable);
        const v_b = try self.inferredCell(s.var_name, elem_src);
        try self.bind(s.var_name, v_b);
        const it_unset = try self.bin(.eq, try self.idx0(it_b.cell), .none_lit);
        try out.append(self.a, self.ifStmt(it_unset, try self.single(self.assign(try self.idx0(it_b.cell), try self.call1("__nox_for_iter", iterable)))));
        const body = try self.emitList(s.body, true, null);
        self.uid += 1;
        const nx = try std.fmt.allocPrint(self.a, "__nox_nx_{d}", .{self.uid});
        const next_callee = try self.box(.{ .attribute = .{ .obj = try self.box(try self.call1("__nox_get", id(it_b.cell))), .attr = "__next__" } });
        var pull: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try pull.append(self.a, self.stmt(.{ .var_decl = .{ .name = nx, .type_expr = .{ .simple = "__infer" }, .value = .{ .call = .{ .callee = next_callee, .args = &.{} } } } }));
        const have = try self.bin(.ne, id(nx), .none_lit);
        var pick = self.ifStmt(have, try self.single(self.assign(try self.idx0(v_b.cell), id(nx))));
        pick.kind.if_stmt.else_body = try self.single(self.stmt(.break_stmt));
        try pull.append(self.a, pick);
        const is_fresh = try self.bin(.eq, try self.idx0(body.pc), .{ .int_lit = 0 });
        var loop_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try loop_body.append(self.a, self.ifStmt(is_fresh, try pull.toOwnedSlice(self.a)));
        try loop_body.appendSlice(self.a, body.code);
        try out.append(self.a, .{ .kind = .{ .while_stmt = .{ .cond = .{ .bool_lit = true }, .body = try loop_body.toOwnedSlice(self.a) } }, .line = st.line });
        try out.append(self.a, self.assign(try self.idx0(it_b.cell), .none_lit));
        return out.toOwnedSlice(self.a);
    }

    // ---- fonksiyon düzeyi ----

    fn assignsName(stmts: []const ast.Stmt, name: []const u8) bool {
        for (stmts) |st| switch (st.kind) {
            .assign => |a| if (a.target == .identifier and std.mem.eql(u8, a.target.identifier, name)) return true,
            .if_stmt => |s| {
                if (assignsName(s.then_body, name)) return true;
                for (s.elif_clauses) |ec| if (assignsName(ec.body, name)) return true;
                if (s.else_body) |eb| if (assignsName(eb, name)) return true;
            },
            .while_stmt => |s| if (assignsName(s.body, name)) return true,
            .for_stmt => |s| if (assignsName(s.body, name)) return true,
            .try_stmt => |s| {
                if (assignsName(s.try_body, name)) return true;
                for (s.except_clauses) |ec| if (assignsName(ec.body, name)) return true;
                if (s.finally_body) |fb| if (assignsName(fb, name)) return true;
            },
            .with_stmt => |s| if (assignsName(s.body, name)) return true,
            .lowlevel_stmt => |s| if (assignsName(s.body, name)) return true,
            else => {},
        };
        return false;
    }

    fn lower(self: *Pass, fd: *ast.FuncDef, line: u32) Error!void {
        self.line = line;
        if (fd.is_async) return self.fail("'yield' is not supported in an 'async def'", .{});
        if (fd.type_params.len > 0) return self.fail("a generator function cannot be generic", .{});
        if (fd.return_type != .generic or !std.mem.eql(u8, fd.return_type.generic.name, "__nox_Gen") or fd.return_type.generic.args.len != 1) {
            return self.fail("a function containing 'yield' must be annotated '-> Iterator[T]' (or Generator[T])", .{});
        }
        self.ytype = fd.return_type.generic.args[0];
        if (self.ytype == .optional) return self.fail("a generator cannot yield an optional type ('T | None'); yield the plain type", .{});
        try self.unsupportedYield(fd.body);
        if (self.diag != null) return;

        self.prelude = .empty;
        self.lifted = .empty;
        self.frames = .empty;
        self.idxs = .empty;
        self.scopes = .empty;
        try self.pushScope();
        // yineleme boyunca değiştirilen parametreler hücreye alınır (başlangıç değeri = argüman)
        for (fd.params) |p| {
            if (p.variadic or p.var_kw) continue;
            if (assignsName(fd.body, p.name)) {
                const cell = try self.newName(p.name);
                const items = try self.a.alloc(ast.Expr, 1);
                items[0] = id(p.name);
                try self.prelude.append(self.a, self.stmt(.{ .var_decl = .{ .name = cell, .type_expr = try self.listOf(p.type_expr), .value = .{ .list_lit = items } } }));
                try self.bind(p.name, .{ .cell = cell, .boxed = false });
            } else try self.bind(p.name, null);
        }
        self.done = try self.boolCell("done", false);
        const root = try self.emitList(fd.body, false, null);
        if (self.diag != null) return;

        var step_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try step_body.append(self.a, self.ifStmt(try self.idx0(self.done), try self.single(self.stmt(.{ .return_stmt = .none_lit }))));
        try step_body.append(self.a, self.assign(try self.idx0(self.done), .{ .bool_lit = true }));
        try step_body.appendSlice(self.a, root.code);
        try step_body.append(self.a, self.stmt(.{ .return_stmt = .none_lit }));
        const step_name = "__nox_step";
        const step_def: ast.FuncDef = .{
            .name = step_name,
            .params = &.{},
            .return_type = try self.optionalOf(self.ytype),
            .body = try step_body.toOwnedSlice(self.a),
        };
        var body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try body.appendSlice(self.a, self.prelude.items);
        try body.append(self.a, self.stmt(.{ .func_def = step_def }));
        try body.append(self.a, self.stmt(.{ .return_stmt = try self.call1("__nox_gen_from_step", id(step_name)) }));
        fd.body = try body.toOwnedSlice(self.a);
    }

    // ---- gezinti ----

    fn processFunc(self: *Pass, fd: *ast.FuncDef, line: u32) Error!void {
        self.nestedDefs(fd.body) catch |e| return e;
        if (self.diag != null) return;
        if (!listHasYield(fd.body)) return;
        const saved_uid = self.uid;
        try self.lower(fd, line);
        self.uid = saved_uid + 1000;
    }

    fn nestedDefs(self: *Pass, stmts: []ast.Stmt) Error!void {
        for (stmts) |*st| switch (st.kind) {
            .func_def => |*fd| try self.processFunc(fd, st.line),
            .if_stmt => |*s| {
                try self.nestedDefs(s.then_body);
                for (s.elif_clauses) |*ec| try self.nestedDefs(ec.body);
                if (s.else_body) |eb| try self.nestedDefs(eb);
            },
            .while_stmt => |*s| try self.nestedDefs(s.body),
            .for_stmt => |*s| try self.nestedDefs(s.body),
            .try_stmt => |*s| {
                try self.nestedDefs(s.try_body);
                for (s.except_clauses) |*ec| try self.nestedDefs(ec.body);
                if (s.finally_body) |fb| try self.nestedDefs(fb);
            },
            .with_stmt => |*s| try self.nestedDefs(s.body),
            else => {},
        };
    }
};

/// Modülün tüm fonksiyonlarını (üst-düzey, metod, iç içe) YERİNDE dönüştürür; hata varsa tanılamayı döner.
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt) Error!?Diagnostic {
    var pass: Pass = .{ .a = allocator };
    for (body) |*st| {
        switch (st.kind) {
            .func_def => |*fd| try pass.processFunc(fd, st.line),
            .class_def => |*cd| for (cd.methods) |*m| try pass.processFunc(m, st.line),
            else => {},
        }
        if (pass.diag) |d| return d;
    }
    return null;
}
