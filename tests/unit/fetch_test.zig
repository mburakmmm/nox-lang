//! Faz O §P.5 birim testleri: `compiler/pkg/fetch.zig`nin `fetchToCache`i.
//!
//! **Kritik test tasarımı kısıtı (bkz. plan dosyası):** testler GERÇEK
//! `github.com`a ASLA dokunmamalı. Fixture'lar test kurulumunda ALT
//! SÜREÇLE (`git init`+dosya+commit) inşa edilen YEREL git repo'ları
//! (`std.testing.tmpDir` içinde), fetcher bu YEREL yola yönlendirilir;
//! `$NOX_HOME` de HER test İÇİN AYRI bir geçici dizine yönlendirilir
//! (gerçek `~/.nox`a ASLA dokunulmaz — bkz. `fetchToCache`'in `nox_home`
//! parametresi, tam da bu hermetik-test senaryosu İÇİN tasarlandı).

const std = @import("std");
const nox = @import("nox");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

/// `dir` içinde `git init` + tek bir commit içeren minimal bir depo kurar,
/// commit edilen dosyanın adını/içeriğini YAZAR. Gerçek `git rev-parse
/// HEAD`in DÖNDÜRECEĞİ SHA'yı bağımsız olarak hesaplamak İÇİN kullanılır
/// (testin KENDİ beklentisi, `fetchToCache`in KENDİ hesaplamasına
/// GÜVENMEDEN, ayrı bir `git rev-parse` çağrısıyla DOĞRULANIR).
fn initFixtureRepo(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const steps = [_][]const []const u8{
        &.{ "git", "init", "-q", "-b", "main" },
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "." },
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "-m", "init" },
    };
    for (steps) |argv| {
        const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = dir_path } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("fixture git komutu basarisiz: {s}\n", .{result.stderr});
            return error.FixtureSetupFailed;
        }
    }
}

fn revParseHead(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = .{ .path = dir_path },
    });
    defer allocator.free(result.stderr);
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

test "fetchToCache: yerel fixture repo getirilir, resolved sha bagimsiz git rev-parse ile eslesir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = "print(\"merhaba paket\")\n" });

    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = try absPath(io, src.dir, &src_buf);
    try initFixtureRepo(io, std.testing.allocator, src_path);
    const expected_sha = try revParseHead(io, a, src_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    const result = try nox.fetch.fetchToCache(a, io, home_path, src_path, "main");
    try std.testing.expectEqualStrings(expected_sha, result.resolved_sha);

    // Getirilen içerik gercekten önbellek dizininde olmali.
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/lib.nox", .{result.cache_dir}), .{});
}

test "fetchToCache: ayni repo+ref icin iki kez cagirmak ayni sonucu uretir (idempotent)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src = std.testing.tmpDir(.{});
    defer src.cleanup();
    try src.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = "print(\"tekrar\")\n" });

    var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src_path = try absPath(io, src.dir, &src_buf);
    try initFixtureRepo(io, std.testing.allocator, src_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    const first = try nox.fetch.fetchToCache(a, io, home_path, src_path, "main");
    const second = try nox.fetch.fetchToCache(a, io, home_path, src_path, "main");

    try std.testing.expectEqualStrings(first.resolved_sha, second.resolved_sha);
    try std.testing.expectEqualStrings(first.cache_dir, second.cache_dir);
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/lib.nox", .{second.cache_dir}), .{});
}

test "fetchToCache: farkli iki fixture repo ayni NOX_HOME altinda cakismadan bir arada yasar" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var src1 = std.testing.tmpDir(.{});
    defer src1.cleanup();
    try src1.dir.writeFile(io, .{ .sub_path = "a.nox", .data = "print(\"a\")\n" });
    var src1_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src1_path = try absPath(io, src1.dir, &src1_buf);
    try initFixtureRepo(io, std.testing.allocator, src1_path);

    var src2 = std.testing.tmpDir(.{});
    defer src2.cleanup();
    try src2.dir.writeFile(io, .{ .sub_path = "b.nox", .data = "print(\"b\")\n" });
    var src2_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const src2_path = try absPath(io, src2.dir, &src2_buf);
    try initFixtureRepo(io, std.testing.allocator, src2_path);

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    const r1 = try nox.fetch.fetchToCache(a, io, home_path, src1_path, "main");
    const r2 = try nox.fetch.fetchToCache(a, io, home_path, src2_path, "main");

    try std.testing.expect(!std.mem.eql(u8, r1.cache_dir, r2.cache_dir));
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/a.nox", .{r1.cache_dir}), .{});
    try std.Io.Dir.cwd().access(io, try std.fmt.allocPrint(a, "{s}/b.nox", .{r2.cache_dir}), .{});
}
