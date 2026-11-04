//! Tarayıcıda çalışan Nox derleyicisinin ön yüzü (`noxc-frontend.wasm`, spec §3.353): `noxc build --target ...`nin ürettiği LLVM IR ile BYTE-BİREBİR aynı IR üretmelidir (aynı `frontend.zig`
//! kodu, stdlib gömülü). Seçili fixture'lar 6 wasm hedefinin hepsinde karşılaştırılır; hata yolları (sözdizimi, tip, yetenek yasağı) ve bağlama planı da denetlenir.
//! Tüm korpus için: `python3 scripts/wasm_frontend_corpus.py`. `node` yoksa testler atlanır.

const std = @import("std");
const build_options = @import("build_options");

const targets = [_][]const u8{ "wasm32-wasi", "wasm32-freestanding", "wasm32-wasi-asyncify", "wasm32-freestanding-asyncify", "wasm32-wasi-threads", "wasm32-freestanding-threads" };

const fixtures = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "hello", .source = "print(\"hi\")\n" },
    .{ .name = "async_spawn_await", .source = @embedFile("codegen_cases/async_spawn_await.nox") },
    .{ .name = "sqlite_memory_roundtrip", .source = @embedFile("codegen_cases/sqlite_memory_roundtrip.nox") },
    .{ .name = "fs_tree_semantics", .source = @embedFile("codegen_cases/fs_tree_semantics.nox") },
    .{ .name = "json_encode_roundtrip", .source = @embedFile("codegen_cases/json_encode_roundtrip.nox") },
    .{ .name = "regex_engine", .source = @embedFile("codegen_cases/regex_engine.nox") },
    .{ .name = "async_channel", .source = @embedFile("codegen_cases/async_channel.nox") },
};

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !?std.process.RunResult {
    return std.process.run(allocator, std.testing.io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024 * 1024) }) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
}

fn expectSame(allocator: std.mem.Allocator, tmp_dir: []const u8, name: []const u8, source: []const u8, target: []const u8) !void {
    const io = std.testing.io;
    const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}.nox", .{ tmp_dir, name });
    defer allocator.free(src_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src_path, .data = source });

    // Yerel `noxc build` .ll dosyasını çıktının yanına bırakır.
    const wasm_path = try std.fmt.allocPrint(allocator, "{s}/{s}.out.wasm", .{ tmp_dir, name });
    defer allocator.free(wasm_path);
    const ll_path = try std.fmt.allocPrint(allocator, "{s}/{s}.out.ll", .{ tmp_dir, name });
    defer allocator.free(ll_path);
    const native = (try run(allocator, &.{ build_options.noxc_path, "build", "--target", target, src_path, "-o", wasm_path })) orelse return error.SkipZigTest;
    defer allocator.free(native.stdout);
    defer allocator.free(native.stderr);
    if (native.term != .exited or native.term.exited != 0) {
        // zig/wasm-opt yoksa bağlama başarısız olur ama .ll yazılmış olur; ön yüz karşılaştırması yine yapılabilir. Başka hata gerçek hatadır.
        if (std.mem.indexOf(u8, native.stderr, "zig cc failed") == null and std.mem.indexOf(u8, native.stderr, "zig not found") == null and std.mem.indexOf(u8, native.stderr, "wasm-opt") == null) {
            std.debug.print("{s} [{s}]: yerel derleme basarisiz: {s}\n", .{ name, target, native.stderr });
            return error.NativeBuildFailed;
        }
    }
    const native_ir = try std.Io.Dir.cwd().readFileAlloc(io, ll_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(native_ir);

    const fe = (try run(allocator, &.{ "node", "--no-warnings", build_options.frontend_driver_path, build_options.frontend_wasm_path, src_path, target })) orelse return error.SkipZigTest;
    defer allocator.free(fe.stdout);
    defer allocator.free(fe.stderr);
    if (fe.term != .exited or fe.term.exited != 0) {
        std.debug.print("{s} [{s}]: on yuz basarisiz: {s}\n", .{ name, target, fe.stderr });
        return error.FrontendFailed;
    }
    if (!std.mem.eql(u8, native_ir, fe.stdout)) {
        std.debug.print("{s} [{s}]: IR farkli (yerel {d} bayt, on yuz {d} bayt)\n", .{ name, target, native_ir.len, fe.stdout.len });
        return error.IrDiffers;
    }
}

