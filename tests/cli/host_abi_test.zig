//! UR-002/UR-005 (NoxPy, v2.2.78): `noxc build --host-abi` + `include/nox_host.h`. `tests/compat/host_abi/fm.nox` (`@export` işlevleri) nesne olarak derlenir, YALNIZCA `nox_host.h`
//! kullanan bir C ana makinesiyle (`host.c`) bağlanıp çalıştırılır: skaler/str/bytes tip eşlemesi, UTF-8 doğrulama, istisna inceleme (sınıf/ileti/satır), modül globali, geçersiz bağlam.
//! `clang` ya da hazır `zig-out/lib/noxrt.o` yoksa atlanır.

const std = @import("std");
const builtin = @import("builtin");

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv });
}

fn exitCode(r: std.process.RunResult) u8 {
    return if (r.term == .exited) r.term.exited else 255;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "host-abi: C ana makinesi nox_host.h ile Nox kütüphanesini çağırır" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const obj = try std.fmt.allocPrint(gpa, "{s}/fm.o", .{dir});
    defer gpa.free(obj);
    const exe = try std.fmt.allocPrint(gpa, "{s}/host", .{dir});
    defer gpa.free(exe);

    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "--module-name", "fm", "-o", obj, "tests/compat/host_abi/fm.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));

    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/host.c", obj, "zig-out/lib/noxrt.o", "-lm", "-pthread", "-o", exe }) catch return; // clang yoksa atla
    defer gpa.free(cc.stdout);
    defer gpa.free(cc.stderr);
    if (exitCode(cc) != 0) {
        std.debug.print("clang: {s}\n", .{cc.stderr});
        return error.LinkFailed;
    }
    const r = try run(gpa, io, &.{exe});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (exitCode(r) != 0) std.debug.print("host çıktısı:\n{s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "ALL OK") != null);
}

test "host-abi: konteyner/Optional/tuple imzaları NoxHostValue ile geçer (UR-008)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const obj = try std.fmt.allocPrint(gpa, "{s}/ct.o", .{dir});
    defer gpa.free(obj);
    const exe = try std.fmt.allocPrint(gpa, "{s}/ct_host", .{dir});
    defer gpa.free(exe);

    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "--module-name", "ct", "-o", obj, "tests/compat/host_abi/containers.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (exitCode(built) != 0) std.debug.print("noxc: {s}\n", .{built.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));

    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/containers_host.c", obj, "zig-out/lib/noxrt.o", "-lm", "-pthread", "-o", exe }) catch return; // clang yoksa atla
    defer gpa.free(cc.stdout);
    defer gpa.free(cc.stderr);
    if (exitCode(cc) != 0) {
        std.debug.print("clang: {s}\n", .{cc.stderr});
        return error.LinkFailed;
    }
    const r = try run(gpa, io, &.{exe});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (exitCode(r) != 0) std.debug.print("host çıktısı:\n{s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "ALL OK") != null);
}

test "host-abi: konteyner içinde desteklenmeyen eleman tipleri açık iletiyle reddedilir (UR-008)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const cases = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "c1", .src = "class P:\n    a: int\n    def __init__(self, a: int) -> None:\n        self.a = a\n\n@export\ndef f(xs: dict[P, int]) -> int:\n    return 1\n" },
        .{ .name = "c2", .src = "@export\ndef f(xs: list[int | None]) -> int:\n    return 1\n" },
        .{ .name = "c3", .src = "@export\ndef f(x: int) -> list[Task[int]]:\n    return []\n" },
    };
    for (cases) |cs| {
        const file = try std.fmt.allocPrint(gpa, "{s}.nox", .{cs.name});
        defer gpa.free(file);
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = cs.src });
        const src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ buf[0..len], file });
        defer gpa.free(src);
        const out = try std.fmt.allocPrint(gpa, "{s}/{s}.o", .{ buf[0..len], cs.name });
        defer gpa.free(out);
        const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "-o", out, src });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expect(exitCode(r) != 0);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--host-abi") != null);
    }
}

test "host-abi: desteklenmeyen imza ve eksik kütüphane bayrağı açık iletiyle reddedilir" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.nox", .data = "@export\ndef f(xs: Task[int]) -> int:\n    return 1\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/bad.nox", .{buf[0..len]});
    defer gpa.free(src);
    const out = try std.fmt.allocPrint(gpa, "{s}/bad.o", .{buf[0..len]});
    defer gpa.free(out);
    const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "-o", out, src });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(exitCode(r) != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "cannot cross the host ABI") != null);
    const r2 = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--host-abi", src });
    defer gpa.free(r2.stdout);
    defer gpa.free(r2.stderr);
    try std.testing.expect(exitCode(r2) != 0);
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "--host-abi requires") != null);
}

