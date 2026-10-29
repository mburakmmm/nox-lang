//! TODO 8.6: `yield` / `yield from` — EAGER (liste-biriktiren) jeneratörler.
//!
//! İçinde `yield` geçen bir fonksiyon (`-> Iterator[T]` / `Generator[T]` / `Iterable[T]`; parser bu adları `list[T]`e indirger) şuna çevrilir:
//! başa `__nox_gen_out: list[T] = []`, her `yield e` → `__nox_gen_out.append(e)`, `yield from e` → `__nox_gen_out.extend(e)`, çıplak `return`
//! ve gövde sonu → `return __nox_gen_out`. Sonuç sıradan bir listedir (`for x in gen():`, `len`, indeksleme çalışır).
//! SINIR: tembel DEĞİLDİR — gövde çağrıda sonuna kadar çalışır; sonsuz bir jeneratör sonsuza dek döner. Bu yüzden sonlu üretimler içindir.
//! Kapsam: üst-düzey fonksiyonlar, metodlar ve iç içe `def`ler (her biri kendi `yield`leri için); `x = yield`/`send()` desteklenmez.

const std = @import("std");
const ast = @import("../parser/ast.zig");

pub const Diagnostic = struct { message: []const u8, line: u32 };

const OUT = "__nox_gen_out";

