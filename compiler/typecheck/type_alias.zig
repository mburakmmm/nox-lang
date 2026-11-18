//! Dil yüzeyi 2 (v2.2.22): `type Ad = Tip` takma adları. Modül düzeyindeki `type_alias` deyimleri toplanır ve tüm tip ifadelerindeki `Ad` kullanımları AST'de yerinde
//! karşılığıyla değiştirilir; böylece checker ve codegen takma adları hiç görmez. Biçimlendirici bu geçişten ÖNCE çalıştığından yazılan takma ad adları korunur.
//! Kapsam (v1): yalnızca tam tip takma adı (`type IntList = list[int]`, `type Id = int`, `type Cb = (int) -> int`); jenerik takma ad yok; takma ad adı modül başına bir kez
//! tanımlanır ve sınıf/işlev adlarıyla çakışamaz; takma adlar birbirine başvurabilir (gerçek döngü hata). Takma adlar MODÜL KAPSAMLIDIR (GPT-6 P1.9): içe aktarılan modülün takma adı
//! module_loader'da `modül_Ad` diye öneklenir (sınıf/işlevlerle aynı kural); diğer modüller `m.Ad` ya da `from m import Ad` ile erişir, `__all__` listesi varsa o uygulanır.

const std = @import("std");
const ast = @import("../parser/ast.zig");

const Error = std.mem.Allocator.Error;

pub const Diag = struct { line: u32, message: []const u8 };

const Ctx = struct {
    a: std.mem.Allocator,
    aliases: std.StringHashMapUnmanaged(ast.TypeExpr) = .{},
    /// Çözülmüş (iç içe takma adları açılmış) hedefler; ad -> tip. Aynı takma ad birden çok kez kullanılsa da bir kez çözülür.
    memo: std.StringHashMapUnmanaged(ast.TypeExpr) = .{},
    /// Şu an çözülmekte olan takma adlar (döngü tespiti için gerçek başvuru yığını).
    stack: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `import a.b as m` -> m => ["a","b"] (nitelikli `m.Ad` tip adı için).
    module_aliases: std.StringHashMapUnmanaged([]const []const u8) = .{},
    exports: []const ast.ModuleExports = &.{},
    err: ?Diag = null,
    line: u32 = 0,
};

pub fn run(a: std.mem.Allocator, body: []ast.Stmt, exports: []const ast.ModuleExports) Error!?Diag {
    var any = false;
    for (body) |st| if (st.kind == .type_alias) {
        any = true;
        break;
    };
    if (!any) return null;
    var cx: Ctx = .{ .a = a, .exports = exports };
    // 1. topla; adlar tekil olmalı ve sınıf/işlev adlarıyla çakışmamalı (içe aktarılan modüllerin takma adları modül önekiyle gelir: `m_Ad`)
    for (body) |st| switch (st.kind) {
        .type_alias => |ta| {
            if (cx.aliases.contains(ta.name)) return .{ .line = st.line, .message = try std.fmt.allocPrint(a, "the type alias '{s}' is defined twice", .{ta.name}) };
            try cx.aliases.put(a, ta.name, ta.target);
        },
        .import_stmt => |imp| if (imp.alias) |al| try cx.module_aliases.put(a, al, imp.segments),
        else => {},
    };
    for (body) |st| {
        const clash: ?[]const u8 = switch (st.kind) {
            .class_def => |c| c.name,
            .func_def => |f| f.name,
            .protocol_def => |p| p.name,
            else => null,
        };
        if (clash) |n| if (cx.aliases.contains(n)) return .{ .line = st.line, .message = try std.fmt.allocPrint(a, "the type alias '{s}' clashes with a class/function of the same name", .{n}) };
    }
    // `from m import Ad [as Yerel]`: takma ad ise yerel ad, modülün (önekli) takma adına bağlanır. Çok modüllü birleşik programda yerel adlar
    // sınıf/işlevlerdeki `from_imports` gibi tek tablodadır (son yazan kazanır).
    for (body) |st| switch (st.kind) {
        .from_import_stmt => |fi| for (fi.names) |nm| {
            const mangled = try mangleSegments(a, fi.segments, nm.name);
            if (!cx.aliases.contains(mangled)) continue;
            if (!try exported(&cx, fi.segments, nm.name)) return .{ .line = st.line, .message = try std.fmt.allocPrint(a, "'{s}' is not part of the public API of module '{s}' (it is not listed in that module's __all__)", .{ nm.name, try joinDots(a, fi.segments) }) };
            try cx.aliases.put(a, nm.alias orelse nm.name, .{ .simple = mangled });
        },
        else => {},
    };
    // 2. takma adların kendi hedefleri (birbirine başvuru, döngü denetimi). Önce kaynak sırasıyla (hata iletisi deterministik olsun), sonra `from` yerel adları.
    var resolved: std.StringHashMapUnmanaged(ast.TypeExpr) = .{};
    for (body) |st| if (st.kind == .type_alias) {
        const n = st.kind.type_alias.name;
        cx.line = st.line;
        const r = try resolveAlias(&cx, n, .{ .simple = n });
        if (cx.err) |d| return d;
        try resolved.put(a, n, r);
    };
    var it = cx.aliases.iterator();
    while (it.next()) |kv| {
        if (resolved.contains(kv.key_ptr.*)) continue;
        cx.line = lineOfAlias(body, kv.key_ptr.*);
        const r = try resolveAlias(&cx, kv.key_ptr.*, .{ .simple = kv.key_ptr.* });
        if (cx.err) |d| return d;
        try resolved.put(a, kv.key_ptr.*, r);
    }
    cx.aliases = resolved;
    // 3. tüm gövdeyi yeniden yaz
    try walkStmts(&cx, body);
    return cx.err;
}

