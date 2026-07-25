//! `noxc add`/`noxc delete` uçtan-uca testleri — `package_resolution_test.zig`
//! İLE AYNI desen (kurulu `zig-out/bin/noxc`yi alt süreç olarak, fixture
//! proje dizinlerinde `.cwd` İLE çalıştırma). `add`/`delete` AĞA ÇIKMAZ
//! (repo AÇIKÇA verilir YA DA `NOX_INDEX_URL` bir YEREL dosyaya işaret
//! eder) — bu YÜZDEN `$NOX_HOME` izolasyonu (fetch/update testlerinin
//! AKSİNE) gerekmez, GERÇEK git/ağ hiç DEVREYE girmez.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn noxcAbsPath(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, noxcPath() });
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

fn runNoxc(a: std.mem.Allocator, io: std.Io, noxc_abs: []const u8, proj_path: []const u8, argv_rest: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(a, noxc_abs);
    try argv.appendSlice(a, argv_rest);
    return std.process.run(std.testing.allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .path = proj_path },
    });
}

test "noxc add: acik repo argumaniyla requires[]e ekler" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}\n" });

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try runNoxc(a, io, noxc_abs, proj_path, &.{ "add", "nyx", "github.com/example/nyx" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("add basarisiz, stderr: {s}\n", .{result.stderr});
    }
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "eklendi: nyx") != null);

    const nox_json = try proj.dir.readFileAlloc(io, "nox.json", a, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "\"alias\": \"nyx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "\"repo\": \"github.com/example/nyx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "\"ref\": \"main\"") != null);
}

test "noxc add: --ref bayragi saygi gorur" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}\n" });

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try runNoxc(a, io, noxc_abs, proj_path, &.{ "add", "nyx", "github.com/example/nyx", "--ref", "v2.0.0" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);

    const nox_json = try proj.dir.readFileAlloc(io, "nox.json", a, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "\"ref\": \"v2.0.0\"") != null);
}

test "noxc add: repo verilmezse NOX_INDEX_URL (yerel dosya) uzerinden alias cozulur" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var idx_dir = std.testing.tmpDir(.{});
    defer idx_dir.cleanup();
    try idx_dir.dir.writeFile(io, .{
        .sub_path = "index.json",
        .data =
        \\{"packages": [{"name": "nyx", "repo": "github.com/example/nyx", "description": "web framework"}]}
        ,
    });
    var idx_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const idx_path = try absPath(io, idx_dir.dir, &idx_buf);
    const idx_file = try std.fmt.allocPrint(a, "{s}/index.json", .{idx_path});

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}\n" });

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_INDEX_URL", idx_file);

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "add", "nyx" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("add basarisiz, stderr: {s}\n", .{result.stderr});
    }
    try std.testing.expect(result.term == .exited and result.term.exited == 0);

    const nox_json = try proj.dir.readFileAlloc(io, "nox.json", a, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "\"repo\": \"github.com/example/nyx\"") != null);
}

test "noxc add: alias indekste yok ve repo verilmedi -> hata, cikis 1" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var idx_dir = std.testing.tmpDir(.{});
    defer idx_dir.cleanup();
    try idx_dir.dir.writeFile(io, .{ .sub_path = "index.json", .data = "{\"packages\": []}" });
    var idx_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const idx_path = try absPath(io, idx_dir.dir, &idx_buf);
    const idx_file = try std.fmt.allocPrint(a, "{s}/index.json", .{idx_path});

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}\n" });

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_INDEX_URL", idx_file);

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "add", "yok-boyle-bir-sey" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "bulunamadi") != null);
}

test "noxc add: rezerve 'nox' alias'i reddedilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}\n" });

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try runNoxc(a, io, noxc_abs, proj_path, &.{ "add", "nox", "github.com/x/y" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "ReservedAlias") != null);
}

