//! Dil yüzeyi 2 (v2.2.22): `type Ad = Tip` takma adları. Modül düzeyindeki `type_alias` deyimleri toplanır ve tüm tip ifadelerindeki `Ad` kullanımları AST'de yerinde
//! karşılığıyla değiştirilir; böylece checker ve codegen takma adları hiç görmez. Biçimlendirici bu geçişten ÖNCE çalıştığından yazılan takma ad adları korunur.
//! Kapsam (v1): yalnızca tam tip takma adı (`type IntList = list[int]`, `type Id = int`, `type Cb = (int) -> int`); jenerik takma ad yok; takma ad adı modül başına bir kez
//! tanımlanır ve sınıf/işlev adlarıyla çakışamaz; takma adlar birbirine başvurabilir (döngü hata). Birleştirilmiş çok-modüllü programda adlar modüller arasında paylaşılır.

const std = @import("std");
const ast = @import("../parser/ast.zig");

const Error = std.mem.Allocator.Error;

pub const Diag = struct { line: u32, message: []const u8 };

const Ctx = struct {
    a: std.mem.Allocator,
    aliases: std.StringHashMapUnmanaged(ast.TypeExpr) = .{},
    err: ?Diag = null,
    line: u32 = 0,
};

pub fn run(a: std.mem.Allocator, body: []ast.Stmt) Error!?Diag {
    var any = false;
    for (body) |st| if (st.kind == .type_alias) {
        any = true;
        break;
    };
    if (!any) return null;
    var cx: Ctx = .{ .a = a };
    // 1. topla; adlar tekil olmalı ve sınıf/işlev adlarıyla çakışmamalı
    for (body) |st| switch (st.kind) {
        .type_alias => |ta| {
            if (cx.aliases.contains(ta.name)) return .{ .line = st.line, .message = try std.fmt.allocPrint(a, "the type alias '{s}' is defined twice", .{ta.name}) };
            try cx.aliases.put(a, ta.name, ta.target);
        },
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
    // 2. takma adların kendi hedefleri (birbirine başvuru, döngü denetimi)
    var it = cx.aliases.iterator();
    var resolved: std.StringHashMapUnmanaged(ast.TypeExpr) = .{};
    while (it.next()) |kv| {
        cx.line = lineOfAlias(body, kv.key_ptr.*);
        const r = try subst(&cx, kv.value_ptr.*, 0);
        if (cx.err) |d| return d;
        try resolved.put(a, kv.key_ptr.*, r);
    }
    cx.aliases = resolved;
    // 3. tüm gövdeyi yeniden yaz
    try walkStmts(&cx, body);
    return cx.err;
}

fn lineOfAlias(body: []const ast.Stmt, name: []const u8) u32 {
    for (body) |st| if (st.kind == .type_alias and std.mem.eql(u8, st.kind.type_alias.name, name)) return st.line;
    return 0;
}

const MAX_DEPTH: u32 = 24;

fn subst(cx: *Ctx, te: ast.TypeExpr, depth: u32) Error!ast.TypeExpr {
    if (cx.err != null) return te;
    switch (te) {
        .simple => |n| {
            if (cx.aliases.get(n)) |target| {
                if (depth >= MAX_DEPTH) {
                    cx.err = .{ .line = cx.line, .message = try std.fmt.allocPrint(cx.a, "the type alias '{s}' refers to itself", .{n}) };
                    return te;
                }
                return subst(cx, target, depth + 1);
            }
            return te;
        },
        .generic => |g| {
            const args = try cx.a.alloc(ast.TypeExpr, g.args.len);
            for (g.args, 0..) |arg, i| args[i] = try subst(cx, arg, depth);
            var out = g;
            out.args = args;
            return .{ .generic = out };
        },
        .func_type => |f| {
            const params = try cx.a.alloc(ast.TypeExpr, f.params.len);
            for (f.params, 0..) |p, i| params[i] = try subst(cx, p, depth);
            const ret = try cx.a.create(ast.TypeExpr);
            ret.* = try subst(cx, f.return_type.*, depth);
            return .{ .func_type = .{ .params = params, .return_type = ret } };
        },
        .qualified => return te,
        .optional => |inner| {
            const boxed = try cx.a.create(ast.TypeExpr);
            boxed.* = try subst(cx, inner.*, depth);
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
        p.type_expr = try subst(cx, p.type_expr, 0);
        if (p.default) |*d| try walkExpr(cx, d);
    }
    fd.return_type = try subst(cx, fd.return_type, 0);
    try walkStmts(cx, fd.body);
}

fn walkStmt(cx: *Ctx, st: *ast.Stmt) Error!void {
    switch (st.kind) {
        .var_decl => |*v| {
            v.type_expr = try subst(cx, v.type_expr, 0);
            try walkExpr(cx, &v.value);
        },
        .assign => |*x| {
            if (x.ann) |ann| x.ann = try subst(cx, ann, 0);
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
            for (c.fields) |*f| f.type_expr = try subst(cx, f.type_expr, 0);
            const consts: []ast.ConstDecl = @constCast(c.consts);
            for (consts) |*k| {
                k.type_expr = try subst(cx, k.type_expr, 0);
                try walkExpr(cx, &k.value);
            }
            const bargs: []ast.TypeExpr = @constCast(c.base_args);
            for (bargs) |*b| b.* = try subst(cx, b.*, 0);
            const variants: []ast.EnumVariant = @constCast(c.enum_variants);
            for (variants) |*v| {
                const vf: []ast.FieldDecl = @constCast(v.fields);
                for (vf) |*f| f.type_expr = try subst(cx, f.type_expr, 0);
            }
            for (c.methods) |*m| try walkFunc(cx, m);
        },
        .protocol_def => |*p| for (p.methods) |*m| try walkFunc(cx, m),
        .extern_def => |*e| {
            for (e.params) |*p| p.type_expr = try subst(cx, p.type_expr, 0);
            e.return_type = try subst(cx, e.return_type, 0);
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
            for (g.type_args) |*ta| ta.* = try subst(cx, ta.*, 0);
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
