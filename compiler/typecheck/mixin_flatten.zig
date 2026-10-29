//! TODO 8.2: çoklu kalıtım — `class C(A, B, D):` karışımı (mixin) düzleştirmesi.
//!
//! İlk taban (`A`) gerçek tekli kalıtımdır (vtable, `super()`, hiyerarşik `except`). Kalan tabanlar (`B`, `D`) MIXIN olarak ele alınır:
//! metodları (`__init__` HARİÇ), sınıf-düzeyi alan bildirimleri ve sabitleri `C`ye KOPYALANIR (checker'dan ÖNCE, AST üzerinde; gövdeler DERİN kopyalanır).
//! Çözümleme sırası Python'un MRO'suyla uyumludur: `C`nin kendi üyeleri > `A` zinciri > `B` > `D`. Mixin kendi tabanlarından da (özyinelemeli) alır.
//!
//! Python'daki AÇIK taban çağrısı desteklenir: `C`nin (ya da kopyalanan bir mixin metodunun) gövdesindeki `B.metod(self, args)`, `B`nin o metodunun
//! adlandırılmış bir kopyasına (`self.__nox_mx_B_metod(args)`) çevrilir; `B.__init__(self, args)` ise `__nox_init_B` kopyasına gider. `__nox_init_*`
//! metodları `__init__` gibi alan OLUŞTURABİLİR (checker): mixin durumu kendi `__init__`inde kurulur, `C`de yeniden atamak gerekmez.
//! `C`, her mixin tipinin ALT TİPİDİR (`cd.mixins`): `C` değeri `B` tipli yere verilebilir, `except B` yakalar; nesne düzeni/vtable bileşen-geneli renklendirilir
//! (`codegen_qbe/mi_layout.zig`). SINIRLAR (belgelenmiş): mixin `__init__`i yalnızca açık çağrıldığında çalışır (Python'daki gibi); `super()` mixin metodunda
//! kullanılamaz (hata); generic mixin yok.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const ast_clone = @import("ast_clone.zig");

pub const Diagnostic = struct { message: []const u8, line: u32 };

const Error = std.mem.Allocator.Error;

const Need = struct { mixin: []const u8, method: []const u8 };

