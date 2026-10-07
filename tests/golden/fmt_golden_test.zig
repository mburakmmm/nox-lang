//! `noxc fmt` (Faz T.4b) golden testleri — formatlayıcının (1) İDEMPOTENT
//! olduğunu (aynı kaynağı İKİNCİ KEZ formatlamak SONUCU DEĞİŞTİRMEZ), (2)
//! çalışma zamanı DAVRANIŞINI DEĞİŞTİRMEDİĞİNİ (formatlanmış kaynak, orijinal
//! İLE AYNI stdout'u üretir) VE (3) yorumları/boş satırları KAYBETMEDİĞİNİ
//! kanıtlar. `compileAndRun`, `tests/golden/codegen_golden_test.zig`
//! İLE AYNI yapıdadır (kasıtlı bir kod tekrarı — bu dosyanın BAĞIMSIZ
//! kalması, paylaşılan bir yardımcı çıkarmaktan daha basit, bkz. AGENTS.md
//! genelindeki YERLEŞİK desen).

const std = @import("std");
const nox = @import("nox");

fn formatSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const result = try nox.lexer.tokenizeWithTrivia(allocator, source);
    const module = try nox.parser.parseModule(allocator, result.tokens);
    return nox.formatter.formatModule(allocator, module, result.trivia);
}

