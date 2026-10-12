//! v2.0 madde 8 (bkz. nox-teknik-spesifikasyon.md §3.196): kamuya açık
//! `--target`/`--emit-asm` bayraklarının GERÇEK `noxc build` çağrılarıyla
//! doğrulanması — üretilen ikilinin ham ELF başlığından DOĞRU mimari
//! olduğu (`freestanding_link_test.zig`/`kernel_boot_x86_64_test.zig`nin
//! ZATEN kullandığı, harici bir araca [`file`/`readelf`] BAĞIMLI OLMAYAN
//! yöntemle) + geçersiz kombinasyonların (riscv64 linksiz, profil/hedef
//! uyuşmazlığı) AÇIK bir hatayla reddedildiği.
//!
//! `windows-x64` hedefi BİLİNÇLİ olarak TAM LİNK doğrulaması YAPMAZ —
//! stok/vendored `qbe` sürümlerinin `amd64_win` backend'inde GERÇEK,
//! BİLİNEN bir upstream ABI hatası VAR (bir spill/reload kopyası YANLIŞ
//! register sınıfı [`Kl`, `instr->cls` YERİNE] kullanıyor — `movsd %r10,
//! ...` GİBİ geçersiz bir komut ÜRETİYOR; bkz. `.github/workflows/
//! release.yml`nin Windows işinin KENDİ `winabi.c` METİN-YAMASI, "GERÇEK
//! bir upstream amd64_win ABI hatasının metin-yaması"). BU projenin
//! standart CI qbe kurulumu (macOS/Linux runner'ları, `ci.yml`) BU YAMAYA
//! SAHİP DEĞİL — bu YÜZDEN windows-x64 SADECE `--emit-asm` (ham `.s`,
//! linksiz) İLE doğrulanır, TAM link denenmez.
//!
//! `qbe`/`zig`/`noxc` (henüz kurulmamışsa) PATH'te/`zig-out`ta YOKSA test
//! SESSİZCE `SkipZigTest` İLE atlanır (bu ailenin AYNI ilkesi).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const EM_X86_64: u16 = 62;
const EM_AARCH64: u16 = 183;
const EM_RISCV: u16 = 243;

fn elfMachine(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[18..20], .little);
}

/// Bağlanan ikili ReleaseFast'te hâlâ debug bilgisi taşıyabildiği için
/// 100 MB'ı aşabiliyor. e_ident ve e_machine başlığın ilk 64 baytında.
fn openBuilt(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !std.Io.File {
    return dir.openFile(io, sub_path, .{}) catch |err| {
        if (builtin.os.tag != .windows) return err;
        const exe_name = try std.fmt.allocPrint(std.testing.allocator, "{s}.exe", .{sub_path});
        defer std.testing.allocator.free(exe_name);
        return dir.openFile(io, exe_name, .{});
    };
}

fn readElfHeader(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ![64]u8 {
    const file = try openBuilt(io, dir, sub_path);
    defer file.close(io);
    var scratch: [256]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, &scratch);
    var hdr: [64]u8 = undefined;
    try reader.interface.readSliceAll(&hdr);
    return hdr;
}

fn expectElf(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, machine: u16) !void {
    const hdr = try readElfHeader(io, dir, sub_path);
    try std.testing.expect(std.mem.eql(u8, hdr[0..4], "\x7fELF"));
    try std.testing.expectEqual(machine, elfMachine(&hdr));
}

fn runNoxcBuild(allocator: std.mem.Allocator, io: std.Io, extra: []const []const u8, src_path: []const u8, out_path: []const u8) !std.process.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, build_options.noxc_path);
    try argv.append(allocator, "build");
    try argv.appendSlice(allocator, extra);
    try argv.appendSlice(allocator, &.{ src_path, "-o", out_path });
    return std.process.run(allocator, io, .{ .argv = argv.items }) catch return error.SkipZigTest;
}

fn writeTrivialFixture(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = "print(1 + 2)\n" });
}

test "v2.0 madde 8: --target linux-x64 dogru e_machine'li bir ELF uretir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_linux_x64", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "linux-x64" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build --target linux-x64 basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }

    try expectElf(io, tmp.dir, "out_linux_x64", EM_X86_64);
}

