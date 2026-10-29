//! Faz 10 (WASM, bkz. nox-teknik-spesifikasyon.md): `noxc build --target wasm32-wasi` uçtan uca — LLVM `.ll` -> `zig cc -target wasm32-wasi` ->
//! `.wasm`, Node'un WASI'siyle çalıştırılır. Her fixture `codegen_cases/` korpusundan alınır; beklenen çıktı native (QBE/LLVM) çalıştırmayla AYNIDIR
//! (Python referansıyla doğrulanmış `.expected`). Kapsanan alanlar: ABI uyarlaması (32-bit işaretçi / 64-bit sözcük), düz (atomik olmayan) ARC,
//! döngü çözücü, iz arabelleği, async üreteç (iç içe çalıştırma benzetimi), kapanış yakalamada Channel retain'i, JSON, fs/regex/gzip/crypto kabukları,
//! çoklu kalıtım vtable'ları. Ayrıca wasm'de olmayan modüllerin DERLEME ZAMANINDA açık iletiyle reddedildiği doğrulanır.
//!
//! Her fixture HEM `wasm32-wasi` HEM `wasm32-freestanding` (ADR-013, `nox_host` import'ları) hedefinde çalışır.
//! `node`/`zig` PATH'te yoksa test SESSİZCE atlanır. Tüm korpus için opt-in `zig build wasm-corpus-test`.

const std = @import("std");
const build_options = @import("build_options");
const wasm_helpers = @import("wasm_helpers.zig");

fn expectGolden(name: []const u8, source: []const u8, expected: []const u8) !void {
    inline for (.{ wasm_helpers.Target.wasi, wasm_helpers.Target.freestanding }) |t| try expectGoldenOn(t, name, source, expected);
}

fn expectGoldenOn(target: wasm_helpers.Target, name: []const u8, source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const outcome = try wasm_helpers.buildAndRun(allocator, build_options.noxc_path, build_options.runner_path, target, source);
    switch (outcome) {
        .tool_missing => return error.SkipZigTest,
        .rejected => |msg| {
            defer allocator.free(msg);
            std.debug.print("{s} [{s}]: wasm hedefinde reddedildi: {s}\n", .{ name, wasm_helpers.targetName(target), msg });
            return error.UnexpectedlyRejected;
        },
        .build_failed => |msg| {
            defer allocator.free(msg);
            std.debug.print("{s} [{s}]: wasm derlemesi basarisiz: {s}\n", .{ name, wasm_helpers.targetName(target), msg });
            return error.BuildFailed;
        },
        .ran => |r| {
            defer allocator.free(r.stdout);
            defer allocator.free(r.stderr);
            if (r.term != .exited or r.term.exited != 0) {
                std.debug.print("{s} [{s}]: wasm programi basarisiz (stderr): {s}\n", .{ name, wasm_helpers.targetName(target), r.stderr });
                return error.ProgramFailed;
            }
            try std.testing.expectEqualStrings(expected, r.stdout);
        },
    }
}

fn expectRejected(source: []const u8, needle: []const u8) !void {
    try expectRejectedOn(.wasi, source, needle);
    try expectRejectedOn(.freestanding, source, needle);
}

fn expectRejectedOn(target: wasm_helpers.Target, source: []const u8, needle: []const u8) !void {
    const allocator = std.testing.allocator;
    const outcome = try wasm_helpers.buildAndRun(allocator, build_options.noxc_path, build_options.runner_path, target, source);
    switch (outcome) {
        .tool_missing => return error.SkipZigTest,
        .rejected => |msg| {
            defer allocator.free(msg);
            try std.testing.expect(std.mem.indexOf(u8, msg, needle) != null);
        },
        .build_failed => |msg| {
            defer allocator.free(msg);
            std.debug.print("beklenen ret degil, baska bir derleme hatasi: {s}\n", .{msg});
            return error.BuildFailed;
        },
        .ran => |r| {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
            return error.ExpectedRejection;
        },
    }
}

test "wasm32-wasi: fibonacci (özyineleme + while + print)" {
    try expectGolden("fibonacci", @embedFile("codegen_cases/fibonacci.nox"), @embedFile("codegen_cases/fibonacci.expected"));
}

test "wasm32-wasi: float yazdırma Python repr ile birebir (printf değişken argüman ABI'si)" {
    try expectGolden("float_repr_python", @embedFile("codegen_cases/float_repr_python.nox"), @embedFile("codegen_cases/float_repr_python.expected"));
}