// Precedence-farkındalıklı parens mantığının KENDİSİNİ (bkz.
// `formatter.zig`nin `printExprAt`i) doğrudan, ÇALIŞMA ZAMANI davranışına
// DOLAYLI bağlı OLMADAN sınar — `(a + b) * 2` İÇİNDEKİ GEREKLİ parens
// KORUNMALIDIR (aksi halde `a + b * 2`e "sadeleşir", FARKLI bir değer
// hesaplar). Tam TERSİNE `(a + b) + c` İÇİNDEKİ GEREKSİZ parens ATILMALIDIR
// (`a + b + c`e "sadeleşir" — anlamca AYNI, ama daha OKUNAKLI).
test "fmt: gerekli parens KORUNUR, gereksiz parens ATILIR (precedence)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "y: int = (a + b) * 2\n", .out = "y: int = (a + b) * 2\n" },
        .{ .in = "y: int = (a + b) + c\n", .out = "y: int = a + b + c\n" },
        .{ .in = "y: int = a + (b + c)\n", .out = "y: int = a + (b + c)\n" },
        .{ .in = "y: int = (a - b) - c\n", .out = "y: int = a - b - c\n" },
        .{ .in = "y: int = a - (b - c)\n", .out = "y: int = a - (b - c)\n" },
        .{ .in = "y: int = (a ** b) ** c\n", .out = "y: int = (a ** b) ** c\n" },
        .{ .in = "y: int = a ** (b ** c)\n", .out = "y: int = a ** b ** c\n" },
        .{ .in = "y: bool = not (a == b)\n", .out = "y: bool = not a == b\n" },
    };
    for (cases) |c| {
        const got = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "fmt: v1.147.0 — varsayılan parametre ve keyword argüman İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "def f(a: int, b: int = 2, c: str = \"x\") -> int:\n    pass\n", .out = "def f(a: int, b: int = 2, c: str = \"x\") -> int:\n    pass\n" },
        .{ .in = "def f(a: int, b: int=-2) -> int:\n    pass\n", .out = "def f(a: int, b: int = -2) -> int:\n    pass\n" },
        .{ .in = "y: int = f(1, b=2)\n", .out = "y: int = f(1, b=2)\n" },
        .{ .in = "y: int = f(b = 2, a = 1)\n", .out = "y: int = f(b=2, a=1)\n" },
        .{ .in = "y: int = f(a=1 if c else 2)\n", .out = "y: int = f(a=1 if c else 2)\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.146.0 — üçlü ifade İDEMPOTENT round-trip ve parantezleme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "y: int = a if c else b\n", .out = "y: int = a if c else b\n" },
        .{ .in = "y: int = (a if c else b)\n", .out = "y: int = a if c else b\n" },
        .{ .in = "y: int = a if c else (b if d else e)\n", .out = "y: int = a if c else b if d else e\n" },
        .{ .in = "y: int = (a if c else b) if d else e\n", .out = "y: int = (a if c else b) if d else e\n" },
        .{ .in = "y: int = (a if c else b) + 1\n", .out = "y: int = (a if c else b) + 1\n" },
        .{ .in = "y: int = 1 + (a if c else b)\n", .out = "y: int = 1 + (a if c else b)\n" },
        .{ .in = "y: bool = a or b if c and d else e\n", .out = "y: bool = a or b if c and d else e\n" },
        .{ .in = "print(a if c else b)\n", .out = "print(a if c else b)\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.145.0 — in/not in İDEMPOTENT round-trip ve öncelik" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "y: bool = a in b\n", .out = "y: bool = a in b\n" },
        .{ .in = "y: bool = a not in b\n", .out = "y: bool = a not in b\n" },
        .{ .in = "y: bool = (a in b) and (c not in d)\n", .out = "y: bool = a in b and c not in d\n" },
        .{ .in = "y: bool = not (a in b)\n", .out = "y: bool = not a in b\n" },
        .{ .in = "y: bool = (a + 1) in b\n", .out = "y: bool = a + 1 in b\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.144.0 — break/continue İDEMPOTENT round-trip (girinti korunur)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const src = "while True:\n    if x:\n        break\n    for k in range(3):\n        if k == 1:\n            continue\n        print(k)\n";
    const once = try formatSource(allocator, src);
    try std.testing.expectEqualStrings(src, once);
    const twice = try formatSource(allocator, once);
    try std.testing.expectEqualStrings(once, twice);
}

// Faz FFI.4: `extern def`nin YENİ `retains(...)` yan tümcesinin
// formatlayıcı TARAFINDAN İDEMPOTENT/KAYIPSIZ yeniden ÜRETİLDİĞİNİN kanıtı
// (`with_rt`nin AYNI, MEVCUT davranışıyla TUTARLI).
test "fmt: extern def retains(...) yan tümcesi İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const src = "extern def foo(x: list[int]) -> None from \"lib\" retains(x)\n";
    const got = try formatSource(allocator, src);
    try std.testing.expectEqualStrings(src, got);
}

fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    // `codegen_golden_test.zig`nin `compileAndRun`ıyla AYNI düzeltme
    // (güvenlik bulgusu H-2'nin `genDictGet`e eklediği `KeyError` raise
    // yolu, HER `d[key]` ifadesinde — çalışma zamanında tetiklenmese
    // BİLE — `core.nox`nin `KeyError` sınıfının codegen'in `self.classes`
    // kaydında BULUNMASINI gerektirir; core.nox HİÇ birleştirilmeden
    // ÇALIŞAN bu test harness'ı, `kitchen_sink.nox`nin `headers["a"]`
    // dict-okuması İLE bu boşluğu İLK KEZ AÇIĞA ÇIKARDI — `module_loader.
    // resolveImports` EKSİKTİ, `codegen_golden_test.zig` ZATEN doğru
    // yapıyordu).
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
    checker_state.checkModule(module) catch |e| {
        std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        return error.FixtureNotWellTyped;
    };
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ d.code, d.message });
        }
        return error.FixtureNotWellTyped;
    }

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(allocator, k.*);

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, checker_state.decorated_functions.items, .qbe, .hosted, null, &.{}, .empty);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ssa_path = try std.fmt.allocPrint(allocator, "{s}/prog.ssa", .{dir_path});
    const asm_path = try std.fmt.allocPrint(allocator, "{s}/prog.s", .{dir_path});
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/prog", .{dir_path});

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ssa", .data = ir });

    const qbe_result = try std.process.run(allocator, io, .{
        .argv = &.{ "qbe", "-t", nox.qbe_target.name(false), "-o", asm_path, ssa_path },
    });
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz: {s}\n", .{qbe_result.stderr});
        return error.QbeFailed;
    }

    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{ "cc", "-rdynamic", "-o", bin_path, asm_path, "zig-out/lib/noxrt.o", "-lm" },
    });
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.CcFailed;
    }

    return std.process.run(allocator, io, .{ .argv = &.{bin_path} });
}

