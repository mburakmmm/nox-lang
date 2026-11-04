//! Faz 10 (WASM): `wasm_target_test.zig` ve `wasm_corpus_test.zig`nin ortak yardımcıları — `noxc build --target wasm32-wasi|wasm32-freestanding` ile derleyip
//! `compiler/wasm_host.mjs` (Node) ile çalıştırır.
//!
//! **KRİTİK** (bkz. `compile_helpers.zig`nin AYNI notu): bu dosyada HİÇBİR `test` bloğu OLMAMALIDIR.

const std = @import("std");

pub const Outcome = union(enum) {
    /// `node` ya da `zig` bulunamadı — çağıran testi `SkipZigTest` ile atlar.
    tool_missing,
    /// Derleyici hedef için bu programı reddetti (ör. `nox.http` wasm32'de yok); ileti `stderr`de.
    rejected: []const u8,
    /// Derleme başka bir nedenle başarısız oldu.
    build_failed: []const u8,
    ran: std.process.RunResult,
};

/// `source`u geçici bir dizinde `.wasm`a derler ve çalıştırır. `noxc_path`/`runner_path` göreli ya da mutlak olabilir.
pub const Target = enum { wasi, freestanding, wasi_asyncify, freestanding_asyncify, wasi_threads, freestanding_threads };

pub fn targetName(t: Target) []const u8 {
    return switch (t) {
        .wasi => "wasm32-wasi",
        .freestanding => "wasm32-freestanding",
        .wasi_asyncify => "wasm32-wasi-asyncify",
        .freestanding_asyncify => "wasm32-freestanding-asyncify",
        .wasi_threads => "wasm32-wasi-threads",
        .freestanding_threads => "wasm32-freestanding-threads",
    };
}

pub fn buildAndRun(allocator: std.mem.Allocator, noxc_path: []const u8, runner_path: []const u8, target: Target, source: []const u8) !Outcome {
    return buildAndRunRepeated(allocator, noxc_path, runner_path, target, source, &.{}, 1);
}

/// Derler ve `runs` kez (her seferinde `extra_args` ile) çalıştırır. Dönen `ran` sonucunun `stdout`u TÜM çalıştırmaların çıktısının art arda eklenmiş halidir,
/// `term` SON çalıştırmanınkidir; herhangi bir çalıştırma başarısızsa o anda durur. Kalıcı sanal dosya sistemi (`--vfs-dir=`) testleri içindir.
pub fn buildAndRunRepeated(allocator: std.mem.Allocator, noxc_path: []const u8, runner_path: []const u8, target: Target, source: []const u8, extra_args: []const []const u8, runs: usize) !Outcome {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    const src_path = try std.fmt.allocPrint(allocator, "{s}/prog.nox", .{dir_path});
    defer allocator.free(src_path);
    const wasm_path = try std.fmt.allocPrint(allocator, "{s}/prog.wasm", .{dir_path});
    defer allocator.free(wasm_path);

    const build = std.process.run(allocator, io, .{
        .argv = &.{ noxc_path, "build", "--target", targetName(target), src_path, "-o", wasm_path },
    }) catch |err| {
        if (err == error.FileNotFound) return .tool_missing;
        return err;
    };
    defer allocator.free(build.stdout);
    if (build.term != .exited or build.term.exited != 0) {
        if (std.mem.indexOf(u8, build.stderr, "zig not found") != null or std.mem.indexOf(u8, build.stderr, "needs 'wasm-opt'") != null) {
            allocator.free(build.stderr);
            return .tool_missing;
        }
        if (std.mem.indexOf(u8, build.stderr, "wasm32-wasi target") != null or std.mem.indexOf(u8, build.stderr, "wasm32-freestanding target") != null) return .{ .rejected = build.stderr };
        return .{ .build_failed = build.stderr };
    }
    allocator.free(build.stderr);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "node", "--no-warnings", runner_path, wasm_path });
    try argv.appendSlice(allocator, extra_args);

    var all_stdout: std.ArrayListUnmanaged(u8) = .empty;
    errdefer all_stdout.deinit(allocator);
    var last: ?std.process.RunResult = null;
    var n: usize = 0;
    while (n < runs) : (n += 1) {
        const run = std.process.run(allocator, io, .{ .argv = argv.items }) catch |err| {
            if (err == error.FileNotFound) return .tool_missing;
            return err;
        };
        try all_stdout.appendSlice(allocator, run.stdout);
        allocator.free(run.stdout);
        if (last) |l| allocator.free(l.stderr);
        last = run;
        if (run.term != .exited or run.term.exited != 0) break;
    }
    var result = last.?;
    result.stdout = try all_stdout.toOwnedSlice(allocator);
    return .{ .ran = result };
}
