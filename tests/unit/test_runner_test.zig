//! Faz O §P.3 birim testleri: `compiler/pkg/test_runner.zig`nin
//! `discoverTestFiles`i — özyinelemeli `*_test.nox` keşfi (derleme/
//! çalıştırma İÇERMEZ, bkz. modül üstü not).

const std = @import("std");
const nox = @import("nox");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

test "discoverTestFiles: ic ice dizinlerde *_test.nox bulunur, digerleri yok sayilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "a_test.nox", .data = "print(1)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "helper.nox", .data = "print(2)\n" });
    try tmp.dir.createDirPath(io, "sub/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/nested/b_test.nox", .data = "print(3)\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/readme.md", .data = "hi\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absPath(io, tmp.dir, &buf);

    const files = try nox.test_runner.discoverTestFiles(a, io, root);
    try std.testing.expectEqual(@as(usize, 2), files.len);

    var found_a = false;
    var found_b = false;
    for (files) |f| {
        if (std.mem.endsWith(u8, f, "a_test.nox")) found_a = true;
        if (std.mem.endsWith(u8, f, "sub/nested/b_test.nox")) found_b = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

test "discoverTestFiles: test dosyasi yoksa bos dizi doner" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "helper.nox", .data = "print(1)\n" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absPath(io, tmp.dir, &buf);

    const files = try nox.test_runner.discoverTestFiles(a, io, root);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}
