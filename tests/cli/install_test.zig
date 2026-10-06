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

/// v1.33.0 (bkz. nox-teknik-spesifikasyon.md §3.100, "noxc refresh"):
/// `seedInstallablePackage`nin İLK commit'İNDEN SONRA fixture repo'ya
/// İKİNCİ bir commit ekler — `noxc refresh`in GERÇEKTEN yeni bir commit'i
/// ÇEKTİĞİNİ kanıtlamak İçİn (çağıran, BU fonksiyondan ÖNCE dosyaları
/// KENDİSİ değiştirir, ör. `cli.nox`nin İçeriğini).
fn commitFixtureUpdate(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) !void {
    const steps = [_][]const []const u8{
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "." },
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "-m", "update" },
    };
    for (steps) |argv| {
        const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = dir_path } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("fixture git guncelleme komutu basarisiz: {s}\n", .{result.stderr});
            return error.FixtureUpdateFailed;
        }
    }
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

test "noxc refresh <paket>: yeni bir commit SONRASI guncel kodu ceker ve yeniden derler" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var pkg_dir = std.testing.tmpDir(.{});
    defer pkg_dir.cleanup();
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg_dir.dir, &pkg_buf);
    try seedInstallablePackage(io, gpa, pkg_dir.dir, pkg_path, "refreshcli", "surum-1");

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

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

    const bin_path = try std.fmt.allocPrint(gpa, "{s}/bin/refreshcli{s}", .{ home_path, exeSuffix() });
    defer gpa.free(bin_path);
    {
        const run_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
        defer gpa.free(run_result.stdout);
        defer gpa.free(run_result.stderr);
        try std.testing.expectEqualStrings("surum-1\n", run_result.stdout);
    }

    try pkg_dir.dir.writeFile(io, .{ .sub_path = "cli.nox", .data = "print(\"surum-2\")\n" });
    try commitFixtureUpdate(io, gpa, pkg_path);

    const refresh_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "refresh", "refreshcli" },
        .environ_map = &env,
    });
    defer gpa.free(refresh_result.stdout);
    defer gpa.free(refresh_result.stderr);
    if (refresh_result.term != .exited or refresh_result.term.exited != 0) {
        std.debug.print("refresh basarisiz (stderr): {s}\n", .{refresh_result.stderr});
        return error.RefreshFailed;
    }
    try std.testing.expect(std.mem.indexOf(u8, refresh_result.stderr, "guncellendi") != null);

    const run_after = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    defer gpa.free(run_after.stdout);
    defer gpa.free(run_after.stderr);
    try std.testing.expectEqualStrings("surum-2\n", run_after.stdout);
}

test "noxc refresh (argumansiz): TUM kurulu paketleri gunceller" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var pkg_a_dir = std.testing.tmpDir(.{});
    defer pkg_a_dir.cleanup();
    var pkg_a_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_a_path = try absPath(io, pkg_a_dir.dir, &pkg_a_buf);
    try seedInstallablePackage(io, gpa, pkg_a_dir.dir, pkg_a_path, "bulkclia", "a-surum-1");

    var pkg_b_dir = std.testing.tmpDir(.{});
    defer pkg_b_dir.cleanup();
    var pkg_b_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_b_path = try absPath(io, pkg_b_dir.dir, &pkg_b_buf);
    try seedInstallablePackage(io, gpa, pkg_b_dir.dir, pkg_b_path, "bulkclib", "b-surum-1");

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    for ([_][]const u8{ pkg_a_path, pkg_b_path }) |p| {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "install", p }, .environ_map = &env });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) {
            std.debug.print("install basarisiz (stderr): {s}\n", .{r.stderr});
            return error.InstallFailed;
        }
    }

    try pkg_a_dir.dir.writeFile(io, .{ .sub_path = "cli.nox", .data = "print(\"a-surum-2\")\n" });
    try commitFixtureUpdate(io, gpa, pkg_a_path);
    try pkg_b_dir.dir.writeFile(io, .{ .sub_path = "cli.nox", .data = "print(\"b-surum-2\")\n" });
    try commitFixtureUpdate(io, gpa, pkg_b_path);

    const refresh_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "refresh" },
        .environ_map = &env,
    });
    defer gpa.free(refresh_result.stdout);
    defer gpa.free(refresh_result.stderr);
    if (refresh_result.term != .exited or refresh_result.term.exited != 0) {
        std.debug.print("refresh basarisiz (stderr): {s}\n", .{refresh_result.stderr});
        return error.RefreshFailed;
    }

    const bin_a = try std.fmt.allocPrint(gpa, "{s}/bin/bulkclia{s}", .{ home_path, exeSuffix() });
    defer gpa.free(bin_a);
    const bin_b = try std.fmt.allocPrint(gpa, "{s}/bin/bulkclib{s}", .{ home_path, exeSuffix() });
    defer gpa.free(bin_b);

    const run_a = try std.process.run(gpa, io, .{ .argv = &.{bin_a} });
    defer gpa.free(run_a.stdout);
    defer gpa.free(run_a.stderr);
    try std.testing.expectEqualStrings("a-surum-2\n", run_a.stdout);

    const run_b = try std.process.run(gpa, io, .{ .argv = &.{bin_b} });
    defer gpa.free(run_b.stdout);
    defer gpa.free(run_b.stderr);
    try std.testing.expectEqualStrings("b-surum-2\n", run_b.stdout);
}

