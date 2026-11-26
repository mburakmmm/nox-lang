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

test "host-abi: @export async def — başlat/on_done/take_result/iptal/release/çıkmaz koruması (UR-011)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const obj = try std.fmt.allocPrint(gpa, "{s}/tk.o", .{dir});
    defer gpa.free(obj);
    const exe = try std.fmt.allocPrint(gpa, "{s}/tk_host", .{dir});
    defer gpa.free(exe);

    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "--module-name", "tk", "-o", obj, "tests/compat/host_abi/tasks.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (exitCode(built) != 0) std.debug.print("noxc: {s}\n", .{built.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));

    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/tasks_host.c", obj, "zig-out/lib/noxrt.o", "-lm", "-pthread", "-o", exe }) catch return; // clang yoksa atla
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

test "host-abi: pinned buffer + TYPED_ARRAY zero-copy (UR-012)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const obj = try std.fmt.allocPrint(gpa, "{s}/bf.o", .{dir});
    defer gpa.free(obj);
    const exe = try std.fmt.allocPrint(gpa, "{s}/bf_host", .{dir});
    defer gpa.free(exe);

    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "--module-name", "bf", "-o", obj, "tests/compat/host_abi/buffers.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (exitCode(built) != 0) std.debug.print("noxc: {s}\n", .{built.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));

    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/buffers_host.c", obj, "zig-out/lib/noxrt.o", "-lm", "-pthread", "-o", exe }) catch return; // clang yoksa atla
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

test "host-abi: kurtarılabilir taşma + host ayırıcısı + yetenekler + bağlam yalıtımı (UR-013/UR-015)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir = buf[0..len];
    const obj = try std.fmt.allocPrint(gpa, "{s}/tr.o", .{dir});
    defer gpa.free(obj);
    const exe = try std.fmt.allocPrint(gpa, "{s}/tr_host", .{dir});
    defer gpa.free(exe);

    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-obj", "--host-abi", "--module-name", "tr", "-o", obj, "tests/compat/host_abi/traps.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (exitCode(built) != 0) std.debug.print("noxc: {s}\n", .{built.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(built));

    const cc = run(gpa, io, &.{ "clang", "-I", "include", "tests/compat/host_abi/traps_host.c", obj, "zig-out/lib/noxrt.o", "-lm", "-pthread", "-o", exe }) catch return; // clang yoksa atla
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

test "host-abi: C11 _Static_assert düzen kapısı derlenir (UR-014)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const r = run(gpa, io, &.{ "clang", "-std=c11", "-Wall", "-Werror", "-fsyntax-only", "-I", "include", "tests/compat/host_abi/abi_layout.c" }) catch return; // clang yoksa atla
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (exitCode(r) != 0) std.debug.print("clang: {s}\n", .{r.stderr});
    try std.testing.expectEqual(@as(u8, 0), exitCode(r));
}

test "host-abi: Windows DLL YALNIZCA nox_host_* sembollerini dışa açar (UR-013)" {
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    if (!fileExists(io, "zig-out/lib/noxrt-windows-x64.o")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dll = try std.fmt.allocPrint(gpa, "{s}/fm.dll", .{buf[0..len]});
    defer gpa.free(dll);
    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--backend", "llvm", "--emit-shared-lib", "--host-abi", "--module-name", "fm", "--target", "windows-x64", "-o", dll, "tests/compat/host_abi/fm.nox" });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (exitCode(built) != 0) return; // zig yok ya da hedef araç zinciri kurulu değil: atla
    const def_path = try std.fmt.allocPrint(gpa, "{s}/fm.def", .{buf[0..len]});
    defer gpa.free(def_path);
    const def = try tmp.dir.readFileAlloc(io, "fm.def", gpa, .limited(1024 * 1024));
    defer gpa.free(def);
    try std.testing.expect(std.mem.indexOf(u8, def, "nox_host_export_fm_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, def, "nox_host_module_init_fm") != null);
    var it = std.mem.tokenizeScalar(u8, def, '\n');
    _ = it.next(); // EXPORTS
    while (it.next()) |line| try std.testing.expect(std.mem.startsWith(u8, std.mem.trim(u8, line, " "), "nox_host_"));
    // PE dışa aktarım tablosu: DLL'in dışa aktardığı HER ad `nox_host_` ile başlamalı (mingw'in "hepsini dışa aç" varsayılanı kapalı).
    const bytes = try tmp.dir.readFileAlloc(io, "fm.dll", gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(bytes);
    const names = try peExportNames(gpa, bytes);
    defer gpa.free(names);
    try std.testing.expect(names.len >= 10);
    for (names) |n| try std.testing.expect(std.mem.startsWith(u8, n, "nox_host_"));
}

/// Asgari PE (x64) dışa aktarım tablosu okuyucusu: ad işaretçileri `bytes` içindeki dilimlerdir.
fn peExportNames(gpa: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    const pe = std.mem.readInt(u32, bytes[0x3c..][0..4], .little);
    const nsec = std.mem.readInt(u16, bytes[pe + 6 ..][0..2], .little);
    const optsz = std.mem.readInt(u16, bytes[pe + 20 ..][0..2], .little);
    const opt = pe + 24;
    const dd = opt + (if (std.mem.readInt(u16, bytes[opt..][0..2], .little) == 0x20b) @as(usize, 112) else 96);
    const exp_rva = std.mem.readInt(u32, bytes[dd..][0..4], .little);
    const sec_off = opt + optsz;
    const Rva = struct {
        fn off(b: []const u8, so: usize, n: u16, rva: u32) usize {
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const e = b[so + i * 40 ..];
                const vs = std.mem.readInt(u32, e[8..12], .little);
                const va = std.mem.readInt(u32, e[12..16], .little);
                const rs = std.mem.readInt(u32, e[16..20], .little);
                const ro = std.mem.readInt(u32, e[20..24], .little);
                if (rva >= va and rva < va + @max(vs, rs)) return rva - va + ro;
            }
            return 0;
        }
    };
    const ed = Rva.off(bytes, sec_off, nsec, exp_rva);
    const n_names = std.mem.readInt(u32, bytes[ed + 24 ..][0..4], .little);
    const names_rva = std.mem.readInt(u32, bytes[ed + 32 ..][0..4], .little);
    const names_off = Rva.off(bytes, sec_off, nsec, names_rva);
    var out = try gpa.alloc([]const u8, n_names);
    var k: usize = 0;
    while (k < n_names) : (k += 1) {
        const r = std.mem.readInt(u32, bytes[names_off + k * 4 ..][0..4], .little);
        const o = Rva.off(bytes, sec_off, nsec, r);
        const end = std.mem.indexOfScalarPos(u8, bytes, o, 0).?;
        out[k] = bytes[o..end];
    }
    return out;
}