test "fmt: kitchen_sink.nox formatlamak İDEMPOTENTTİR (iki kez formatlamak AYNI sonucu verir)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("fmt_cases/kitchen_sink.nox");

    const once = try formatSource(allocator, source);
    const twice = try formatSource(allocator, once);
    try std.testing.expectEqualStrings(once, twice);
}

test "fmt: kitchen_sink.nox formatlamak çalışma zamanı davranışını DEĞİŞTİRMEZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("fmt_cases/kitchen_sink.nox");
    const formatted = try formatSource(allocator, source);

    const original_result = try compileAndRun(allocator, source);
    if (original_result.term != .exited or original_result.term.exited != 0) {
        std.debug.print("orijinal program basarisiz cikti: {s}\n", .{original_result.stderr});
        return error.ProgramFailed;
    }
    const formatted_result = try compileAndRun(allocator, formatted);
    if (formatted_result.term != .exited or formatted_result.term.exited != 0) {
        std.debug.print("formatlanmis program basarisiz cikti: {s}\n", .{formatted_result.stderr});
        return error.ProgramFailed;
    }
    try std.testing.expectEqualStrings(original_result.stdout, formatted_result.stdout);
}

test "fmt: standalone/trailing yorumlar VE sınıf/metod gövdeleri korunur" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("fmt_cases/kitchen_sink.nox");
    const formatted = try formatSource(allocator, source);

    try std.testing.expect(std.mem.indexOf(u8, formatted, "# standalone yorum: modül başı") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "# trailing yorum: alan ataması") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "# standalone yorum: gövde içi") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "class MyError:") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "except MyError as e:") != null);
}

// Faz FF.4 (bkz. nox-teknik-spesifikasyon.md §3.63): `nox fmt`in çıplak
// `self`i `self: ClassName`e "GENİŞLETMEDİĞİNİN" (normalize-ETMEME'nin)
// AÇIK kanıtı — salt idempotentlik YETERSİZDİR, HER ZAMAN `self: X`e
// "genişleten" bozuk bir formatlayıcı da idempotent OLURDU. Açık
// `self: Counter`nin de DEĞİŞMEDEN kaldığı AYRI bir örnekle (aynı tabloda)
// İKİ yüzey biçiminin de KENDİ SABİT NOKTASI olduğu (birbirine
// "normalize" OLMADIĞI) kanıtlanır.
test "fmt: çıplak self normalize EDİLMEZ, açık self: Tip de DEĞİŞMEDEN kalır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{
            .in = "class Counter:\n    def bump(self) -> None:\n        pass\n",
            .out = "class Counter:\n    def bump(self) -> None:\n        pass\n",
        },
        .{
            .in = "class Counter:\n    def bump(self: Counter) -> None:\n        pass\n",
            .out = "class Counter:\n    def bump(self: Counter) -> None:\n        pass\n",
        },
        .{
            .in = "protocol Shape:\n    def area(self) -> float:\n        pass\n",
            .out = "protocol Shape:\n    def area(self) -> float:\n        pass\n",
        },
    };
    for (cases) |c| {
        const got = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

// Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): AÇIKÇA bildirilen
// sınıf alanları `nox fmt`den SONRA HÂLÂ MEVCUT olmalı — formatlayıcının
// `.class_def` dalı GÜNCELLENMEDEN, bu alanlar SESSİZCE SİLİNİRDİ (dosya
// HÂLÂ parse OLURDU, yalnızca çıkarım-only semantiğe geri dönerdi) —
// bu test O regresyonun DOĞRUDAN kanıtıdır. İKİNCİ bir formatlamanın
// (`formatSource` İKİ KEZ çağrılarak) AYNI sonucu üretmesi (idempotentlik)
// de doğrulanır.
test "fmt: bildirilen sınıf alanları SİLİNMEZ, idempotenttir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "class Point:\n    x: int\n    y: int\n\n    def __init__(self, x: int, y: int) -> None:\n        self.x = x\n        self.y = y\n";
    const formatted_once = try formatSource(allocator, source);
    try std.testing.expect(std.mem.indexOf(u8, formatted_once, "x: int") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted_once, "y: int") != null);
    try std.testing.expectEqualStrings(source, formatted_once);

    const formatted_twice = try formatSource(allocator, formatted_once);
    try std.testing.expectEqualStrings(formatted_once, formatted_twice);
}