test "wasm32-wasi: list/dict comprehension + sınıf + istisna mesajı" {
    try expectGolden("comprehensions", @embedFile("codegen_cases/comprehensions.nox"), @embedFile("codegen_cases/comprehensions.expected"));
    try expectGolden("exception_str_message", @embedFile("codegen_cases/exception_str_message.nox"), @embedFile("codegen_cases/exception_str_message.expected"));
    try expectGolden("dunder_protocol", @embedFile("codegen_cases/dunder_protocol.nox"), @embedFile("codegen_cases/dunder_protocol.expected"));
}

test "wasm32-wasi: çoklu kalıtım vtable'ları ({i32,i32} çift sabitleri)" {
    try expectGolden("multiple_inheritance_mixins", @embedFile("codegen_cases/multiple_inheritance_mixins.nox"), @embedFile("codegen_cases/multiple_inheritance_mixins.expected"));
    try expectGolden("multiple_inheritance_subtyping", @embedFile("codegen_cases/multiple_inheritance_subtyping.nox"), @embedFile("codegen_cases/multiple_inheritance_subtyping.expected"));
}

test "wasm32-wasi: döngü çözücü + iz arabelleği 8 baytlık yuvalar" {
    try expectGolden("class_reference_cycle_collected", @embedFile("codegen_cases/class_reference_cycle_collected.nox"), @embedFile("codegen_cases/class_reference_cycle_collected.expected"));
    try expectGolden("cycle_nested_list_class_fields", @embedFile("codegen_cases/cycle_nested_list_class_fields.nox"), @embedFile("codegen_cases/cycle_nested_list_class_fields.expected"));
}

test "wasm32-wasi: jeneratörler ve async üreteçler (Channel parametresi kapanışta retain edilir)" {
    try expectGolden("generators_auto_close", @embedFile("codegen_cases/generators_auto_close.nox"), @embedFile("codegen_cases/generators_auto_close.expected"));
    try expectGolden("async_generators", @embedFile("codegen_cases/async_generators.nox"), @embedFile("codegen_cases/async_generators.expected"));
}

test "wasm32-wasi: JSON, regex, gzip, sha256, fs kabukları" {
    try expectGolden("json_encode_roundtrip", @embedFile("codegen_cases/json_encode_roundtrip.nox"), @embedFile("codegen_cases/json_encode_roundtrip.expected"));
    try expectGolden("regex_engine", @embedFile("codegen_cases/regex_engine.nox"), @embedFile("codegen_cases/regex_engine.expected"));
    try expectGolden("gzip_roundtrip", @embedFile("codegen_cases/gzip_compress_decompress_str_roundtrip.nox"), @embedFile("codegen_cases/gzip_compress_decompress_str_roundtrip.expected"));
    try expectGolden("crypto_sha256", @embedFile("codegen_cases/crypto_sha256_known_vectors.nox"), @embedFile("codegen_cases/crypto_sha256_known_vectors.expected"));
    try expectGoldenOn(.wasi, "fs_read_write_roundtrip", @embedFile("codegen_cases/fs_read_write_roundtrip.nox"), @embedFile("codegen_cases/fs_read_write_roundtrip.expected"));
}

test "wasm32-wasi: soket gerektiren modül derleme zamanında açık iletiyle reddedilir" {
    try expectRejected("import nox.http\nprint(1)\n", "cannot be used on the wasm32-wasi target");
    try expectRejected("import nox.sqlite\nprint(1)\n", "cannot be used on the wasm32-wasi target");
}

test "wasm32-wasi: HPy/WASM köprü yerleşikleri reddedilir" {
    try expectRejected("print(wasm_call(\"a.wasm\", \"f\", 1))\n", "cannot be used on the wasm32-wasi target");
}

test "wasm32-freestanding: nox_host stdout/stderr, ortam tablosu, argv[0], libm" {
    // Yalnızca freestanding'e özgü davranışlar: boş başlangıç ortamı + modüle özel set_var, argv[0] = "nox", math (compiler-rt + atan2).
    try expectGoldenOn(.freestanding, "os_new_operations", @embedFile("codegen_cases/os_new_operations.nox"), @embedFile("codegen_cases/os_new_operations.expected"));
    try expectGoldenOn(.freestanding, "os_args_basic", @embedFile("codegen_cases/os_args_basic.nox"), @embedFile("codegen_cases/os_args_basic.expected"));
    try expectGoldenOn(.freestanding, "mathx_basic", @embedFile("codegen_cases/mathx_basic.nox"), @embedFile("codegen_cases/mathx_basic.expected"));
}

test "wasm32-freestanding: nox.fs derleme zamanında reddedilir (dosya sistemi yok), wasi'de çalışır" {
    try expectRejectedOn(.freestanding, "import nox.fs\nprint(1)\n", "cannot be used on the wasm32-freestanding target");
}
