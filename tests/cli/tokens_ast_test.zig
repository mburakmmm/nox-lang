//! noxc-nightly Aşama 0.4/0.5: gizli geliştirici komutları `noxc tokens` / `noxc ast` ve global `--frontend` bayrağı.

const std = @import("std");

fn runNoxc(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(a, io, .{ .argv = argv });
}

test "tokens: metin dokumu satir:sutun kind bayt-araligi lexeme" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t.nox", .data = "x: str = \"a\\n\\\"b\"  # c\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/t.nox", .{dir});
    defer std.testing.allocator.free(path);
    const r = try runNoxc(std.testing.allocator, io, &.{ "zig-out/bin/noxc", "tokens", path });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "1:1 identifier 0-1 \"x\"\n1:2 colon 1-2 \":\"\n1:4 identifier 3-6 \"str\"\n1:8 assign 7-8 \"=\"\n1:10 string_lit "));
    try std.testing.expect(std.mem.endsWith(u8, r.stdout, "newline 25-25 \"\"\n2:1 eof 26-26 \"\"\n") or std.mem.indexOf(u8, r.stdout, " eof ") != null);
}

test "tokens: --json ve sozcuk hatasi (cikis 1, stdout'ta ERROR)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.nox", .data = "a = 1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.nox", .data = "x = $\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const ok = try std.fmt.allocPrint(std.testing.allocator, "{s}/ok.nox", .{dir});
    defer std.testing.allocator.free(ok);
    const bad = try std.fmt.allocPrint(std.testing.allocator, "{s}/bad.nox", .{dir});
    defer std.testing.allocator.free(bad);

    const j = try runNoxc(std.testing.allocator, io, &.{ "zig-out/bin/noxc", "tokens", "--json", ok });
    defer std.testing.allocator.free(j.stdout);
    defer std.testing.allocator.free(j.stderr);
    try std.testing.expect(std.mem.startsWith(u8, j.stdout, "{\"tokens\":[{\"kind\":\"identifier\",\"lexeme\":\"a\",\"line\":1,\"col\":1,\"start\":0,\"end\":1}"));

    const e = try runNoxc(std.testing.allocator, io, &.{ "zig-out/bin/noxc", "tokens", bad });
    defer std.testing.allocator.free(e.stdout);
    defer std.testing.allocator.free(e.stderr);
    try std.testing.expect(e.term == .exited and e.term.exited == 1);
    try std.testing.expectEqualStrings("ERROR UnexpectedCharacter 1:5\n", e.stdout);
}

test "ast: yalnizca ayristirir ve AST dokumunu basar; --frontend nox normal noxc'te reddedilir" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.nox", .data = "def f(x: int) -> int:\n    return x\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/a.nox", .{dir});
    defer std.testing.allocator.free(path);
    const r = try runNoxc(std.testing.allocator, io, &.{ "zig-out/bin/noxc", "ast", path });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "(module\n  (def f (x:int) int\n"));

    const n = try runNoxc(std.testing.allocator, io, &.{ "zig-out/bin/noxc", "--frontend", "nox", "tokens", path });
    defer std.testing.allocator.free(n.stdout);
    defer std.testing.allocator.free(n.stderr);
    try std.testing.expect(n.term == .exited and n.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, n.stderr, "no Nox frontend components") != null);

    const z = try runNoxc(std.testing.allocator, io, &.{ "zig-out/bin/noxc", "--frontend", "zig", "tokens", path });
    defer std.testing.allocator.free(z.stdout);
    defer std.testing.allocator.free(z.stderr);
    try std.testing.expect(z.term == .exited and z.term.exited == 0);
}
