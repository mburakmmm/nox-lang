//! Faz U.2 uçtan-uca golden testi: kurulu `zig-out/bin/noxc`yi (bir ALT
//! SÜREÇ olarak) `nox.json` içeren, proje-içi (birinci-taraf) çoklu-dosya
//! bir programla çalıştırıp `resolveProjectImports`in yeni `project_root`
//! katmanının (bkz. `compiler/module_loader.zig`) doğru çalıştığını
//! kanıtlar — hem doğrudan (`import helpers` -> `<root>/helpers.nox`) hem
//! iç içe (`import utils.mathy` -> `<root>/utils/mathy.nox`) yol, hem de
//! hata yolu (gerçekten var olmayan bir proje-içi modül). `$NOX_HOME`,
//! `package_resolution_test.zig` İLE AYNI izolasyon deseniyle gerçek
//! `~/.nox`a dokunmadan bir geçici dizine yönlendirilir.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

fn isolatedNoxHome(io: std.Io, home_dir: std.Io.Dir, buf: []u8) !std.process.Environ.Map {
    const home_path = try absPath(io, home_dir, buf);
    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    try env_map.put("NOX_HOME", home_path);
    return env_map;
}

test "U.2: dogrudan proje-ici birinci-taraf import (import helpers)" {
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
        .sub_path = "helpers.nox",
        .data = "def double(x: int) -> int:\n    return x * 2\n",
    });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data = "import helpers\n\nprint(helpers.double(21))\n",
    });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env_map = try isolatedNoxHome(io, home.dir, &home_buf);
    defer env_map.deinit();

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
}

test "U.2: ic ice proje-ici birinci-taraf import (import utils.mathy)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);

    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}" });
    try proj.dir.createDirPath(io, "utils");
    try proj.dir.writeFile(io, .{
        .sub_path = "utils/mathy.nox",
        .data = "def triple(x: int) -> int:\n    return x * 3\n",
    });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data = "import utils.mathy\n\nprint(utils.mathy.triple(7))\n",
    });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env_map = try isolatedNoxHome(io, home.dir, &home_buf);
    defer env_map.deinit();

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
    try std.testing.expectEqualStrings("21\n", run_result.stdout);
}

// Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `module_loader.zig`nin
// `renameStmt`/`renameExpr`i (`.class_def`/`.generic_construct` kopyalama
// yolları) DOĞRU çalıştığını — bir generic sınıfın `type_params`ının İMPORT
// SIRASINDA kaybolmadığını (GERÇEK bir hata olarak bulunup düzeltildi) VE
// `resolved_class_name`in modüller arası TAZE bir işaretçi olarak
// kopyalandığını — kanıtlar.
test "P2.1: import edilen bir generic sinif [T](args) ile GERCEKTEN cozulur" {
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
        .sub_path = "helpers.nox",
        .data =
        \\class Box[T]:
        \\    value: T
        \\    def __init__(self: Box, value: T) -> None:
        \\        self.value = value
        \\    def get(self: Box) -> T:
        \\        return self.value
        \\
        ,
    });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data = "from helpers import Box\n\nprint(Box[int](9).get())\n",
    });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env_map = try isolatedNoxHome(io, home.dir, &home_buf);
    defer env_map.deinit();

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
    // Bos stderr — hem sizinti YOK (Faz P2.1'in `isTemporaryExpr` düzeltmesi,
    // bkz. abi.zig) hem de dogru calisti kanitlanir.
    try std.testing.expectEqualStrings("", run_result.stderr);
    try std.testing.expectEqualStrings("9\n", run_result.stdout);
}

