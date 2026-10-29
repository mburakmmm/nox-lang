//! Deyim/ifade AST'sinin DERİN kopyası (iç içe `def`ler dahil). Mixin düzleştirmesi (`mixin_flatten.zig`) mixin metod gövdelerini her hedef sınıfa
//! ayrı kopyalar: checker'ın işaretçiyle anahtarlı yan tabloları iki sınıfın aynı düğümleri paylaşmasını kaldıramaz.
//! Dize/tip ifadeleri değiştirilmediği için paylaşılır; `resolved_class_name` gibi checker'ın SONRADAN yazacağı hücreler yeniden oluşturulur.

const std = @import("std");
const ast = @import("../parser/ast.zig");

const Error = std.mem.Allocator.Error;

pub fn stmts(a: std.mem.Allocator, src: []const ast.Stmt) Error![]ast.Stmt {
    const out = try a.alloc(ast.Stmt, src.len);
    for (src, 0..) |s, i| out[i] = try stmt(a, s);
    return out;
}

fn optStmts(a: std.mem.Allocator, src: ?[]ast.Stmt) Error!?[]ast.Stmt {
    return if (src) |s| try stmts(a, s) else null;
}

pub fn stmt(a: std.mem.Allocator, s: ast.Stmt) Error!ast.Stmt {
    var out = s;
    out.kind = switch (s.kind) {
        .expr_stmt => |e| .{ .expr_stmt = try expr(a, e) },
        .var_decl => |v| blk: {
            var c = v;
            c.value = try expr(a, v.value);
            break :blk .{ .var_decl = c };
        },
        .assign => |x| blk: {
            var c = x;
            c.target = try expr(a, x.target);
            c.value = try expr(a, x.value);
            break :blk .{ .assign = c };
        },
        .if_stmt => |f| blk: {
            var c = f;
            c.cond = try expr(a, f.cond);
            c.then_body = try stmts(a, f.then_body);
            const ecs = try a.alloc(ast.ElifClause, f.elif_clauses.len);
            for (f.elif_clauses, 0..) |ec, i| ecs[i] = .{ .cond = try expr(a, ec.cond), .body = try stmts(a, ec.body) };
            c.elif_clauses = ecs;
            c.else_body = try optStmts(a, f.else_body);
            break :blk .{ .if_stmt = c };
        },
        .while_stmt => |w| .{ .while_stmt = .{ .cond = try expr(a, w.cond), .body = try stmts(a, w.body) } },
        .for_stmt => |f| blk: {
            var c = f;
            c.iterable = try expr(a, f.iterable);
            c.body = try stmts(a, f.body);
            break :blk .{ .for_stmt = c };
        },
        .func_def => |fd| blk: {
            var c = fd;
            const params = try a.dupe(ast.Param, fd.params);
            for (params) |*p| if (p.default) |d| {
                p.default = try expr(a, d);
            };
            c.params = params;
            c.body = try stmts(a, fd.body);
            break :blk .{ .func_def = c };
        },
        .return_stmt => |r| .{ .return_stmt = if (r) |e| try expr(a, e) else null },
        .raise_stmt => |e| .{ .raise_stmt = try expr(a, e) },
        .del_stmt => |e| .{ .del_stmt = try expr(a, e) },
        .try_stmt => |t| blk: {
            const ecs = try a.alloc(ast.ExceptClause, t.except_clauses.len);
            for (t.except_clauses, 0..) |ec, i| {
                ecs[i] = ec;
                ecs[i].body = try stmts(a, ec.body);
            }
            break :blk .{ .try_stmt = .{ .try_body = try stmts(a, t.try_body), .except_clauses = ecs, .finally_body = try optStmts(a, t.finally_body) } };
        },
        .lowlevel_stmt => |l| .{ .lowlevel_stmt = .{ .body = try stmts(a, l.body) } },
        .with_stmt => |w| .{ .with_stmt = .{ .ctx_expr = try expr(a, w.ctx_expr), .binding = w.binding, .body = try stmts(a, w.body), .is_async = w.is_async } },
        .defer_stmt => |d| .{ .defer_stmt = .{ .call = try callExpr(a, d.call) } },
        .class_def, .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => s.kind,
    };
    return out;
}

