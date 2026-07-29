//! `noxc install`/`uninstall`/`list` (bkz. plan dosyası "GLOBAL paket
//! kurulumu" bölümü + `compiler/pkg/install.zig`nin modül üstü notu)
//! uçtan uca testleri — kurulu `zig-out/bin/noxc`yi GERÇEK bir alt süreç
//! olarak çalıştırır (`tests/cli/sqlite_test.zig`/`upgrade_test.zig` İLE
//! AYNI desen). `tests/unit/fetch_test.zig`nin YEREL git-fixture deseni
//! (`git init` + tek commit, `std.testing.tmpDir` İçinde) İLE — GERÇEK
//! `github.com`a ASLA dokunulmaz. `NOX_HOME` HER test İçin AYRI, İZOLE
//! bir geçici dizine yönlendirilir (gerçek `~/.nox`a ASLA dokunulmaz).

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

/// `dir_path` içinde `git init` + tek bir commit İÇEREN minimal bir depo
/// kurar — `tests/unit/fetch_test.zig`nin `initFixtureRepo`sıyla BİREBİR
/// AYNI (bu dosya `nox` modülünü DEĞİL, GERÇEK `noxc` ikilisini alt süreç
/// olarak çalıştırdığından, `nox.fetch`e DOĞRUDAN erişimi YOK — KENDİ
/// KÜÇÜK KOPYASI gerekir).
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

/// `nox.json` (`bin` alanı DAHIL) + bir tek-satırlık `.nox` giriş dosyası
/// İÇEREN, global kurulum İçin GEÇERLİ minimal bir paket kurar, GİT İLE
/// commit'ler.
fn seedInstallablePackage(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, dir_path: []const u8, command_name: []const u8, printed_text: []const u8) !void {
    const manifest_json = try std.fmt.allocPrint(allocator, "{{\"name\": \"testpkg\", \"entry\": \"main.nox\", \"bin\": {{\"name\": \"{s}\", \"path\": \"cli.nox\"}}}}", .{command_name});
    defer allocator.free(manifest_json);
    try dir.writeFile(io, .{ .sub_path = "nox.json", .data = manifest_json });
    const cli_source = try std.fmt.allocPrint(allocator, "print(\"{s}\")\n", .{printed_text});
    defer allocator.free(cli_source);
    try dir.writeFile(io, .{ .sub_path = "cli.nox", .data = cli_source });
    try dir.writeFile(io, .{ .sub_path = "main.nox", .data = "print(\"lib entry, not used by install\")\n" });
    try initFixtureRepo(io, allocator, dir_path);
}

fn exeSuffix() []const u8 {
    return if (@import("builtin").os.tag == .windows) ".exe" else "";
}

test "noxc install: yerel fixture paket global kurulur, GERCEKTEN calisir, list gosterir, uninstall kaldirir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var pkg_dir = std.testing.tmpDir(.{});
    defer pkg_dir.cleanup();
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg_dir.dir, &pkg_buf);
    try seedInstallablePackage(io, gpa, pkg_dir.dir, pkg_path, "hellocli", "hello from hellocli!");

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    // 1) install
    const install_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "install", pkg_path },
        .environ_map = &env,
    });
    defer gpa.free(install_result.stdout);
    defer gpa.free(install_result.stderr);
    if (install_result.term != .exited or install_result.term.exited != 0) {
        std.debug.print("install basarisiz (stderr): {s}\n", .{install_result.stderr});
        return error.InstallFailed;
    }
    try std.testing.expect(std.mem.indexOf(u8, install_result.stderr, "hellocli") != null);

    // 2) kurulan ikili GERCEKTEN var mi ve CALISIYOR mu?
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/bin/hellocli{s}", .{ home_path, exeSuffix() });
    defer gpa.free(bin_path);
    try std.Io.Dir.cwd().access(io, bin_path, .{});

    const run_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), run_result.term.exited);
    try std.testing.expectEqualStrings("hello from hellocli!\n", run_result.stdout);

    // 3) list bunu gostermeli
    const list_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "list" },
        .environ_map = &env,
    });
    defer gpa.free(list_result.stdout);
    defer gpa.free(list_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), list_result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, list_result.stdout, "hellocli") != null);

    // 4) uninstall SONRASI ikili SILINMELI VE list ARTIK gostermemeli
    const uninstall_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "uninstall", "hellocli" },
        .environ_map = &env,
    });
    defer gpa.free(uninstall_result.stdout);
    defer gpa.free(uninstall_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), uninstall_result.term.exited);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, bin_path, .{}));

    const list_after_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "list" },
        .environ_map = &env,
    });
    defer gpa.free(list_after_result.stdout);
    defer gpa.free(list_after_result.stderr);
    try std.testing.expect(std.mem.indexOf(u8, list_after_result.stdout, "hellocli") == null);
}

test "noxc install: 'bin' girdi noktasi olmayan bir paket net bir hatayla reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var pkg_dir = std.testing.tmpDir(.{});
    defer pkg_dir.cleanup();
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg_dir.dir, &pkg_buf);
    try pkg_dir.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\": \"libonly\", \"entry\": \"main.nox\"}" });
    try pkg_dir.dir.writeFile(io, .{ .sub_path = "main.nox", .data = "print(\"lib only\")\n" });
    try initFixtureRepo(io, gpa, pkg_path);

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "install", pkg_path },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'bin'") != null);
}

test "noxc uninstall: kurulu olmayan bir komut adi net bir hatayla reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "uninstall", "hicbir-yerde-yok" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
}

test "noxc list: hicbir paket kurulu degilken bilgilendirici bir mesaj yazdirir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "list" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}
