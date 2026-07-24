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

/// `noxcPath`in MUTLAK sürümü — `.cwd` İLE farklı bir çalışma dizininde
/// (ör. bir fixture proje kökünde) çalıştırılan alt süreçler İÇİN
/// GEREKLİDİR: `std.process.run`ın `argv[0]`i, GÖRELİ bir yol İSE (`"zig-
/// out/bin/noxc"` gibi) test SÜRECİNİN DEĞİL, `.cwd` İLE VERİLEN YENİ
/// çalışma dizinine göre çözülür — bu YÜZDEN `.cwd` KULLANAN çağrı
/// siteleri BURADAKİ mutlak yolu kullanmalıdır (GERÇEK bir denemede
/// `ENOENT`-benzeri bir `processSpawnPosix` çökmesiyle KEŞFEDİLDİ).
fn noxcAbsPath(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, noxcPath() });
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

fn addFixtureCommit(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8, file_name: []const u8, contents: []const u8) !void {
    // `std.Io.Dir.openAbsolute` bu Zig sürümünde YOK — `project.zig`nin
    // `saveLockfile`i GİBİ, `Dir.cwd()`e MUTLAK bir `sub_path` geçmek
    // (bu API'nin KENDİSİ absolute yolları SAYDAM olarak destekler)
    // ZATEN kanıtlanmış desendir.
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    defer allocator.free(full_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = contents });
    const steps = [_][]const []const u8{
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "add", "." },
        &.{ "git", "-c", "user.email=test@example.com", "-c", "user.name=test", "commit", "-q", "-m", "update" },
    };
    for (steps) |argv| {
        const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .path = dir_path } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("fixture git commit basarisiz: {s}\n", .{result.stderr});
            return error.FixtureSetupFailed;
        }
    }
}

fn fixtureHeadSha(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "rev-parse", "HEAD" }, .cwd = .{ .path = dir_path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

// Faz CC.2 (bkz. nox-teknik-spesifikasyon.md §3.54): `noxc fetch`,
// `resolveImportsForBuild`in "otomatik, gerektiğinde getir" davranışının
// AYNISINI — bir `.nox` dosyası derlemeden, standalone — uygular. İKİNCİ
// çalıştırmanın (fixture repo'nun `.git`i SİLİNDİKTEN SONRA BİLE) BAŞARILI
// olması, `nox.lock`taki kilitli SHA'nın GERÇEKTEN kullanıldığını (`git`e
// TEKRAR dokunulmadığını) kanıtlar — `package_resolution_test`in İLK
// testindeki AYNI "ikinci build offline" deseni.
test "noxc fetch: bagimliligi getirip nox.lock yazar, ikinci calistirmada onbellekten (offline) gecer" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pkg = std.testing.tmpDir(.{});
    defer pkg.cleanup();
    try pkg.dir.writeFile(io, .{ .sub_path = "util.nox", .data = "def double(x: int) -> int:\n    return x * 2\n" });
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg.dir, &pkg_buf);
    try initFixtureRepo(io, std.testing.allocator, pkg_path);

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    const manifest_json = try std.fmt.allocPrint(a,
        \\{{"name":"proj","entry":"main.nox","requires":[{{"alias":"mypkg","repo":"{s}","ref":"main"}}]}}
    , .{pkg_path});
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = manifest_json });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_HOME", home_path);

    const noxc_abs = try noxcAbsPath(io, a);
    const fetch1 = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "fetch" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(fetch1.stdout);
    defer std.testing.allocator.free(fetch1.stderr);
    if (fetch1.term != .exited or fetch1.term.exited != 0) {
        std.debug.print("fetch basarisiz, stderr: {s}\n", .{fetch1.stderr});
    }
    try std.testing.expect(fetch1.term == .exited and fetch1.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, fetch1.stderr, "getirildi: mypkg") != null);
    try proj.dir.access(io, "nox.lock", .{});

    // Fixture repo'nun `.git`i SİLİNİR — ikinci `fetch` `git`e HİÇ
    // dokunmadan (lock+önbellekten) BAŞARILI olmalı, "zaten guncel" basmalı.
    try pkg.dir.deleteTree(io, ".git");
    const fetch2 = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "fetch" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(fetch2.stdout);
    defer std.testing.allocator.free(fetch2.stderr);
    try std.testing.expect(fetch2.term == .exited and fetch2.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, fetch2.stderr, "zaten guncel: mypkg") != null);
}