const Pass = struct {
    a: std.mem.Allocator,
    diag: ?Diagnostic = null,

    fn fail(self: *Pass, line: u32, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        if (self.diag == null) self.diag = .{ .message = try std.fmt.allocPrint(self.a, fmt, args), .line = line };
    }

    fn isYield(e: ast.Expr) ?[]const u8 {
        if (e == .call and e.call.callee.* == .identifier and e.call.args.len == 1) {
            const n = e.call.callee.identifier;
            if (std.mem.eql(u8, n, "__nox_yield") or std.mem.eql(u8, n, "__nox_yield_from")) return n;
        }
        return null;
    }

    fn hasYield(stmts: []const ast.Stmt) bool {
        for (stmts) |st| switch (st.kind) {
            .expr_stmt => |e| if (isYield(e) != null) return true,
            .if_stmt => |s| {
                if (hasYield(s.then_body)) return true;
                for (s.elif_clauses) |ec| if (hasYield(ec.body)) return true;
                if (s.else_body) |eb| if (hasYield(eb)) return true;
            },
            .while_stmt => |s| if (hasYield(s.body)) return true,
            .for_stmt => |s| if (hasYield(s.body)) return true,
            .try_stmt => |s| {
                if (hasYield(s.try_body)) return true;
                for (s.except_clauses) |ec| if (hasYield(ec.body)) return true;
                if (s.finally_body) |fb| if (hasYield(fb)) return true;
            },
            .with_stmt => |s| if (hasYield(s.body)) return true,
            .lowlevel_stmt => |s| if (hasYield(s.body)) return true,
            else => {},
        };
        return false;
    }

    fn box(self: *Pass, e: ast.Expr) std.mem.Allocator.Error!*ast.Expr {
        const p = try self.a.create(ast.Expr);
        p.* = e;
        return p;
    }

    fn outCall(self: *Pass, method: []const u8, arg: ast.Expr) std.mem.Allocator.Error!ast.Expr {
        const obj = try self.box(.{ .identifier = OUT });
        const callee = try self.box(.{ .attribute = .{ .obj = obj, .attr = method } });
        const args = try self.a.alloc(ast.Expr, 1);
        args[0] = arg;
        return .{ .call = .{ .callee = callee, .args = args } };
    }

    /// Gövdedeki (iç içe def'ler HARİÇ) `yield`leri ve `return`leri yeniden yazar.
    fn rewrite(self: *Pass, stmts: []ast.Stmt) std.mem.Allocator.Error!void {
        for (stmts) |*st| switch (st.kind) {
            .expr_stmt => |e| if (isYield(e)) |name| {
                const arg = e.call.args[0];
                const method: []const u8 = if (std.mem.eql(u8, name, "__nox_yield")) "append" else "extend";
                st.kind = .{ .expr_stmt = try self.outCall(method, arg) };
            },
            .return_stmt => |r| {
                if (r != null) {
                    try self.fail(st.line, "a generator ('yield') cannot 'return' a value", .{});
                    return;
                }
                st.kind = .{ .return_stmt = .{ .identifier = OUT } };
            },
            .if_stmt => |*s| {
                try self.rewrite(s.then_body);
                for (s.elif_clauses) |*ec| try self.rewrite(ec.body);
                if (s.else_body) |eb| try self.rewrite(eb);
            },
            .while_stmt => |*s| try self.rewrite(s.body),
            .for_stmt => |*s| try self.rewrite(s.body),
            .try_stmt => |*s| {
                try self.rewrite(s.try_body);
                for (s.except_clauses) |*ec| try self.rewrite(ec.body);
                if (s.finally_body) |fb| try self.rewrite(fb);
            },
            .with_stmt => |*s| try self.rewrite(s.body),
            .lowlevel_stmt => |*s| try self.rewrite(s.body),
            else => {},
        };
    }

    fn processFunc(self: *Pass, fd: *ast.FuncDef, line: u32) std.mem.Allocator.Error!void {
        // iç içe def'ler kendi yield'leriyle bağımsızdır
        for (fd.body) |*st| try self.nested(st);
        if (self.diag != null or !hasYield(fd.body)) return;
        if (fd.is_async) {
            try self.fail(line, "'yield' is not supported in an 'async def'", .{});
            return;
        }
        if (fd.return_type != .generic or !std.mem.eql(u8, fd.return_type.generic.name, "list") or fd.return_type.generic.args.len != 1) {
            try self.fail(line, "a function containing 'yield' must be annotated '-> Iterator[T]' (or Generator[T] / Iterable[T])", .{});
            return;
        }
        try self.rewrite(fd.body);
        if (self.diag != null) return;
        const body = try self.a.alloc(ast.Stmt, fd.body.len + 2);
        body[0] = .{ .kind = .{ .var_decl = .{ .name = OUT, .type_expr = fd.return_type, .value = .{ .list_lit = &.{} } } }, .line = line };
        @memcpy(body[1 .. fd.body.len + 1], fd.body);
        body[fd.body.len + 1] = .{ .kind = .{ .return_stmt = .{ .identifier = OUT } }, .line = line };
        fd.body = body;
    }

    /// Bir deyimin içindeki iç içe `def`leri bulup işler.
    fn nested(self: *Pass, st: *ast.Stmt) std.mem.Allocator.Error!void {
        switch (st.kind) {
            .func_def => |*fd| try self.processFunc(fd, st.line),
            .if_stmt => |*s| {
                for (s.then_body) |*x| try self.nested(x);
                for (s.elif_clauses) |*ec| for (ec.body) |*x| try self.nested(x);
                if (s.else_body) |eb| for (eb) |*x| try self.nested(x);
            },
            .while_stmt => |*s| for (s.body) |*x| try self.nested(x),
            .for_stmt => |*s| for (s.body) |*x| try self.nested(x),
            .try_stmt => |*s| {
                for (s.try_body) |*x| try self.nested(x);
                for (s.except_clauses) |*ec| for (ec.body) |*x| try self.nested(x);
                if (s.finally_body) |fb| for (fb) |*x| try self.nested(x);
            },
            .with_stmt => |*s| for (s.body) |*x| try self.nested(x),
            else => {},
        }
    }
};

/// Modülün tüm fonksiyonlarını (üst-düzey, metod, iç içe) YERİNDE dönüştürür; hata varsa tanılamayı döner.
pub fn run(allocator: std.mem.Allocator, body: []ast.Stmt) std.mem.Allocator.Error!?Diagnostic {
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