test "noxc add: ayni alias'a ikinci cagri upsert yapar (requires.len degismez, ref guncellenir)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}\n" });

    const noxc_abs = try noxcAbsPath(io, a);
    {
        const r1 = try runNoxc(a, io, noxc_abs, proj_path, &.{ "add", "nyx", "github.com/example/nyx", "--ref", "v1.0.0" });
        defer std.testing.allocator.free(r1.stdout);
        defer std.testing.allocator.free(r1.stderr);
        try std.testing.expect(r1.term == .exited and r1.term.exited == 0);
    }
    const r2 = try runNoxc(a, io, noxc_abs, proj_path, &.{ "add", "nyx", "github.com/example/nyx", "--ref", "v2.0.0" });
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    try std.testing.expect(r2.term == .exited and r2.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "guncellendi: nyx") != null);

    const nox_json = try proj.dir.readFileAlloc(io, "nox.json", a, .limited(64 * 1024));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, nox_json, "\"alias\":"));
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "\"ref\": \"v2.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "v1.0.0") == null);
}

test "noxc delete: var olan alias'i cikarir, olmayan icin hata verir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}\n" });

    const noxc_abs = try noxcAbsPath(io, a);
    {
        const r1 = try runNoxc(a, io, noxc_abs, proj_path, &.{ "add", "nyx", "github.com/example/nyx" });
        defer std.testing.allocator.free(r1.stdout);
        defer std.testing.allocator.free(r1.stderr);
        try std.testing.expect(r1.term == .exited and r1.term.exited == 0);
    }
    {
        const r2 = try runNoxc(a, io, noxc_abs, proj_path, &.{ "delete", "nyx" });
        defer std.testing.allocator.free(r2.stdout);
        defer std.testing.allocator.free(r2.stderr);
        try std.testing.expect(r2.term == .exited and r2.term.exited == 0);
        try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "silindi: nyx") != null);
    }
    const nox_json = try proj.dir.readFileAlloc(io, "nox.json", a, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, nox_json, "nyx") == null);

    const r3 = try runNoxc(a, io, noxc_abs, proj_path, &.{ "delete", "nyx" });
    defer std.testing.allocator.free(r3.stdout);
    defer std.testing.allocator.free(r3.stderr);
    try std.testing.expect(r3.term == .exited and r3.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, r3.stderr, "bulunamadi") != null);
}

test "noxc delete: eslesen nox.lock girdisini de budar" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{
        .sub_path = "nox.json",
        .data =
        \\{"name":"proj","entry":"main.nox","requires":[{"alias":"nyx","repo":"github.com/example/nyx","ref":"main"}]}
        ,
    });
    try proj.dir.writeFile(io, .{
        .sub_path = "nox.lock",
        .data =
        \\{"packages":[{"alias":"nyx","repo":"github.com/example/nyx","ref":"main","resolved":"deadbeef"},{"alias":"other","repo":"github.com/example/other","ref":"main","resolved":"cafef00d"}]}
        ,
    });

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try runNoxc(a, io, noxc_abs, proj_path, &.{ "delete", "nyx" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);

    const lock_json = try proj.dir.readFileAlloc(io, "nox.lock", a, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, lock_json, "\"nyx\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, lock_json, "\"other\"") != null);
}

test "noxc add/delete: proje disinda calistirilirsa hata verir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    var outside_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const outside_path = try absPath(io, outside.dir, &outside_buf);

    const noxc_abs = try noxcAbsPath(io, a);
    {
        const r1 = try runNoxc(a, io, noxc_abs, outside_path, &.{ "add", "nyx", "github.com/example/nyx" });
        defer std.testing.allocator.free(r1.stdout);
        defer std.testing.allocator.free(r1.stderr);
        try std.testing.expect(r1.term == .exited and r1.term.exited == 1);
        try std.testing.expect(std.mem.indexOf(u8, r1.stderr, "nox.json bulunamadi") != null);
    }
    const r2 = try runNoxc(a, io, noxc_abs, outside_path, &.{ "delete", "nyx" });
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    try std.testing.expect(r2.term == .exited and r2.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "nox.json bulunamadi") != null);
}
