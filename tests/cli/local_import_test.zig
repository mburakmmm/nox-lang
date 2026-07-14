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
