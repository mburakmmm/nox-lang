//! AST'yi deterministik, insan-okunur bir S-expression dizgisine döker.
//! Golden testlerin karşılaştırma temelini oluşturur (bkz. tests/golden).

const std = @import("std");
const ast = @import("ast.zig");

pub fn dumpModule(writer: *std.Io.Writer, module: ast.Module) std.Io.Writer.Error!void {
    try writer.writeAll("(module\n");
    for (module.body) |stmt| try dumpStmt(writer, stmt, 1);
    try writer.writeAll(")\n");
}

fn indent(writer: *std.Io.Writer, depth: usize) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try writer.writeAll("  ");
}

fn dumpStmt(writer: *std.Io.Writer, stmt: ast.Stmt, depth: usize) std.Io.Writer.Error!void {
    // dumpFuncDef kendi ilk satır girintisini kendisi basar (class_def içindeki
    // metodlar için de aynı fonksiyon çağrıldığından, çifte girintiyi önlemek adına
    // burada erken dönülür).
    if (stmt.kind == .func_def) return dumpFuncDef(writer, stmt.kind.func_def, depth);

    try indent(writer, depth);
    switch (stmt.kind) {
        .expr_stmt => |e| {
            try writer.writeAll("(expr_stmt ");
            try dumpExpr(writer, e);
            try writer.writeAll(")\n");
        },
        .var_decl => |v| {
            try writer.print("(var_decl {s} ", .{v.name});
            try dumpType(writer, v.type_expr);
            try writer.writeAll(" ");
            try dumpExpr(writer, v.value);
            try writer.writeAll(")\n");
        },
        .assign => |a| {
            try writer.writeAll("(assign ");
            try dumpExpr(writer, a.target);
            try writer.writeAll(" ");
            try dumpExpr(writer, a.value);
            try writer.writeAll(")\n");
        },
        .if_stmt => |f| {
            try writer.writeAll("(if ");
            try dumpExpr(writer, f.cond);
            try writer.writeAll("\n");
            try indent(writer, depth + 1);
            try writer.writeAll("(then\n");
            for (f.then_body) |s| try dumpStmt(writer, s, depth + 2);
            try indent(writer, depth + 1);
            try writer.writeAll(")\n");
            for (f.elif_clauses) |ec| {
                try indent(writer, depth + 1);
                try writer.writeAll("(elif ");
                try dumpExpr(writer, ec.cond);
                try writer.writeAll("\n");
                for (ec.body) |s| try dumpStmt(writer, s, depth + 2);
                try indent(writer, depth + 1);
                try writer.writeAll(")\n");
            }
            if (f.else_body) |eb| {
                try indent(writer, depth + 1);
                try writer.writeAll("(else\n");
                for (eb) |s| try dumpStmt(writer, s, depth + 2);
                try indent(writer, depth + 1);
                try writer.writeAll(")\n");
            }
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
        .while_stmt => |w| {
            try writer.writeAll("(while ");
            try dumpExpr(writer, w.cond);
            try writer.writeAll("\n");
            for (w.body) |s| try dumpStmt(writer, s, depth + 1);
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
        .for_stmt => |f| {
            try writer.print("(for {s} ", .{f.var_name});
            try dumpExpr(writer, f.iterable);
            try writer.writeAll("\n");
            for (f.body) |s| try dumpStmt(writer, s, depth + 1);
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
        .func_def => unreachable, // yukarıda erken döndürüldü
        .class_def => |c| {
            try writer.print("(class {s}\n", .{c.name});
            for (c.fields) |fd| {
                try indent(writer, depth + 1);
                try writer.print("(field {s}:", .{fd.name});
                try dumpType(writer, fd.type_expr);
                try writer.writeAll(")\n");
            }
            for (c.methods) |m| try dumpFuncDef(writer, m, depth + 1);
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
        .protocol_def => |p| {
            try writer.print("(protocol {s}\n", .{p.name});
            for (p.methods) |m| try dumpFuncDef(writer, m, depth + 1);
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
        .extern_def => |e| {
            try writer.print("(extern {s} (", .{e.name});
            for (e.params, 0..) |p, idx| {
                if (idx != 0) try writer.writeAll(" ");
                try writer.print("{s}:", .{p.name});
                try dumpType(writer, p.type_expr);
            }
            try writer.writeAll(") ");
            try dumpType(writer, e.return_type);
            try writer.print(" from \"{s}\"", .{e.from_lib});
            if (e.needs_rt) try writer.writeAll(" with_rt");
            try writer.writeAll(")\n");
        },
        .return_stmt => |r| {
            if (r) |e| {
                try writer.writeAll("(return ");
                try dumpExpr(writer, e);
                try writer.writeAll(")\n");
            } else {
                try writer.writeAll("(return)\n");
            }
        },
        .raise_stmt => |e| {
            try writer.writeAll("(raise ");
            try dumpExpr(writer, e);
            try writer.writeAll(")\n");
        },
        .try_stmt => |t| {
            try writer.writeAll("(try\n");
            for (t.try_body) |s| try dumpStmt(writer, s, depth + 1);
            for (t.except_clauses) |ec| {
                try indent(writer, depth);
                if (ec.bind_name) |bn| {
                    try writer.print("(except {s} as {s}\n", .{ ec.class_name, bn });
                } else {
                    try writer.print("(except {s}\n", .{ec.class_name});
                }
                for (ec.body) |s| try dumpStmt(writer, s, depth + 1);
                try indent(writer, depth);
                try writer.writeAll(")\n");
            }
            if (t.finally_body) |fb| {
                try indent(writer, depth);
                try writer.writeAll("(finally\n");
                for (fb) |s| try dumpStmt(writer, s, depth + 1);
                try indent(writer, depth);
                try writer.writeAll(")\n");
            }
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
        .lowlevel_stmt => |ll| {
            try writer.writeAll("(lowlevel\n");
            for (ll.body) |s| try dumpStmt(writer, s, depth + 1);
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
        .pass_stmt => try writer.writeAll("(pass)\n"),
        .import_stmt => |imp| {
            try writer.writeAll("(import");
            for (imp.segments) |seg| try writer.print(" {s}", .{seg});
            if (imp.alias) |alias| try writer.print(" as {s}", .{alias});
            try writer.writeAll(")\n");
        },
        .from_import_stmt => |fi| {
            try writer.writeAll("(from-import");
            for (fi.segments) |seg| try writer.print(" {s}", .{seg});
            try writer.writeAll(" import");
            for (fi.names) |nm| {
                try writer.print(" {s}", .{nm.name});
                if (nm.alias) |alias| try writer.print(" as {s}", .{alias});
            }
            try writer.writeAll(")\n");
        },
        .with_stmt => |w| {
            try writer.writeAll("(with ");
            try dumpExpr(writer, w.ctx_expr);
            if (w.binding) |bn| try writer.print(" as {s}", .{bn});
            try writer.writeAll("\n");
            for (w.body) |s| try dumpStmt(writer, s, depth + 1);
            try indent(writer, depth);
            try writer.writeAll(")\n");
        },
    }
}

fn dumpFuncDef(writer: *std.Io.Writer, fd: ast.FuncDef, depth: usize) std.Io.Writer.Error!void {
    try indent(writer, depth);
    if (fd.is_async) try writer.writeAll("(async-def ") else try writer.writeAll("(def ");
    try writer.print("{s}", .{fd.name});
    if (fd.type_params.len > 0) {
        try writer.writeAll("[");
        for (fd.type_params, 0..) |tp, idx| {
            if (idx != 0) try writer.writeAll(" ");
            try writer.writeAll(tp);
        }
        try writer.writeAll("]");
    }
    try writer.writeAll(" (");
    for (fd.params, 0..) |p, idx| {
        if (idx != 0) try writer.writeAll(" ");
        try writer.print("{s}:", .{p.name});
        try dumpType(writer, p.type_expr);
    }
    try writer.writeAll(") ");
    try dumpType(writer, fd.return_type);
    try writer.writeAll("\n");
    for (fd.body) |s| try dumpStmt(writer, s, depth + 1);
    try indent(writer, depth);
    try writer.writeAll(")\n");
}

fn dumpType(writer: *std.Io.Writer, t: ast.TypeExpr) std.Io.Writer.Error!void {
    switch (t) {
        .simple => |s| try writer.writeAll(s),
        .generic => |g| {
            try writer.print("{s}[", .{g.name});
            for (g.args, 0..) |a, idx| {
                if (idx != 0) try writer.writeAll(", ");
                try dumpType(writer, a);
            }
            try writer.writeAll("]");
        },
        .func_type => |ft| {
            try writer.writeAll("(");
            for (ft.params, 0..) |p, idx| {
                if (idx != 0) try writer.writeAll(", ");
                try dumpType(writer, p);
            }
            try writer.writeAll(") -> ");
            try dumpType(writer, ft.return_type.*);
        },
        .optional => |inner| {
            try dumpType(writer, inner.*);
            try writer.writeAll(" | None");
        },
    }
}

fn dumpExpr(writer: *std.Io.Writer, e: ast.Expr) std.Io.Writer.Error!void {
    switch (e) {
        .int_lit => |v| try writer.print("(int_lit {d})", .{v}),
        .float_lit => |v| try writer.print("(float_lit {d})", .{v}),
        .bool_lit => |v| try writer.print("(bool_lit {any})", .{v}),
        .string_lit => |s| try writer.print("(string_lit \"{s}\")", .{s}),
        .none_lit => try writer.writeAll("(none_lit)"),
        .identifier => |name| try writer.print("(identifier {s})", .{name}),
        .unary => |u| {
            try writer.print("(unary {s} ", .{@tagName(u.op)});
            try dumpExpr(writer, u.operand.*);
            try writer.writeAll(")");
        },
        .binary => |b| {
            try writer.print("(binary {s} ", .{@tagName(b.op)});
            try dumpExpr(writer, b.left.*);
            try writer.writeAll(" ");
            try dumpExpr(writer, b.right.*);
            try writer.writeAll(")");
        },
        .call => |c| {
            try writer.writeAll("(call ");
            try dumpExpr(writer, c.callee.*);
            for (c.args) |a| {
                try writer.writeAll(" ");
                try dumpExpr(writer, a);
            }
            try writer.writeAll(")");
        },
        .attribute => |a| {
            try writer.writeAll("(attribute ");
            try dumpExpr(writer, a.obj.*);
            try writer.print(" {s})", .{a.attr});
        },
        .index => |idx| {
            try writer.writeAll("(index ");
            try dumpExpr(writer, idx.obj.*);
            try writer.writeAll(" ");
            try dumpExpr(writer, idx.index.*);
            try writer.writeAll(")");
        },
        .list_lit => |elems| {
            try writer.writeAll("(list");
            for (elems) |el| {
                try writer.writeAll(" ");
                try dumpExpr(writer, el);
            }
            try writer.writeAll(")");
        },
        .dict_lit => |pairs| {
            try writer.writeAll("(dict");
            for (pairs) |p| {
                try writer.writeAll(" (");
                try dumpExpr(writer, p.key);
                try writer.writeAll(" ");
                try dumpExpr(writer, p.value);
                try writer.writeAll(")");
            }
            try writer.writeAll(")");
        },
        .await_expr => |operand| {
            try writer.writeAll("(await ");
            try dumpExpr(writer, operand.*);
            try writer.writeAll(")");
        },
        .spawn_expr => |operand| {
            try writer.writeAll("(spawn ");
            try dumpExpr(writer, operand.*);
            try writer.writeAll(")");
        },
        .generic_construct => |g| {
            try writer.print("(generic_construct {s}[", .{g.name});
            for (g.type_args, 0..) |ta, idx| {
                if (idx != 0) try writer.writeAll(", ");
                try dumpType(writer, ta);
            }
            try writer.writeAll("]");
            for (g.args) |a| {
                try writer.writeAll(" ");
                try dumpExpr(writer, a);
            }
            try writer.writeAll(")");
        },
    }
}

/// Test kolaylığı: modülü belleğe ayrılmış bir dizgeye döker.
pub fn dumpToAlloc(allocator: std.mem.Allocator, module: ast.Module) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try dumpModule(&aw.writer, module);
    return aw.toOwnedSlice();
}