fn mangleSegments(a: std.mem.Allocator, segs: []const []const u8, name: []const u8) Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (segs) |seg| {
        try buf.appendSlice(a, seg);
        try buf.append(a, '_');
    }
    try buf.appendSlice(a, name);
    return buf.toOwnedSlice(a);
}

fn joinDots(a: std.mem.Allocator, segs: []const []const u8) Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (segs, 0..) |seg, i| {
        if (i != 0) try buf.append(a, '.');
        try buf.appendSlice(a, seg);
    }
    return buf.toOwnedSlice(a);
}

/// Modülün `__all__` listesi varsa `name` ona dahil mi? (Liste yoksa her ad açıktır.)
fn exported(cx: *Ctx, segs: []const []const u8, name: []const u8) Error!bool {
    const dotted = try joinDots(cx.a, segs);
    for (cx.exports) |ex| {
        if (!std.mem.eql(u8, ex.module, dotted)) continue;
        for (ex.names) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
    return true;
}

fn lineOfAlias(body: []const ast.Stmt, name: []const u8) u32 {
    for (body) |st| if (st.kind == .type_alias and std.mem.eql(u8, st.kind.type_alias.name, name)) return st.line;
    return 0;
}

/// Savunma amaçlı özyineleme sınırı (gerçek döngüler `stack` ile yakalanır; bu yalnızca çok uzun ama döngüsüz zincirler için yığın taşmasını önler).
const MAX_CHAIN: usize = 2000;

fn resolveAlias(cx: *Ctx, n: []const u8, te: ast.TypeExpr) Error!ast.TypeExpr {
    if (cx.memo.get(n)) |r| return r;
    for (cx.stack.items, 0..) |s, i| if (std.mem.eql(u8, s, n)) {
        var chain: std.ArrayListUnmanaged(u8) = .empty;
        for (cx.stack.items[i..]) |c| {
            try chain.appendSlice(cx.a, c);
            try chain.appendSlice(cx.a, " -> ");
        }
        try chain.appendSlice(cx.a, n);
        cx.err = .{ .line = cx.line, .message = try std.fmt.allocPrint(cx.a, "the type alias '{s}' refers to itself ({s})", .{ n, chain.items }) };
        return te;
    };
    if (cx.stack.items.len >= MAX_CHAIN) {
        cx.err = .{ .line = cx.line, .message = try std.fmt.allocPrint(cx.a, "the type alias '{s}' is nested too deeply (more than {d} aliases in one chain)", .{ n, MAX_CHAIN }) };
        return te;
    }
    const target = cx.aliases.get(n).?;
    try cx.stack.append(cx.a, n);
    const r = try subst(cx, target);
    _ = cx.stack.pop();
    if (cx.err == null) try cx.memo.put(cx.a, n, r);
    return r;
}

fn subst(cx: *Ctx, te: ast.TypeExpr) Error!ast.TypeExpr {
    if (cx.err != null) return te;
    switch (te) {
        .simple => |n| {
            if (cx.aliases.contains(n)) return resolveAlias(cx, n, te);
            return te;
        },
        .generic => |g| {
            const args = try cx.a.alloc(ast.TypeExpr, g.args.len);
            for (g.args, 0..) |arg, i| args[i] = try subst(cx, arg);
            var out = g;
            out.args = args;
            return .{ .generic = out };
        },
        .func_type => |f| {
            const params = try cx.a.alloc(ast.TypeExpr, f.params.len);
            for (f.params, 0..) |p, i| params[i] = try subst(cx, p);
            const ret = try cx.a.create(ast.TypeExpr);
            ret.* = try subst(cx, f.return_type.*);
            return .{ .func_type = .{ .params = params, .return_type = ret } };
        },
        // `m.Ad` / `pkg.m.Ad`: modül yolu (varsa `import ... as m` takma adı açılarak) + `_` birleşimi, modülün önekli takma adıdır.
        .qualified => |segs| {
            if (segs.len < 2) return te;
            var full: std.ArrayListUnmanaged([]const u8) = .empty;
            if (cx.module_aliases.get(segs[0])) |target| try full.appendSlice(cx.a, target) else try full.append(cx.a, segs[0]);
            try full.appendSlice(cx.a, segs[1..]);
            const mangled = try mangleSegments(cx.a, full.items[0 .. full.items.len - 1], full.items[full.items.len - 1]);
            if (!cx.aliases.contains(mangled)) return te;
            if (!try exported(cx, full.items[0 .. full.items.len - 1], full.items[full.items.len - 1])) {
                cx.err = .{ .line = cx.line, .message = try std.fmt.allocPrint(cx.a, "'{s}' is not part of the public API of module '{s}' (it is not listed in that module's __all__)", .{ full.items[full.items.len - 1], try joinDots(cx.a, full.items[0 .. full.items.len - 1]) }) };
                return te;
            }
            return resolveAlias(cx, mangled, te);
        },
        .optional => |inner| {
            const boxed = try cx.a.create(ast.TypeExpr);
            boxed.* = try subst(cx, inner.*);
            return .{ .optional = boxed };
        },
    }
}

fn walkStmts(cx: *Ctx, stmts: []ast.Stmt) Error!void {
    for (stmts) |*st| {
        if (cx.err != null) return;
        cx.line = st.line;
        try walkStmt(cx, st);
    }
}

fn walkFunc(cx: *Ctx, fd: *ast.FuncDef) Error!void {
    for (fd.params) |*p| {
        p.type_expr = try subst(cx, p.type_expr);
        if (p.default) |*d| try walkExpr(cx, d);
    }
    fd.return_type = try subst(cx, fd.return_type);
    try walkStmts(cx, fd.body);
}

fn walkStmt(cx: *Ctx, st: *ast.Stmt) Error!void {
    switch (st.kind) {
        .var_decl => |*v| {
            v.type_expr = try subst(cx, v.type_expr);
            try walkExpr(cx, &v.value);
        },
        .assign => |*x| {
            if (x.ann) |ann| x.ann = try subst(cx, ann);
            try walkExpr(cx, &x.target);
            try walkExpr(cx, &x.value);
        },
        .expr_stmt => |*e| try walkExpr(cx, e),
        .return_stmt => |*r| if (r.*) |*e| try walkExpr(cx, e),
        .raise_stmt => |*e| try walkExpr(cx, e),
        .del_stmt => |*e| try walkExpr(cx, e),
        .defer_stmt => |*d| {
            try walkExpr(cx, d.call.callee);
            for (d.call.args) |*arg| try walkExpr(cx, arg);
        },
        .if_stmt => |*f| {
            try walkExpr(cx, &f.cond);
            try walkStmts(cx, f.then_body);
            for (f.elif_clauses) |*ec| {
                try walkExpr(cx, &ec.cond);
                try walkStmts(cx, ec.body);
            }
            if (f.else_body) |eb| try walkStmts(cx, eb);
        },
        .while_stmt => |*w| {
            try walkExpr(cx, &w.cond);
            try walkStmts(cx, w.body);
        },
        .for_stmt => |*f| {
            try walkExpr(cx, &f.iterable);
            try walkStmts(cx, f.body);
        },
        .try_stmt => |*t| {
            try walkStmts(cx, t.try_body);
            for (t.except_clauses) |*ec| try walkStmts(cx, ec.body);
            if (t.finally_body) |fb| try walkStmts(cx, fb);
        },
        .with_stmt => |*w| {
            try walkExpr(cx, &w.ctx_expr);
            try walkStmts(cx, w.body);
        },
        .lowlevel_stmt => |*l| try walkStmts(cx, l.body),
        .func_def => |*fd| try walkFunc(cx, fd),
        .class_def => |*c| {
            for (c.fields) |*f| f.type_expr = try subst(cx, f.type_expr);
            const consts: []ast.ConstDecl = @constCast(c.consts);
            for (consts) |*k| {
                k.type_expr = try subst(cx, k.type_expr);
                try walkExpr(cx, &k.value);
            }
            const bargs: []ast.TypeExpr = @constCast(c.base_args);
            for (bargs) |*b| b.* = try subst(cx, b.*);
            const variants: []ast.EnumVariant = @constCast(c.enum_variants);
            for (variants) |*v| {
                const vf: []ast.FieldDecl = @constCast(v.fields);
                for (vf) |*f| f.type_expr = try subst(cx, f.type_expr);
            }
            for (c.methods) |*m| try walkFunc(cx, m);
        },
        .protocol_def => |*p| for (p.methods) |*m| try walkFunc(cx, m),
        .extern_def => |*e| {
            for (e.params) |*p| p.type_expr = try subst(cx, p.type_expr);
            e.return_type = try subst(cx, e.return_type);
        },
        .type_alias, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
    }
}

fn walkExprs(cx: *Ctx, es: []ast.Expr) Error!void {
    for (es) |*e| try walkExpr(cx, e);
}

fn walkClauses(cx: *Ctx, cls: []ast.CompClause) Error!void {
    for (cls) |*cl| switch (cl.*) {
        .for_clause => |*f| try walkExpr(cx, &f.iterable),
        .if_clause => |*e| try walkExpr(cx, e),
    };
}

fn walkExpr(cx: *Ctx, e: *ast.Expr) Error!void {
    switch (e.*) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        .unary => |*u| try walkExpr(cx, u.operand),
        .binary => |*b| {
            try walkExpr(cx, b.left);
            try walkExpr(cx, b.right);
        },
        .call => |*c| {
            try walkExpr(cx, c.callee);
            try walkExprs(cx, c.args);
        },
        .attribute => |*x| try walkExpr(cx, x.obj),
        .index => |*x| {
            try walkExpr(cx, x.obj);
            try walkExpr(cx, x.index);
        },
        .list_lit, .tuple_lit => |items| try walkExprs(cx, items),
        .dict_lit => |pairs| for (pairs) |*p| {
            try walkExpr(cx, &p.key);
            try walkExpr(cx, &p.value);
        },
        .await_expr => |x| try walkExpr(cx, x),
        .spawn_expr => |x| try walkExpr(cx, x),
        .generic_construct => |*g| {
            for (g.type_args) |*ta| ta.* = try subst(cx, ta.*);
            try walkExprs(cx, g.args);
        },
        .ternary => |*t| {
            try walkExpr(cx, t.cond);
            try walkExpr(cx, t.then_expr);
            try walkExpr(cx, t.else_expr);
        },
        .kwarg => |*k| try walkExpr(cx, k.value),
        .slice => |*s| {
            try walkExpr(cx, s.obj);
            if (s.lo) |x| try walkExpr(cx, x);
            if (s.hi) |x| try walkExpr(cx, x);
            if (s.step) |x| try walkExpr(cx, x);
        },
        .lambda => |*l| try walkExpr(cx, l.body),
        .list_comp => |*lc| {
            try walkExpr(cx, lc.elem);
            try walkClauses(cx, lc.clauses);
        },
        .dict_comp => |*dc| {
            try walkExpr(cx, dc.key);
            try walkExpr(cx, dc.value);
            try walkClauses(cx, dc.clauses);
        },
    }
}
