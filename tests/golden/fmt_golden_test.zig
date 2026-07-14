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

fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, null, .empty);

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
        .argv = &.{ "qbe", "-t", nox.qbe_target.name(), "-o", asm_path, ssa_path },
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