test "host-abi: iki bağımsız paylaşılan kütüphane aynı süreçte yaşar, yalnızca nox_host_* dışa açılır" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const ext = if (builtin.os.tag == .macos) "dylib" else "so";
    const libs = [_][]const u8{ "ma", "mb" };
    var paths: [2][]u8 = undefined;
    for (libs, 0..) |mod, i| {
        paths[i] = try std.fmt.allocPrint(gpa, "{s}/lib{s}.{s}", .{ dir, mod, ext });
        const b = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-shared-lib", "--host-abi", "--module-name", mod, "-o", paths[i], "tests/compat/host_abi/fm.nox" });
        defer gpa.free(b.stdout);
        defer gpa.free(b.stderr);
        try std.testing.expectEqual(@as(u8, 0), exitCode(b));
    }
    defer for (paths) |p| gpa.free(p);
    const exe = try std.fmt.allocPrint(gpa, "{s}/host_dl", .{dir});
    defer gpa.free(exe);
    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/host_dl.c", "-ldl", "-o", exe }) catch return; // clang yoksa atla
    defer gpa.free(cc.stdout);
    defer gpa.free(cc.stderr);
    try std.testing.expectEqual(@as(u8, 0), exitCode(cc));
    const r = try run(gpa, io, &.{ exe, paths[0], paths[1] });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (exitCode(r) != 0) std.debug.print("host_dl çıktısı:\n{s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "ALL OK") != null);
}

test "host-abi: @export class — kurucu/yöntem/özellik/statik/classmethod/dunder/istisna + NOX_HOST_VALUE_HANDLE (UR-009)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const obj = try std.fmt.allocPrint(gpa, "{s}/cl.o", .{dir});
    defer gpa.free(obj);
    const exe = try std.fmt.allocPrint(gpa, "{s}/cl_host", .{dir});
    defer gpa.free(exe);

    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "--module-name", "cl", "-o", obj, "tests/compat/host_abi/classes.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (exitCode(built) != 0) std.debug.print("noxc: {s}\n", .{built.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));

    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/classes_host.c", obj, "zig-out/lib/noxrt.o", "-lm", "-pthread", "-o", exe }) catch return; // clang yoksa atla
    defer gpa.free(cc.stdout);
    defer gpa.free(cc.stderr);
    if (exitCode(cc) != 0) {
        std.debug.print("clang: {s}\n", .{cc.stderr});
        return error.LinkFailed;
    }
    const r = try run(gpa, io, &.{exe});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (exitCode(r) != 0) std.debug.print("host çıktısı:\n{s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "ALL OK") != null);
}

test "host-abi: @export class desteklenmeyen biçimler açık iletiyle reddedilir (UR-009)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const cases = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "k1", .src = "@export\nclass Box[T]:\n    v: T\n    def __init__(self, v: T) -> None:\n        self.v = v\n" },
        .{ .name = "k2", .src = "@export\n@dataclass\nclass P:\n    x: int\n" },
        .{ .name = "k3", .src = "def Counter_inc() -> int:\n    return 1\n\n@export\nclass Counter:\n    n: int\n    def __init__(self) -> None:\n        self.n = 0\n    def inc(self) -> int:\n        return 1\n" },
    };
    for (cases) |cs| {
        const file = try std.fmt.allocPrint(gpa, "{s}.nox", .{cs.name});
        defer gpa.free(file);
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = cs.src });
        const src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ buf[0..len], file });
        defer gpa.free(src);
        const out = try std.fmt.allocPrint(gpa, "{s}/{s}.o", .{ buf[0..len], cs.name });
        defer gpa.free(out);
        const r = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "-o", out, src });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expect(exitCode(r) != 0);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--host-abi") != null);
    }
}

test "host-abi: HostObject geri çağrıları, yeniden giriş, host istisnası + jeton, retain/release dengesi (UR-010)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const obj = try std.fmt.allocPrint(gpa, "{s}/cb.o", .{dir});
    defer gpa.free(obj);
    const exe = try std.fmt.allocPrint(gpa, "{s}/cb_host", .{dir});
    defer gpa.free(exe);

    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "--module-name", "cb", "-o", obj, "tests/compat/host_abi/callbacks.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (exitCode(built) != 0) std.debug.print("noxc: {s}\n", .{built.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));

    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/callbacks_host.c", obj, "zig-out/lib/noxrt.o", "-lm", "-pthread", "-o", exe }) catch return; // clang yoksa atla
    defer gpa.free(cc.stdout);
    defer gpa.free(cc.stderr);
    if (exitCode(cc) != 0) {
        std.debug.print("clang: {s}\n", .{cc.stderr});
        return error.LinkFailed;
    }
    const r = try run(gpa, io, &.{exe});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (exitCode(r) != 0) std.debug.print("host çıktısı:\n{s}{s}\n", .{ r.stdout, r.stderr });
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "ALL OK") != null);
}
