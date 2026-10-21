//! Mobil hedef LLVM'de kalır, QBE reddedilir, dört üçlü kilitlidir.
//! Simülatör arşivi bir C çağrısıyla çalışır. Android `.so` NDK veya zig cc
//! varsa üretilir ve 16 KiB hizası ölçülür.

const std = @import("std");
const builtin = @import("builtin");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

const Source =
    \\def mobile_label() -> str:
    \\    return "no" + "x"
    \\
    \\def mobile_add(a: int, b: int) -> int:
    \\    return a + b
    \\
;

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv });
}

fn closeFd(fd: std.posix.fd_t) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.close(fd),
        else => _ = std.c.close(fd),
    }
}

/// `zig build` mobil runtime nesnelerini kurmaz. Bağ testi, nesne
/// kurulmuşsa çalışır (`zig build mobile-rt` veya `mobile-rt-android`).
fn runtimeObjectReady(name: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "zig-out/lib/{s}.o", .{name}) catch return false;
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

fn expectFail(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, needle: []const u8) !void {
    const result = try run(gpa, io, argv);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term != .exited or result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, needle) != null);
}

test "qbe is rejected for a mobile target" {
    if (builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = Source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const src = try std.fmt.allocPrint(std.testing.allocator, "{s}/prog.nox", .{path_buf[0..len]});
    defer std.testing.allocator.free(src);
    try expectFail(std.testing.allocator, io, &.{ noxcPath(), "build", "--target", "ios-simulator-arm64", "--backend", "qbe", "--emit-static-lib", src }, "qbe");
}

test "mobile llvm object carries the simulator triple" {
    if (builtin.os.tag != .macos) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = Source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const out = try std.fmt.allocPrint(gpa, "{s}/prog.o", .{dir});
    defer gpa.free(out);
    const built = try run(gpa, io, &.{ noxcPath(), "build", "--target", "ios-simulator-arm64", "--emit-obj", "-o", out, src });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (built.term == .exited) built.term.exited else 1);
    const ll = try std.fmt.allocPrint(gpa, "{s}/prog.ll", .{dir});
    defer gpa.free(ll);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, ll, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "target triple = \"arm64-apple-ios17.0-simulator\"") != null);
    if (!runtimeObjectReady("noxrt-ios-simulator-arm64")) return;
    const archive = try std.fmt.allocPrint(gpa, "{s}/prog.a", .{dir});
    defer gpa.free(archive);
    const archived = try run(gpa, io, &.{ noxcPath(), "build", "--target", "ios-simulator-arm64", "--emit-static-lib", "-o", archive, src });
    defer gpa.free(archived.stdout);
    defer gpa.free(archived.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (archived.term == .exited) archived.term.exited else 1);
    const fd = try std.posix.openat(std.posix.AT.FDCWD, archive, .{ .ACCMODE = .RDONLY }, 0);
    defer closeFd(fd);
    var magic: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try std.posix.read(fd, &magic));
    try std.testing.expectEqualStrings("!<arch>\n", &magic);
}

