//! D1.5 (selfhost dogfood): skaler `match` hata yolları — literal ile enum desenleri karışamaz; konu tipi ile literal tipi uyuşmalı.
const std = @import("std");

fn checkSource(a: std.mem.Allocator, io: std.Io, src: []const u8) !std.process.RunResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "m.nox", .data = src });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(a, "{s}/m.nox", .{dir});
    defer a.free(path);
    return std.process.run(a, io, .{ .argv = &.{ "zig-out/bin/noxc", "check", path } });
}

test "skaler match: enum ve literal desenleri karisamaz" {
    const io = std.testing.io;
    const r = try checkSource(std.testing.allocator, io,
        \\enum E:
        \\    A
        \\    B
        \\
        \\def f(e: E) -> int:
        \\    match e:
        \\        case E.A:
        \\            return 1
        \\        case 2:
        \\            return 2
        \\    return 0
        \\
    );
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(!(r.term == .exited and r.term.exited == 0));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "cannot mix literal cases and enum-variant cases") != null);
}

test "skaler match: literal tipi konu tipiyle uyusmali" {
    const io = std.testing.io;
    const r = try checkSource(std.testing.allocator, io,
        \\def f(k: int) -> int:
        \\    match k:
        \\        case "a":
        \\            return 1
        \\    return 0
        \\
    );
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(!(r.term == .exited and r.term.exited == 0));
}