fn box(a: std.mem.Allocator, e: ast.Expr) Error!*ast.Expr {
    const p = try a.create(ast.Expr);
    p.* = try expr(a, e);
    return p;
}

fn optBox(a: std.mem.Allocator, e: ?*ast.Expr) Error!?*ast.Expr {
    return if (e) |x| try box(a, x.*) else null;
}

fn exprs(a: std.mem.Allocator, src: []const ast.Expr) Error![]ast.Expr {
    const out = try a.alloc(ast.Expr, src.len);
    for (src, 0..) |e, i| out[i] = try expr(a, e);
    return out;
}

fn callExpr(a: std.mem.Allocator, c: ast.Call) Error!ast.Call {
    var out = c;
    out.callee = try box(a, c.callee.*);
    out.args = try exprs(a, c.args);
    return out;
}

fn clauses(a: std.mem.Allocator, src: []const ast.CompClause) Error![]ast.CompClause {
    const out = try a.alloc(ast.CompClause, src.len);
    for (src, 0..) |cl, i| out[i] = switch (cl) {
        .for_clause => |f| .{ .for_clause = .{ .var_name = f.var_name, .iterable = try expr(a, f.iterable) } },
        .if_clause => |e| .{ .if_clause = try expr(a, e) },
    };
    return out;
}

pub fn expr(a: std.mem.Allocator, e: ast.Expr) Error!ast.Expr {
    return switch (e) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => e,
        .unary => |u| .{ .unary = .{ .op = u.op, .operand = try box(a, u.operand.*) } },
        .binary => |b| blk: {
            var c = b;
            c.left = try box(a, b.left.*);
            c.right = try box(a, b.right.*);
            break :blk .{ .binary = c };
        },
        .call => |c| .{ .call = try callExpr(a, c) },
        .attribute => |x| .{ .attribute = .{ .obj = try box(a, x.obj.*), .attr = x.attr } },
        .index => |x| .{ .index = .{ .obj = try box(a, x.obj.*), .index = try box(a, x.index.*) } },
        .list_lit => |items| .{ .list_lit = try exprs(a, items) },
        .tuple_lit => |items| .{ .tuple_lit = try exprs(a, items) },
        .dict_lit => |pairs| blk: {
            const out = try a.alloc(ast.DictPair, pairs.len);
            for (pairs, 0..) |p, i| out[i] = .{ .key = try expr(a, p.key), .value = try expr(a, p.value) };
            break :blk .{ .dict_lit = out };
        },
        .await_expr => |x| .{ .await_expr = try box(a, x.*) },
        .spawn_expr => |x| .{ .spawn_expr = try box(a, x.*) },
        .generic_construct => |g| blk: {
            var c = g;
            c.args = try exprs(a, g.args);
            const resolved = try a.create(?[]const u8);
            resolved.* = null;
            c.resolved_class_name = resolved;
            break :blk .{ .generic_construct = c };
        },
        .ternary => |t| .{ .ternary = .{ .cond = try box(a, t.cond.*), .then_expr = try box(a, t.then_expr.*), .else_expr = try box(a, t.else_expr.*) } },
        .kwarg => |k| .{ .kwarg = .{ .name = k.name, .value = try box(a, k.value.*) } },
        .slice => |s| .{ .slice = .{ .obj = try box(a, s.obj.*), .lo = try optBox(a, s.lo), .hi = try optBox(a, s.hi), .step = try optBox(a, s.step) } },
        .lambda => |l| .{ .lambda = .{ .params = l.params, .body = try box(a, l.body.*) } },
        .list_comp => |lc| blk: {
            var c = lc;
            c.elem = try box(a, lc.elem.*);
            c.clauses = try clauses(a, lc.clauses);
            break :blk .{ .list_comp = c };
        },
        .dict_comp => |dc| blk: {
            var c = dc;
            c.key = try box(a, dc.key.*);
            c.value = try box(a, dc.value.*);
            c.clauses = try clauses(a, dc.clauses);
            break :blk .{ .dict_comp = c };
        },
    };
}
