//! Faz HH.1 (bkz. plan dosyası "QBE↔LLVM backend conformance suite"):
//! `codegen_golden_test.zig`nin `compileAndRun`ı VE `llvm_golden_test.zig`nin
//! `compileAndRunLlvm`ı BURAYA taşındı — bu İKİ fonksiyon bu projenin
//! genelde kullandığı "kasıtlı tekrar" konvansiyonundan (küçük, DURAĞAN
//! yardımcılar İçİn — ör. `http_serve_tls_golden_test.zig`nin
//! `tlsRequestAndRead`i) BİLİNÇLİ bir SAPMADIR: bunlar KÜÇÜK DEĞİL (~90
//! satır, ÇOK ADIMLI harici-süreç boru hattı) VE AKTİF olarak EVRİLİYOR
//! (`-rdynamic` GİBİ bayraklar SONRADAN EKLENDİ) — ÜÇÜNCÜ bir bağımsız
//! kopya (YENİ `backend_conformance_test.zig` İçİn) GERÇEK bir gelecekteki
//! drift riski taşırdı — TAM OLARAK BU paketin ÖNLEMEYE ÇALIŞTIĞI hata
//! SINIFI (İKİ backend'in SESSİZCE FARKLI davranması).
//!
//! **KRİTİK**: bu dosyada HİÇBİR `test` bloğu OLMAMALIDIR — Zig'in test-
//! keşfi `@import` edilen dosyaların `test` bloklarını da TOPLAR; bu
//! dosya bir `test` bloğu İçERSEYDİ, onu `@import` EDEN HER dosya
//! (`codegen_golden_test.zig`, `llvm_golden_test.zig`,
//! `backend_conformance_test.zig`) o testi de KENDİ test ikilisine
//! KATARDI — AYNI testler BİRDEN FAZLA KEZ çalışırdı.

const std = @import("std");
const nox = @import("nox");

/// Kaynağı QBE İLE derler, native bir binary üretir ve çalıştırır; ham
/// `RunResult`'ı döner (çıkış kodu/stderr üzerindeki iddialar çağırana
/// bırakılır).
pub fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, checker_state.class_instantiations.items, generic_class_names.items, null, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, functions_used_as_value.items, checker_state.module_aliases, checker_state.decorated_functions.items, .qbe);

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

    // `-rdynamic` ZORUNLUDUR — `runtime/stdlib_shims/json.zig`nin `dlsym`i
    // ana programın KENDİ sembollerini dinamik sembol tablosunda bulmayı
    // gerektirir (bkz. `compiler/main.zig`nin AYNI satırı).
    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{ "cc", "-rdynamic", "-o", bin_path, asm_path, "zig-out/lib/noxrt.o", "-lm" },
    });
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.CcFailed;
    }

    return std.process.run(allocator, io, .{ .argv = &.{bin_path} });
}

/// `compileAndRun`ın AYNISI ama LLVM İLE — `compiler/main.zig`nin
/// `buildOne`ının `--release` yolunu İZLER (`.ll` yazıp TEK bir
/// `clang -O2` çağrısı, geleneksel `opt|llc|cc` boru hattı DEĞİL).
pub fn compileAndRunLlvm(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
    // `checker_state.backend` `--release` altında `.llvm` OLMALIDIR —
    // `isThreadTransferSafeType`/`isSpawnParamSafeType`nin backend-
    // farkındalı gevşetmesi BUNA BAĞLIDIR; `compiler/main.zig`nin
    // `buildOne`sinin GERÇEK sırasıyla TUTARLI (backend HESAPLANIR,
    // SONRA `Checker.init`e ATANIR).
    checker_state.backend = .llvm;
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
