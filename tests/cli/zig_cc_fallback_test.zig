//! v2.0 madde 2: LLVM backend'i `clang` BAŞKA bir C sürücüsü olarak PATH'te yokken `zig cc`'ye düşer (`.ll` girdisini derler).
//! PATH yalnızca `zig` içeren bir dizine daraltılır; `noxc` yine de LLVM yolunu seçmeli (`.ll` üretir, QBE notu basmaz) ve program çalışmalı.

const std = @import("std");
const builtin = @import("builtin");

test "LLVM backend: PATH'te clang yokken zig cc ile derler ve calisir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const which = try std.process.run(gpa, io, .{ .argv = &.{ "sh", "-c", "command -v zig" } });
    defer gpa.free(which.stdout);
    defer gpa.free(which.stderr);
    if (which.term != .exited or which.term.exited != 0) return error.SkipZigTest;
    const zig_path = std.mem.trim(u8, which.stdout, " \n\r");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = try gpa.dupe(u8, path_buf[0..len]);
    defer gpa.free(dir);

    try tmp.dir.createDir(io, "onlyzig", .default_dir);
    const link = try std.fmt.allocPrint(gpa, "{s}/onlyzig/zig", .{dir});
    defer gpa.free(link);
    try std.Io.Dir.symLinkAbsolute(io, zig_path, link, .{});
    const only_zig_dir = try std.fmt.allocPrint(gpa, "{s}/onlyzig", .{dir});
    defer gpa.free(only_zig_dir);

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = "print(6 * 7)\n" });
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const out = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{dir});
    defer gpa.free(out);

    var env_map = try std.testing.environ.createMap(gpa);
    defer env_map.deinit();
    try env_map.put("PATH", only_zig_dir);

    const build = try std.process.run(gpa, io, .{
        .argv = &.{ "zig-out/bin/noxc", "build", "-o", out, src },
        .environ_map = &env_map,
    });
    defer gpa.free(build.stdout);
    defer gpa.free(build.stderr);
    if (build.term != .exited or build.term.exited != 0) {
        std.debug.print("derleme basarisiz: {s}\n", .{build.stderr});
        return error.BuildFailed;
    }
    // QBE'ye sessiz düşüş OLMAMALI: LLVM yolu seçildi (not basılmadı) ve .ll üretildi.
    try std.testing.expect(std.mem.indexOf(u8, build.stderr, "QBE") == null);
    try tmp.dir.access(io, "prog_bin.ll", .{});

    const run = try std.process.run(gpa, io, .{ .argv = &.{out} });
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    try std.testing.expectEqualStrings("42\n", run.stdout);
}
