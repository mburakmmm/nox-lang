//! `noxc sign` (ADR-011): anahtar üretimi, imzalama, güven, iptal ve doğrulama uçtan uca; izole bir `NOX_HOME` ile.

const std = @import("std");

fn noxc(gpa: std.mem.Allocator, io: std.Io, home: []const u8, args: []const []const u8) !std.process.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig-out/bin/noxc");
    try argv.appendSlice(gpa, args);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    try env.put("NOX_HOME", home);
    return std.process.run(gpa, io, .{ .argv = argv.items, .environ_map = &env });
}

fn exited(r: std.process.RunResult) u8 {
    return if (r.term == .exited) r.term.exited else 255;
}

test "imza akışı: keygen, lock, güvenilmeyen, trust, tamam, değişiklik, iptal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "home", .default_dir);
    try tmp.dir.createDir(io, "proj", .default_dir);
    const lock = "{\"packages\":[{\"alias\":\"a\",\"repo\":\"github.com/x/a\",\"ref\":\"v1\",\"resolved\":\"abc\"}]}";
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/nox.lock", .data = lock });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const base = buf[0..n];
    const home = try std.fmt.allocPrint(gpa, "{s}/home", .{base});
    defer gpa.free(home);
    const proj = try std.fmt.allocPrint(gpa, "{s}/proj", .{base});
    defer gpa.free(proj);
    const pubkey = try std.fmt.allocPrint(gpa, "{s}/keys/pub.pub", .{home});
    defer gpa.free(pubkey);

    const steps = [_]struct { args: []const []const u8, want: u8 }{
        .{ .args = &.{ "sign", "keygen", "pub" }, .want = 0 },
        .{ .args = &.{ "sign", "keygen", "pub" }, .want = 1 }, // üzerine yazılmaz
        .{ .args = &.{ "sign", "verify", proj }, .want = 1 }, // imza yok
        .{ .args = &.{ "sign", "lock", "--key", "pub", proj }, .want = 0 },
        .{ .args = &.{ "sign", "verify", proj }, .want = 1 }, // imzalayan güvenilir değil
        .{ .args = &.{ "sign", "trust", pubkey }, .want = 0 },
        .{ .args = &.{ "sign", "verify", proj }, .want = 0 },
    };
    for (steps) |st| {
        const r = try noxc(gpa, io, home, st.args);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(st.want, exited(r));
    }

    // kilit değişirse imza geçersiz
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/nox.lock", .data = lock ++ " " });
    {
        const r = try noxc(gpa, io, home, &.{ "sign", "verify", proj });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 1), exited(r));
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "does not match") != null);
    }
    // eski kilit + iptal
    try tmp.dir.writeFile(io, .{ .sub_path = "proj/nox.lock", .data = lock });
    {
        const listing = try noxc(gpa, io, home, &.{ "sign", "trust", pubkey });
        defer gpa.free(listing.stdout);
        defer gpa.free(listing.stderr);
        const fp = std.mem.trim(u8, listing.stderr["trusted key ".len..], " \r\n");
        const rev = try noxc(gpa, io, home, &.{ "sign", "revoke", fp });
        defer gpa.free(rev.stdout);
        defer gpa.free(rev.stderr);
        try std.testing.expectEqual(@as(u8, 0), exited(rev));
    }
    const r = try noxc(gpa, io, home, &.{ "sign", "verify", proj });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 1), exited(r));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "revoked") != null);
}