// Bulundu (bkz. proje belleği "from-import class type annotations" görevi):
// `from X import Widget` İLE bağlanan ÇIPLAK bir isim, bir KURUCU ÇAĞRISI
// olarak (`checkCall`in `.identifier` dalının `from_imports` geri düşüşü
// SAYESİNDE) ZATEN çalışıyordu — ama bir TİP ANNOTASYONU (bir `var_decl`
// bildiriminde YA DA bir fonksiyon PARAMETRESİNDE) olarak KULLANILDIĞINDA
// `error.UnknownType: bilinmeyen tip: Widget` İLE BAŞARISIZ olurdu, çünkü
// (a) `checker.zig`nin `typeExprToType`ı `self.from_imports`e HİÇ
// bakmıyordu, VE (b) `.from_import_stmt` (`self.from_imports`i DOLDURAN
// deyim) checker'ın ANA (Geçiş 3) döngüsünde, PARAMETRE tiplerini çözen
// `registerSignatures` (Geçiş 2) TAMAMLANDIKTAN SONRA işleniyordu — bu YÜZDEN
// BİR fonksiyon PARAMETRESİ olarak kullanım, `typeExprToType` düzeltilse
// BİLE, HÂLÂ başarısız OLURDU (SIRALAMA hatası, AYRICA düzeltildi: import/
// from-import bildirimleri artık `collectImports` İLE, `registerSignatures`
// DEN ÖNCE toplanıyor). Bu test HER İKİ kullanımı da (bir `var_decl`
// bildiriminde VE bir fonksiyon PARAMETRESİNDE) DOĞRU ÇALIŞTIĞINI kanıtlar
// — codegen'in KENDİ (checker'dan BAĞIMSIZ) `resolveType`ının da AYNI
// `from_imports` haritasına (`Codegen.from_imports`, `main.zig` TARAFINDAN
// `checker_state.from_imports`den kopyalanmadan aktarılır) İHTİYAÇ
// DUYDUĞU AYRICA doğrulanır (yalnızca tip DENETİMİ değil, GERÇEK
// derleme+çalıştırma).
test "bulundu: import edilen (generic OLMAYAN, PLAIN) bir sinif hem kurucu cagrisi hem de tip annotasyonu (var_decl VE fonksiyon parametresi) OLARAK calisir" {
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
        .sub_path = "helpers.nox",
        .data =
        \\class Widget:
        \\    x: int
        \\    def __init__(self: Widget, x: int) -> None:
        \\        self.x = x
        \\    def get(self: Widget) -> int:
        \\        return self.x
        \\
        ,
    });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data =
        \\from helpers import Widget
        \\
        \\def take(w: Widget) -> int:
        \\    return w.get()
        \\
        \\w: Widget = Widget(9)
        \\print(take(w))
        \\
        ,
    });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env_map = try isolatedNoxHome(io, home.dir, &home_buf);
    defer env_map.deinit();

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
    try std.testing.expectEqualStrings("", run_result.stderr);
    try std.testing.expectEqualStrings("9\n", run_result.stdout);
}

test "U.2: gercekten var olmayan proje-ici modul acik hata mesajiyla basarisiz olur" {
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
        .data = "import nonexistent_module\n\nprint(nonexistent_module.foo(1))\n",
    });

    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var env_map = try isolatedNoxHome(io, home.dir, &home_buf);
    defer env_map.deinit();

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

test "U.2: nox.json olmadan (manifestsiz) proje-ici import ESKI davranisla basarisiz olur" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);

    // Kasitli olarak nox.json YOK — proje-ici import mekanizmasi devreye
    // GIRMEMELI, tek-dosya/manifestsiz kullanim ESKI ("yalnizca stdlib")
    // davranisini korumali (bkz. plan: "Birinci-parti importlar nox.json
    // GEREKTIRIR").
    try proj.dir.writeFile(io, .{
        .sub_path = "helpers.nox",
        .data = "def double(x: int) -> int:\n    return x * 2\n",
    });
    try proj.dir.writeFile(io, .{
        .sub_path = "main.nox",
        .data = "import helpers\n\nprint(helpers.double(21))\n",
    });

    const main_path = try std.fmt.allocPrint(a, "{s}/main.nox", .{proj_path});
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "build", main_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "stdlib modülü bulunamadı") != null);
}
