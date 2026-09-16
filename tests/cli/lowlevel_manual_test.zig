//! Faz F.3 (bkz. plan dosyası "Dil uzantısı: 'lowlevel:'in 'manuel
//! katman'a genişletilmesi"): kırmızı-takım — `ptr_read_int`/`detach`/
//! `adopt`nin `lowlevel:` DIŞINDA kullanıldığı bir program, checker'ı
//! (tür olarak GEÇERLİ) geçer AMA codegen'in `checkInsideLowlevel`/
//! `in_lowlevel_depth` kontrolü YÜZÜNDEN `error.Unsupported`e (genel,
//! `main.zig`nin ZATEN karşıladığı mesajla) düşer — `tests/cli/profile_
//! test.zig`nin AYNI "gerçek noxc alt-süreci" deseni.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn writeTempSource(gpa: std.mem.Allocator, io: std.Io, source: []const u8, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    return std.fmt.allocPrint(gpa, "{s}/prog.nox", .{path_buf[0..len]});
}

fn expectRejectedOutsideLowlevel(source: []const u8) !void {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io, source, &tmp);
    defer gpa.free(path);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{path_buf[0..dir_len]});
    defer gpa.free(out_path);

    const build_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", path, "-o", out_path } });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, build_result.stderr, "desteklenmeyen bir yapı") != null);
}

test "noxc build: ptr_read_int lowlevel: DIŞINDA kullanılırsa reddedilir" {
    try expectRejectedOutsideLowlevel(
        \\p: ptr = ptr_from_int(0)
        \\v: int = ptr_read_int(p)
        \\print(v)
        \\
    );
}

test "noxc build: detach lowlevel: DIŞINDA kullanılırsa reddedilir" {
    try expectRejectedOutsideLowlevel(
        \\xs: list[int] = [1, 2, 3]
        \\p: ptr = detach(xs)
        \\print(ptr_to_int(p))
        \\
    );
}

test "noxc build: adopt lowlevel: DIŞINDA kullanılırsa reddedilir" {
    try expectRejectedOutsideLowlevel(
        \\p: ptr = ptr_from_int(0)
        \\x: int = adopt(p)
        \\print(x)
        \\
    );
}
