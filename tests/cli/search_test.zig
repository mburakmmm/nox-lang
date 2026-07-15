//! Faz Y.1 golden testi: `noxc search`i (bkz. `compiler/pkg/index.zig`nin
//! modül üstü notu) `subcommand_test.zig` İLE AYNI desende — kurulu
//! `zig-out/bin/noxc`yi GERÇEK bir alt süreç olarak çalıştırarak — doğrular.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

const FIXTURE_INDEX =
    \\{"packages": [
    \\  {"name": "noxhttp-extras", "repo": "github.com/example/noxhttp-extras",
    \\   "description": "nox.http icin yardimci fonksiyonlar", "tags": ["http", "web"]},
    \\  {"name": "noxcolor", "repo": "github.com/example/noxcolor",
    \\   "description": "Terminal renklendirme"}
    \\]}
;

test "noxc search: sorgu olmadan tum katalogu listeler" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = FIXTURE_INDEX });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const index_path = try std.fmt.allocPrint(a, "{s}/index.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxhttp-extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxcolor") != null);
}

test "noxc search: sorgu eslesen TEK paketi doner" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = FIXTURE_INDEX });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const index_path = try std.fmt.allocPrint(a, "{s}/index.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path, "http" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxhttp-extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxcolor") == null);
}

test "noxc search: eslesme yoksa acik bir mesaj basar" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = FIXTURE_INDEX });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const index_path = try std.fmt.allocPrint(a, "{s}/index.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path, "hicbiryerde" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expectEqualStrings("eslesen paket bulunamadi\n", result.stdout);
}

test "noxc search: bozuk indeks dosyasi net bir hatayla cikis kodu 1 doner" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{ bozuk" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    var buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&buf, "{s}/bad.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
}
