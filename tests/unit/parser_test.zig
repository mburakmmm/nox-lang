//! `nox` modülünün parser'ı için dıştan (public API üzerinden) ek testler.
//! compiler/parser/parser.zig içindeki testlerle çakışmayan durumlar hedeflenir.

const std = @import("std");
const nox = @import("nox");
const ast = nox.ast;

fn parse(allocator: std.mem.Allocator, source: []const u8) !ast.Module {
    const tokens = try nox.lexer.tokenize(allocator, source);
    return nox.parser.parseModule(allocator, tokens);
}

test "unary eksi ile üs alma Python önceliğini izler: -2 ** 2 == -(2 ** 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(), "x: int = -2 ** 2\n");
    const value = module.body[0].var_decl.value;
    try std.testing.expect(value == .unary);
    try std.testing.expectEqual(ast.UnaryOp.neg, value.unary.op);
    const inner = value.unary.operand.*;
    try std.testing.expect(inner == .binary);
    try std.testing.expectEqual(ast.BinaryOp.pow, inner.binary.op);
}

test "while gövdesi ve dönüş değeri olmayan return ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(),
        \\def loop() -> None:
        \\    while True:
        \\        return
        \\
    );
    const fd = module.body[0].func_def;
    const while_stmt = fd.body[0].while_stmt;
    try std.testing.expectEqual(ast.Expr.bool_lit, @as(std.meta.Tag(ast.Expr), while_stmt.cond));
    try std.testing.expectEqual(@as(?ast.Expr, null), while_stmt.body[0].return_stmt);
}

test "sınıf tanımı yalnızca metodlardan oluşur ve self açıkça tiplenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(),
        \\class Point:
        \\    def __init__(self: Point, x: int) -> None:
        \\        self.x = x
        \\
    );
    const class_def = module.body[0].class_def;
    try std.testing.expectEqualStrings("Point", class_def.name);
    try std.testing.expectEqual(@as(usize, 1), class_def.methods.len);
    const init_method = class_def.methods[0];
    try std.testing.expectEqualStrings("self", init_method.params[0].name);
    try std.testing.expectEqualStrings("Point", init_method.params[0].type_expr.simple);
}

test "zincirlenmiş obj.attr çağrısı ve indeksleme ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(), "y: int = xs[0].value()\n");
    const value = module.body[0].var_decl.value;
    try std.testing.expect(value == .call);
    try std.testing.expect(value.call.callee.* == .attribute);
    try std.testing.expect(value.call.callee.attribute.obj.* == .index);
}
