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

// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
// yapılandırılmış tanılamalar") — Aşama 3 kabul kriteri: `ast.Stmt.span`
// TEK-SATIR bir deyim İçin BAŞLANGIÇ token'ından SON tükettiği token'a
// (dahil) kadar doğru hesaplanıyor mu?
test "Stmt.span: tek-satır bir var_decl deyiminin başlangıç/bitiş konumu doğru" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(), "x: int = 1\n");
    const s = module.body[0].span;
    try std.testing.expect(!s.isNone());
    try std.testing.expectEqual(@as(u32, 1), s.start_line);
    try std.testing.expectEqual(@as(u32, 1), s.start_col);
    try std.testing.expectEqual(@as(u32, 1), s.end_line);
    // "x: int = 1" 10 karakter, `\n` konumu (0-tabanlı 10) => sütun 11.
    try std.testing.expectEqual(@as(u32, 11), s.end_col);
}

// Bileşik (çok-satırlı) bir deyimin span'ı TÜM iç içe gövdeyi (SON
// `dedent`e kadar) KAPSAMALI — bkz. `ast.Stmt.span`nin belge notu.
test "Stmt.span: çok-satırlı bir if deyiminin span'ı TÜM iç içe gövdeyi kapsar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(),
        \\def f() -> None:
        \\    if True:
        \\        x: int = 1
        \\
    );
    const fd = module.body[0].kind.func_def;
    const if_span = fd.body[0].span;
    try std.testing.expect(!if_span.isNone());
    try std.testing.expectEqual(@as(u32, 2), if_span.start_line);
    try std.testing.expect(if_span.end_line > if_span.start_line);

    // `f`in KENDİ (func_def) span'ı da if BLOĞUNUN TAMAMINI kapsamalı.
    const f_span = module.body[0].span;
    try std.testing.expectEqual(@as(u32, 1), f_span.start_line);
    try std.testing.expect(f_span.end_line >= if_span.end_line);
}

// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
// yapılandırılmış tanılamalar") — Aşama 4 kabul kriteri: `ParseError`
// KÜMESİ DEĞİŞMEDEN (bkz. AŞAĞIDAKİ mevcut `expectError` testleri), ama
// `Parser.last_diagnostic` GERÇEK `expected`/`found`/`span` bilgisini
// TAŞIYOR mu?
test "Parser.last_diagnostic: expect() başarısızlığında beklenen/bulunan/span doğru" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `x: int` sonrasında `=` BEKLENİR ama `\n` BULUNUR.
    const tokens = try nox.lexer.tokenize(a, "x: int\n");
    var p = nox.parser.Parser.init(a, tokens);
    try std.testing.expectError(error.UnexpectedToken, p.parseModule());
    const d = p.last_diagnostic.?;
    try std.testing.expectEqual(nox.token.TokenKind.assign, d.expected.?);
    try std.testing.expectEqual(nox.token.TokenKind.newline, d.found);
    try std.testing.expect(!d.span.isNone());
    try std.testing.expectEqual(@as(u32, 1), d.span.start_line);
}

test "Parser.last_diagnostic: özyineleme sınırı aşıldığında span dolduruluyor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "x: int = ");
    for (0..600) |_| try src.appendSlice(a, "(");
    try src.appendSlice(a, "1");
    for (0..600) |_| try src.appendSlice(a, ")");
    try src.appendSlice(a, "\n");

    const tokens = try nox.lexer.tokenize(a, src.items);
    var p = nox.parser.Parser.init(a, tokens);
    try std.testing.expectError(error.RecursionLimitExceeded, p.parseModule());
    const d = p.last_diagnostic.?;
    try std.testing.expect(!d.span.isNone());
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

// Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
// `x += 1` parse-zamanında `x = x + 1`e desugar edilir — AST'nin `.assign`
// düğümünün `.value`i BİR `.binary{.op=.add}` OLMALI, `.target`/`.binary.
// left` AYNI ismi TAŞIMALI (sığ kopya, `.identifier` bir dilim olduğundan
// GÜVENLİ).
test "augmented atama (+=) parse-zamaninda 'x = x + degeri'e desugar edilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(), "x: int = 0\nx += 5\n");
    const assign = module.body[1].kind.assign;
    try std.testing.expect(assign.target == .identifier);
    try std.testing.expectEqualStrings("x", assign.target.identifier);
    try std.testing.expect(assign.value == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, assign.value.binary.op);
    try std.testing.expect(assign.value.binary.left.* == .identifier);
    try std.testing.expectEqualStrings("x", assign.value.binary.left.identifier);
    try std.testing.expect(assign.value.binary.right.* == .int_lit);
    try std.testing.expectEqual(@as(i64, 5), assign.value.binary.right.int_lit);
}

