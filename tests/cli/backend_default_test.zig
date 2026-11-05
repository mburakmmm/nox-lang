//! v1.143.0: `noxc build`in VARSAYILAN backend'i artık LLVM (`.ll` + `clang -O2`); QBE (`.ssa` + `qbe` + `cc`)
//! `--backend qbe` ile açıkça seçilir, `--target`/`--emit-asm`/`--profile freestanding` ile (ve Windows'ta,
//! `clang` yokken) otomatik seçilir. `--release` eski ad olarak LLVM'e eşdeğer kalır. GERÇEK `noxc` alt
//! süreciyle doğrulanır (`profile_test.zig`nin AYNI deseni): hangi ara dosyanın üretildiği backend'i ayırt eder.

const std = @import("std");
const builtin = @import("builtin");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

const Probe = struct {
    ok: bool,
    has_ll: bool,
    has_ssa: bool,
    stdout: []const u8,
};

fn buildAndProbe(gpa: std.mem.Allocator, io: std.Io, extra: []const []const u8) !Probe {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = "print(6 * 7)\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const out = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{dir});
    defer gpa.free(out);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ noxcPath(), "build" });
    try argv.appendSlice(gpa, extra);
    try argv.appendSlice(gpa, &.{ "-o", out, src });
    const build = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(build.stdout);
    defer gpa.free(build.stderr);
    const ok = build.term == .exited and build.term.exited == 0;

    const has_ll = if (tmp.dir.access(io, "prog_bin.ll", .{})) |_| true else |_| false;
    const has_ssa = if (tmp.dir.access(io, "prog_bin.ssa", .{})) |_| true else |_| false;

    var stdout: []const u8 = try gpa.dupe(u8, "");
    if (ok and !hasFlag(extra, "--emit-asm")) {
        const run = try std.process.run(gpa, io, .{ .argv = &.{out} });
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);
        gpa.free(stdout);
        stdout = try gpa.dupe(u8, run.stdout);
    }
    return .{ .ok = ok, .has_ll = has_ll, .has_ssa = has_ssa, .stdout = stdout };
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

test "noxc build: varsayilan backend LLVM (.ll), Windows disinda" {
    const gpa = std.testing.allocator;
    const p = try buildAndProbe(gpa, std.testing.io, &.{});
    defer gpa.free(p.stdout);
    try std.testing.expect(p.ok);
    try std.testing.expectEqualStrings("42\n", p.stdout);
    if (builtin.os.tag != .windows) {
        try std.testing.expect(p.has_ll);
        try std.testing.expect(!p.has_ssa);
    }
}

test "noxc build --backend qbe: QBE yolu (.ssa), ayni cikti" {
    const gpa = std.testing.allocator;
    const p = try buildAndProbe(gpa, std.testing.io, &.{ "--backend", "qbe" });
    defer gpa.free(p.stdout);
    try std.testing.expect(p.ok);
    try std.testing.expectEqualStrings("42\n", p.stdout);
    try std.testing.expect(p.has_ssa);
    try std.testing.expect(!p.has_ll);
}

test "noxc build --backend llvm ve eski --release: LLVM yolu (.ll)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    for ([_][]const []const u8{ &.{ "--backend", "llvm" }, &.{"--release"} }) |extra| {
        const p = try buildAndProbe(gpa, std.testing.io, extra);
        defer gpa.free(p.stdout);
        try std.testing.expect(p.ok);
        try std.testing.expectEqualStrings("42\n", p.stdout);
        try std.testing.expect(p.has_ll);
        try std.testing.expect(!p.has_ssa);
    }
}

test "noxc build --emit-asm: varsayilan olarak QBE yolu (LLVM --emit-asm'i desteklemez)" {
    const gpa = std.testing.allocator;
    const p = try buildAndProbe(gpa, std.testing.io, &.{"--emit-asm"});
    defer gpa.free(p.stdout);
    try std.testing.expect(p.ok);
    try std.testing.expect(p.has_ssa);
    try std.testing.expect(!p.has_ll);
}

test "noxc build --backend <bilinmeyen>: acik hata, cikis kodu 1" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--backend", "cranelift", "x.nox" } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(r.term == .exited and r.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "cranelift") != null);
}

test "noxc build -g: varsayilan backend QBE'ye duser (DWARF yalnizca orada uretilir)" {
    const gpa = std.testing.allocator;
    const p = try buildAndProbe(gpa, std.testing.io, &.{"-g"});
    defer gpa.free(p.stdout);
    try std.testing.expect(p.ok);
    try std.testing.expectEqualStrings("42\n", p.stdout);
    try std.testing.expect(p.has_ssa);
    try std.testing.expect(!p.has_ll);
}

test "noxc build -g --backend llvm: acik hata (LLVM hata ayiklama bilgisi uretmez)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "-g", "--backend", "llvm", "x.nox" } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(r.term == .exited and r.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--backend qbe -g") != null);
}

test "noxc build --backend llvm --target <bilinmeyen>: acik hata (yanlis platform ikilisi uretilmez)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--backend", "llvm", "--target", "plan9-x64", "x.nox" } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(r.term == .exited and r.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unknown or unsupported target 'plan9-x64'") != null);
}

test "noxc build --backend llvm --target windows-x64 -g / --emit-asm: acik hata (yalnizca QBE)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "-g", "--emit-asm" }) |flag| {
        const r = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--backend", "llvm", "--target", "windows-x64", flag, "x.nox" } });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expect(r.term == .exited and r.term.exited == 1);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "does not support -g or --emit-asm for target 'windows-x64'") != null);
    }
}

fn zigAvailable(gpa: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "zig", "version" } }) catch return false;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

/// v2.0.177 (Faz 11.1): masaüstü `--target` artik LLVM'den gecer (varsayilan, `zig` varsa): `.ll` uretilir, `.ssa` uretilmez. `-g` / `--emit-asm` / `--backend qbe` QBE'de kalir.
fn crossProbe(gpa: std.mem.Allocator, io: std.Io, extra: []const []const u8) !Probe {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = "print(6 * 7)\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const src = try std.fmt.allocPrint(gpa, "{s}/prog.nox", .{dir});
    defer gpa.free(src);
    const out = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{dir});
    defer gpa.free(out);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ noxcPath(), "build" });
    try argv.appendSlice(gpa, extra);
    try argv.appendSlice(gpa, &.{ "-o", out, src });
    const build = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(build.stdout);
    defer gpa.free(build.stderr);
    if (build.term != .exited or build.term.exited != 0) std.debug.print("noxc build basarisiz: {s}\n", .{build.stderr});
    return .{
        .ok = build.term == .exited and build.term.exited == 0,
        .has_ll = if (tmp.dir.access(io, "prog_bin.ll", .{})) |_| true else |_| false,
        .has_ssa = if (tmp.dir.access(io, "prog_bin.ssa", .{})) |_| true else |_| false,
        .stdout = "",
    };
}

test "noxc build --target linux-arm64: varsayilan olarak LLVM (.ll), --backend qbe ile QBE (.ssa)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    if (!zigAvailable(gpa, io)) return error.SkipZigTest;
    const llvm = try crossProbe(gpa, io, &.{ "--target", "linux-arm64" });
    try std.testing.expect(llvm.ok and llvm.has_ll and !llvm.has_ssa);
    const qbe = try crossProbe(gpa, io, &.{ "--backend", "qbe", "--target", "linux-arm64" });
    try std.testing.expect(qbe.ok and qbe.has_ssa and !qbe.has_ll);
}
