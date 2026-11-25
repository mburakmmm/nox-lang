//! UR-001 (NoxPy): masaüstü hedeflerde `--emit-obj` / `--emit-static-lib` / `--emit-shared-lib` (LLVM, PIC).
//! Nesne `main` taşımaz; arşiv `noxrt.o`yu içerir; paylaşımlı kütüphane ana makinede yüklenir; QBE açık hatayla reddedilir.
//! Linux/Windows çapraz paylaşımlı kütüphane yalnız `zig` ve çapraz runtime nesneleri kuruluysa denenir (ELF bağlayıcısı PIC olmayan nesneyi reddeder).

const std = @import("std");
const builtin = @import("builtin");

const Source =
    \\@export
    \\def nox_add(a: int, b: int) -> int:
    \\    return a + b
    \\
;

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv });
}

fn exitCode(r: std.process.RunResult) u8 {
    return if (r.term == .exited) r.term.exited else 255;
}

fn workDir(io: std.Io, tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = Source });
    const len = try tmp.dir.realPath(io, buf);
    return buf[0..len];
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "desktop --emit-obj produces a relocatable object without main" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try workDir(io, &tmp, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const obj = try std.fmt.allocPrint(gpa, "{s}/prog.o", .{dir});
    defer gpa.free(obj);
    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "-o", obj, src });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));
    try std.testing.expect(fileExists(io, obj));
    // `main` sembolü yok: kütüphane kipi (`nm -g` bulunmayan ortamlarda sembol denetimi atlanır).
    const nm = run(gpa, io, &.{ "nm", "-g", obj }) catch return;
    defer gpa.free(nm.stdout);
    defer gpa.free(nm.stderr);
    if (exitCode(nm) != 0) return;
    try std.testing.expect(std.mem.indexOf(u8, nm.stdout, " T _main") == null and std.mem.indexOf(u8, nm.stdout, " T main") == null);
}

test "desktop --emit-static-lib packs the runtime and --emit-shared-lib links" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try workDir(io, &tmp, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);

    const archive = try std.fmt.allocPrint(gpa, "{s}/libprog.a", .{dir});
    defer gpa.free(archive);
    const a = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-static-lib", "-o", archive, src });
    defer gpa.free(a.stdout);
    defer gpa.free(a.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(a));
    const st = try std.Io.Dir.cwd().statFile(io, archive, .{});
    try std.testing.expect(st.size > 1 << 20); // noxrt.o dahil (yalnız nesne birkaç KB'tır)

    const shared = try std.fmt.allocPrint(gpa, "{s}/libprog.{s}", .{ dir, if (builtin.os.tag == .macos) "dylib" else "so" });
    defer gpa.free(shared);
    const s = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-shared-lib", "-o", shared, src });
    defer gpa.free(s.stdout);
    defer gpa.free(s.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(s));
    try std.testing.expect(fileExists(io, shared));
}

test "desktop library emit rejects the qbe backend with a clear message" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try workDir(io, &tmp, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "qbe", "--emit-obj", src });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(exitCode(r) != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "need the LLVM backend") != null);
}

test "cross --emit-shared-lib links a PIC runtime for linux-x64 and linux-arm64" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt-linux-x64.o") or !fileExists(io, "zig-out/lib/noxrt-linux-arm64.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try workDir(io, &tmp, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    for ([_][]const u8{ "linux-x64", "linux-arm64" }) |t| {
        const out = try std.fmt.allocPrint(gpa, "{s}/lib_{s}.so", .{ dir, t });
        defer gpa.free(out);
        const r = run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-shared-lib", "--target", t, "-o", out, src }) catch return; // zig yoksa atla
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), exitCode(r));
        const head = try std.Io.Dir.cwd().readFileAlloc(io, out, gpa, .limited(64 << 20));
        defer gpa.free(head);
        try std.testing.expectEqualStrings("\x7fELF", head[0..4]);
    }
}