test "noxc refresh: kurulu olmayan bir paket adi net bir hatayla reddedilir" {
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
        .argv = &.{ noxcPath(), "refresh", "hicbir-yerde-yok" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
}

test "noxc refresh (argumansiz): TOPLU modda TEK bir paketin basarisizligi DIGERINI ENGELLEMEZ" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var pkg_ok_dir = std.testing.tmpDir(.{});
    defer pkg_ok_dir.cleanup();
    var pkg_ok_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_ok_path = try absPath(io, pkg_ok_dir.dir, &pkg_ok_buf);
    try seedInstallablePackage(io, gpa, pkg_ok_dir.dir, pkg_ok_path, "partialok", "ok-surum-1");

    var pkg_bad_dir = std.testing.tmpDir(.{});
    var pkg_bad_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_bad_path = try absPath(io, pkg_bad_dir.dir, &pkg_bad_buf);
    try seedInstallablePackage(io, gpa, pkg_bad_dir.dir, pkg_bad_path, "partialbad", "bad-surum-1");

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    for ([_][]const u8{ pkg_ok_path, pkg_bad_path }) |p| {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "install", p }, .environ_map = &env });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) {
            std.debug.print("install basarisiz (stderr): {s}\n", .{r.stderr});
            return error.InstallFailed;
        }
    }

    // "ok" paketine YENI bir commit ekle.
    try pkg_ok_dir.dir.writeFile(io, .{ .sub_path = "cli.nox", .data = "print(\"ok-surum-2\")\n" });
    try commitFixtureUpdate(io, gpa, pkg_ok_path);

    // "bad" paketinin fixture dizinini TAMAMEN SIL — repo ARTIK erisilemez,
    // `refresh`in KENDI stored repo/ref'iyle yeniden fetch DENEMESI
    // BASARISIZ olmali.
    pkg_bad_dir.cleanup();

    const refresh_result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "refresh" },
        .environ_map = &env,
    });
    defer gpa.free(refresh_result.stdout);
    defer gpa.free(refresh_result.stderr);
    try std.testing.expect(refresh_result.term == .exited and refresh_result.term.exited != 0);

    const bin_ok = try std.fmt.allocPrint(gpa, "{s}/bin/partialok{s}", .{ home_path, exeSuffix() });
    defer gpa.free(bin_ok);
    const run_ok = try std.process.run(gpa, io, .{ .argv = &.{bin_ok} });
    defer gpa.free(run_ok.stdout);
    defer gpa.free(run_ok.stderr);
    try std.testing.expectEqualStrings("ok-surum-2\n", run_ok.stdout);
}

// ---- Önbellek temizliği (bkz. nox-teknik-spesifikasyon.md §3.239) ----

fn isShaName(name: []const u8) bool {
    if (name.len != 40) return false;
    for (name) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// `pkg/mod` altında, `.git` içinde OLMAYAN ve `skip_prefix` ile BAŞLAMAYAN
/// 40-hex adlı dizinlerin sayısı (gerçek paket SHA dizinleri).
fn countShaDirs(io: std.Io, allocator: std.mem.Allocator, home_dir: std.Io.Dir, skip_prefix: []const u8) !usize {
    var mod = home_dir.openDir(io, "pkg/mod", .{ .iterate = true }) catch return 0;
    defer mod.close(io);
    var walker = try mod.walk(allocator);
    defer walker.deinit();
    var n: usize = 0;
    while (try walker.next(io)) |e| {
        if (e.kind != .directory) continue;
        if (std.mem.indexOf(u8, e.path, ".git") != null) continue;
        if (std.mem.startsWith(u8, e.path, skip_prefix)) continue;
        if (isShaName(e.basename)) n += 1;
    }
    return n;
}

fn dirExists(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

fn plantFakeSha(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, mtime_ns: i96) !void {
    try dir.createDirPath(io, sub_path);
    var buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&buf, "{s}/payload.txt", .{sub_path});
    try dir.writeFile(io, .{ .sub_path = file_path, .data = "x" ** 2048 });
    try dir.setTimestamps(io, sub_path, .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(mtime_ns) } });
}