test "mobile mask rejects process and allows async" {
    if (builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "proc.nox", .data = "import nox.process\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "asy.nox", .data = "async def work() -> int:\n    return 1\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const proc = try std.fmt.allocPrint(gpa, "{s}/proc.nox", .{dir});
    defer gpa.free(proc);
    const asy = try std.fmt.allocPrint(gpa, "{s}/asy.nox", .{dir});
    defer gpa.free(asy);
    try expectFail(gpa, io, &.{ noxcPath(), "check", "--target", "android-arm64", proc }, "mobile target");
    const allowed_async = try run(gpa, io, &.{ noxcPath(), "check", "--target", "ios-arm64", asy });
    defer gpa.free(allowed_async.stdout);
    defer gpa.free(allowed_async.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (allowed_async.term == .exited) allowed_async.term.exited else 1);
    try tmp.dir.writeFile(io, .{ .sub_path = "args.nox", .data = "from nox.os import arg, arg_count\ncount: int = arg_count()\nfirst: str = arg(0)\n" });
    const args = try std.fmt.allocPrint(gpa, "{s}/args.nox", .{dir});
    defer gpa.free(args);
    const allowed = try run(gpa, io, &.{ noxcPath(), "check", "--target", "ios-simulator-arm64", args });
    defer gpa.free(allowed.stdout);
    defer gpa.free(allowed.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (allowed.term == .exited) allowed.term.exited else 1);
}

test "mobile mask allows jwt and rejects host libraries" {
    if (builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "pure.nox", .data = "import nox.base64\nimport nox.jwt\nimport nox.websocket\nimport nox.smtp\nimport nox.http\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mysql.nox", .data = "import nox.mysql\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "postgres.nox", .data = "import nox.postgres\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tls_srv.nox", .data = "import nox.http\nnox.http.serve_tls(1, 2, \"a\", \"b\")\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ws_tls.nox", .data = "import nox.http\nnox.http.serve_ws_tls(1, 2, 3, \"a\", \"b\")\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fd_tls.nox", .data = "import nox.http\nnox.http.serve_fd_tls(1, 2, \"a\", \"b\")\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const pure = try std.fmt.allocPrint(gpa, "{s}/pure.nox", .{dir});
    defer gpa.free(pure);
    const mysql = try std.fmt.allocPrint(gpa, "{s}/mysql.nox", .{dir});
    defer gpa.free(mysql);
    const postgres = try std.fmt.allocPrint(gpa, "{s}/postgres.nox", .{dir});
    defer gpa.free(postgres);
    const tls_srv = try std.fmt.allocPrint(gpa, "{s}/tls_srv.nox", .{dir});
    defer gpa.free(tls_srv);
    const ws_tls = try std.fmt.allocPrint(gpa, "{s}/ws_tls.nox", .{dir});
    defer gpa.free(ws_tls);
    const fd_tls = try std.fmt.allocPrint(gpa, "{s}/fd_tls.nox", .{dir});
    defer gpa.free(fd_tls);
    const allowed = try run(gpa, io, &.{ noxcPath(), "check", "--target", "ios-arm64", pure });
    defer gpa.free(allowed.stdout);
    defer gpa.free(allowed.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (allowed.term == .exited) allowed.term.exited else 1);
    try expectFail(gpa, io, &.{ noxcPath(), "check", "--target", "android-arm64", mysql }, "host shared library");
    try expectFail(gpa, io, &.{ noxcPath(), "check", "--target", "ios-simulator-arm64", postgres }, "host shared library");
    try expectFail(gpa, io, &.{ noxcPath(), "check", "--target", "ios-arm64", tls_srv }, "libssl");
    try expectFail(gpa, io, &.{ noxcPath(), "check", "--target", "android-x64", ws_tls }, "libssl");
    try expectFail(gpa, io, &.{ noxcPath(), "check", "--target", "ios-simulator-arm64", fd_tls }, "libssl");
    const desktop = try run(gpa, io, &.{ noxcPath(), "check", mysql });
    defer gpa.free(desktop.stdout);
    defer gpa.free(desktop.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (desktop.term == .exited) desktop.term.exited else 1);
}

test "mobile library entry compiles async" {
    if (builtin.os.tag != .macos) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "entry.nox", .data = "async def add(a: int, b: int) -> int:\n    return a + b\nvalue: int = await spawn add(20, 22)\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/entry.nox", .{path_buf[0..len]});
    defer gpa.free(src);
    const obj = try std.fmt.allocPrint(gpa, "{s}/entry.o", .{path_buf[0..len]});
    defer gpa.free(obj);
    const built = try run(gpa, io, &.{ noxcPath(), "build", "--target", "ios-simulator-arm64", "--emit-obj", "-o", obj, src });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (built.term == .exited) built.term.exited else 1);
}

test "mobile library entry compiles a void program" {
    if (builtin.os.tag != .macos) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "entry.nox", .data = "def touch() -> None:\n    return\ntouch()\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/entry.nox", .{path_buf[0..len]});
    defer gpa.free(src);
    const obj = try std.fmt.allocPrint(gpa, "{s}/entry.o", .{path_buf[0..len]});
    defer gpa.free(obj);
    const built = try run(gpa, io, &.{ noxcPath(), "build", "--target", "ios-simulator-arm64", "--emit-obj", "-o", obj, src });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    try std.testing.expectEqual(@as(u8, 0), if (built.term == .exited) built.term.exited else 1);
}