// TÜM 7 augmented-atama operatörünün DOĞRU `BinaryOp`e eşlendiğini doğrular.
test "augmented atamanin 7 operatoru de dogru BinaryOp'e eslenir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { src: []const u8, op: ast.BinaryOp }{
        .{ .src = "x: int = 0\nx += 1\n", .op = .add },
        .{ .src = "x: int = 0\nx -= 1\n", .op = .sub },
        .{ .src = "x: int = 0\nx *= 1\n", .op = .mul },
        .{ .src = "x: int = 0\nx /= 1\n", .op = .div },
        .{ .src = "x: int = 0\nx //= 1\n", .op = .floordiv },
        .{ .src = "x: int = 0\nx %= 1\n", .op = .mod },
        .{ .src = "x: int = 0\nx **= 1\n", .op = .pow },
    };
    for (cases) |c| {
        const module = try parse(arena.allocator(), c.src);
        try std.testing.expectEqual(c.op, module.body[1].kind.assign.value.binary.op);
    }
}

// KRİTİK güvenlik testi (bkz. plan dosyası): `.attribute`/`.index` hedeflerde
// augmented atama REDDEDİLİR — receiver'ı İKİ KEZ değerlendirmenin (yan-etkili
// bir receiver İçin GERÇEK bir çiftleme hatası olurdu) ÖNÜNE GEÇER.
test "augmented atama .attribute/.index hedeflerde REDDEDILIR (receiver cift degerlendirme riski)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedToken, parse(arena.allocator(), "obj.field += 1\n"));
    try std.testing.expectError(error.UnexpectedToken, parse(arena.allocator(), "arr[0] += 1\n"));
}

// F-string desugarı: `f"a{x}b"` → `("a" + str(x)) + "b"` (soldan sağa
// `.binary{.add}` zinciri, ifade segment'leri `str()` çağrısına SARILIR).
test "f-string interpolasyonlu ifade str()+concat zincirine desugar edilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // 3 segment ("a", x, "b") SOLDAN SAĞA katlanır: ((("a" + str(x)) + "b").
    const module = try parse(arena.allocator(), "x: int = 1\ny: str = f\"a{x}b\"\n");
    const value = module.body[1].kind.var_decl.value;
    try std.testing.expect(value == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, value.binary.op);
    // Dış katmanın sağı: "b".
    const outer_right = value.binary.right.*;
    try std.testing.expect(outer_right == .string_lit);
    try std.testing.expectEqualStrings("b", outer_right.string_lit);
    // Dış katmanın solu: ("a" + str(x)).
    const inner = value.binary.left.*;
    try std.testing.expect(inner == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, inner.binary.op);
    const inner_left = inner.binary.left.*;
    try std.testing.expect(inner_left == .string_lit);
    try std.testing.expectEqualStrings("a", inner_left.string_lit);
    const inner_right = inner.binary.right.*;
    try std.testing.expect(inner_right == .call);
    try std.testing.expect(inner_right.call.callee.* == .identifier);
    try std.testing.expectEqualStrings("str", inner_right.call.callee.identifier);
    try std.testing.expectEqual(@as(usize, 1), inner_right.call.args.len);
    try std.testing.expect(inner_right.call.args[0] == .identifier);
    try std.testing.expectEqualStrings("x", inner_right.call.args[0].identifier);
}

// İnterpolasyonSUZ bir f-string doğrudan bir `.string_lit` döner —
// gereksiz birleştirme ÜRETİLMEMELİ.
test "f-string interpolasyonsuz duz .string_lit dondurur (gereksiz concat YOK)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const module = try parse(arena.allocator(), "y: str = f\"duz metin\"\n");
    const value = module.body[0].kind.var_decl.value;
    try std.testing.expect(value == .string_lit);
    try std.testing.expectEqualStrings("duz metin", value.string_lit);
}
