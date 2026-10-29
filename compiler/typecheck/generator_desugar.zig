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

const ResetKind = enum { zero, false_, none };
const ResetCell = struct { cell: []const u8, kind: ResetKind };

const Pass = struct {
    a: std.mem.Allocator,
    /// Temizlik (`try`/`with`) içeren jeneratör fonksiyonlarının adları (`f` ya da `Sınıf.metod`): checker bunların TAZE çağrıları üzerindeki
    /// `for` döngülerinde çıkışta `close()` çağırır (CPython'un referans sayımıyla anında kapatmasının karşılığı).
    cleanup_gens: *std.StringHashMapUnmanaged(void),
    owner: ?[]const u8 = null,
    diag: ?Diagnostic = null,
    line: u32 = 0,
    uid: u32 = 0,
    prelude: std.ArrayListUnmanaged(ast.Stmt) = .empty,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    idxs: std.ArrayListUnmanaged(usize) = .empty,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    ytype: ast.TypeExpr = .{ .simple = "int" },
    /// `Generator[Y, S]`: gönderilen değerin hücresi (`x = yield e` sonrası okunur); `null` = `send` yok.
    sent: ?Binding = null,
    send_line: u32 = 0,
    done: []const u8 = "",
    /// `try`/`with` içinde `yield` varsa: `close()`un yield noktasında `GeneratorExit` fırlattırdığı bayrak hücresi ("" = gerek yok).
    closing: []const u8 = "",
    /// `closing` varsa: `g.throw(e)`nin yield noktasında fırlattırdığı istisnayı taşıyan `Exception | None` hücresi (null = gerek yok).
    thrown: ?Binding = null,
    /// Etkin listelerin doğrudan elemanı olan iç içe `def`ler: her adımda tanımlı olmaları için adım başına taşınır.
    lifted: std.ArrayListUnmanaged(ast.Stmt) = .empty,
    /// Yeniden-giriş DURUMU taşıyan hücreler (program sayaçları, seçiciler, döngü yineleyicileri, bağlam yöneticileri). Bir `try` gövdesinde
    /// fırlayan istisna yakalanıp jeneratör sürerse, gövdenin içinde askıda kalmış bu hücreler sıfırlanmalıdır; aksi halde `try` yeniden
    /// girildiğinde (örn. bir döngü içinde) eski yineleyiciden/sayaçtan devam eder.
    resets: std.ArrayListUnmanaged(ResetCell) = .empty,

    fn fail(self: *Pass, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.diag == null) self.diag = .{ .message = try std.fmt.allocPrint(self.a, fmt, args), .line = self.line };
    }

    // ---- yield tespiti ----

    fn isYield(e: ast.Expr) ?[]const u8 {
        if (e == .call and e.call.callee.* == .identifier and e.call.args.len == 1) {
            const n = e.call.callee.identifier;
            if (std.mem.eql(u8, n, "__nox_yield") or std.mem.eql(u8, n, "__nox_yield_from") or std.mem.eql(u8, n, "__nox_yield_expr")) return n;
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
            .var_decl => |v| isYieldExpr(v.value),
            .assign => |a| isYieldExpr(a.value),
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
                .try_stmt => |s| {
                    try self.unsupportedYield(s.try_body);
                    for (s.except_clauses) |ec| try self.unsupportedYield(ec.body);
                    if (s.finally_body) |fb| try self.unsupportedYield(fb);
                },
                .with_stmt => |s| try self.unsupportedYield(s.body),
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

    fn regReset(self: *Pass, cell: []const u8, kind: ResetKind) Error!void {
        try self.resets.append(self.a, .{ .cell = cell, .kind = kind });
    }

    /// `mark`tan beri kaydedilen durum hücrelerini başlangıç değerlerine döndüren atamalar.
    fn resetSince(self: *Pass, mark: usize) Error![]ast.Stmt {
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        for (self.resets.items[mark..]) |rc| {
            const v: ast.Expr = switch (rc.kind) {
                .zero => .{ .int_lit = 0 },
                .false_ => .{ .bool_lit = false },
                .none => .none_lit,
            };
            try out.append(self.a, self.assign(try self.idx0(rc.cell), v));
        }
        return out.toOwnedSlice(self.a);
    }

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
            // fonksiyon tipli yerel: `Optional[func]` yazılamadığından hücre jenerik `__nox_FnBox[F]` kutusunu taşır (yazmalar checker'da kutulanır, `__nox_get` `.f`yi okur)
            const targs = try self.a.alloc(ast.TypeExpr, 1);
            targs[0] = t;
            return self.typedCell(name, .{ .generic = .{ .name = "__nox_FnBox", .args = targs } });
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
                if (c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "__nox_sent") and c.args.len == 0) {
                    if (self.sent) |b| e.* = try self.readOf(b);
                    return;
                }
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
        try self.regReset(pc, .zero);
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
            if (self.closing.len > 0 and stmts[i].kind == .expr_stmt) {
                // `close()` bu yield noktasından devam ettirdiğinde (`pc == 2*i+2` ve bayrak) `GeneratorExit` fırlat: çevreleyen `try`/`with` temizlikleri çalışır
                const resumed = try self.bin(.eq, try self.idx0(pc), .{ .int_lit = @intCast(2 * i + 2) });
                const cond = try self.bin(.and_, try self.idx0(self.closing), resumed);
                const exit_ctor = try self.call1("GeneratorExit", .{ .string_lit = "generator closed" });
                var chk = self.ifStmt(cond, try self.single(self.stmt(.{ .raise_stmt = exit_ctor })));
                chk.line = stmts[i].line;
                try out.append(self.a, chk);
                // `g.throw(e)`: bu yield noktasından devam edilirken bekleyen istisnayı fırlat (çevreleyen `try/except` yakalayabilir)
                const tb = self.thrown.?;
                const has_thrown = try self.bin(.ne, try self.idx0(tb.cell), .none_lit);
                const throw_cond = try self.bin(.and_, has_thrown, resumed);
                self.uid += 1;
                const tmp = try std.fmt.allocPrint(self.a, "__nox_th_{d}", .{self.uid});
                var tbody: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                try tbody.append(self.a, self.stmt(.{ .var_decl = .{ .name = tmp, .type_expr = .{ .simple = "__infer" }, .value = try self.readOf(tb) } }));
                try tbody.append(self.a, self.assign(try self.idx0(tb.cell), .none_lit));
                try tbody.append(self.a, self.stmt(.{ .raise_stmt = id(tmp) }));
                var tchk = self.ifStmt(throw_cond, try tbody.toOwnedSlice(self.a));
                tchk.line = stmts[i].line;
                try out.append(self.a, tchk);
            }
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
            .try_stmt => |s| return self.emitTry(s, st),
            .with_stmt => |s| return self.emitWith(s, st),
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
        try self.regReset(sel, .zero);
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

    /// Bir deyim listesinde, çevreleyen `try`nin DIŞINA çıkan `return`/`break`/`continue` var mı? (`loop_depth`: listenin kendi içindeki döngüler.)
    fn hasEscapingJump(stmts: []const ast.Stmt, loop_depth: u32) bool {
        for (stmts) |st| {
            switch (st.kind) {
                .return_stmt => return true,
                .break_stmt, .continue_stmt => if (loop_depth == 0) return true,
                .if_stmt => |s| {
                    if (hasEscapingJump(s.then_body, loop_depth)) return true;
                    for (s.elif_clauses) |ec| if (hasEscapingJump(ec.body, loop_depth)) return true;
                    if (s.else_body) |eb| if (hasEscapingJump(eb, loop_depth)) return true;
                },
                .while_stmt => |s| if (hasEscapingJump(s.body, loop_depth + 1)) return true,
                .for_stmt => |s| if (hasEscapingJump(s.body, loop_depth + 1)) return true,
                .try_stmt => |s| {
                    if (hasEscapingJump(s.try_body, loop_depth)) return true;
                    for (s.except_clauses) |ec| if (hasEscapingJump(ec.body, loop_depth)) return true;
                    if (s.finally_body) |fb| if (hasEscapingJump(fb, loop_depth)) return true;
                },
                .with_stmt => |s| if (hasEscapingJump(s.body, loop_depth)) return true,
                .lowlevel_stmt => |s| if (hasEscapingJump(s.body, loop_depth)) return true,
                else => {},
            }
        }
        return false;
    }

    /// `try`/`except`/`finally`. Yield `try` gövdesinde, `except` işleyicilerinde ve/veya `finally`de olabilir.
    ///
    /// Gövde etkin listedir; her adım girişinde `try` yeniden kurulur (yan etkisizdir) ve gövde sayaçla kaldığı yere atlar. Bir `yield` adımdan
    /// `return` ettiğinde `finally` ÇALIŞMAMALI: `done` yalnızca yield'de temizlenir, bu yüzden kullanıcı `finally`si `if done:` ile korunur.
    ///
    /// `yield` içeren bir `except` işleyicisi gerçek `except` içinde ÇALIŞTIRILAMAZ (yeniden girişte istisna artık yoktur): gerçek `except` yalnızca
    /// hangi işleyicinin seçildiğini (`which`) ve istisna nesnesini bir hücreye yazar; işleyici gövdesi aynı `try` bloğunun içinde, iç `try`den SONRA
    /// etkin liste olarak çalışır (`which == k` iken, kendi sayacıyla yeniden girilebilir). Böylece işleyicideki bir hata hâlâ `finally`ye gider.
    ///
    /// `yield` içeren bir `finally` gerçek `finally` olamaz (istisna beklerken yield, istisnayı yutardı): korunan bölge bir yakala-hepsini ile bekleyen
    /// istisnayı (`pend`) saklar, `finally` gövdesi etkin liste olarak bölgeden SONRA çalışır, bitince bekleyen istisna yeniden fırlatılır. Bu modda
    /// `try`yi terk eden `return`/`break`/`continue` desteklenmez (`finally` çalışmadan çıkardı): net hata verilir.
    fn emitTry(self: *Pass, s: ast.TryStmt, st: ast.Stmt) Error![]ast.Stmt {
        var deferred = false;
        for (s.except_clauses) |ec| if (listHasYield(ec.body)) {
            deferred = true;
        };
        const fin_yield = if (s.finally_body) |fb| listHasYield(fb) else false;
        if (fin_yield) {
            var jumps = hasEscapingJump(s.try_body, 0);
            for (s.except_clauses) |ec| if (hasEscapingJump(ec.body, 0)) {
                jumps = true;
            };
            if (jumps or hasEscapingJump(s.finally_body.?, 0)) {
                try self.fail("'return', 'break' or 'continue' that leaves a 'try' whose 'finally' contains 'yield' is not supported in a generator (the 'finally' would be skipped)", .{});
                return &.{};
            }
        }
        const mark = self.resets.items.len;
        const body = try self.emitList(s.try_body, false, null);
        const body_resets = try self.resetSince(mark);
        const which: []const u8 = if (deferred) try self.intCell("which", 0) else "";
        if (deferred) try self.regReset(which, .zero);

        const ecs = try self.a.alloc(ast.ExceptClause, s.except_clauses.len);
        const Deferred = struct { k: usize, bind: ?Binding, list_code: []ast.Stmt };
        var defs: std.ArrayListUnmanaged(Deferred) = .empty;
        for (s.except_clauses, 0..) |ec, k| {
            try self.pushScope();
            defer self.popScope();
            ecs[k] = ec;
            if (listHasYield(ec.body)) {
                var b: ?Binding = null;
                var clause_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                try clause_body.appendSlice(self.a, body_resets);
                try clause_body.append(self.a, try self.setCell(which, @intCast(k + 1)));
                if (ec.bind_name) |bn| {
                    const cn = ec.class_name orelse "Exception";
                    const nb = try self.typedCell(bn, .{ .simple = cn });
                    try self.regReset(nb.cell, .none);
                    try clause_body.append(self.a, self.assign(try self.idx0(nb.cell), id(bn)));
                    try self.bind(bn, nb);
                    b = nb;
                }
                ecs[k].body = try clause_body.toOwnedSlice(self.a);
                const hl = try self.emitList(ec.body, false, which);
                try defs.append(self.a, .{ .k = k, .bind = b, .list_code = hl.code });
            } else {
                if (ec.bind_name) |bn| try self.bind(bn, null);
                var clause_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                try clause_body.appendSlice(self.a, body_resets);
                try clause_body.appendSlice(self.a, try self.plainBlock(ec.body, .{ .top = true }));
                ecs[k].body = try clause_body.toOwnedSlice(self.a);
            }
        }
        const inner: ast.Stmt = .{ .kind = .{ .try_stmt = .{ .try_body = body.code, .except_clauses = ecs, .finally_body = null } }, .line = st.line };

        // korunan bölge: (which == 0 iken) iç try + seçilen ertelenmiş işleyici
        var region: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        if (deferred) {
            var first = self.ifStmt(try self.bin(.eq, try self.idx0(which), .{ .int_lit = 0 }), try self.single(inner));
            first.line = st.line;
            try region.append(self.a, first);
            for (defs.items) |d| {
                var blk: std.ArrayListUnmanaged(ast.Stmt) = .empty;
                try blk.appendSlice(self.a, d.list_code);
                if (d.bind) |bnd| try blk.append(self.a, self.assign(try self.idx0(bnd.cell), .none_lit));
                var chk = self.ifStmt(try self.bin(.eq, try self.idx0(which), .{ .int_lit = @intCast(d.k + 1) }), try blk.toOwnedSlice(self.a));
                chk.line = st.line;
                try region.append(self.a, chk);
            }
            try region.append(self.a, try self.setCell(which, 0));
        } else try region.append(self.a, inner);

        if (!fin_yield) {
            var fin: std.ArrayListUnmanaged(ast.Stmt) = .empty;
            if (s.finally_body) |fb| try fin.appendSlice(self.a, try self.plainBlock(fb, .{ .top = true }));
            try fin.appendSlice(self.a, try self.resetSince(mark));
            const guarded = self.ifStmt(try self.idx0(self.done), try fin.toOwnedSlice(self.a));
            const t: ast.Stmt = .{ .kind = .{ .try_stmt = .{ .try_body = try region.toOwnedSlice(self.a), .except_clauses = &.{}, .finally_body = try self.single(guarded) } }, .line = st.line };
            return self.single(t);
        }

        // yield içeren finally
        const fst = try self.intCell("fst", 0);
        try self.regReset(fst, .zero);
        const pend = try self.typedCell("pend", .{ .simple = "Exception" });
        try self.regReset(pend.cell, .none);
        const fl = try self.emitList(s.finally_body.?, false, null);
        var catch_body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try catch_body.appendSlice(self.a, try self.resetSince(mark));
        try catch_body.append(self.a, self.assign(try self.idx0(pend.cell), id("__nox_pending")));
        const catch_all = try self.a.alloc(ast.ExceptClause, 1);
        catch_all[0] = .{ .class_name = "Exception", .bind_name = "__nox_pending", .body = try catch_body.toOwnedSlice(self.a) };
        const protected: ast.Stmt = .{ .kind = .{ .try_stmt = .{ .try_body = try region.toOwnedSlice(self.a), .except_clauses = catch_all, .finally_body = null } }, .line = st.line };
        var enter_blk: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try enter_blk.append(self.a, protected);
        try enter_blk.append(self.a, try self.setCell(fst, 1));
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        var enter_if = self.ifStmt(try self.bin(.eq, try self.idx0(fst), .{ .int_lit = 0 }), try enter_blk.toOwnedSlice(self.a));
        enter_if.line = st.line;
        try out.append(self.a, enter_if);
        var fin_blk: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try fin_blk.appendSlice(self.a, fl.code);
        try fin_blk.append(self.a, try self.setCell(fst, 0));
        self.uid += 1;
        const tmp = try std.fmt.allocPrint(self.a, "__nox_pe_{d}", .{self.uid});
        var rethrow: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try rethrow.append(self.a, self.stmt(.{ .var_decl = .{ .name = tmp, .type_expr = .{ .simple = "__infer" }, .value = try self.readOf(pend) } }));
        try rethrow.append(self.a, self.assign(try self.idx0(pend.cell), .none_lit));
        try rethrow.append(self.a, self.stmt(.{ .raise_stmt = id(tmp) }));
        try fin_blk.append(self.a, self.ifStmt(try self.bin(.ne, try self.idx0(pend.cell), .none_lit), try rethrow.toOwnedSlice(self.a)));
        var fin_if = self.ifStmt(try self.bin(.eq, try self.idx0(fst), .{ .int_lit = 1 }), try fin_blk.toOwnedSlice(self.a));
        fin_if.line = st.line;
        try out.append(self.a, fin_if);
        return out.toOwnedSlice(self.a);
    }

    /// `with ctx as b: gövde` ≡ yöneticiyi bir kez (taze girişte) kur + `__enter__`, gövdeyi `try` içinde sürdür, çıkışta (yield DEĞİL) `__exit__`.
    fn emitWith(self: *Pass, s: ast.WithStmt, st: ast.Stmt) Error![]ast.Stmt {
        var ctx_e = s.ctx_expr;
        try self.rename(&ctx_e);
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        const mgr = try self.inferredCell("mgr", ctx_e);
        try self.regReset(mgr.cell, .none);
        try self.pushScope();
        defer self.popScope();
        var binding_cell: ?Binding = null;
        const enter_name: []const u8 = if (s.is_async) "__aenter__" else "__enter__";
        const exit_name: []const u8 = if (s.is_async) "__aexit__" else "__exit__";
        if (s.binding) |bn| {
            const enter_callee = try self.box(.{ .attribute = .{ .obj = try self.box(try self.call1("__nox_get", id(mgr.cell))), .attr = enter_name } });
            const enter_expr: ast.Expr = .{ .call = .{ .callee = enter_callee, .args = &.{} } };
            const b = try self.inferredCell(bn, enter_expr);
            try self.bind(bn, b);
            binding_cell = b;
        }
        // taze giriş: yöneticiyi geçici yerelde kur, `__enter__` başarılı olduktan SONRA hücreye yaz
        self.uid += 1;
        const tmp = try std.fmt.allocPrint(self.a, "__nox_wm_{d}", .{self.uid});
        var fresh: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try fresh.append(self.a, self.stmt(.{ .var_decl = .{ .name = tmp, .type_expr = .{ .simple = "__infer" }, .value = ctx_e } }));
        const enter_on_tmp = try self.box(.{ .attribute = .{ .obj = try self.box(id(tmp)), .attr = enter_name } });
        const enter_call: ast.Expr = .{ .call = .{ .callee = enter_on_tmp, .args = &.{} } };
        if (binding_cell) |b| {
            try fresh.append(self.a, self.assign(try self.writeTarget(b), enter_call));
        } else try fresh.append(self.a, self.stmt(.{ .expr_stmt = enter_call }));
        try fresh.append(self.a, self.assign(try self.idx0(mgr.cell), id(tmp)));
        const unset = try self.bin(.eq, try self.idx0(mgr.cell), .none_lit);
        var fresh_if = self.ifStmt(unset, try fresh.toOwnedSlice(self.a));
        fresh_if.line = st.line;
        try out.append(self.a, fresh_if);
        const body = try self.emitList(s.body, false, null);
        var fin: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        const exit_callee = try self.box(.{ .attribute = .{ .obj = try self.box(try self.call1("__nox_get", id(mgr.cell))), .attr = exit_name } });
        try fin.append(self.a, self.stmt(.{ .expr_stmt = .{ .call = .{ .callee = exit_callee, .args = &.{} } } }));
        try fin.append(self.a, self.assign(try self.idx0(mgr.cell), .none_lit));
        try fin.append(self.a, try self.setCell(body.pc, 0));
        const guarded = self.ifStmt(try self.idx0(self.done), try fin.toOwnedSlice(self.a));
        try out.append(self.a, .{ .kind = .{ .try_stmt = .{ .try_body = body.code, .except_clauses = &.{}, .finally_body = try self.single(guarded) } }, .line = st.line });
        return out.toOwnedSlice(self.a);
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
            try self.regReset(started, .false_);
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
        try self.regReset(it_b.cell, .none);
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

    /// Etkin (yield içeren) bir `try`/`with` var mı? Varsa `close()` temizlikleri çalıştırabilmek için yield noktalarına `GeneratorExit` denetimi eklenir.
    fn hasCleanup(stmts: []const ast.Stmt) bool {
        for (stmts) |st| {
            if (!stmtHasYield(st)) continue;
            switch (st.kind) {
                .try_stmt, .with_stmt => return true,
                .if_stmt => |s| {
                    if (hasCleanup(s.then_body)) return true;
                    for (s.elif_clauses) |ec| if (hasCleanup(ec.body)) return true;
                    if (s.else_body) |eb| if (hasCleanup(eb)) return true;
                },
                .while_stmt => |s| if (hasCleanup(s.body)) return true,
                .for_stmt => |s| if (hasCleanup(s.body)) return true,
                else => {},
            }
        }
        return false;
    }

    fn isYieldExpr(e: ast.Expr) bool {
        return e == .call and e.call.callee.* == .identifier and std.mem.eql(u8, e.call.callee.identifier, "__nox_yield_expr") and e.call.args.len == 1;
    }

    /// `x = yield e` / `x: T = yield e` deyimlerini `yield e` + `x = <gönderilen değer>` çiftine böler (tüm iç içe gövdelerde).
    /// Başka konumdaki yield ifadesi (`f((yield 1))`) desteklenmez.
    fn expandSend(self: *Pass, stmts: []ast.Stmt, uses_send: *bool) Error![]ast.Stmt {
        var out: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        for (stmts) |st_in| {
            var st = st_in;
            self.line = st.line;
            switch (st.kind) {
                .assign => |a| if (isYieldExpr(a.value)) {
                    uses_send.* = true;
                    if (self.send_line == 0) self.send_line = st.line;
                    try out.append(self.a, .{ .kind = .{ .expr_stmt = try self.call1("__nox_yield", a.value.call.args[0]) }, .line = st.line, .span = st.span });
                    var s2 = st;
                    s2.kind.assign.value = .{ .call = .{ .callee = try self.box(id("__nox_sent")), .args = &.{} } };
                    try out.append(self.a, s2);
                    continue;
                },
                .var_decl => |v| if (isYieldExpr(v.value)) {
                    uses_send.* = true;
                    if (self.send_line == 0) self.send_line = st.line;
                    try out.append(self.a, .{ .kind = .{ .expr_stmt = try self.call1("__nox_yield", v.value.call.args[0]) }, .line = st.line, .span = st.span });
                    var s2 = st;
                    s2.kind.var_decl.value = .{ .call = .{ .callee = try self.box(id("__nox_sent")), .args = &.{} } };
                    try out.append(self.a, s2);
                    continue;
                },
                .expr_stmt => |e| if (isYieldExpr(e)) {
                    // `yield e` ifade deyimi olarak yazılmış (parantezli) biçim: gönderilen değer atılır
                    try out.append(self.a, .{ .kind = .{ .expr_stmt = try self.call1("__nox_yield", e.call.args[0]) }, .line = st.line, .span = st.span });
                    continue;
                },
                .if_stmt => |*s| {
                    s.then_body = try self.expandSend(s.then_body, uses_send);
                    for (s.elif_clauses) |*ec| ec.body = try self.expandSend(ec.body, uses_send);
                    if (s.else_body) |eb| s.else_body = try self.expandSend(eb, uses_send);
                },
                .while_stmt => |*s| s.body = try self.expandSend(s.body, uses_send),
                .for_stmt => |*s| s.body = try self.expandSend(s.body, uses_send),
                .try_stmt => |*s| {
                    s.try_body = try self.expandSend(s.try_body, uses_send);
                    for (s.except_clauses) |*ec| ec.body = try self.expandSend(ec.body, uses_send);
                    if (s.finally_body) |fb| s.finally_body = try self.expandSend(fb, uses_send);
                },
                .with_stmt => |*s| s.body = try self.expandSend(s.body, uses_send),
                else => {},
            }
            try out.append(self.a, st);
        }
        return out.toOwnedSlice(self.a);
    }

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
        // `async def` + `yield` = ASYNC jeneratör: çağrı bir görev başlatmaz, jeneratör nesnesi döner (işlev eşzamanlı olur); `await`ler adım
        // fonksiyonunda çalışır (tüketicinin fiber'ında), bu yüzden adım `allow_await` taşır.
        const was_async = fd.is_async;
        const is_gens = fd.return_type == .generic and std.mem.eql(u8, fd.return_type.generic.name, "__nox_GenS") and fd.return_type.generic.args.len == 2;
        const is_gen = fd.return_type == .generic and std.mem.eql(u8, fd.return_type.generic.name, "__nox_Gen") and fd.return_type.generic.args.len == 1;
        if (!is_gens and !is_gen) {
            return self.fail("a function containing 'yield' must be annotated '-> Iterator[T]' (or Generator[T], or Generator[Y, S] to receive values with send())", .{});
        }
        self.ytype = fd.return_type.generic.args[0];
        var uses_send = false;
        self.send_line = 0;
        const fn_line = self.line;
        fd.body = try self.expandSend(fd.body, &uses_send);
        if (uses_send and !is_gens) self.line = self.send_line;
        if (uses_send and !is_gens) return self.fail("'x = yield value' receives sent values: annotate the function '-> Generator[Y, S]' (S is the type of the values passed to send())", .{});
        self.line = fn_line;
        if (self.ytype == .optional) return self.fail("a generator cannot yield an optional type ('T | None'); yield the plain type", .{});
        try self.unsupportedYield(fd.body);
        if (self.diag != null) return;

        self.prelude = .empty;
        self.resets = .empty;
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
        self.closing = if (hasCleanup(fd.body)) try self.boolCell("closing", false) else "";
        self.thrown = null;
        if (self.closing.len > 0) self.thrown = try self.typedCell("thrown", .{ .simple = "Exception" });
        self.sent = null;
        var sender_def: ?ast.FuncDef = null;
        if (is_gens) {
            const stype = fd.return_type.generic.args[1];
            const sb = try self.typedCell("sent", stype);
            if (self.diag != null) return;
            self.sent = sb;
            // `g.send(v)` bu kapanışla değeri hücreye yazar
            const sp = try self.a.alloc(ast.Param, 1);
            sp[0] = .{ .name = "v", .type_expr = stype };
            const sbody = try self.single(self.assign(try self.writeTarget(sb), id("v")));
            sender_def = .{ .name = "__nox_send", .params = sp, .return_type = .{ .simple = "None" }, .body = sbody };
            try self.prelude.append(self.a, self.stmt(.{ .func_def = sender_def.? }));
        }
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
            .allow_await = was_async,
        };
        var body: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        try body.appendSlice(self.a, self.prelude.items);
        try body.append(self.a, self.stmt(.{ .func_def = step_def }));
        if (is_gens) {
            // `send` destekli jeneratör: kapanabilir değilse boş `closing` listesi geçilir
            var closing_name = self.closing;
            if (closing_name.len == 0) {
                closing_name = try self.newName("noclose");
                try body.append(self.a, self.stmt(.{ .var_decl = .{ .name = closing_name, .type_expr = try self.listOf(.{ .simple = "bool" }), .value = .{ .list_lit = &.{} } } }));
            }
            var thrown_name: []const u8 = if (self.thrown) |tb| tb.cell else "";
            if (thrown_name.len == 0) {
                thrown_name = try self.newName("nothrow");
                try body.append(self.a, self.stmt(.{ .var_decl = .{ .name = thrown_name, .type_expr = try self.listOf(try self.optionalOf(.{ .simple = "Exception" })), .value = .{ .list_lit = &.{} } } }));
            }
            const gargs = try self.a.alloc(ast.Expr, 4);
            gargs[0] = id(step_name);
            gargs[1] = id(closing_name);
            gargs[2] = id(thrown_name);
            gargs[3] = id("__nox_send");
            const gcall: ast.Expr = .{ .call = .{ .callee = try self.box(id("__nox_gens_from_step")), .args = gargs } };
            try body.append(self.a, self.stmt(.{ .return_stmt = gcall }));
        } else if (self.closing.len > 0) {
            const gargs = try self.a.alloc(ast.Expr, 3);
            gargs[0] = id(step_name);
            gargs[1] = id(self.closing);
            gargs[2] = id(self.thrown.?.cell);
            const gcall: ast.Expr = .{ .call = .{ .callee = try self.box(id("__nox_gen_from_step_closable")), .args = gargs } };
            try body.append(self.a, self.stmt(.{ .return_stmt = gcall }));
        } else {
            try body.append(self.a, self.stmt(.{ .return_stmt = try self.call1("__nox_gen_from_step", id(step_name)) }));
        }
        fd.body = try body.toOwnedSlice(self.a);
        fd.is_async = false;
        if (self.closing.len > 0) {
            const key = if (self.owner) |o| try std.fmt.allocPrint(self.a, "{s}.{s}", .{ o, fd.name }) else fd.name;
            try self.cleanup_gens.put(self.a, key, {});
        }
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
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt, cleanup_gens: *std.StringHashMapUnmanaged(void)) Error!?Diagnostic {
    var pass: Pass = .{ .a = allocator, .cleanup_gens = cleanup_gens };
    for (body) |*st| {
        switch (st.kind) {
            .func_def => |*fd| try pass.processFunc(fd, st.line),
            .class_def => |*cd| {
                pass.owner = cd.name;
                defer pass.owner = null;
                for (cd.methods) |*m| {
                    // `async def __aenter__/__aexit__`: `async with` onları çağıranın fiber'ında doğrudan çağırır ve gövdeleri `await` edebilir.
                    if (m.is_async and (std.mem.eql(u8, m.name, "__aenter__") or std.mem.eql(u8, m.name, "__aexit__"))) {
                        m.is_async = false;
                        m.allow_await = true;
                    }
                    try pass.processFunc(m, st.line);
                }
            },
            else => {},
        }
        if (pass.diag) |d| return d;
    }
    return null;
}