// `noxc update`, `fetch`in AKSİNE HER bağımlılığı `ref`den KOŞULSUZ
// yeniden çözer — fixture repo'ya İKİNCİ bir commit eklenip `main`
// dalının GERÇEKTEN İLERLEDİĞİ senaryoda, `nox.lock`taki kilitli SHA'nın
// YENİ commit'e GÜNCELLENDİĞİ doğrulanır (eski SHA ARTIK lock'ta
// GÖRÜNMEMELİ).
test "noxc update: dal ilerleyince nox.lock'taki kilitli SHA yeni commit'e guncellenir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pkg = std.testing.tmpDir(.{});
    defer pkg.cleanup();
    try pkg.dir.writeFile(io, .{ .sub_path = "util.nox", .data = "def double(x: int) -> int:\n    return x * 2\n" });
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg.dir, &pkg_buf);
    try initFixtureRepo(io, std.testing.allocator, pkg_path);
    const sha1 = try fixtureHeadSha(io, a, pkg_path);

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    const manifest_json = try std.fmt.allocPrint(a,
        \\{{"name":"proj","entry":"main.nox","requires":[{{"alias":"mypkg","repo":"{s}","ref":"main"}}]}}
    , .{pkg_path});
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = manifest_json });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_HOME", home_path);

    const noxc_abs = try noxcAbsPath(io, a);
    const fetch1 = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "fetch" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(fetch1.stdout);
    defer std.testing.allocator.free(fetch1.stderr);
    try std.testing.expect(fetch1.term == .exited and fetch1.term.exited == 0);

    const lock_after_fetch = try proj.dir.readFileAlloc(io, "nox.lock", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, lock_after_fetch, sha1) != null);

    try addFixtureCommit(io, std.testing.allocator, pkg_path, "extra.nox", "def triple(x: int) -> int:\n    return x * 3\n");
    const sha2 = try fixtureHeadSha(io, a, pkg_path);
    try std.testing.expect(!std.mem.eql(u8, sha1, sha2));

    const update_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "update" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(update_result.stdout);
    defer std.testing.allocator.free(update_result.stderr);
    if (update_result.term != .exited or update_result.term.exited != 0) {
        std.debug.print("update basarisiz, stderr: {s}\n", .{update_result.stderr});
    }
    try std.testing.expect(update_result.term == .exited and update_result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, update_result.stderr, "guncellendi: mypkg") != null);

    const lock_after_update = try proj.dir.readFileAlloc(io, "nox.lock", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, lock_after_update, sha2) != null);
    try std.testing.expect(std.mem.indexOf(u8, lock_after_update, sha1) == null);
}

// Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi" planı —
// GERÇEK, önceden keşfedilmemiş bir hata): `nox.lock`ın VAR OLMA amacı
// ("TEKRARLANABİLİR derlemenin bütün amacı BU", bkz. `project.zig`nin
// `Lockfile`/`LockedPackage` belge notu) — bir `main` dalı kilitlendikten
// SONRA İLERLESE BİLE, `noxc fetch` (`update` DEĞİL) HER ZAMAN kilitli
// SHA'yı kullanmalıdır, ÖNBELLEK dizini SİLİNMİŞ olsa BİLE. Bu test
// DÜZELTMEDEN ÖNCE KIRMIZI olmalıydı (`nox.lock` yanlışlıkla `sha2`ye
// güncellenirdi) — DÜZELTMEDEN SONRA `nox.lock` `sha1`de KALIR.
test "noxc fetch: onbellek silinse bile kilitli SHA'dan sapmaz (dal ilerlemis olsa bile)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pkg = std.testing.tmpDir(.{});
    defer pkg.cleanup();
    try pkg.dir.writeFile(io, .{ .sub_path = "util.nox", .data = "def double(x: int) -> int:\n    return x * 2\n" });
    var pkg_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const pkg_path = try absPath(io, pkg.dir, &pkg_buf);
    try initFixtureRepo(io, std.testing.allocator, pkg_path);
    const sha1 = try fixtureHeadSha(io, a, pkg_path);

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    const manifest_json = try std.fmt.allocPrint(a,
        \\{{"name":"proj","entry":"main.nox","requires":[{{"alias":"mypkg","repo":"{s}","ref":"main"}}]}}
    , .{pkg_path});
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = manifest_json });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home_path = try absPath(io, home.dir, &home_buf);
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_HOME", home_path);

    const noxc_abs = try noxcAbsPath(io, a);

    // 1) Ilk fetch: sha1'i kilitler.
    const fetch1 = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "fetch" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(fetch1.stdout);
    defer std.testing.allocator.free(fetch1.stderr);
    try std.testing.expect(fetch1.term == .exited and fetch1.term.exited == 0);

    const lock_after_fetch1 = try proj.dir.readFileAlloc(io, "nox.lock", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, lock_after_fetch1, sha1) != null);

    // 2) Fixture deposunun "main" dali ILERLER (sha2) — AMA nox.lock HALA sha1 diyor.
    try addFixtureCommit(io, std.testing.allocator, pkg_path, "extra.nox", "def triple(x: int) -> int:\n    return x * 3\n");
    const sha2 = try fixtureHeadSha(io, a, pkg_path);
    try std.testing.expect(!std.mem.eql(u8, sha1, sha2));

    // 3) Onbellek TAMAMEN silinir (ör. "~/.nox'u temizledim", yeni makine,
    // CI onbellek kacirmasi) — nox.lock DOKUNULMAZ, hala sha1 diyor.
    home.dir.deleteTree(io, "pkg") catch {};

    // 4) Ikinci fetch (update DEGIL): onbellek eksik oldugundan git YENIDEN
    // cagrilir, AMA kilitli SHA'nin (sha1) KENDISI getirilmelidir - "main"
    // ADI DEGIL (o ARTIK sha2'ye isaret ediyor).
    const fetch2 = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "fetch" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(fetch2.stdout);
    defer std.testing.allocator.free(fetch2.stderr);
    if (fetch2.term != .exited or fetch2.term.exited != 0) {
        std.debug.print("ikinci fetch basarisiz, stderr: {s}\n", .{fetch2.stderr});
    }
    try std.testing.expect(fetch2.term == .exited and fetch2.term.exited == 0);
    // Yeni `.recached` DepAction'in KENDI mesaji basilmali (bkz. `DepAction.recached`in belge notu) —
    // `.fetched`/`.updated` DEGIL (kilitli SHA DEGISMEDI, sadece YENIDEN onbelleklendi).
    try std.testing.expect(std.mem.indexOf(u8, fetch2.stderr, "onbellek yeniden olusturuldu") != null);

    const lock_after_fetch2 = try proj.dir.readFileAlloc(io, "nox.lock", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, lock_after_fetch2, sha1) != null);
    try std.testing.expect(std.mem.indexOf(u8, lock_after_fetch2, sha2) == null);
}