const Pass = struct {
    a: std.mem.Allocator,
    classes: std.StringHashMapUnmanaged(*ast.ClassDef) = .empty,
    lines: std.StringHashMapUnmanaged(u32) = .empty,
    done: std.StringHashMapUnmanaged(void) = .empty,
    visiting: std.StringHashMapUnmanaged(void) = .empty,
    from_imports: *const std.StringHashMapUnmanaged([]const u8),
    diag: ?Diagnostic = null,
    // tarama durumu (bir sınıf için)
    scan_mixins: []const []const u8 = &.{},
    scan_base: ?[]const u8 = null,
    scan_from_mixin: bool = false,
    scan_needs: std.ArrayListUnmanaged(Need) = .empty,
    scan_line: u32 = 0,

    fn fail(self: *Pass, line: u32, comptime fmt: []const u8, args: anytype) Error!void {
        if (self.diag == null) self.diag = .{ .message = try std.fmt.allocPrint(self.a, fmt, args), .line = line };
    }

    fn resolve(self: *Pass, name: []const u8) ?*ast.ClassDef {
        if (self.classes.get(name)) |c| return c;
        if (self.from_imports.get(name)) |q| if (self.classes.get(q)) |c| return c;
        return null;
    }

    fn hasMethodInChain(self: *Pass, cd: *const ast.ClassDef, name: []const u8) bool {
        var cur: ?*const ast.ClassDef = cd;
        var guard: usize = 0;
        while (cur) |c| : (guard += 1) {
            if (guard > 64) return false;
            for (c.methods) |m| if (std.mem.eql(u8, m.name, name)) return true;
            cur = if (c.base) |b| self.resolve(b) else null;
        }
        return false;
    }

    fn mangled(self: *Pass, mixin: []const u8, method: []const u8) Error![]const u8 {
        if (std.mem.eql(u8, method, "__init__")) return std.fmt.allocPrint(self.a, "__nox_init_{s}", .{mixin});
        return std.fmt.allocPrint(self.a, "__nox_mx_{s}_{s}", .{ mixin, method });
    }

    fn box(self: *Pass, e: ast.Expr) Error!*ast.Expr {
        const p = try self.a.create(ast.Expr);
        p.* = e;
        return p;
    }

    // ---- açık taban çağrısı yeniden yazımı + super() denetimi ----

    fn onExpr(self: *Pass, e: *ast.Expr) Error!void {
        if (e.* != .call) return;
        const c = &e.call;
        if (self.scan_from_mixin and c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "super")) {
            try self.fail(self.scan_line, "'super()' cannot be used in a mixin method (the mixin is copied into the class that lists it)", .{});
            return;
        }
        if (c.callee.* != .attribute) return;
        const at = c.callee.attribute;
        if (at.obj.* != .identifier or c.args.len < 1) return;
        if (c.args[0] != .identifier or !std.mem.eql(u8, c.args[0].identifier, "self")) return;
        // Gerçek tabana açık çağrı: `A.metod(self, ...)` → `super().metod(...)`.
        if (!self.scan_from_mixin) if (self.scan_base) |b| if (std.mem.eql(u8, b, at.obj.identifier)) {
            const super_call: ast.Expr = .{ .call = .{ .callee = try self.box(.{ .identifier = "super" }), .args = &.{} } };
            c.callee.* = .{ .attribute = .{ .obj = try self.box(super_call), .attr = at.attr } };
            c.args = c.args[1..];
            return;
        };
        var is_mixin = false;
        for (self.scan_mixins) |mn| if (std.mem.eql(u8, mn, at.obj.identifier)) {
            is_mixin = true;
        };
        if (!is_mixin) return;
        try self.scan_needs.append(self.a, .{ .mixin = at.obj.identifier, .method = at.attr });
        const new_name = try self.mangled(at.obj.identifier, at.attr);
        c.callee.* = .{ .attribute = .{ .obj = try self.box(.{ .identifier = "self" }), .attr = new_name } };
        c.args = c.args[1..];
    }

    fn walkStmts(self: *Pass, stmts: []ast.Stmt) Error!void {
        for (stmts) |*st| {
            self.scan_line = st.line;
            try self.walkStmt(st);
        }
    }

    fn walkStmt(self: *Pass, st: *ast.Stmt) Error!void {
        switch (st.kind) {
            .expr_stmt => |*e| try self.walkExpr(e),
            .var_decl => |*v| try self.walkExpr(&v.value),
            .assign => |*x| {
                try self.walkExpr(&x.target);
                try self.walkExpr(&x.value);
            },
            .if_stmt => |*s| {
                try self.walkExpr(&s.cond);
                try self.walkStmts(s.then_body);
                for (s.elif_clauses) |*ec| {
                    try self.walkExpr(&ec.cond);
                    try self.walkStmts(ec.body);
                }
                if (s.else_body) |eb| try self.walkStmts(eb);
            },
            .while_stmt => |*s| {
                try self.walkExpr(&s.cond);
                try self.walkStmts(s.body);
            },
            .for_stmt => |*s| {
                try self.walkExpr(&s.iterable);
                try self.walkStmts(s.body);
            },
            .func_def => |*fd| try self.walkStmts(fd.body),
            .return_stmt => |*r| if (r.*) |*e| try self.walkExpr(e),
            .raise_stmt => |*e| try self.walkExpr(e),
            .del_stmt => |*e| try self.walkExpr(e),
            .try_stmt => |*s| {
                try self.walkStmts(s.try_body);
                for (s.except_clauses) |*ec| try self.walkStmts(ec.body);
                if (s.finally_body) |fb| try self.walkStmts(fb);
            },
            .lowlevel_stmt => |*s| try self.walkStmts(s.body),
            .with_stmt => |*s| {
                try self.walkExpr(&s.ctx_expr);
                try self.walkStmts(s.body);
            },
            .defer_stmt => |*d| {
                try self.walkExpr(d.call.callee);
                for (d.call.args) |*x| try self.walkExpr(x);
            },
            .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
        }
    }

    fn walkExpr(self: *Pass, e: *ast.Expr) Error!void {
        try self.onExpr(e);
        switch (e.*) {
            .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
            .unary => |*u| try self.walkExpr(u.operand),
            .kwarg => |*k| try self.walkExpr(k.value),
            .ternary => |*t| {
                try self.walkExpr(t.cond);
                try self.walkExpr(t.then_expr);
                try self.walkExpr(t.else_expr);
            },
            .binary => |*b| {
                try self.walkExpr(b.left);
                try self.walkExpr(b.right);
            },
            .call => |*c| {
                try self.walkExpr(c.callee);
                for (c.args) |*x| try self.walkExpr(x);
            },
            .attribute => |*x| try self.walkExpr(x.obj),
            .list_comp => |*lc| {
                try self.walkExpr(lc.elem);
                try self.walkClauses(lc.clauses);
            },
            .dict_comp => |*dc| {
                try self.walkExpr(dc.key);
                try self.walkExpr(dc.value);
                try self.walkClauses(dc.clauses);
            },
            .lambda => |*l| try self.walkExpr(l.body),
            .slice => |*s| {
                try self.walkExpr(s.obj);
                if (s.lo) |v| try self.walkExpr(v);
                if (s.hi) |v| try self.walkExpr(v);
                if (s.step) |v| try self.walkExpr(v);
            },
            .index => |*x| {
                try self.walkExpr(x.obj);
                try self.walkExpr(x.index);
            },
            .list_lit => |items| for (items) |*it| try self.walkExpr(it),
            .tuple_lit => |items| for (items) |*it| try self.walkExpr(it),
            .dict_lit => |pairs| for (pairs) |*p| {
                try self.walkExpr(&p.key);
                try self.walkExpr(&p.value);
            },
            .await_expr => |x| try self.walkExpr(x),
            .spawn_expr => |x| try self.walkExpr(x),
            .generic_construct => |*g| for (g.args) |*x| try self.walkExpr(x),
        }
    }

    fn walkClauses(self: *Pass, clauses: []ast.CompClause) Error!void {
        for (clauses) |*cl| switch (cl.*) {
            .for_clause => |*fc| try self.walkExpr(&fc.iterable),
            .if_clause => |*ce| try self.walkExpr(ce),
        };
    }

    // ---- düzleştirme ----

    fn withSelfType(self: *Pass, m: ast.FuncDef, class_name: []const u8) Error!ast.FuncDef {
        var copy = m;
        copy.body = try ast_clone.stmts(self.a, m.body);
        if (copy.params.len > 0 and std.mem.eql(u8, copy.params[0].name, "self")) {
            const ps = try self.a.dupe(ast.Param, copy.params);
            ps[0].type_expr = .{ .simple = class_name };
            copy.params = ps;
        }
        return copy;
    }

    fn findMethod(self: *Pass, start: *const ast.ClassDef, name: []const u8) ?ast.FuncDef {
        var src: ?*const ast.ClassDef = start;
        var guard: usize = 0;
        while (src) |sc| : (guard += 1) {
            if (guard > 64) return null;
            for (sc.methods) |m| if (std.mem.eql(u8, m.name, name)) return m;
            src = if (sc.base) |b| self.resolve(b) else null;
        }
        return null;
    }

    /// `cd`nin mixin'lerini (kendi tabanları dahil) önce düzleştirir, sonra üyelerini `cd`ye kopyalar.
    fn flatten(self: *Pass, cd: *ast.ClassDef) Error!void {
        if (self.done.contains(cd.name) or self.diag != null) return;
        if (self.visiting.contains(cd.name)) {
            try self.fail(self.lines.get(cd.name) orelse 0, "class '{s}': cyclic base classes", .{cd.name});
            return;
        }
        try self.visiting.put(self.a, cd.name, {});
        defer _ = self.visiting.remove(cd.name);
        const line = self.lines.get(cd.name) orelse 0;
        // Önce gerçek tabanı (kendi mixin'leri `C`nin MRO'sunda önce gelmeli).
        if (cd.base) |b| if (self.resolve(b)) |bc| try self.flatten(bc);
        if (cd.extra_bases.len == 0) {
            try self.done.put(self.a, cd.name, {});
            return;
        }
        var methods: std.ArrayListUnmanaged(ast.FuncDef) = .empty;
        var from_mixin: std.ArrayListUnmanaged(bool) = .empty;
        for (cd.methods) |m| {
            try methods.append(self.a, m);
            try from_mixin.append(self.a, false);
        }
        var fields: std.ArrayListUnmanaged(ast.FieldDecl) = .empty;
        try fields.appendSlice(self.a, cd.fields);
        var consts: std.ArrayListUnmanaged(ast.ConstDecl) = .empty;
        try consts.appendSlice(self.a, cd.consts);
        for (cd.extra_bases) |mn| {
            const mixin = self.resolve(mn) orelse {
                try self.fail(line, "class '{s}': unknown base class '{s}'", .{ cd.name, mn });
                return;
            };
            if (mixin.type_params.len != 0) {
                try self.fail(line, "class '{s}': the generic class '{s}' cannot be used as a mixin", .{ cd.name, mn });
                return;
            }
            if (cd.base != null and mixin.name.ptr == (self.resolve(cd.base.?) orelse mixin).name.ptr) continue;
            try self.flatten(mixin);
            if (self.diag != null) return;
            // mixin'in kendi (zaten düzleştirilmiş) üyeleri + gerçek taban zinciri
            var src: ?*const ast.ClassDef = mixin;
            var guard: usize = 0;
            while (src) |sc| : (guard += 1) {
                if (guard > 64) break;
                for (sc.methods) |m| {
                    if (std.mem.eql(u8, m.name, "__init__")) continue;
                    var taken = false;
                    for (methods.items) |e| if (std.mem.eql(u8, e.name, m.name)) {
                        taken = true;
                        break;
                    };
                    if (!taken and cd.base != null) if (self.resolve(cd.base.?)) |bc| {
                        if (self.hasMethodInChain(bc, m.name)) taken = true;
                    };
                    if (taken) continue;
                    try methods.append(self.a, try self.withSelfType(m, cd.name));
                    try from_mixin.append(self.a, true);
                }
                for (sc.fields) |f| {
                    var have = false;
                    for (fields.items) |e| if (std.mem.eql(u8, e.name, f.name)) {
                        have = true;
                        break;
                    };
                    if (!have) try fields.append(self.a, f);
                }
                for (sc.consts) |k| {
                    var have = false;
                    for (consts.items) |e| if (std.mem.eql(u8, e.name, k.name)) {
                        have = true;
                        break;
                    };
                    if (have) continue;
                    // Kopya, özgün sınıfın (sentetik depo değişkeninin sahibi) adını taşır.
                    var copy = k;
                    if (copy.owner == null) copy.owner = sc.name;
                    try consts.append(self.a, copy);
                }
                src = if (sc.base) |b| self.resolve(b) else null;
            }
        }
        // Açık taban çağrıları: `B.metod(self, ...)` → adlandırılmış kopya (yeni kopyaların gövdeleri de taranır).
        // Açık taban çağrısı hedefleri: doğrudan mixin'ler + onların (taban zinciri / kendi mixin'leri üzerinden) tüm ataları — bir mixin'in `__init__`i
        // kendi tabanını `Taban.__init__(self)` ile başlatabilir; kopyalandığında o çağrı ana sınıftaki adlandırılmış kopyaya gider.
        var scan_names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cd.extra_bases) |mn| try scan_names.append(self.a, mn);
        var si: usize = 0;
        while (si < scan_names.items.len and scan_names.items.len < 256) : (si += 1) {
            const mc = self.resolve(scan_names.items[si]) orelse continue;
            if (mc.base) |b| {
                var dup = false;
                for (scan_names.items) |e| if (std.mem.eql(u8, e, b)) {
                    dup = true;
                };
                if (!dup) try scan_names.append(self.a, b);
            }
            for (mc.mixins) |m2| {
                var dup = false;
                for (scan_names.items) |e| if (std.mem.eql(u8, e, m2)) {
                    dup = true;
                };
                if (!dup) try scan_names.append(self.a, m2);
            }
        }
        self.scan_mixins = scan_names.items;
        self.scan_base = cd.base;
        var scanned: usize = 0;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        while (scanned < methods.items.len) {
            self.scan_needs = .empty;
            self.scan_from_mixin = from_mixin.items[scanned];
            self.scan_line = line;
            try self.walkStmts(methods.items[scanned].body);
            if (self.diag != null) return;
            scanned += 1;
            for (self.scan_needs.items) |need| {
                const nm = try self.mangled(need.mixin, need.method);
                if (seen.contains(nm)) continue;
                try seen.put(self.a, nm, {});
                const mixin = self.resolve(need.mixin).?;
                const src_m = self.findMethod(mixin, need.method) orelse {
                    try self.fail(line, "class '{s}': mixin '{s}' has no method '{s}'", .{ cd.name, need.mixin, need.method });
                    return;
                };
                var copy = try self.withSelfType(src_m, cd.name);
                copy.name = nm;
                try methods.append(self.a, copy);
                try from_mixin.append(self.a, true);
            }
        }
        cd.methods = try methods.toOwnedSlice(self.a);
        cd.fields = try fields.toOwnedSlice(self.a);
        cd.consts = try consts.toOwnedSlice(self.a);
        var resolved_mixins: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cd.extra_bases) |mn| {
            const mixin = self.resolve(mn).?;
            if (cd.base != null and mixin.name.ptr == (self.resolve(cd.base.?) orelse mixin).name.ptr) continue;
            try resolved_mixins.append(self.a, mixin.name);
        }
        cd.mixins = try resolved_mixins.toOwnedSlice(self.a);
        cd.extra_bases = &.{};
        try self.done.put(self.a, cd.name, {});
    }
};

