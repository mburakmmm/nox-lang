//! Faz F.2 (bkz. plan dosyası "capability sistemi"): `noxc build/check
//! --profile <hosted|freestanding>`nin uçtan-uca davranışını, GERÇEK
//! `noxc` alt süreciyle (`tests/cli/explain_test.zig`nin AYNI deseni)
//! doğrular — HER senaryo GERÇEK module_loader birleştirmesinden (bkz.
//! `compiler/module_loader.zig`nin `loadImportsRecursive`ı) GEÇTİĞİNDEN,
//! bu testler `tests/golden/typecheck_golden_test.zig`nin (tek dosya,
//! HİÇ stdlib birleştirmesi YAPMAYAN) SAF tip-kontrolü testlerinin
//! KAPSAYAMADIĞI "transitif yakalama" mekanizmasını da (bkz. plan dosyası
//! "Kritik bulgu") GERÇEKTEN kanıtlar.

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

test "noxc build --profile freestanding: izin verilen bir stdlib modülü (nox.strings) BAŞARIYLA derlenir ve ÇALIŞIR" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.strings
        \\
        \\parts: list[str] = nox.strings.split("a,b,c", ",")
        \\print(len(parts))
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
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    const run_result = try std.process.run(gpa, io, .{ .argv = &.{out_path} });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    try std.testing.expect(run_result.term == .exited and run_result.term.exited == 0);
    try std.testing.expectEqualStrings("3\n", run_result.stdout);
}

test "noxc build --profile freestanding: dogrudan yasakli bir modul (nox.http) reddedilir" {
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
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "kullan") != null);
}

test "noxc build --profile freestanding: TRANSITIF olarak yasakli bir modul (nox.router -> nox.http) reddedilir, hata 'nox.http'yi gosterir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.router
        \\
        \\print("hic calismamali")
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    // KRİTİK: mesaj `nox.router`i DEĞİL `nox.http`yi göstermeli — router'ın
    // KENDİ, transitif bağımlılığı `module_loader.zig`nin merged body'sine
    // router'ın KENDİ statement'larından ÖNCE eklenir (bkz. plan dosyasının
    // "Kritik bulgu"), bu YÜZDEN `collectImports` router'a HİÇ ULAŞMADAN
    // http'yi yakalar.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.http") != null);
}

test "noxc build (varsayilan profil = hosted): nox.http HALA serbestce kullanilabilir (regresyon-yok)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.router
        \\
        \\print("ok")
        \\
    , &tmp);
    defer gpa.free(path);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{path_buf[0..dir_len]});
    defer gpa.free(out_path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", path, "-o", out_path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

test "noxc check --profile freestanding: izin verilen modul kabul, yasakli modul red (link gerekmeden)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const ok_path = try writeTempSource(gpa, io, "import nox.json\n\nprint(1)\n", &tmp);
        defer gpa.free(ok_path);
        const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", "--profile", "freestanding", ok_path } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
    }

    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    {
        const bad_path = try writeTempSource(gpa, io, "import nox.thread\n\nprint(1)\n", &tmp2);
        defer gpa.free(bad_path);
        const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", "--profile", "freestanding", bad_path } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 1);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.thread") != null);
    }
}

test "noxc build --profile bilinmeyen-bir-isim: acik 'bilinmeyen profil' hatasiyla exit 1" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io, "print(1)\n", &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "bilinmeyen-bir-isim", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "bilinmeyen profil") != null);
}
