//! Faz B.2 (Aether NOX_LIMITATIONS.md madde 4+19, bkz. nox-teknik-
//! spesifikasyon.md ilgili bölüm): `nox.http.serve*`e verilen closure
//! handler'ının DERLEME-ZAMANI reddi. `tests/golden/typecheck_golden_test.
//! zig` stdlib import'larını (`import nox.http`) YÜKLEMEDİĞİNDEN bu
//! negatif testler GERÇEK `noxc check`i alt süreç olarak çalıştırır.

const std = @import("std");

fn checkSource(io: std.Io, a: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.nox", .data = source });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const dir_path = buf[0..len];
    const cwd = try std.process.currentPathAlloc(io, a);
    const noxc = try std.fs.path.join(a, &.{ cwd, "zig-out/bin/noxc" });
    return std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "check", "main.nox" },
        .cwd = .{ .path = dir_path },
    });
}

test "nox.http.serve_multicore: closure handler derleme zamaninda reddedilir (ayri RuntimeState)" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try checkSource(io, a,
        \\import nox.http
        \\
        \\def make_handler(tag: str) -> (nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\        return nox_http_HttpResponse(200, tag, {"x": "y"})
        \\    return handle
        \\
        \\h: (nox_http_HttpRequest) -> nox_http_HttpResponse = make_handler("a")
        \\nox.http.serve_multicore(8080, h, 2)
        \\
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "closure handler bu varyantta DESTEKLENMEZ") != null);
}

test "nox.http.serve: yanlis imzali closure handler reddedilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try checkSource(io, a,
        \\import nox.http
        \\
        \\def make_handler(n: int) -> (int) -> int:
        \\    def handle(x: int) -> int:
        \\        return x + n
        \\    return handle
        \\
        \\h: (int) -> int = make_handler(1)
        \\nox.http.serve(8080, h)
        \\
    );
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'handle'in parametresi 'HttpRequest' olmalı") != null);
}
