//! Faz F.3 (bkz. plan dosyası "Dil uzantısı: 'lowlevel:'in 'manuel
//! katman'a genişletilmesi") — kırmızı-takım: `ptr_read_int`/`detach`/
//! `adopt`nin `lowlevel:` DIŞINDA kullanıldığı bir program REDDEDİLİR.
//!
//! v1.95.2 (bkz. nox-teknik-spesifikasyon.md §3.179 — GPT-5.6 incelemesinde
//! bulunup DOĞRULANAN GERÇEK bir hata): DAHA ÖNCE bu kısıtlama SADECE
//! codegen'in `in_lowlevel_depth`inde uygulanıyordu — `noxc check` bu
//! programları TÜR olarak GEÇERLİ sayıp SESSİZCE kabul ediyordu, SADECE
//! `noxc build` codegen aşamasında GENEL bir "desteklenmeyen yapı"
//! mesajıyla reddediyordu (GERÇEK NEDENİ hiç GÖSTERMEDEN). ARTIK
//! checker'ın KENDİSİ de `LowlevelRequired` İLE reddediyor — `noxc check`
//! VE `noxc build` AYNI, DOĞRU/AÇIKLAYICI mesajla (AYNI SEMANTİKLE)
//! BAŞARISIZ olur — `tests/cli/profile_test.zig`nin AYNI "gerçek noxc
//! alt-süreci" deseni.

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

    // v1.95.2: `noxc check`in KENDİSİ de ARTIK reddediyor — DAHA ÖNCE
    // SESSİZCE geçerdi (bkz. modül-üstü belge notu, `check`/`build`
    // semantik tutarsızlığı).
    const check_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", path } });
    defer gpa.free(check_result.stdout);
    defer gpa.free(check_result.stderr);
    try std.testing.expect(check_result.term == .exited and check_result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, check_result.stderr, "LowlevelRequired") != null);

    const build_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", path, "-o", out_path } });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, build_result.stderr, "LowlevelRequired") != null);
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