test "simulator archive answers 42" {
    if (builtin.os.tag != .macos) return;
    if (!runtimeObjectReady("noxrt-ios-simulator-arm64")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = Source });
    try tmp.dir.writeFile(io, .{ .sub_path = "host.c", .data =
        \\#include <stdint.h>
        \\#include <string.h>
        \\#include "nox_embed.h"
        \\char *mobile_label(void *rt);
        \\int64_t mobile_add(void *rt, int64_t a, int64_t b);
        \\void nox_str_release(void *rt, char *ptr);
        \\int main(void) {
        \\    NoxEmbedSlot slot = {NOX_EMBED_ABI, 0};
        \\    NoxHostConfig cfg;
        \\    memset(&cfg, 0, sizeof(cfg));
        \\    cfg.size = sizeof(cfg);
        \\    cfg.abi_version = NOX_EMBED_ABI;
        \\    cfg.slot = &slot;
        \\    cfg.documents = "/tmp/nox-docs";
        \\    cfg.support = "/tmp/nox-support";
        \\    cfg.cache = "/tmp/nox-cache";
        \\    cfg.temp_dir = "/tmp/nox-temp";
        \\    void *app = 0;
        \\    if (nox_app_create(&cfg, &app) != 0) return 10;
        \\    nox_embed_bind(app);
        \\    if (nox_app_start(app) != 0) return 11;
        \\    void *rt = nox_app_runtime(app);
        \\    if (!rt) return 12;
        \\    char *label = mobile_label(rt);
        \\    if (!label || strcmp(label, "nox") != 0) return 13;
        \\    if (mobile_add(rt, 20, 22) != 42) return 14;
        \\    nox_str_release(rt, label);
        \\    if (nox_app_destroy(slot.app) != 0) return 15;
        \\    if (nox_app_destroy(slot.app) != 0) return 16;
        \\    return 0;
        \\}
    });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const archive = try std.fmt.allocPrint(gpa, "{s}/prog.a", .{dir});
    defer gpa.free(archive);
    const built = try run(gpa, io, &.{ noxcPath(), "build", "--target", "ios-simulator-arm64", "--emit-static-lib", "-o", archive, src });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (built.term != .exited or built.term.exited != 0) {
        std.debug.print("{s}\n", .{built.stderr});
        return error.BuildFailed;
    }
    const sdk = try run(gpa, io, &.{ "xcrun", "--sdk", "iphonesimulator", "--show-sdk-path" });
    defer gpa.free(sdk.stdout);
    defer gpa.free(sdk.stderr);
    try std.testing.expect(sdk.term == .exited and sdk.term.exited == 0);
    const sdk_path = std.mem.trim(u8, sdk.stdout, " \t\r\n");
    const host_c = try std.fmt.allocPrint(gpa, "{s}/host.c", .{dir});
    defer gpa.free(host_c);
    const host_bin = try std.fmt.allocPrint(gpa, "{s}/host", .{dir});
    defer gpa.free(host_bin);
    const linked = try run(gpa, io, &.{ "xcrun", "clang", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk_path, "-I", "include", "-o", host_bin, host_c, archive });
    defer gpa.free(linked.stdout);
    defer gpa.free(linked.stderr);
    if (linked.term != .exited or linked.term.exited != 0) {
        std.debug.print("{s}\n", .{linked.stderr});
        return error.LinkFailed;
    }
    const listed = try run(gpa, io, &.{ "xcrun", "simctl", "list", "devices", "available" });
    defer gpa.free(listed.stdout);
    defer gpa.free(listed.stderr);
    const udid = firstPhoneUdid(listed.stdout) orelse return error.NoSimulator;
    const booted = try run(gpa, io, &.{ "xcrun", "simctl", "bootstatus", udid, "-b" });
    defer gpa.free(booted.stdout);
    defer gpa.free(booted.stderr);
    const ran = try run(gpa, io, &.{ "xcrun", "simctl", "spawn", udid, host_bin });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0) {
        std.debug.print("simulator spawn: {s}\n", .{ran.stderr});
        return error.SimulatorFailed;
    }
    const swift = try std.fmt.allocPrint(gpa, "{s}/main.swift", .{dir});
    defer gpa.free(swift);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.swift", .data =
        \\import Darwin
        \\struct Slot { var abi: Int32; var app: UnsafeMutableRawPointer? }
        \\struct Config { var size: UInt32; var abi: UInt32; var slot: UnsafeMutablePointer<Slot>; var documents: UnsafePointer<CChar>; var support: UnsafePointer<CChar>; var cache: UnsafePointer<CChar>; var tempDir: UnsafePointer<CChar> }
        \\@_silgen_name("nox_app_create") func noxAppCreate(_ c: UnsafePointer<Config>, _ o: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        \\@_silgen_name("nox_app_start") func noxAppStart(_ a: UnsafeMutableRawPointer?) -> Int32
        \\@_silgen_name("nox_app_runtime") func noxAppRuntime(_ a: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
        \\@_silgen_name("nox_app_destroy") func noxAppDestroy(_ a: UnsafeMutableRawPointer?) -> Int32
        \\@_silgen_name("nox_embed_bind") func noxEmbedBind(_ a: UnsafeMutableRawPointer?)
        \\@_silgen_name("nox_str_release") func noxStrRelease(_ r: UnsafeMutableRawPointer?, _ p: UnsafeMutablePointer<CChar>?)
        \\@_silgen_name("mobile_label") func mobileLabel(_ r: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
        \\@_silgen_name("mobile_add") func mobileAdd(_ r: UnsafeMutableRawPointer?, _ a: Int64, _ b: Int64) -> Int64
        \\@main struct Host {
        \\  static func main() { exit(run()) }
        \\  static func run() -> Int32 {
        \\    let slot = UnsafeMutablePointer<Slot>.allocate(capacity: 1)
        \\    slot.initialize(to: Slot(abi: 1, app: nil))
        \\    let docs = strdup("/tmp/nox-docs")!
        \\    let support = strdup("/tmp/nox-support")!
        \\    let cache = strdup("/tmp/nox-cache")!
        \\    let temp = strdup("/tmp/nox-temp")!
        \\    var cfg = Config(size: UInt32(MemoryLayout<Config>.size), abi: 1, slot: slot, documents: docs, support: support, cache: cache, tempDir: temp)
        \\    var app: UnsafeMutableRawPointer? = nil
        \\    if noxAppCreate(&cfg, &app) != 0 { return 10 }
        \\    noxEmbedBind(app)
        \\    if noxAppStart(app) != 0 { return 11 }
        \\    guard let rt = noxAppRuntime(app) else { return 12 }
        \\    guard let label = mobileLabel(rt) else { return 13 }
        \\    if String(cString: label) != "nox" { return 14 }
        \\    if mobileAdd(rt, 20, 22) != 42 { return 15 }
        \\    noxStrRelease(rt, label)
        \\    if noxAppDestroy(slot.pointee.app) != 0 { return 16 }
        \\    if noxAppDestroy(slot.pointee.app) != 0 { return 17 }
        \\    return 0
        \\  }
        \\}
    });
    const swift_bin = try std.fmt.allocPrint(gpa, "{s}/host-swift", .{dir});
    defer gpa.free(swift_bin);
    const compiled = try run(gpa, io, &.{ "xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk_path, "-o", swift_bin, swift, archive });
    defer gpa.free(compiled.stdout);
    defer gpa.free(compiled.stderr);
    if (compiled.term != .exited or compiled.term.exited != 0) {
        std.debug.print("{s}\n", .{compiled.stderr});
        return error.SwiftFailed;
    }
    const swift_ran = try run(gpa, io, &.{ "xcrun", "simctl", "spawn", udid, swift_bin });
    defer gpa.free(swift_ran.stdout);
    defer gpa.free(swift_ran.stderr);
    if (swift_ran.term != .exited or swift_ran.term.exited != 0) {
        std.debug.print("swift spawn: {s}\n", .{swift_ran.stderr});
        return error.SimulatorFailed;
    }
}

fn firstPhoneUdid(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "iPhone")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, ')') orelse continue;
        const udid = trimmed[open + 1 .. close];
        if (udid.len < 32) continue;
        return udid;
    }
    return null;
}

