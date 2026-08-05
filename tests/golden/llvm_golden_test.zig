//! Faz LLVM.6 (bkz. plan dosyası "`noxc build --release` için deneysel bir
//! LLVM backend'i"): `codegen_golden_test.zig`nin `compileAndRun` desenini
//! İZLER, ama `qbe`/`cc` YERİNE `.ll` yazıp TEK bir `clang -O2` çağrısı
//! yapar (bkz. `compiler/main.zig`nin `buildOne`ındaki AYNI `--release`
//! yolu). Doğrulama BİLİNÇLİ olarak davranışsal (stdout + çıkış kodu) —
//! `codegen_ir_diff_test.zig`nin AKSİNE IR-METNİ karşılaştırması YAPILMAZ
//! (LLVM çıktısı QBE'ninkiyle TEMELDEN farklı metin).
//!
//! **Kapsam BİLİNÇLİ olarak dar** (bkz. planın "Kapsam DIŞI" bölümü):
//! sadece aritmetik/karşılaştırma/`if`/`print(int)` İçeren minimal bir
//! fixture — closure/exception/string/list/dict/float TAMAMEN Kapsam
//! DIŞI kalır (core.nox'un KOŞULSUZ birleştirdiği sınıf-makinesi HARİÇ,
//! bkz. Faz LLVM.5'in bulgusu — O ZATEN göç ETTİRİLDİ).
//!
//! Önkoşul: `clang` sistemde PATH üzerinde bulunmalıdır (bkz. Faz LLVM.5'in
//! belge notu — Homebrew LLVM ya da Apple Command Line Tools'un `clang`ı).

const std = @import("std");
const nox = @import("nox");

fn compileAndRunLlvm(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
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

    var generic_class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_class_it = checker_state.generic_classes.keyIterator();
    while (generic_class_it.next()) |k| try generic_class_names.append(allocator, k.*);

    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try allocator.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(allocator, entry.key_ptr.*, names);
    }

    var functions_used_as_value: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = checker_state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try functions_used_as_value.append(allocator, k.*);

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, checker_state.class_instantiations.items, generic_class_names.items, null, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, functions_used_as_value.items, checker_state.module_aliases, checker_state.decorated_functions.items, .llvm);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ll_path = try std.fmt.allocPrint(allocator, "{s}/prog.ll", .{dir_path});
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/prog", .{dir_path});

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ll", .data = ir });

    // Faz LLVM.5'in `buildOne`ıyla AYNI: TEK `clang -O2` çağrısı (geleneksel
    // `opt|llc|cc` boru hattı DEĞİL), `-rdynamic` (`nox.json`nin `dlsym`
    // deseni İçin — bkz. `codegen_golden_test.zig`nin AYNI notu).
    const clang_result = std.process.run(allocator, io, .{
        .argv = &.{ "clang", "-O2", "-rdynamic", "-o", bin_path, ll_path, "zig-out/lib/noxrt.o", "-lm" },
    }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("clang bulunamadi (PATH'te yok) - bu test 'brew install llvm' gerektirir\n", .{});
            return error.ClangNotFound;
        }
        return err;
    };
    if (clang_result.term != .exited or clang_result.term.exited != 0) {
        std.debug.print("clang basarisiz: {s}\n", .{clang_result.stderr});
        return error.ClangFailed;
    }

    return std.process.run(allocator, io, .{ .argv = &.{bin_path} });
}

fn expectGoldenLlvm(comptime source: []const u8, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRunLlvm(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    if (run_result.stderr.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{run_result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings(expected, run_result.stdout);
}

test "llvm(çalıştır): aritmetik + karşılaştırma + if + print(int)" {
    try expectGoldenLlvm(
        \\x: int = 1
        \\y: int = 2
        \\z: int = x + y
        \\if z == 3:
        \\    print(z)
        \\
    ,
        "3\n",
    );
}

test "llvm(çalıştır): fonksiyon çağrısı + aritmetik (döngü ve bool YOK)" {
    try expectGoldenLlvm(
        \\def add(a: int, b: int) -> int:
        \\    return a + b
        \\
        \\x: int = add(10, 5)
        \\y: int = add(x, 2)
        \\print(y)
        \\
    ,
        "17\n",
    );
}
