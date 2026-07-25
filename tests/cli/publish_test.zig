//! `noxc publish` uçtan uca testleri — `search_test.zig`/`upgrade_test.zig`
//! İLE AYNI ham-soket yerel-sunucu deseni (bkz. `pkg/registry.zig`nin
//! `submitPublish`i). `NOX_PUBLISH_API_BASE` env override'ı İLE `noxc`,
//! GERÇEK `noxpkg.2mtechnology.org` YERİNE bu yerel sahte sunucuya
//! yönlendirilir — GERÇEK ağa ASLA dokunulmaz.

const std = @import("std");
const posix = std.posix;

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn noxcAbsPath(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, noxcPath() });
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

fn testListenerOn127001(port_out: *u16) !posix.fd_t {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 4) != 0) return error.ListenFailed;

    var got: std.c.sockaddr.in = undefined;
    var got_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    port_out.* = std.mem.bigToNative(u16, got.port);
    return fd;
}

fn contentLengthOf(headers: []const u8) usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    return 0;
}

/// Tek bir bağlantı kabul eder, isteği (başlıklar + gövde, TAMAMEN
/// drenaj edilir) okur, `response_body`yi `Content-Type: application/
/// json` İLE yanıtlar.
fn serveOnePublishResponse(listen_fd: posix.fd_t, response_body: []const u8) void {
    const conn = std.c.accept(listen_fd, null, null);
    if (conn < 0) return;
    defer _ = std.c.close(conn);

    var req_buf: [8192]u8 = undefined;
    var total: usize = 0;
    var header_end: usize = 0;
    while (total < req_buf.len) {
        const n = std.c.read(conn, req_buf[total..].ptr, req_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n")) |idx| {
            header_end = idx + 4;
            break;
        }
    }
    const content_length = contentLengthOf(req_buf[0..header_end]);
    var body_so_far = total - header_end;
    while (body_so_far < content_length and total < req_buf.len) {
        const n = std.c.read(conn, req_buf[total..].ptr, req_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        body_so_far += @intCast(n);
    }

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n", .{response_body.len}) catch return;
    var written: usize = 0;
    while (written < header.len) {
        const n = std.c.write(conn, header[written..].ptr, header.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    written = 0;
    while (written < response_body.len) {
        const n = std.c.write(conn, response_body[written..].ptr, response_body.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

fn writeProjectWithName(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !void {
    try dir.writeFile(io, .{
        .sub_path = "nox.json",
        .data = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"entry\":\"main.nox\"}}\n", .{name}),
    });
}

test "noxc publish: sunucu ok:true donerse basarili cikar, id'yi yazdirir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);
    const thread = try std.Thread.spawn(.{}, serveOnePublishResponse, .{ listen_fd, "{\"ok\":true,\"id\":\"abc123\"}" });
    defer thread.join();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try writeProjectWithName(io, a, proj.dir, "testpkg");

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    const api_base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    try env_map.put("NOX_PUBLISH_API_BASE", api_base);
    try env_map.put("NOX_ALLOW_INSECURE_TRANSPORT", "1");

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "publish", "github.com/example/testpkg", "--description", "test paketi" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("publish basarisiz, stderr: {s}\n", .{result.stderr});
    }
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "gonderildi: testpkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "abc123") != null);
}

test "noxc publish: sunucu ok:false donerse cikis 1, hata mesaji basilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);
    const thread = try std.Thread.spawn(.{}, serveOnePublishResponse, .{ listen_fd, "{\"ok\":false,\"error\":\"isim zaten kayitli\"}" });
    defer thread.join();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try writeProjectWithName(io, a, proj.dir, "testpkg");

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    const api_base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    try env_map.put("NOX_PUBLISH_API_BASE", api_base);
    try env_map.put("NOX_ALLOW_INSECURE_TRANSPORT", "1");

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "publish", "github.com/example/testpkg" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "isim zaten kayitli") != null);
}

test "noxc publish: nox.json'da bos 'name' varsa hic ag cagrisi yapmadan yerel hata verir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var proj_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const proj_path = try absPath(io, proj.dir, &proj_buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"entry\":\"main.nox\"}\n" });

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    // Baglanti KURULAMAYACAK bir port (dinleyici HIC baslatilmadi) --
    // agir bir ag cagrisi denenirse test ZAMAN ASIMINA UGRAR/basarisiz
    // olur, boylece "hic denenmedi" dolayli olarak dogrulanir.
    try env_map.put("NOX_PUBLISH_API_BASE", "http://127.0.0.1:1");
    try env_map.put("NOX_ALLOW_INSECURE_TRANSPORT", "1");

    const noxc_abs = try noxcAbsPath(io, a);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc_abs, "publish", "github.com/example/testpkg" },
        .cwd = .{ .path = proj_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "'name' bos") != null);
}