test "v2.0 madde 8: --target linux-arm64 dogru e_machine'li bir ELF uretir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_linux_arm64", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "linux-arm64" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build --target linux-arm64 basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }

    try expectElf(io, tmp.dir, "out_linux_arm64", EM_AARCH64);
}

test "v2.0.4: --target linux-riscv64 dogru e_machine'li statik bir ELF uretir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_linux_riscv64", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "linux-riscv64" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build --target linux-riscv64 basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }

    try expectElf(io, tmp.dir, "out_linux_riscv64", EM_RISCV);
}

test "v2.0 madde 8: --target x86_64 --profile freestanding dogru e_machine'li bir ELF uretir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_fs_x86_64", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "x86_64", "--profile", "freestanding" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build --target x86_64 --profile freestanding basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }

    try expectElf(io, tmp.dir, "out_fs_x86_64", EM_X86_64);
}

test "v2.0 madde 8: --target aarch64 --profile freestanding dogru e_machine'li bir ELF uretir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_fs_aarch64", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "aarch64", "--profile", "freestanding" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build --target aarch64 --profile freestanding basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }

    try expectElf(io, tmp.dir, "out_fs_aarch64", EM_AARCH64);
}

test "v2.0 madde 8: --target windows-x64 --emit-asm ham .s uretir (tam link, bilinen amd64_win qbe hatasi yuzunden denenmez)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_win", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "windows-x64", "--emit-asm" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build --target windows-x64 --emit-asm basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }

    const s_path = try std.fmt.allocPrint(allocator, "{s}.s", .{out_path});
    defer allocator.free(s_path);
    const stat = try std.Io.Dir.cwd().statFile(io, s_path, .{});
    try std.testing.expect(stat.size > 0);
}

test "v2.0 madde 8: --target riscv64 --profile freestanding (linksiz) acik bir hatayla reddedilir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_riscv64", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "riscv64", "--profile", "freestanding" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "riscv64") != null);
}

test "v2.0 madde 8: --target riscv64 --profile freestanding --emit-asm HALA calisir (ham .s)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_riscv64_asm", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "riscv64", "--profile", "freestanding", "--emit-asm" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build --target riscv64 --emit-asm basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }
    const s_path = try std.fmt.allocPrint(allocator, "{s}.s", .{out_path});
    defer allocator.free(s_path);
    const stat = try std.Io.Dir.cwd().statFile(io, s_path, .{});
    try std.testing.expect(stat.size > 0);
}

test "v2.0 madde 8: profil/hedef uyusmazligi (hosted isim + freestanding profili) acik bir hatayla reddedilir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_bad1", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "linux-x64", "--profile", "freestanding" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
}

test "v2.0 madde 8: profil/hedef uyusmazligi (freestanding mimari adi + hosted profili) acik bir hatayla reddedilir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_bad2", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{ "--target", "x86_64" }, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
}

test "v2.0 madde 8: --target VERILMEDEN (varsayilan) davranis DEGISMEZ" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    try writeTrivialFixture(io, tmp.dir, "t.nox");
    const src_path = try std.fmt.allocPrint(allocator, "{s}/t.nox", .{dir_path});
    defer allocator.free(src_path);
    const out_path = try std.fmt.allocPrint(allocator, "{s}/out_default", .{dir_path});
    defer allocator.free(out_path);

    const result = try runNoxcBuild(allocator, io, &.{}, src_path, out_path);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("noxc build (varsayilan) basarisiz: {s}\n", .{result.stderr});
        return error.NoxcBuildFailed;
    }
    const stat = std.Io.Dir.cwd().statFile(io, out_path, .{}) catch |err| blk: {
        if (builtin.os.tag != .windows) return err;
        const exe_path = try std.fmt.allocPrint(allocator, "{s}.exe", .{out_path});
        defer allocator.free(exe_path);
        break :blk try std.Io.Dir.cwd().statFile(io, exe_path, .{});
    };
    try std.testing.expect(stat.size > 0);
}
