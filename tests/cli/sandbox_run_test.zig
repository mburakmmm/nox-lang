//! `noxc run --sandbox` (ADR-010): sandbox içinde ev dizinine yazma ve ağ reddedilir, sandbox'sız aynı program yazar. macOS'ta
//! `sandbox-exec` ile çalışır; diğer platformlarda atlanır (Linux `bwrap` birim testleri `compiler/sandbox.zig`dedir).

const std = @import("std");
const builtin = @import("builtin");

const Source =
    \\import nox.fs
    \\import nox.os
    \\import nox.http
    \\from nox.fs import FsError
    \\from nox.http import HttpError, HttpResponse
    \\
    \\probe: str = nox.os.getenv("NOX_SANDBOX_PROBE")
    \\try:
    \\    nox.fs.write_string(probe, "x")
    \\    print("yazildi")
    \\except FsError:
    \\    print("yazilamadi")
    \\try:
    \\    r: HttpResponse = nox.http.get("http://127.0.0.1:9/", {})
    \\    print("ag acik")
    \\except HttpError:
    \\    print("ag kapali")
    \\
;

fn runNoxc(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, probe: []const u8) !std.process.RunResult {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    if (std.c.getenv("PATH")) |p| try env.put("PATH", std.mem.span(p));
    if (std.c.getenv("HOME")) |h| try env.put("HOME", std.mem.span(h));
    if (std.c.getenv("TMPDIR")) |t| try env.put("TMPDIR", std.mem.span(t));
    try env.put("NOX_SANDBOX_PROBE", probe);
    return std.process.run(gpa, io, .{ .argv = argv, .environ_map = &env });
}

test "sandbox ev dizinine yazmayı ve ağı reddeder, sandbox'sız program yazar" {
    if (builtin.os.tag != .macos) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "probe.nox", .data = Source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const src = try std.fmt.allocPrint(gpa, "{s}/probe.nox", .{path_buf[0..len]});
    defer gpa.free(src);

    const home = std.mem.span(std.c.getenv("HOME") orelse return);
    const probe = try std.fmt.allocPrint(gpa, "{s}/.nox_sandbox_probe_{d}", .{ home, std.c.getpid() });
    defer gpa.free(probe);
    defer std.Io.Dir.cwd().deleteFile(io, probe) catch {};

    const sandboxed = try runNoxc(gpa, io, &.{ "zig-out/bin/noxc", "run", "--sandbox", src }, probe);
    defer gpa.free(sandboxed.stdout);
    defer gpa.free(sandboxed.stderr);
    try std.testing.expectEqualStrings("yazilamadi\nag kapali\n", sandboxed.stdout);
    std.Io.Dir.cwd().access(io, probe, .{}) catch {
        // beklenen: dosya oluşmadı
        const plain = try runNoxc(gpa, io, &.{ "zig-out/bin/noxc", "run", src }, probe);
        defer gpa.free(plain.stdout);
        defer gpa.free(plain.stderr);
        try std.testing.expect(std.mem.startsWith(u8, plain.stdout, "yazildi\n"));
        return;
    };
    return error.SandboxLeakedWrite;
}

test "sandbox bayrakları --sandbox olmadan reddedilir" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "zig-out/bin/noxc", "run", "--allow-net", "x.nox" } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expect(r.term == .exited and r.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "only apply together with --sandbox") != null);
}
