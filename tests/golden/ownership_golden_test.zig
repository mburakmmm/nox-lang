//! Sahiplik analizi golden testleri: `tests/golden/ownership_cases/*.nox`
//! kaynaklarını (önce tip denetiminden geçirip) analiz eder ve raporu
//! `*.expected` ile karşılaştırır. AGENTS.md İlke #7; §8 Katman 1 test
//! gereksinimi: her ASAP kararı için hem tahsis hem serbest bırakma noktası.

const std = @import("std");
const nox = @import("nox");

fn expectGolden(comptime source: []const u8, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => |e| {
            std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ e.code, e.message });
            return error.FixtureNotWellTyped;
        },
    }

    const report = try nox.ownership.analyze(allocator, module, &.{}, &.{});
    const dump = try nox.ownership.dumpToAlloc(allocator, report);

    try std.testing.expectEqualStrings(expected, dump);
}

test "golden(ownership): yerel değişken kaçmıyor -> ASAP" {
    try expectGolden(
        @embedFile("ownership_cases/asap_local_no_escape.nox"),
        @embedFile("ownership_cases/asap_local_no_escape.expected"),
    );
}

test "golden(ownership): yeniden atama ek serbest noktası üretir" {
    try expectGolden(
        @embedFile("ownership_cases/asap_reassignment.nox"),
        @embedFile("ownership_cases/asap_reassignment.expected"),
    );
}

test "golden(ownership): return ile kaçış -> ARC" {
    try expectGolden(
        @embedFile("ownership_cases/arc_return_escape.nox"),
        @embedFile("ownership_cases/arc_return_escape.expected"),
    );
}

test "golden(ownership): self.alan atamasıyla kaçış -> ARC" {
    try expectGolden(
        @embedFile("ownership_cases/arc_field_store_escape.nox"),
        @embedFile("ownership_cases/arc_field_store_escape.expected"),
    );
}

test "golden(ownership): liste/çağrı argümanıyla kaçış -> ARC, kaçmayan ASAP kalır" {
    try expectGolden(
        @embedFile("ownership_cases/arc_list_and_call_escape.nox"),
        @embedFile("ownership_cases/arc_list_and_call_escape.expected"),
    );
}

test "golden(ownership): metod alıcısı ve parametreler -> ARC" {
    try expectGolden(
        @embedFile("ownership_cases/arc_method_receiver_and_param.nox"),
        @embedFile("ownership_cases/arc_method_receiver_and_param.expected"),
    );
}

// Faz FF.4 (bkz. nox-teknik-spesifikasyon.md §3.63): `arc_method_receiver_
// and_param.nox` İLE YAPISAL OLARAK BİREBİR AYNI, yalnızca `self: Point`
// YERİNE çıplak `self` — rapor BİREBİR AYNI kalmalı (`self`in her zaman
// `.class` heap-tipli OLMASI, hangi FİZİKSEL alanları taşıdığından
// BAĞIMSIZ olduğundan) — `ownership/analysis.zig`nin GERÇEKTEN sıfır
// değişiklik gerektirdiğinin regresyon-korumalı kanıtı.
test "golden(ownership): Faz FF.4 — çıplak self'li metod alıcısı, açık self İLE AYNI ARC izini üretir" {
    try expectGolden(
        @embedFile("ownership_cases/arc_bare_self_method_receiver.nox"),
        @embedFile("ownership_cases/arc_bare_self_method_receiver.expected"),
    );
}

test "golden(ownership): başka bir değişkene atanan (takma ad) kaynak -> ARC" {
    try expectGolden(
        @embedFile("ownership_cases/arc_alias_escape.nox"),
        @embedFile("ownership_cases/arc_alias_escape.expected"),
    );
}

test "golden(ownership): raise ile fırlatılan yerel -> ARC" {
    try expectGolden(
        @embedFile("ownership_cases/arc_raise_escape.nox"),
        @embedFile("ownership_cases/arc_raise_escape.expected"),
    );
}
