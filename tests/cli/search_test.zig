//! Faz Y.1 golden testi: `noxc search`i (bkz. `compiler/pkg/index.zig`nin
//! modül üstü notu) `subcommand_test.zig` İLE AYNI desende — kurulu
//! `zig-out/bin/noxc`yi GERÇEK bir alt süreç olarak çalıştırarak — doğrular.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

const FIXTURE_INDEX =
    \\{"packages": [
    \\  {"name": "noxhttp-extras", "repo": "github.com/example/noxhttp-extras",
    \\   "description": "nox.http icin yardimci fonksiyonlar", "tags": ["http", "web"]},
    \\  {"name": "noxcolor", "repo": "github.com/example/noxcolor",
    \\   "description": "Terminal renklendirme"}
    \\]}
;

test "noxc search: sorgu olmadan tum katalogu listeler" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = FIXTURE_INDEX });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const index_path = try std.fmt.allocPrint(a, "{s}/index.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxhttp-extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxcolor") != null);
}

test "noxc search: sorgu eslesen TEK paketi doner" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = FIXTURE_INDEX });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const index_path = try std.fmt.allocPrint(a, "{s}/index.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path, "http" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxhttp-extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxcolor") == null);
}

test "noxc search: eslesme yoksa acik bir mesaj basar" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "index.json", .data = FIXTURE_INDEX });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const index_path = try std.fmt.allocPrint(a, "{s}/index.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path, "hicbiryerde" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expectEqualStrings("eslesen paket bulunamadi\n", result.stdout);
}

test "noxc search: bozuk indeks dosyasi net bir hatayla cikis kodu 1 doner" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{ bozuk" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    var buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&buf, "{s}/bad.json", .{path_buf[0..len]});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", index_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
}

// Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
// `noxc search`in YENİ URL yolu (`pkg_index.loadIndexFromUrl`) — GERÇEK bir
// yerel HTTP sunucusuna karşı, `tests/compat/http_stdlib_golden_test.zig`nin
// AYNI ham-soket deseniyle. `Content-Encoding: gzip` GERÇEK bir gzip
// akışıyla test edilir — `runtime/stdlib_shims/http_client.zig`de bulunan/
// düzeltilen AYNI hatanın (gövde HAM/sıkıştırılmış okunması) burada TEKRAR
// EDİLMEDİĞİNİN kanıtı.

const posix = std.posix;

fn testListenerOn127001(port_out: *u16) !posix.fd_t {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 1) != 0) return error.ListenFailed;

    var got: std.c.sockaddr.in = undefined;
    var got_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    port_out.* = std.mem.bigToNative(u16, got.port);
    return fd;
}

/// Bir bağlantı kabul eder, isteği okur, `gzip_body`yi (ZATEN gzip
/// sıkıştırılmış baytlar — çağıran hazırlar) `Content-Encoding: gzip` İLE
/// yanıtlar.
fn testServeGzipIndex(listen_fd: posix.fd_t, gzip_body: []const u8) void {
    const conn = std.c.accept(listen_fd, null, null);
    if (conn < 0) return;
    defer _ = std.c.close(conn);

    var req_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < req_buf.len) {
        const n = std.c.read(conn, req_buf[total..].ptr, req_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) break;
    }

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n", .{gzip_body.len}) catch return;
    var written: usize = 0;
    while (written < header.len) {
        const n = std.c.write(conn, header[written..].ptr, header.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    written = 0;
    while (written < gzip_body.len) {
        const n = std.c.write(conn, gzip_body[written..].ptr, gzip_body.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

test "noxc search: http:// URL varsayilan olarak reddedilir (guvenli-tasima)" {
    const io = std.testing.io;
    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/index.json", .{port});
    defer std.testing.allocator.free(url);

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", url },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "InsecureIndexUrlRejected") != null);
}

test "noxc search: NOX_ALLOW_INSECURE_TRANSPORT ile http:// URL'den gzip'li indeks GERCEKTEN cekilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var compressed = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer compressed.deinit();
    var gz_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var gz_compress = try std.compress.flate.Compress.init(&compressed.writer, &gz_buf, .gzip, .default);
    try gz_compress.writer.writeAll(FIXTURE_INDEX);
    try gz_compress.finish();
    const gzip_body = compressed.written();

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);

    const server_thread = try std.Thread.spawn(.{}, testServeGzipIndex, .{ listen_fd, gzip_body });
    defer server_thread.join();

    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/index.json", .{port});
    defer gpa.free(url);

    var env = try std.testing.environ.createMap(gpa);
    defer env.deinit();
    try env.put("NOX_ALLOW_INSECURE_TRANSPORT", "1");

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ noxcPath(), "search", url, "http" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxhttp-extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxcolor") == null);
}