test "wasm ön yüzü: yerel noxc ile byte-birebir aynı LLVM IR (6 hedef x seçili fixture'lar)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir = path_buf[0..len];
    for (targets) |t| {
        for (fixtures) |f| try expectSame(allocator, dir, f.name, f.source, t);
    }
}

test "wasm ön yüzü: sözdizimi, tip ve yetenek hataları okunaklı tanılama verir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const cases = [_]struct { src: []const u8, deny: []const u8, needle: []const u8 }{
        .{ .src = "print(1 2)\n", .deny = "", .needle = "syntax error: unexpected '2' (expected ')')" },
        .{ .src = "x: int = \"a\"\n", .deny = "", .needle = "type error (TypeMismatch)" },
        .{ .src = "import nox.fs\nnox.fs.write_string(\"/tmp/a\", \"x\")\n", .deny = "fs", .needle = "the capability 'filesystem' is denied" },
        .{ .src = "import nox.tls\nprint(1)\n", .deny = "", .needle = "cannot be used on the wasm32" },
        .{ .src = "import nox.nonexistent\nprint(1)\n", .deny = "", .needle = "import error" },
    };
    for (cases, 0..) |c, i| {
        const src_path = try std.fmt.allocPrint(allocator, "{s}/err{d}.nox", .{ path_buf[0..len], i });
        defer allocator.free(src_path);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = src_path, .data = c.src });
        const fe = (try run(allocator, &.{ "node", "--no-warnings", build_options.frontend_driver_path, build_options.frontend_wasm_path, src_path, "wasm32-freestanding", c.deny })) orelse return error.SkipZigTest;
        defer allocator.free(fe.stdout);
        defer allocator.free(fe.stderr);
        try std.testing.expect(fe.term == .exited and fe.term.exited == 1);
        if (std.mem.indexOf(u8, fe.stderr, c.needle) == null) {
            std.debug.print("beklenen '{s}', gelen: {s}\n", .{ c.needle, fe.stderr });
            return error.WrongDiagnostic;
        }
    }
}

test "wasm ön yüzü: bağlama planı (sqlite, fs/vfs dışa aktarımları, asyncify + fetch, threads)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const src_path = try std.fmt.allocPrint(allocator, "{s}/plan.nox", .{path_buf[0..len]});
    defer allocator.free(src_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = src_path, .data = @embedFile("codegen_cases/sqlite_memory_roundtrip.nox") });
    const fe = (try run(allocator, &.{ "node", "--no-warnings", build_options.frontend_driver_path, build_options.frontend_wasm_path, src_path, "wasm32-freestanding-threads", "", "--plan" })) orelse return error.SkipZigTest;
    defer allocator.free(fe.stdout);
    defer allocator.free(fe.stderr);
    try std.testing.expect(fe.term == .exited and fe.term.exited == 0);
    for ([_][]const u8{ "\"runtime\":\"noxrt-wasm32-freestanding-threads\"", "\"compilerRt\":\"compiler-rt-wasm32-threads.a\"", "\"sqlite\":true", "\"threadsFeatures\":true", "-Wl,--shared-memory", "-Wl,--export=nox_vfs_host_snapshot", "-Wl,--export=nox_host_thread_start" }) |needle| {
        if (std.mem.indexOf(u8, fe.stdout, needle) == null) {
            std.debug.print("plan '{s}' icermiyor: {s}\n", .{ needle, fe.stdout });
            return error.WrongPlan;
        }
    }
}