/// Modüldeki tüm sınıfları YERİNDE düzleştirir; hata varsa tanılamayı döner.
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt, from_imports: *const std.StringHashMapUnmanaged([]const u8)) Error!?Diagnostic {
    var any = false;
    for (body) |st| if (st.kind == .class_def and (st.kind.class_def.extra_bases.len > 0 or st.kind.class_def.base != null)) {
        any = true;
        break;
    };
    if (!any) return null;
    var pass: Pass = .{ .a = allocator, .from_imports = from_imports };
    for (body) |*st| if (st.kind == .class_def) {
        try pass.classes.put(allocator, st.kind.class_def.name, &st.kind.class_def);
        try pass.lines.put(allocator, st.kind.class_def.name, st.line);
    };
    for (body) |*st| if (st.kind == .class_def) {
        try pass.flatten(&st.kind.class_def);
        if (pass.diag) |d| return d;
    };
    // Mixin'siz sınıflarda da Python'un açık taban çağrısı `Taban.metod(self, ...)` (örn. `Taban.__init__(self)`) `super()` çağrısına çevrilir. Bu geçiş
    // düzleştirmeden SONRA yapılır: bir sınıf başka bir sınıfa mixin olarak kopyalanacaksa gövdesi kopyalanana kadar açık biçimde kalmalıdır.
    for (body) |*st| if (st.kind == .class_def) {
        const cd = &st.kind.class_def;
        if (cd.base == null or cd.mixins.len > 0) continue;
        pass.scan_mixins = &.{};
        pass.scan_base = cd.base;
        pass.scan_from_mixin = false;
        pass.scan_line = pass.lines.get(cd.name) orelse 0;
        for (cd.methods) |m| {
            if (std.mem.startsWith(u8, m.name, "__nox_")) continue;
            try pass.walkStmts(m.body);
        }
        if (pass.diag) |d| return d;
    };
    return null;
}
