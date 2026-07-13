//! Golden testler: `tests/golden/cases/*.nox` kaynaklarını ayrıştırıp
//! AST dump çıktısını `tests/golden/cases/*.ast.expected` ile karşılaştırır.
//! AGENTS.md İlke #7: her yeni dil davranışı en az bir golden testle gelir.

const std = @import("std");
const nox = @import("nox");

fn expectGolden(comptime source: []const u8, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    const dump = try nox.ast_dump.dumpToAlloc(allocator, module);

    try std.testing.expectEqualStrings(expected, dump);
}

test "golden: değişken tanımı ve aritmetik" {
    try expectGolden(
        @embedFile("cases/var_arith.nox"),
        @embedFile("cases/var_arith.ast.expected"),
    );
}

test "golden: if/elif/else" {
    try expectGolden(
        @embedFile("cases/if_elif_else.nox"),
        @embedFile("cases/if_elif_else.ast.expected"),
    );
}

test "golden: while döngüsü" {
    try expectGolden(
        @embedFile("cases/while_loop.nox"),
        @embedFile("cases/while_loop.ast.expected"),
    );
}

test "golden: for ... in range" {
    try expectGolden(
        @embedFile("cases/for_range.nox"),
        @embedFile("cases/for_range.ast.expected"),
    );
}

test "golden: fonksiyon tanımı ve çağrısı" {
    try expectGolden(
        @embedFile("cases/func_def_call.nox"),
        @embedFile("cases/func_def_call.ast.expected"),
    );
}

test "golden: basit sınıf" {
    try expectGolden(
        @embedFile("cases/simple_class.nox"),
        @embedFile("cases/simple_class.ast.expected"),
    );
}

test "golden: generic fonksiyon tanımı (tip parametreleri)" {
    try expectGolden(
        @embedFile("cases/generic_func_def.nox"),
        @embedFile("cases/generic_func_def.ast.expected"),
    );
}

test "golden: protokol tanımı (yalnızca imza)" {
    try expectGolden(
        @embedFile("cases/protocol_def.nox"),
        @embedFile("cases/protocol_def.ast.expected"),
    );
}

test "golden: extern def (C ABI FFI bildirimi)" {
    try expectGolden(
        @embedFile("cases/extern_def.nox"),
        @embedFile("cases/extern_def.ast.expected"),
    );
}

test "golden: async def + spawn + await + Channel[T](...) inşası + .send" {
    try expectGolden(
        @embedFile("cases/async_spawn_await_channel.nox"),
        @embedFile("cases/async_spawn_await_channel.ast.expected"),
    );
}
