//! v2.0.178 (Faz 11.9) uçtan-uca testi: `extern def ... from "göreli/yol.o"` çalışma dizininde yoksa derlenen kaynağın PROJE KÖKÜNDE (`nox.json`un dizini) aranır. Aura örneği:
//! `cd examples/dashboard && noxc run main.nox` eskiden `native/libaura_host.dylib`i bulamıyordu. Sınır: arama proje kökünde DURUR (üst dizinlere çıkılmaz) ve `nox.json` yoksa hiçbir şey değişmez.
//! Native nesne `zig cc -c` ile üretilir (`zig` yoksa test atlanır). `$NOX_HOME` yalıtılır.

const std = @import("std");
const builtin = @import("builtin");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

const helper_c = "long long helper_add_one(long long x) { return x + 1; }\n";
const main_nox = "extern def helper_add_one(x: int) -> int from \"native/helper.o\"\n\nprint(helper_add_one(41))\n";

const Ctx = struct {
    a: std.mem.Allocator,
    io: std.Io,
    noxc: []const u8,
    env: *std.process.Environ.Map,

    fn run(self: Ctx, cwd: []const u8, argv_tail: []const []const u8) !std.process.RunResult {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try argv.append(self.a, self.noxc);
        try argv.appendSlice(self.a, argv_tail);
        return std.process.run(self.a, self.io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .environ_map = self.env });
    }
};

/// `<dir>/native/helper.o`yu üretir; `zig` yoksa `false`.
fn buildHelper(c: Ctx, dir: []const u8) !bool {
    var native = try std.Io.Dir.cwd().createDirPathOpen(c.io, try std.fmt.allocPrint(c.a, "{s}/native", .{dir}), .{});
    defer native.close(c.io);
    try native.writeFile(c.io, .{ .sub_path = "helper.c", .data = helper_c });
    const src = try std.fmt.allocPrint(c.a, "{s}/native/helper.c", .{dir});
    const obj = try std.fmt.allocPrint(c.a, "{s}/native/helper.o", .{dir});
    const r = std.process.run(c.a, c.io, .{ .argv = &.{ "zig", "cc", "-c", "-O2", "-fno-sanitize=undefined", "-o", obj, src } }) catch return false;
    return r.term == .exited and r.term.exited == 0;
}

fn setup(a: std.mem.Allocator, io: std.Io, home: *std.testing.TmpDir, env: *std.process.Environ.Map) !Ctx {
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try env.put("NOX_HOME", try a.dupe(u8, try absPath(io, home.dir, &home_buf)));
    const cwd = try std.process.currentPathAlloc(io, a);
    return .{ .a = a, .io = io, .noxc = try std.fmt.allocPrint(a, "{s}/zig-out/bin/noxc", .{cwd}), .env = env };
}

test "extern from: calisma dizininde yoksa proje kokunde bulunur (ornek klasorunden calistirma)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var env = try std.testing.environ.createMap(a);
    const c = try setup(a, io, &home, &env);

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, try absPath(io, proj.dir, &pbuf));
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"demo\",\"entry\":\"examples/app/main.nox\"}" });
    try proj.dir.createDirPath(io, "examples/app");
    try proj.dir.writeFile(io, .{ .sub_path = "examples/app/main.nox", .data = main_nox });
    if (!try buildHelper(c, root)) return error.SkipZigTest;

    // Proje kökünden (dosya çalışma dizininde var): bugünkü davranış.
    const r1 = try c.run(root, &.{ "run", "examples/app/main.nox" });
    try std.testing.expectEqualStrings("42\n", r1.stdout);

    // Örnek klasöründen (dosya çalışma dizininde YOK): proje kökünde bulunur.
    const app = try std.fmt.allocPrint(a, "{s}/examples/app", .{root});
    const r2 = try c.run(app, &.{ "run", "main.nox" });
    if (r2.term != .exited or r2.term.exited != 0) std.debug.print("derleme basarisiz: {s}\n", .{r2.stderr});
    try std.testing.expectEqualStrings("42\n", r2.stdout);
}

test "extern from: arama proje kokunde durur (ust dizine cikilmaz) ve nox.json yoksa hicbir sey degismez" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    var env = try std.testing.environ.createMap(a);
    const c = try setup(a, io, &home, &env);

    var base = std.testing.tmpDir(.{});
    defer base.cleanup();
    var bbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, try absPath(io, base.dir, &bbuf));
    // `nox.json` base/app'te; native nesne ONUN ÜSTÜNDE (base/native): bulunmamalı.
    try base.dir.createDirPath(io, "app/src");
    try base.dir.writeFile(io, .{ .sub_path = "app/nox.json", .data = "{\"name\":\"demo\",\"entry\":\"src/main.nox\"}" });
    try base.dir.writeFile(io, .{ .sub_path = "app/src/main.nox", .data = main_nox });
    if (!try buildHelper(c, root)) return error.SkipZigTest;
    const src = try std.fmt.allocPrint(a, "{s}/app/src", .{root});
    const r1 = try c.run(src, &.{ "run", "main.nox" });
    try std.testing.expect(r1.term != .exited or r1.term.exited != 0);

    // `nox.json` hiç yok: üst dizindeki (base/native) nesne yine bulunmaz.
    try base.dir.createDirPath(io, "loose/sub");
    try base.dir.writeFile(io, .{ .sub_path = "loose/sub/main.nox", .data = main_nox });
    const loose = try std.fmt.allocPrint(a, "{s}/loose/sub", .{root});
    const r2 = try c.run(loose, &.{ "run", "main.nox" });
    try std.testing.expect(r2.term != .exited or r2.term.exited != 0);
}
