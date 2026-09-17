//! Faz R.3+F.1 tamamlama (bkz. plan dosyası "Faz R.3 + F.1'in
//! tamamlanması — GERÇEK `noxc build --profile freestanding` cross-link
//! akışı"): `noxc build --profile freestanding`nin, GERÇEK `noxc` alt
//! süreciyle (`tests/cli/profile_test.zig`nin AYNI deseni), UÇTAN UCA
//! GERÇEKTEN derleyip LİNKLEDİĞİNİ kanıtlar — F.0.7 SADECE runtime
//! KAYNAĞININ (`runtime/lib_freestanding.zig`) KENDİ BAŞINA `zig build-obj`
//! İLE derlendiğini kanıtlamıştı, kullanıcı KODU (spawn/await/Task[T]
//! DAHİL) HİÇ dahil DEĞİLDİ — BU dosyanın İLK testi, F.0.7'nin scheduler-
//! DAHİL kapsamının GERÇEK `noxc` CLI'siyle İLK KEZ uçtan-uca kanıtıdır.
//!
//! ÜRETİLEN ikili SADECE `tests/golden/freestanding_link_test.zig`nin AYNI
//! hand-rolled ELF-header doğrulamasıyla (magic + `e_type == ET_EXEC`)
//! kontrol edilir — HİÇBİR YERDE ÇALIŞTIRILMAZ (HENÜZ bir bootloader/
//! linker script YOK, bkz. planın "Kapsam Dışı" bölümü — Faz F.4'ün işi).

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

/// `tests/golden/freestanding_link_test.zig`nin AYNI, ZATEN kanıtlanmış
/// hand-rolled ELF header doğrulaması — magic bytes + `e_type == ET_EXEC`
/// (statik, çalıştırılabilir bir ikili, PIE/paylaşımlı nesne DEĞİL).
fn expectRealElfExecutable(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024));
    defer gpa.free(bytes);
    try std.testing.expect(bytes.len >= 18);
    try std.testing.expectEqualSlices(u8, "\x7fELF", bytes[0..4]);
    const e_type = std.mem.readInt(u16, bytes[16..18], .little);
    try std.testing.expectEqual(@as(u16, 2), e_type); // ET_EXEC
}

test "noxc build --profile freestanding: spawn/await/Task[int] iceren bir program GERCEK bir ELF'e derlenip linklenir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\async def worker(x: int) -> int:
        \\    return x + 1
        \\
        \\t: Task[int] = spawn worker(41)
        \\result: int = await t
        \\print(result)
        \\
    , &tmp);
    defer gpa.free(path);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{path_buf[0..dir_len]});
    defer gpa.free(out_path);

    const build_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path, "-o", out_path } });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("noxc build basarisiz: {s}\n", .{build_result.stderr});
    }
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    try expectRealElfExecutable(gpa, io, out_path);
}

test "noxc build --profile freestanding: spawn'siz basit bir program GERCEK bir ELF'e derlenip linklenir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\x: int = 21
        \\y: int = x + x
        \\print(y)
        \\
    , &tmp);
    defer gpa.free(path);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{path_buf[0..dir_len]});
    defer gpa.free(out_path);

    const build_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path, "-o", out_path } });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("noxc build basarisiz: {s}\n", .{build_result.stderr});
    }
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    try expectRealElfExecutable(gpa, io, out_path);
}

test "noxc build --release --profile freestanding: acik hata ile reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\print("hic calismamali")
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--release", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "freestanding") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "release") != null);
}

test "noxc build --profile freestanding: yasakli bir stdlib modulu (nox.http) checker asamasinda reddedilir (regresyon-yok, F.2)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.http
        \\
        \\print("hic calismamali")
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.http") != null);
}
