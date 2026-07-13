//! Faz O §P.1 birim testleri: `compiler/project.zig`nin proje kökü keşfi
//! (`nox.json` arayarak yukarı yürüyüş) + manifest ayrıştırma + kaynak-dizini
//! (self-exe-göreli/`NOX_HOME`-override) çözümlemesi.

const std = @import("std");
const nox = @import("nox");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

test "findProjectRoot: manifest bir üst atada bulunur" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"root\"}" });
    try tmp.dir.createDirPath(io, "a/b/c");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_path = try absPath(io, tmp.dir, &buf);

    var buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var nested = try tmp.dir.openDir(io, "a/b/c", .{});
    defer nested.close(io);
    const nested_path = try absPath(io, nested, &buf2);

    const found = try nox.project.findProjectRoot(a, io, nested_path);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings(root_path, found.?);
}

test "findProjectRoot: manifest hiç yoksa null döner" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "x/y");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var nested = try tmp.dir.openDir(io, "x/y", .{});
    defer nested.close(io);
    const nested_path = try absPath(io, nested, &buf);

    const found = try nox.project.findProjectRoot(a, io, nested_path);
    try std.testing.expect(found == null);
}

test "loadManifest: gecerli JSON dogru ayristirilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"myproject\",\"entry\":\"src/app.nox\"}" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &buf);

    const manifest = try nox.project.loadManifest(a, io, dir_path);
    try std.testing.expectEqualStrings("myproject", manifest.name);
    try std.testing.expectEqualStrings("src/app.nox", manifest.entry);
}

test "loadManifest: entry verilmezse main.nox varsayilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"noentry\"}" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &buf);

    const manifest = try nox.project.loadManifest(a, io, dir_path);
    try std.testing.expectEqualStrings("main.nox", manifest.entry);
}

test "loadManifest: bozuk JSON error.InvalidManifest doner" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{not valid json" });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &buf);

    try std.testing.expectError(error.InvalidManifest, nox.project.loadManifest(a, io, dir_path));
}

test "loadManifest: bilinmeyen (Faz O oncesi) alanlar yok sayilir, requires dogru ayristirilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "nox.json",
        .data = "{\"name\":\"fw\",\"unknown_future_field\":123,\"requires\":[{\"alias\":\"x\",\"repo\":\"github.com/x/y\",\"ref\":\"main\"}]}",
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &buf);

    const manifest = try nox.project.loadManifest(a, io, dir_path);
    try std.testing.expectEqualStrings("fw", manifest.name);
    try std.testing.expectEqual(@as(usize, 1), manifest.requires.len);
    try std.testing.expectEqualStrings("x", manifest.requires[0].alias);
    try std.testing.expectEqualStrings("github.com/x/y", manifest.requires[0].repo);
    try std.testing.expectEqualStrings("main", manifest.requires[0].ref);
}

test "validateManifest: yinelenen alias reddedilir" {
    const requires = [_]nox.project.Requirement{
        .{ .alias = "somepkg", .repo = "github.com/a/b", .ref = "main" },
        .{ .alias = "somepkg", .repo = "github.com/c/d", .ref = "v1" },
    };
    const m: nox.project.Manifest = .{ .requires = &requires };
    try std.testing.expectError(error.DuplicateAlias, nox.project.validateManifest(m));
}

test "validateManifest: 'nox' alias'i rezerve, reddedilir" {
    const requires = [_]nox.project.Requirement{
        .{ .alias = "nox", .repo = "github.com/a/b", .ref = "main" },
    };
    const m: nox.project.Manifest = .{ .requires = &requires };
    try std.testing.expectError(error.ReservedAlias, nox.project.validateManifest(m));
}

test "validateManifest: gecerli requires kabul edilir" {
    const requires = [_]nox.project.Requirement{
        .{ .alias = "somepkg", .repo = "github.com/a/b", .ref = "main" },
        .{ .alias = "otherpkg", .repo = "github.com/c/d", .ref = "v1" },
    };
    const m: nox.project.Manifest = .{ .requires = &requires };
    try nox.project.validateManifest(m);
}

test "loadManifest: yinelenen alias iceren manifest DuplicateAlias ile reddedilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "nox.json",
        .data = "{\"requires\":[{\"alias\":\"x\",\"repo\":\"a\",\"ref\":\"m\"},{\"alias\":\"x\",\"repo\":\"b\",\"ref\":\"m\"}]}",
    });

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &buf);

    try std.testing.expectError(error.DuplicateAlias, nox.project.loadManifest(a, io, dir_path));
}

test "parseLockfile: gecerli JSON saf bellek-ici ayristirilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\{"packages":[{"alias":"somepkg","repo":"github.com/a/b","ref":"v1.2.3","resolved":"abc123"}]}
    ;
    const lock = try nox.project.parseLockfile(a, source);
    try std.testing.expectEqual(@as(usize, 1), lock.packages.len);
    try std.testing.expectEqualStrings("somepkg", lock.packages[0].alias);
    try std.testing.expectEqualStrings("abc123", lock.packages[0].resolved);
}

test "parseLockfile: bozuk JSON error.InvalidLockfile doner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidLockfile, nox.project.parseLockfile(a, "{not valid"));
}

test "findLocked: bulunur/bulunmaz" {
    const packages = [_]nox.project.LockedPackage{
        .{ .alias = "somepkg", .repo = "github.com/a/b", .ref = "v1", .resolved = "sha1" },
    };
    const lock: nox.project.Lockfile = .{ .packages = &packages };
    try std.testing.expect(nox.project.findLocked(lock, "somepkg") != null);
    try std.testing.expect(nox.project.findLocked(lock, "yok") == null);
}

test "loadLockfile: dosya yoksa bos Lockfile doner (hata degil)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &buf);

    const lock = try nox.project.loadLockfile(a, io, dir_path);
    try std.testing.expectEqual(@as(usize, 0), lock.packages.len);
}

test "saveLockfile + loadLockfile: roundtrip" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &buf);

    const packages = [_]nox.project.LockedPackage{
        .{ .alias = "somepkg", .repo = "github.com/a/b", .ref = "v1", .resolved = "deadbeef" },
    };
    const original: nox.project.Lockfile = .{ .packages = &packages };
    try nox.project.saveLockfile(a, io, dir_path, original);

    const loaded = try nox.project.loadLockfile(a, io, dir_path);
    try std.testing.expectEqual(@as(usize, 1), loaded.packages.len);
    try std.testing.expectEqualStrings("somepkg", loaded.packages[0].alias);
    try std.testing.expectEqualStrings("deadbeef", loaded.packages[0].resolved);
}

test "resolveResourceDirs: NOX_HOME override ile deterministik yollar" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dirs = try nox.project.resolveResourceDirs(a, io, "/tmp/fake-nox-home");
    try std.testing.expectEqualStrings("/tmp/fake-nox-home/lib/nox/stdlib", dirs.stdlib_dir);
    try std.testing.expectEqualStrings("/tmp/fake-nox-home/lib/noxrt.o", dirs.noxrt_path);
}

test "resolveResourceDirs: override yoksa self-exe-göreli hesaplanir, cökmez" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dirs = try nox.project.resolveResourceDirs(a, io, null);
    try std.testing.expect(std.mem.endsWith(u8, dirs.stdlib_dir, "/lib/nox/stdlib"));
    try std.testing.expect(std.mem.endsWith(u8, dirs.noxrt_path, "/lib/noxrt.o"));
}