test "fmt: v1.153.0 — dilimleme İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "y: list[int] = xs[1:3]\n", .out = "y: list[int] = xs[1:3]\n" },
        .{ .in = "y: list[int] = xs[ : 3 ]\n", .out = "y: list[int] = xs[:3]\n" },
        .{ .in = "y: list[int] = xs[2:]\n", .out = "y: list[int] = xs[2:]\n" },
        .{ .in = "y: list[int] = xs[:]\n", .out = "y: list[int] = xs[:]\n" },
        .{ .in = "y: list[int] = xs[::-1]\n", .out = "y: list[int] = xs[::-1]\n" },
        .{ .in = "y: str = s[1:n+1:2]\n", .out = "y: str = s[1:n + 1:2]\n" },
        .{ .in = "y: list[int] = xs[1:3][0:1]\n", .out = "y: list[int] = xs[1:3][0:1]\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.154.0 — comprehension İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "y: list[int] = [x*x for x in xs]\n", .out = "y: list[int] = [x * x for x in xs]\n" },
        .{ .in = "y: list[int] = [x for x in xs if x>0 if x<9]\n", .out = "y: list[int] = [x for x in xs if x > 0 if x < 9]\n" },
        .{ .in = "y: list[int] = [a+b for a in xs for b in ys]\n", .out = "y: list[int] = [a + b for a in xs for b in ys]\n" },
        .{ .in = "y: dict[str, int] = {k: len(k) for k in names}\n", .out = "y: dict[str, int] = {k: len(k) for k in names}\n" },
        .{ .in = "y: list[int] = [a if c else b for a in xs]\n", .out = "y: list[int] = [a if c else b for a in xs]\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.155.0 — lambda İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "f: (int) -> int = lambda x: x+1\n", .out = "f: (int) -> int = lambda x: x + 1\n" },
        .{ .in = "y: int = apply(lambda a,b: a*b, 1, 2)\n", .out = "y: int = apply(lambda a, b: a * b, 1, 2)\n" },
        .{ .in = "f: () -> int = lambda : 42\n", .out = "f: () -> int = lambda: 42\n" },
        .{ .in = "f: (int) -> (int) -> int = lambda x: lambda y: x + y\n", .out = "f: (int) -> (int) -> int = lambda x: lambda y: x + y\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.156.0 — `is None` / `is not None` ve çok argümanlı print İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "y: bool = a is None\n", .out = "y: bool = a is None\n" },
        .{ .in = "y: bool = a   is   not   None and b\n", .out = "y: bool = a is not None and b\n" },
        .{ .in = "y: bool = a == None\n", .out = "y: bool = a == None\n" },
        .{ .in = "if x is None or y is not None:\n    pass\n", .out = "if x is None or y is not None:\n    pass\n" },
        .{ .in = "print(a,b, sep = \",\", end = \"\")\n", .out = "print(a, b, sep=\",\", end=\"\")\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.157.0 — tuple literal, açma ve çıplak tuple İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "t: tuple[int, str] = (1, \"x\")\n", .out = "t: tuple[int, str] = (1, \"x\")\n" },
        .{ .in = "t: tuple[int, int] = 1,2\n", .out = "t: tuple[int, int] = (1, 2)\n" },
        .{ .in = "y: tuple[int] = (1,)\n", .out = "y: tuple[int] = (1,)\n" },
        .{ .in = "a,b = b,a\n", .out = "a, b = b, a\n" },
        .{ .in = "q, r = divmod2(17, 5)\n", .out = "q, r = divmod2(17, 5)\n" },
        .{ .in = "self.x, self.y = p\n", .out = "self.x, self.y = p\n" },
        .{ .in = "for k,v in d.items():\n    print(k, v)\n", .out = "for k, v in d.items():\n    print(k, v)\n" },
        .{ .in = "def f() -> tuple[int, int]:\n    return 1,2\n", .out = "def f() -> tuple[int, int]:\n    return (1, 2)\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.162.0 — assert, birleşik atama (öz/dizin), zincirleme karşılaştırma, üreteç ifadesi İDEMPOTENT round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "assert  x>0\n", .out = "assert x > 0\n" },
        .{ .in = "assert x>0 , \"neg\"\n", .out = "assert x > 0, \"neg\"\n" },
        .{ .in = "self.n+=1\n", .out = "self.n += 1\n" },
        .{ .in = "xs[i] *=2\n", .out = "xs[i] *= 2\n" },
        .{ .in = "d[k]-=1\n", .out = "d[k] -= 1\n" },
        .{ .in = "ok: bool = 0<x<10\n", .out = "ok: bool = 0 < x < 10\n" },
        .{ .in = "ok: bool = 0<x<=y<10\n", .out = "ok: bool = 0 < x <= y < 10\n" },
        .{ .in = "t: int = sum(v*v for v in xs if v>0)\n", .out = "t: int = sum(v * v for v in xs if v > 0)\n" },
        .{ .in = "x = x + 1\n", .out = "x = x + 1\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.164.0 — f-string ve str.format yüzey biçimi korunur (İDEMPOTENT)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "print(f\"a{x}b {x:>3}\")\n", .out = "print(f\"a{x}b {x:>3}\")\n" },
        .{ .in = "print(f\"{x+1:03d}\")\n", .out = "print(f\"{x + 1:03d}\")\n" },
        .{ .in = "s: str = f\"{{lit}} {d['k']}\"\n", .out = "s: str = f\"{{lit}} {d['k']}\"\n" },
        .{ .in = "print(\"{} and {:>4}\".format(a, b))\n", .out = "print(f\"{a} and {b:>4}\")\n" },
        .{ .in = "s: str = \"a\" + str(x) + \"b\"\n", .out = "s: str = \"a\" + str(x) + \"b\"\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.165.0 — docstring, except (A, B), üç tırnak İDEMPOTENT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "def f() -> None:\n    \"\"\"Doc.\"\"\"\n    pass\n", .out = "def f() -> None:\n    \"\"\"Doc.\"\"\"\n    pass\n" },
        .{ .in = "class A:\n    \"\"\"Doc.\"\"\"\n    def f(self) -> None:\n        pass\n", .out = "class A:\n    \"\"\"Doc.\"\"\"\n    def f(self) -> None:\n        pass\n" },
        .{ .in = "try:\n    pass\nexcept (ValueError,KeyError) as e:\n    pass\n", .out = "try:\n    pass\nexcept (ValueError, KeyError) as e:\n    pass\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}

test "fmt: v1.168.0 — set[T] ve küme literali yüzey biçimi korunur (İDEMPOTENT)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "a: set[int] = {1,2, 3}\n", .out = "a: set[int] = {1, 2, 3}\n" },
        .{ .in = "b: set[int] = {x*x for x in xs if x>0}\n", .out = "b: set[int] = {x * x for x in xs if x > 0}\n" },
        .{ .in = "e: set[str] = set()\n", .out = "e: set[str] = set()\n" },
    };
    for (cases) |c| {
        const once = try formatSource(allocator, c.in);
        try std.testing.expectEqualStrings(c.out, once);
        const twice = try formatSource(allocator, once);
        try std.testing.expectEqualStrings(once, twice);
    }
}
