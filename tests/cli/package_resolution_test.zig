//! Faz O §P.6 uçtan-uca çapraz-repo golden testi: kurulu `zig-out/bin/noxc`yi
//! (bir ALT SÜREÇ olarak) gerçek bir üçüncü-taraf paket bağımlılığıyla
//! (`nox.json`'ın `requires[]`i, yerel bir git fixture repo'ya işaret eder)
//! `build`/`run` alt komutlarıyla çalıştırıp doğru derlenmiş/çalıştırılmış
//! çıktıyı doğrular. `$NOX_HOME`, `std.testing.environ.createMap` ile
//! MEVCUT ortamın bir kopyası üzerine `NOX_HOME` EKLENEREK izole edilir —
//! gerçek `~/.nox`a ASLA dokunulmaz (bkz. P.5'in AYNI hermetik-test
//! disiplini, `compiler/pkg/fetch.zig`nin `fetchToCache`i).

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

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

test "ucdan uca: nox.json requires ile ucuncu-taraf paket cozumlenir, build+run dogru calisir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1) Fixture "paket": tek bir .nox dosyası ihraç eden yerel bir git repo.
    var pkg = std.testing.tmpDir(.{});
    defer pkg.cleanup();
    try pkg.dir.writeFile(io, .{
        .sub_path = "util.nox",
        .data =
        \\def double(x: int) -> int:
        \\    return x * 2
        \\
        ,
    });
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg.dir, &pkg_buf);
    try initFixtureRepo(io, std.testing.allocator, pkg_path);

    // 2) Fixture "proje": paketi `requires[]` ile bildiren bir nox.json + onu
    // kullanan bir main.nox.
    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);

    const manifest_json = try std.fmt.allocPrint(a,
        \\{{"name":"proj","entry":"main.nox","requires":[{{"alias":"mypkg","repo":"{s}","ref":"main"}}]}}
    , .{pkg_path});
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = manifest_json });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data =
        \\import mypkg.util
        \\
        \\print(mypkg.util.double(21))
        \\
        ,
    });

    // 3) Izole $NOX_HOME: gercek ~/.nox'a HIC dokunulmaz.
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_HOME", home_path);

    const main_path = try std.fmt.allocPrint(a, "{s}/main.nox", .{proj_path});
    const bin_path = try std.fmt.allocPrint(a, "{s}/main", .{proj_path});

    const build_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "build", main_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(build_result.stdout);
    defer std.testing.allocator.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("build basarisiz, stderr: {s}\n", .{build_result.stderr});
    }
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    const run_result = try std.process.run(std.testing.allocator, io, .{ .argv = &.{bin_path} });
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqualStrings("42\n", run_result.stdout);

    // 4) nox.lock yazilmis olmali (SHA ile).
    try proj.dir.access(io, "nox.lock", .{});

    // 5) Kaynak fixture repo YOK EDILSE BILE (lock+onbellek sayesinde)
    // IKINCI bir build TAMAMEN offline basarili olmali.
    try pkg.dir.deleteTree(io, ".git");
    try proj.dir.deleteFile(io, "main");

    const second_build = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "build", main_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(second_build.stdout);
    defer std.testing.allocator.free(second_build.stderr);
    try std.testing.expect(second_build.term == .exited and second_build.term.exited == 0);
}

test "ucdan uca: bilinmeyen alias acik hata mesajiyla basarisiz olur" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);

    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}" });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data = "import unknownpkg.thing\n\nprint(unknownpkg.thing.foo())\n",
    });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_HOME", home_path);

    const main_path = try std.fmt.allocPrint(a, "{s}/main.nox", .{proj_path});
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "build", main_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "bilinmeyen alias") != null);
}

// Faz O §P.7 (bkz. plan dosyası "Faz O" bölümü, nox-teknik-spesifikasyon.md
// §3.6): planın ORİJİNAL endişesi — "iki farklı üçüncü-taraf paketi AYNI
// noktalı adı (ör. ikisi de `util.parse`) ihraç ederse mangling ÇAKIŞIR" —
// bu, P.4'ün `validateManifest`inin (bkz. `project.zig`) `requires[].alias`
// BENZERSİZLİĞİNİ ZORUNLU KILMASIYLA, ayrı bir hash-önekleme şeması
// EKLENMEDEN, ZATEN kapanmıştı: `module_loader`ın mangling'i HER ZAMAN
// alias'ı (projede BENZERSİZLİĞİ GARANTİLİ) segment zincirinin BAŞINA
// koyar, bu yüzden İKİ farklı alias ASLA aynı mangled isme ÇÖZÜLEMEZ. Bu
// test bunu KANITLAR: iki fixture paket, İKİSİ de `util.parse` adlı bir
// fonksiyon İHRAÇ EDER, TEK projede İKİ farklı alias ile TÜKETİLİR — HEM
// linker çakışması OLMADIĞI HEM her çağrı sitesinin KENDİ paketinin
// implementasyonuna (ayırt edilebilir çalışma-zamanı çıktısıyla) doğru
// çözüldüğü doğrulanır.
test "P.7: iki farkli paket ayni adli fonksiyonu ihrac ederse mangling CAKISMAZ" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pkg_a = std.testing.tmpDir(.{});
    defer pkg_a.cleanup();
    try pkg_a.dir.writeFile(io, .{
        .sub_path = "util.nox",
        .data = "def parse(x: int) -> int:\n    return x + 100\n",
    });
    var pkg_a_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_a_path = try absPath(io, pkg_a.dir, &pkg_a_buf);
    try initFixtureRepo(io, std.testing.allocator, pkg_a_path);

    var pkg_b = std.testing.tmpDir(.{});
    defer pkg_b.cleanup();
    try pkg_b.dir.writeFile(io, .{
        .sub_path = "util.nox",
        .data = "def parse(x: int) -> int:\n    return x + 200\n",
    });
    var pkg_b_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_b_path = try absPath(io, pkg_b.dir, &pkg_b_buf);
    try initFixtureRepo(io, std.testing.allocator, pkg_b_path);

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);

    const manifest_json = try std.fmt.allocPrint(a,
        \\{{"name":"proj","entry":"main.nox","requires":[{{"alias":"pkga","repo":"{s}","ref":"main"}},{{"alias":"pkgb","repo":"{s}","ref":"main"}}]}}
    , .{ pkg_a_path, pkg_b_path });
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = manifest_json });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data =
        \\import pkga.util
        \\import pkgb.util
        \\
        \\print(pkga.util.parse(1))
        \\print(pkgb.util.parse(1))
        \\
        ,
    });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_HOME", home_path);

    const main_path = try std.fmt.allocPrint(a, "{s}/main.nox", .{proj_path});
    const bin_path = try std.fmt.allocPrint(a, "{s}/main", .{proj_path});

    const build_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "build", main_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(build_result.stdout);
    defer std.testing.allocator.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("build basarisiz, stderr: {s}\n", .{build_result.stderr});
    }
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    const run_result = try std.process.run(std.testing.allocator, io, .{ .argv = &.{bin_path} });
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqualStrings("101\n201\n", run_result.stdout);
}