test "noxc refresh: eski SHA onbellek dizini otomatik temizlenir, kurulu SHA korunur" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var pkg_dir = std.testing.tmpDir(.{});
    defer pkg_dir.cleanup();
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg_dir.dir, &pkg_buf);
    try seedInstallablePackage(io, gpa, pkg_dir.dir, pkg_path, "prunecli", "surum-1");

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "install", pkg_path }, .environ_map = &env });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.exited);
    }
    try std.testing.expectEqual(@as(usize, 1), try countShaDirs(io, gpa, home_dir.dir, "fake.example"));

    try pkg_dir.dir.writeFile(io, .{ .sub_path = "cli.nox", .data = "print(\"surum-2\")\n" });
    try commitFixtureUpdate(io, gpa, pkg_path);

    const r2 = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "refresh", "prunecli" }, .environ_map = &env });
    defer gpa.free(r2.stdout);
    defer gpa.free(r2.stderr);
    try std.testing.expectEqual(@as(u8, 0), r2.term.exited);
    // Yeni SHA eklendi AMA eski SHA temizlendi: toplam hâlâ 1.
    try std.testing.expectEqual(@as(usize, 1), try countShaDirs(io, gpa, home_dir.dir, "fake.example"));
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "temizlendi") != null or std.mem.indexOf(u8, r2.stderr, "pruned") != null);

    // Kurulu ikili hâlâ çalışıyor.
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/bin/prunecli{s}", .{ home_path, exeSuffix() });
    defer gpa.free(bin_path);
    const run_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    try std.testing.expectEqualStrings("surum-2\n", run_result.stdout);
}

test "noxc cache prune: --dry-run silmez; varsayilan en yeni+kurulu korur; --all yalniz kurulu korur; eski pkg/tmp sUpurulur" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var pkg_dir = std.testing.tmpDir(.{});
    defer pkg_dir.cleanup();
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg_dir.dir, &pkg_buf);
    try seedInstallablePackage(io, gpa, pkg_dir.dir, pkg_path, "keepcli", "keep");

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "install", pkg_path }, .environ_map = &env });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.exited);
    }

    // Kurulu OLMAYAN sahte bir repo: eski + yeni SHA, ayrıca bayat/taze pkg/tmp girdileri.
    const old_ns: i96 = 1_000_000_000 * 1000;
    const old_sha = "pkg/mod/fake.example/repo/" ++ ("a" ** 40);
    const new_sha = "pkg/mod/fake.example/repo/" ++ ("b" ** 40);
    try plantFakeSha(io, home_dir.dir, old_sha, old_ns);
    try plantFakeSha(io, home_dir.dir, new_sha, old_ns + 10_000_000_000);
    try home_dir.dir.createDirPath(io, "pkg/tmp/stage-stale");
    try home_dir.dir.setTimestamps(io, "pkg/tmp/stage-stale", .{ .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(old_ns) } });
    try home_dir.dir.createDirPath(io, "pkg/tmp/stage-fresh");

    // 1) --dry-run: hiçbir şey silinmez.
    {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "cache", "prune", "--dry-run" }, .environ_map = &env });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.exited);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "silinecek:") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "dry-run") != null);
    }
    try std.testing.expect(dirExists(io, home_dir.dir, old_sha));
    try std.testing.expect(dirExists(io, home_dir.dir, "pkg/tmp/stage-stale"));

    // 2) varsayılan: eski sahte SHA + bayat tmp silinir; yeni sahte SHA (repo'nun en yenisi) + taze tmp + kurulu SHA kalır.
    {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "cache", "prune" }, .environ_map = &env });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.exited);
    }
    try std.testing.expect(!dirExists(io, home_dir.dir, old_sha));
    try std.testing.expect(dirExists(io, home_dir.dir, new_sha));
    try std.testing.expect(!dirExists(io, home_dir.dir, "pkg/tmp/stage-stale"));
    try std.testing.expect(dirExists(io, home_dir.dir, "pkg/tmp/stage-fresh"));
    try std.testing.expectEqual(@as(usize, 1), try countShaDirs(io, gpa, home_dir.dir, "fake.example"));

    // 3) --all: en yeni sahte SHA da gider; kurulu SHA kalır ve ikili çalışır.
    {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "cache", "prune", "--all" }, .environ_map = &env });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.exited);
    }
    try std.testing.expect(!dirExists(io, home_dir.dir, new_sha));
    try std.testing.expectEqual(@as(usize, 1), try countShaDirs(io, gpa, home_dir.dir, "fake.example"));
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/bin/keepcli{s}", .{ home_path, exeSuffix() });
    defer gpa.free(bin_path);
    const run_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    try std.testing.expectEqualStrings("keep\n", run_result.stdout);
}

test "noxc cache: gecersiz alt komut/secenek net bir hatayla reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var home_dir = std.testing.tmpDir(.{});
    defer home_dir.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home_dir.dir, &home_buf);
    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_HOME", home_path);

    const r1 = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "cache" }, .environ_map = &env });
    defer gpa.free(r1.stdout);
    defer gpa.free(r1.stderr);
    try std.testing.expect(r1.term == .exited and r1.term.exited != 0);

    const r2 = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "cache", "prune", "--bogus" }, .environ_map = &env });
    defer gpa.free(r2.stdout);
    defer gpa.free(r2.stderr);
    try std.testing.expect(r2.term == .exited and r2.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "--bogus") != null);

    // Boş bir NOX_HOME'da prune hata vermez.
    const r3 = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "cache", "prune" }, .environ_map = &env });
    defer gpa.free(r3.stdout);
    defer gpa.free(r3.stderr);
    try std.testing.expectEqual(@as(u8, 0), r3.term.exited);
}
