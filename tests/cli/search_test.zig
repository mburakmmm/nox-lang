//! Faz Y.1 golden testi: `noxc search`i (bkz. `compiler/pkg/index.zig`nin
//! modül üstü notu) `subcommand_test.zig` İLE AYNI desende — kurulu
//! `zig-out/bin/noxc`yi GERÇEK bir alt süreç olarak çalıştırarak — doğrular.

const std = @import("std");
const sys = @import("sys_compat");

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

test "noxc search: bos sorguyla (2-argumanli form) tum katalogu listeler" {
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
        .argv = &.{ noxcPath(), "search", index_path, "" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxhttp-extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxcolor") != null);
}

// Bulundu, kullanıcı isteği (services/noxpkg/'in canlıya alınmasından
// SONRA — bkz. proje belleği "noxc add/delete/publish + noxpkg merkezi
// sunucusu" fazı): `noxc add`nin `repo` atlandığında `NOX_INDEX_URL`e
// (varsayılan merkezi kayıt) DÜŞMESİYLE AYNI desen `search`e de eklendi
// — TEK bir pozisyonel argüman (`noxc search <isim>`), o argümanı
// `<indeks>` DEĞİL `<sorgu>` olarak yorumlayıp indeksi HER ZAMAN
// `NOX_INDEX_URL`den (ya da varsayılandan) çözer.
test "noxc search: TEK argumanla (sorgu) varsayilan/NOX_INDEX_URL indeksi sorgular" {
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

    var env_map = try std.testing.environ.createMap(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("NOX_INDEX_URL", index_path);

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", "http" },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("search basarisiz, stderr: {s}\n", .{result.stderr});
    }
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxhttp-extras") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "noxcolor") == null);
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
    try std.testing.expectEqualStrings("no matching packages found\n", result.stdout);
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
        .argv = &.{ noxcPath(), "search", index_path, "" },
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

fn testListenerOn127001(port_out: *u16) !sys.fd_t {
    const fd = sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    if (sys.badFd(fd)) return error.SocketFailed;
    var reuse: c_int = 1;
    _ = sys.setsockopt(fd, sys.SOL.SOCKET, sys.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: sys.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (sys.bind(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.in)) != 0) return error.BindFailed;
    if (sys.listen(fd, 1) != 0) return error.ListenFailed;

    var got: sys.sockaddr.in = undefined;
    var got_len: sys.socklen_t = @sizeOf(sys.sockaddr.in);
    if (sys.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    port_out.* = std.mem.bigToNative(u16, got.port);
    return fd;
}

/// v1.80.6 (bkz. CHANGELOG.md/nox-teknik-spesifikasyon.md §3.156):
/// `sys.accept`in ÇIPLAK (zaman-aşımsız) hâli, GERÇEK bir CI koşusunda
/// (Linux aarch64, `zig build test`nin TAM paralel paketi İÇİNDE, bir
/// Docker/aarch64 konteynerinde GERÇEKTEN reprodüklenip `gdb`yle KANITLANDI)
/// istemci alt-süreci (GERÇEK `noxc` çağrısı) BEKLENEN bağlantıyı HİÇ
/// KURMADAN döndüğünde (ağır kaynak-çekişmesi ALTINDA, KESİN kök neden
/// henüz İZOLE EDİLEMEDİ — AMA semptom KESİN: sunucu iş parçacığı `accept()`
/// içinde SONSUZA KADAR bekliyor, `defer server_thread.join()` de dolayısıyla
/// SONSUZA KADAR bloklanıyor) test sürecini SONSUZA KADAR ASKIDA bırakıyordu
/// — `MN.11`in CI `timeout-minutes` düzeltmesiyle AYNI savunma-derinliği
/// ilkesi: kök neden TAM olarak KANITLANAMASA da, HANGİSİ olursa olsun
/// `accept()`i SINIRLI bir sürede GERİ dönmeye ZORLAYIP (`poll()` İLE)
/// sessiz bir sonsuz askıyı HIZLI/AÇIK bir test BAŞARISIZLIĞINA çevirir.
fn acceptWithTimeout(listen_fd: sys.fd_t, timeout_ms: i32) sys.fd_t {
    var pfd = [1]sys.pollfd{.{ .fd = listen_fd, .events = sys.POLL.IN, .revents = 0 }};
    const n = sys.poll(&pfd, 1, timeout_ms);
    if (n <= 0) return sys.bad_fd;
    return sys.accept(listen_fd, null, null);
}

/// Bir bağlantı kabul eder, isteği okur, `gzip_body`yi (ZATEN gzip
/// sıkıştırılmış baytlar — çağıran hazırlar) `Content-Encoding: gzip` İLE
/// yanıtlar.
fn testServeGzipIndex(listen_fd: sys.fd_t, gzip_body: []const u8) void {
    const conn = acceptWithTimeout(listen_fd, 15_000);
    if (sys.badFd(conn)) return;
    defer _ = sys.close(conn);

    var req_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < req_buf.len) {
        const n = sys.read(conn, req_buf[total..].ptr, req_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
        if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) break;
    }

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n", .{gzip_body.len}) catch return;
    var written: usize = 0;
    while (written < header.len) {
        const n = sys.write(conn, header[written..].ptr, header.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    written = 0;
    while (written < gzip_body.len) {
        const n = sys.write(conn, gzip_body[written..].ptr, gzip_body.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

test "noxc search: http:// URL varsayilan olarak reddedilir (guvenli-tasima)" {
    const io = std.testing.io;
    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);

    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/index.json", .{port});
    defer std.testing.allocator.free(url);

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxcPath(), "search", url, "" },
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
    defer _ = sys.close(listen_fd);

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
