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
    const value = module.body[0].kind.var_decl.value;
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
    const fd = module.body[0].kind.func_def;
    const while_stmt = fd.body[0].kind.while_stmt;
    try std.testing.expectEqual(ast.Expr.bool_lit, @as(std.meta.Tag(ast.Expr), while_stmt.cond));
    try std.testing.expectEqual(@as(?ast.Expr, null), while_stmt.body[0].kind.return_stmt);
}

test "sınıf tanımı yalnızca metodlardan oluşur, açıkça tiplenmiş self çalışır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(),
        \\class Point:
        \\    def __init__(self: Point, x: int) -> None:
        \\        self.x = x
        \\
    );
    const class_def = module.body[0].kind.class_def;
    try std.testing.expectEqualStrings("Point", class_def.name);
    try std.testing.expectEqual(@as(usize, 1), class_def.methods.len);
    const init_method = class_def.methods[0];
    try std.testing.expectEqualStrings("self", init_method.params[0].name);
    try std.testing.expectEqualStrings("Point", init_method.params[0].type_expr.simple);
    try std.testing.expectEqual(false, init_method.params[0].self_inferred);
}

// Faz FF.4 (bkz. nox-teknik-spesifikasyon.md §3.63): çıplak `self`
// (anotasyonsuz) bir metodun İLK parametresi olarak KABUL edilir — tipi
// kapsayan sınıfın adı olarak (`self: Point` AÇIKÇA yazılmış GİBİ)
// DOĞRUDAN sentezlenir, `self_inferred` bayrağı bunu İŞARETLER.
test "Faz FF.4: çıplak self kapsayan sınıfa çözülür ve self_inferred işaretlenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(),
        \\class Point:
        \\    def __init__(self, x: int) -> None:
        \\        self.x = x
        \\
        \\    def bump(self) -> None:
        \\        self.x = self.x + 1
        \\
    );
    const class_def = module.body[0].kind.class_def;
    try std.testing.expectEqual(@as(usize, 2), class_def.methods.len);
    for (class_def.methods) |m| {
        try std.testing.expectEqualStrings("self", m.params[0].name);
        try std.testing.expectEqualStrings("Point", m.params[0].type_expr.simple);
        try std.testing.expectEqual(true, m.params[0].self_inferred);
    }
    // `bump`in sonraki parametresi (varsa) VE her metodun DIŞINDAKİ (ör.
    // üst-düzey) bir `self` adlı parametrenin ETKİLENMEDİĞİ ayrı bir testte
    // (aşağıda) doğrulanır.
}

// `self`in ÖZEL anlamı YALNIZCA bir sınıf/protokol gövdesi İÇİNDEDİR —
// üst-düzey bir fonksiyonun `self` adlı bir parametresi HÂLÂ (DEĞİŞMEDEN)
// açık tip anotasyonu GEREKTİRİR.
test "Faz FF.4: üst-düzey fonksiyonda self adlı parametre hâlâ açık tip gerektirir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedToken, parse(arena.allocator(),
        \\def foo(self) -> None:
        \\    pass
        \\
    ));
}

test "zincirlenmiş obj.attr çağrısı ve indeksleme ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(), "y: int = xs[0].value()\n");
    const value = module.body[0].kind.var_decl.value;
    try std.testing.expect(value == .call);
    try std.testing.expect(value.call.callee.* == .attribute);
    try std.testing.expect(value.call.callee.attribute.obj.* == .index);
}

test "Faz U.4.1: (int, int) -> int fonksiyon tip ifadesi ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(),
        \\def apply(f: (int, int) -> int, x: int, y: int) -> int:
        \\    return x + y
        \\
    );
    const fd = module.body[0].kind.func_def;
    const f_type = fd.params[0].type_expr;
    try std.testing.expect(f_type == .func_type);
    try std.testing.expectEqual(@as(usize, 2), f_type.func_type.params.len);
    try std.testing.expectEqualStrings("int", f_type.func_type.params[0].simple);
    try std.testing.expectEqualStrings("int", f_type.func_type.params[1].simple);
    try std.testing.expectEqualStrings("int", f_type.func_type.return_type.simple);
}

test "Faz U.4.1: parametresiz () -> None fonksiyon tip ifadesi ayrıştırılır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(),
        \\def run(callback: () -> None) -> None:
        \\    pass
        \\
    );
    const fd = module.body[0].kind.func_def;
    const cb_type = fd.params[0].type_expr;
    try std.testing.expect(cb_type == .func_type);
    try std.testing.expectEqual(@as(usize, 0), cb_type.func_type.params.len);
    try std.testing.expectEqualStrings("None", cb_type.func_type.return_type.simple);
}

// Güvenlik bulgusu H-3 (bkz. güvenlik raporu, 20 Temmuz 2026) — DÜZELTİLDİ:
// özyinelemeli-iniş ayrıştırıcının HİÇBİR derinlik sınırı YOKTU, bu YÜZDEN
// aşırı iç içe bir ifade `noxc`nin KENDİSİNİ yığın taşmasıyla ÇÖKERTİYORDU
// (50.000 iç içe parantezle DOĞRUDAN doğrulandı). Üç ayrı özyineleme
// vektörünün (parantez/`not`/tekli eksi) HEPSİNİN AYNI paylaşılan sayaçla
// yakalandığını doğrular — makul (500'ün ALTINDA) derinliklerin HÂLÂ
// SORUNSUZ ayrıştığını da (yanlış-pozitif OLMADIĞINI) kanıtlar.
test "güvenlik H-3: aşırı iç içe ifadeler noxc'un kendisini çökertmek yerine RecursionLimitExceeded döner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Makul derinlik (500'ün ALTINDA) — HÂLÂ TEMİZ ayrıştırılmalı.
    {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        try source.appendSlice(allocator, "x: int = ");
        try source.appendNTimes(allocator, '(', 50);
        try source.append(allocator, '1');
        try source.appendNTimes(allocator, ')', 50);
        try source.append(allocator, '\n');
        _ = try parse(allocator, source.items);
    }

    // Parantez iç içeliği (50.000 seviye — GERÇEK repro'nun AYNISI).
    {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        try source.appendSlice(allocator, "x: int = ");
        try source.appendNTimes(allocator, '(', 50_000);
        try source.append(allocator, '1');
        try source.appendNTimes(allocator, ')', 50_000);
        try source.append(allocator, '\n');
        try std.testing.expectError(error.RecursionLimitExceeded, parse(allocator, source.items));
    }

    // `not` zinciri — AYRI bir özyineleme vektörü (parseNot kendi kendini
    // çağırır, parseExpr'in YENİDEN girişinden GEÇMEZ).
    {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        try source.appendSlice(allocator, "x: bool = ");
        var i: usize = 0;
        while (i < 5_000) : (i += 1) try source.appendSlice(allocator, "not ");
        try source.appendSlice(allocator, "True\n");
        try std.testing.expectError(error.RecursionLimitExceeded, parse(allocator, source.items));
    }

    // Tekli eksi zinciri — ÜÇÜNCÜ AYRI özyineleme vektörü (parseUnary).
    {
        var source: std.ArrayListUnmanaged(u8) = .empty;
        try source.appendSlice(allocator, "x: int = ");
        try source.appendNTimes(allocator, '-', 5_000);
        try source.appendSlice(allocator, "1\n");
        try std.testing.expectError(error.RecursionLimitExceeded, parse(allocator, source.items));
    }
}