fn elfLoadAlign(bytes: []const u8) !u64 {
    if (bytes.len < 64 or bytes[0] != 0x7f or bytes[1] != 'E') return error.NotElf;
    const little = bytes[5] == 1;
    if (!little) return error.NotElf;
    const phoff = std.mem.readInt(u64, bytes[32..40], .little);
    const phentsize = std.mem.readInt(u16, bytes[54..56], .little);
    const phnum = std.mem.readInt(u16, bytes[56..58], .little);
    var align_min: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const off: usize = @intCast(phoff + phentsize * i);
        if (off + 56 > bytes.len) return error.Truncated;
        const p_type = std.mem.readInt(u32, bytes[off..][0..4], .little);
        if (p_type != 1) continue;
        const p_align = std.mem.readInt(u64, bytes[off + 48 ..][0..8], .little);
        if (p_align < align_min) align_min = p_align;
    }
    if (align_min == std.math.maxInt(u64)) return error.NoLoad;
    return align_min;
}

test "android shared library is 16 KiB aligned" {
    if (builtin.os.tag == .windows) return;
    if (!runtimeObjectReady("noxrt-android-x64")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = Source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const so = try std.fmt.allocPrint(gpa, "{s}/libnoxapp.so", .{dir});
    defer gpa.free(so);
    const built = try run(gpa, io, &.{ noxcPath(), "build", "--target", "android-x64", "--emit-shared-lib", "-o", so, src });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (built.term != .exited or built.term.exited != 0) {
        std.debug.print("{s}\n", .{built.stderr});
        return error.BuildFailed;
    }
    const fd = try std.posix.openat(std.posix.AT.FDCWD, so, .{ .ACCMODE = .RDONLY }, 0);
    defer closeFd(fd);
    var bytes: [4096]u8 = undefined;
    const n = try std.posix.read(fd, &bytes);
    const align_min = try elfLoadAlign(bytes[0..n]);
    try std.testing.expect(align_min >= 16384);
    const ll = try std.fmt.allocPrint(gpa, "{s}/libnoxapp.ll", .{dir});
    defer gpa.free(ll);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, ll, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "target triple = \"x86_64-linux-android24\"") != null);
}
