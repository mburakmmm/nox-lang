//! v1.147.0 (varsayılan + keyword argümanlar): checker her çağrıyı hedefin imzasına göre TAM konumsal argüman listesine
//! genişletir (keyword'ler parametre sırasına dizilir, eksikler varsayılan literalle dolar) ama `checkExpr` AST'yi
//! DEĞER olarak aldığından genişletmeyi `Checker.call_expansions`a (anahtar: çağrının `callee` kutusunun adresi,
//! `generic_construct` için `resolved_class_name` kutusunun adresi) yazar. Bu geçiş checker bittikten SONRA AST'yi YERİNDE
//! yeniden yazar: böylece sahiplik/kaçış/inline/raise analizleri ve codegen (argüman↔parametre eşlemesini İNDEKSLE yapan
//! her şey) yalnızca sıradan, tam konumsal çağrılar görür; `kwarg` düğümü hiçbir aşağı-akış geçişine ulaşmaz.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Map = std.AutoHashMapUnmanaged(usize, []ast.Expr);

pub fn stmts(body: []ast.Stmt, map: *const Map) void {
    for (body) |*stmt| {
        switch (stmt.kind) {
            .expr_stmt => |*e| expr(e, map),
            .var_decl => |*v| expr(&v.value, map),
            .assign => |*a| {
                expr(&a.target, map);
                expr(&a.value, map);
            },
            .if_stmt => |*s| {
                expr(&s.cond, map);
                stmts(s.then_body, map);
                for (s.elif_clauses) |*ec| {
                    expr(&ec.cond, map);
                    stmts(ec.body, map);
                }
                if (s.else_body) |eb| stmts(eb, map);
            },
            .while_stmt => |*s| {
                expr(&s.cond, map);
                stmts(s.body, map);
            },
            .for_stmt => |*s| {
                expr(&s.iterable, map);
                stmts(s.body, map);
            },
            .func_def => |fd| stmts(fd.body, map),
            .class_def => |cd| for (cd.methods) |m| stmts(m.body, map),
            .return_stmt => |*maybe| if (maybe.*) |*e| expr(e, map),
            .raise_stmt => |*e| expr(e, map),
            .try_stmt => |*s| {
                stmts(s.try_body, map);
                for (s.except_clauses) |ec| stmts(ec.body, map);
                if (s.finally_body) |fb| stmts(fb, map);
            },
            .lowlevel_stmt => |s| stmts(s.body, map),
            .with_stmt => |*s| {
                expr(&s.ctx_expr, map);
                stmts(s.body, map);
            },
            .defer_stmt => |*d| {
                if (map.get(@intFromPtr(d.call.callee))) |exp| d.call.args = exp;
                expr(d.call.callee, map);
                for (d.call.args) |*a| expr(a, map);
            },
            .protocol_def, .extern_def, .import_stmt, .from_import_stmt, .pass_stmt, .break_stmt, .continue_stmt => {},
        }
    }
}

pub fn expr(e: *ast.Expr, map: *const Map) void {
    switch (e.*) {
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit, .identifier => {},
        .unary => |*u| expr(u.operand, map),
        .kwarg => |*k| expr(k.value, map),
        .ternary => |*t| {
            expr(t.cond, map);
            expr(t.then_expr, map);
            expr(t.else_expr, map);
        },
        .binary => |*b| {
            expr(b.left, map);
            expr(b.right, map);
        },
        .call => |*c| {
            if (map.get(@intFromPtr(c.callee))) |exp| c.args = exp;
            expr(c.callee, map);
            for (c.args) |*a| expr(a, map);
        },
        .attribute => |*a| expr(a.obj, map),
        .index => |*ix| {
            expr(ix.obj, map);
            expr(ix.index, map);
        },
        .list_lit => |items| for (items) |*it| expr(it, map),
        .dict_lit => |pairs| for (pairs) |*p| {
            expr(&p.key, map);
            expr(&p.value, map);
        },
        .await_expr => |op| expr(op, map),
        .spawn_expr => |op| expr(op, map),
        .generic_construct => |*g| {
            if (map.get(@intFromPtr(g.resolved_class_name))) |exp| g.args = exp;
            for (g.args) |*a| expr(a, map);
        },
    }
}
