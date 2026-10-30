//! `stdlib/nox/http.nox` (D.1.5) uçtan uca golden testleri — bkz. nox-teknik-
//! spesifikasyon.md. `tests/golden/codegen_golden_test.zig`nin `compileAndRun`ı
//! (import çözümlemesi İÇİN `module_loader.resolveImports` KULLANIR) İLE
//! `tests/compat/extern_ffi_test.zig`nin RUNTIME (comptime OLMAYAN) `source`
//! desteği (port numarasını `std.fmt.allocPrint`la kaynağa GÖMMEK İÇİN)
//! BİRLEŞTİRİLİR — kasıtlı bir kod tekrarı (bu dosyanın ikisinin de İHTİYAÇ
//! duyduğu TEK bir noktada birleşmesi).
//!
//! Test sunucusu — `runtime/stdlib_shims/http_client.zig`nin KENDİ birim
//! testindeki ham POSIX soket deseniyle AYNI (AYRI bir Zig modülü olduğundan
//! doğrudan yeniden KULLANILAMAZ, bilinçli tekrar).

const std = @import("std");
const sys = @import("sys_compat");
const nox = @import("nox");
const host_link = @import("host_link");

fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
    checker_state.checkModule(module) catch |e| {
        std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        return error.FixtureNotWellTyped;
    };
    // Faz T.2: kurtarılmış tanılamalar artık FIRLATILMAZ, `diagnostics`e
    // KAYDEDİLİR — bu fixture'ın hatasız derlenmesi BEKLENDİĞİNDEN, herhangi
    // biri VARSA testin (öncekiyle AYNI şekilde) başarısız olması gerekir.
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ d.code, d.message });
        }
        return error.FixtureNotWellTyped;
    }

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(allocator, k.*);

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, checker_state.decorated_functions.items, .qbe, .hosted, null, &.{}, .empty);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ssa_path = try std.fmt.allocPrint(allocator, "{s}/prog.ssa", .{dir_path});
    const asm_path = try std.fmt.allocPrint(allocator, "{s}/prog.s", .{dir_path});
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/prog", .{dir_path});

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ssa", .data = ir });

    const qbe_result = try std.process.run(allocator, io, .{
        .argv = &.{ "qbe", "-t", nox.qbe_target.name(false), "-o", asm_path, ssa_path },
    });
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz: {s}\n", .{qbe_result.stderr});
        return error.QbeFailed;
    }

    const link_argv = try host_link.hostLinkArgv(allocator, &.{ "cc", host_link.hostLinkVisibility() }, bin_path, asm_path, &.{});
    defer allocator.free(link_argv);
    const cc_result = try std.process.run(allocator, io, .{
        .argv = link_argv,
    });
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.CcFailed;
    }

    return std.process.run(allocator, io, .{ .argv = &.{bin_path} });
}

fn expectGolden(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    if (run_result.stderr.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{run_result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings(expected, run_result.stdout);
}

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

/// v1.80.6 (bkz. `tests/cli/search_test.zig`nin AYNI adlı yardımcısının
/// belge notu — BİREBİR AYNI gerekçe/savunma-derinliği ilkesi, BU dosyaya
/// AYRI bir kopya olarak uygulanır).
fn acceptWithTimeout(listen_fd: sys.fd_t, timeout_ms: i32) sys.fd_t {
    var pfd = [1]sys.pollfd{.{ .fd = listen_fd, .events = sys.POLL.IN, .revents = 0 }};
    const n = sys.poll(&pfd, 1, timeout_ms);
    if (n <= 0) return sys.bad_fd;
    return sys.accept(listen_fd, null, null);
}

fn testServeOnce(listen_fd: sys.fd_t) void {
    const conn = acceptWithTimeout(listen_fd, 120_000);
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

    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Nox-Test: merhaba\r\nConnection: close\r\n\r\nhello";
    var written: usize = 0;
    while (written < response.len) {
        const n = sys.write(conn, response[written..].ptr, response.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
}

/// Bir bağlantı kabul eder, isteği okur, VERİLEN `headers`i (bitmiş HTTP
/// başlık bloğu, `\r\n\r\n` DAHİL) VE `body`yi OLDUĞU GİBİ (ham baytlar,
/// `Content-Length` ÇAĞIRANDAN gelir) yazar — `testServeOnce`nin AYNI
/// bağlantı-kabul/istek-okuma iskeleti, ama yanıtın HANGİ başlıkları/
/// gövdeyi taşıyacağı ÇAĞIRAN tarafından (gzip fixture'ı VEYA gömülü-NUL
/// fixture'ı İÇİN) BELİRLENİR.
fn testServeOnceRaw(listen_fd: sys.fd_t, headers: []const u8, body: []const u8) void {
    const conn = acceptWithTimeout(listen_fd, 120_000);
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

    var written: usize = 0;
    while (written < headers.len) {
        const n = sys.write(conn, headers[written..].ptr, headers.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    written = 0;
    while (written < body.len) {
        const n = sys.write(conn, body[written..].ptr, body.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

test "nox.http.get: gercek bir yerel sunucuya karsi uctan uca (import + extern def + with_rt + dict[str,str] donus)" {
    const allocator = std.testing.allocator;

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);

    const server_thread = try std.Thread.spawn(.{}, testServeOnce, .{listen_fd});
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\headers: dict[str, str] = {{"X-Req": "1"}}
        \\resp: nox_http_HttpResponse = nox.http.get("http://127.0.0.1:{d}/hello", headers)
        \\print(resp.status)
        \\print(resp.body)
        \\print(resp.headers["X-Nox-Test"])
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "200\nhello\nmerhaba\n");
}

test "nox.http.get: baglanti hatasi HttpError'i raise eder, try/except yakalar" {
    const allocator = std.testing.allocator;

    // Hicbir dinleyici olmayan bir port (dinlemeden hemen kapatilir, bu
    // yuzden connect() ECONNREFUSED ile basarisiz olur).
    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    _ = sys.close(listen_fd);

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\req_headers: dict[str, str] = {{"a": "a"}}
        \\try:
        \\    resp: nox_http_HttpResponse = nox.http.get("http://127.0.0.1:{d}/hello", req_headers)
        \\    print(resp.status)
        \\except nox_http_HttpError as e:
        \\    print("hata yakalandi")
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "hata yakalandi\n");
}

// Düzeltme 1 (bkz. plan dosyası): `nox.http.get`, `Content-Encoding: gzip`
// bir yanıtı DOĞRU çözebilmeli — ÖNCEDEN `workerThreadFn` HAM (sıkıştırılmış)
// baytları döndürüyordu (`Response.reader` yerine `Response.
// readerDecompressing` gerekiyordu, bkz. Zig std `Client.fetch`in KENDİ
// deseni). Gerçek bir gzip akışı üretmek İÇİN sistemin `gzip` aracı
// kullanılır (bu dosyanın ZATEN `qbe`/`cc`yi `std.process.run` İLE
// çağırdığı desenle AYNI — CI'nin her iki runner'ında da (`ubuntu`/`macos`)
// standart olarak mevcuttur).
test "nox.http.get: gzip Content-Encoding dogru cozulur (Duzeltme 1 — onceden HAM/bozuk bayt donuyordu)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const plaintext = "merhaba sikistirilmis dunya";
    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = plaintext });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const plain_path = try std.fmt.allocPrint(allocator, "{s}/plain.txt", .{dir_path});
    defer allocator.free(plain_path);

    const gzip_result = try std.process.run(allocator, io, .{
        .argv = &.{ "gzip", "-kf", plain_path },
    });
    if (gzip_result.term != .exited or gzip_result.term.exited != 0) {
        std.debug.print("gzip basarisiz: {s}\n", .{gzip_result.stderr});
        return error.GzipFailed;
    }

    const gzip_body = try tmp.dir.readFileAlloc(io, "plain.txt.gz", allocator, .limited(4096));
    defer allocator.free(gzip_body);

    const response_headers = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n",
        .{gzip_body.len},
    );
    defer allocator.free(response_headers);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);

    const server_thread = try std.Thread.spawn(.{}, testServeOnceRaw, .{ listen_fd, response_headers, gzip_body });
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\headers: dict[str, str] = {{"X-Req": "1"}}
        \\resp: nox_http_HttpResponse = nox.http.get("http://127.0.0.1:{d}/hello", headers)
        \\print(resp.status)
        \\print(resp.body)
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "200\nmerhaba sikistirilmis dunya\n");
}

// v2.0.69 regresyonu: gzip + `Transfer-Encoding: chunked` (Cloudflare/Google gerçek dünya biçimi). Sıkıştırma çözücü kendi akışının sonunda durur, taşıma
// katmanının son `0\r\n\r\n` parçası okunmamış kalırdı; kesik-gövde denetimi bunu yanlışlıkla HttpError sayıyordu.
test "nox.http.get: gzip + chunked yanit kesik govde sayilmaz (son 0-chunk okunur)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "plain.txt", .data = "chunked sikistirilmis dunya" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const plain_path = try std.fmt.allocPrint(allocator, "{s}/plain.txt", .{path_buf[0..dir_len]});
    defer allocator.free(plain_path);
    const gzip_result = try std.process.run(allocator, io, .{ .argv = &.{ "gzip", "-kf", plain_path } });
    if (gzip_result.term != .exited or gzip_result.term.exited != 0) return error.GzipFailed;
    const gzip_body = try tmp.dir.readFileAlloc(io, "plain.txt.gz", allocator, .limited(4096));
    defer allocator.free(gzip_body);

    // Tek chunk + sonlandırıcı chunk; gövde iki yazıda gelir (çözücü son chunk'tan önce biter).
    const chunked_body = try std.fmt.allocPrint(allocator, "{x}\r\n{s}\r\n0\r\n\r\n", .{ gzip_body.len, gzip_body });
    defer allocator.free(chunked_body);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);
    const headers = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Encoding: gzip\r\nConnection: close\r\n\r\n";
    const server_thread = try std.Thread.spawn(.{}, testServePartial, .{ listen_fd, headers, chunked_body, false });
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\resp: nox_http_HttpResponse = nox.http.get("http://127.0.0.1:{d}/c", {{}})
        \\print(resp.status)
        \\print(resp.body)
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "200\nchunked sikistirilmis dunya\n");
}

// Düzeltme 2 (eski): gövdede HAM bir `\0` bulunan yanıt `strlen()` tabanlı `str` yüzünden reddediliyordu. `str` artık
// uzunluğu başlıkta taşıdığından (v1.18.0 ABI) gövde reddedilmez ve bayt-doğru döner (v2.0.31).
test "nox.http.get: govdede gomulu NUL bayti varsa gövde reddedilmez, bayt-dogru doner (v2.0.31; str uzunlugu basliktadir)" {
    const allocator = std.testing.allocator;

    const body_with_nul = "onc" ++ [_]u8{0} ++ "esi";
    const response_headers = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body_with_nul.len},
    );
    defer allocator.free(response_headers);

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);

    const server_thread = try std.Thread.spawn(.{}, testServeOnceRaw, .{ listen_fd, response_headers, body_with_nul });
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\headers: dict[str, str] = {{"X-Req": "1"}}
        \\try:
        \\    resp: nox_http_HttpResponse = nox.http.get("http://127.0.0.1:{d}/hello", headers)
        \\    print(resp.status)
        \\    print(len(resp.body))
        \\except nox_http_HttpError as e:
        \\    print("hata yakalandi")
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "200\n7\n");
}

// ---- Akışlı istemci (v2.0.69, Nova N.4) -----------------------------------------------------------------------------------

/// Bir bağlantı kabul eder, istek başlığını okur, `headers` + `body`yi yazar, sonra `hold`sa istemci kapatana kadar bekler
/// (zaman aşımı testleri için: sunucu cevabı yarıda keser ve susar), değilse bağlantıyı hemen kapatır.
fn testServePartial(listen_fd: sys.fd_t, headers: []const u8, body: []const u8, hold: bool) void {
    const conn = acceptWithTimeout(listen_fd, 120_000);
    if (sys.badFd(conn)) return;
    defer _ = sys.close(conn);
    var req_buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < req_buf.len) {
        const n = sys.read(conn, req_buf[total..].ptr, req_buf.len - total);
        if (n <= 0) return;
        total += @intCast(n);
        if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n") != null) break;
    }
    for ([_][]const u8{ headers, body }) |part| {
        var written: usize = 0;
        while (written < part.len) {
            const n = sys.write(conn, part[written..].ptr, part.len - written);
            if (n <= 0) return;
            written += @intCast(n);
        }
    }
    if (hold) {
        // İstemci bağlantıyı iptal edince `read` 0/hata döner.
        var sink: [64]u8 = undefined;
        while (true) {
            const n = sys.read(conn, &sink, sink.len);
            if (n <= 0) break;
        }
    }
}

/// İstek gövdesini (Content-Length ya da chunked) tamamen okur ve "`len=<bayt> sum=<toplam>`" cevabını döner.
fn testServeUploadEcho(listen_fd: sys.fd_t) void {
    const conn = acceptWithTimeout(listen_fd, 120_000);
    if (sys.badFd(conn)) return;
    defer _ = sys.close(conn);

    var buf: [1 << 16]u8 = undefined;
    var have: usize = 0;
    var head_end: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, buf[0..have], "\r\n\r\n")) |i| {
            head_end = i + 4;
            break;
        }
        if (have == buf.len) return;
        const n = sys.read(conn, buf[have..].ptr, buf.len - have);
        if (n <= 0) return;
        have += @intCast(n);
    }
    const head = buf[0..head_end];
    const chunked = std.ascii.indexOfIgnoreCase(head, "transfer-encoding: chunked") != null;
    var content_length: usize = 0;
    if (std.ascii.indexOfIgnoreCase(head, "content-length: ")) |i| {
        const rest = head[i + "content-length: ".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '\r') orelse rest.len;
        content_length = std.fmt.parseInt(usize, rest[0..end], 10) catch 0;
    }

    var len: usize = 0;
    var sum: u64 = 0;
    // Gövdenin kalanını ham akış olarak tüket; chunked ise `terminator` görülene kadar, değilse content_length kadar.
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(std.heap.page_allocator);
    pending.appendSlice(std.heap.page_allocator, buf[head_end..have]) catch return;
    while (true) {
        if (chunked) {
            // Chunk-ayrıştırma: <hex>\r\n<veri>\r\n ... 0\r\n\r\n
            var done = false;
            while (true) {
                const line_end = std.mem.indexOf(u8, pending.items, "\r\n") orelse break;
                const size = std.fmt.parseInt(usize, pending.items[0..line_end], 16) catch return;
                if (size == 0) {
                    done = true;
                    break;
                }
                if (pending.items.len < line_end + 2 + size + 2) break;
                for (pending.items[line_end + 2 .. line_end + 2 + size]) |b| sum +%= b;
                len += size;
                pending.replaceRange(std.heap.page_allocator, 0, line_end + 2 + size + 2, &.{}) catch return;
            }
            if (done) break;
        } else {
            for (pending.items) |b| sum +%= b;
            len += pending.items.len;
            pending.clearRetainingCapacity();
            if (len >= content_length) break;
        }
        var tmp: [8192]u8 = undefined;
        const n = sys.read(conn, &tmp, tmp.len);
        if (n <= 0) return;
        pending.appendSlice(std.heap.page_allocator, tmp[0..@intCast(n)]) catch return;
    }

    var body_buf: [64]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "len={d} sum={d}", .{ len, sum }) catch return;
    var resp_buf: [160]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 201 Created\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
    var written: usize = 0;
    while (written < resp.len) {
        const n = sys.write(conn, resp[written..].ptr, resp.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

test "nox.http.stream: chunked gövde parça parça okunur (ikili veri + gömülü NUL, başlıklar, gövde sonu, çift close)" {
    const allocator = std.testing.allocator;

    // 3 chunk: "abc", "\0\x01\xff" (ham bayt), "defgh".
    const body = "3\r\nabc\r\n3\r\n\x00\x01\xff\r\n5\r\ndefgh\r\n0\r\n\r\n";
    const headers = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Nox-Test: akis\r\nConnection: close\r\n\r\n";

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);
    const server_thread = try std.Thread.spawn(.{}, testServePartial, .{ listen_fd, headers, body, false });
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\import nox.strings
        \\
        \\s: nox_http_HttpStream = nox.http.stream("GET", "http://127.0.0.1:{d}/x", {{}})
        \\print(s.status)
        \\print(s.headers["X-Nox-Test"])
        \\total: int = 0
        \\sum: int = 0
        \\while True:
        \\    c: str = s.read_chunk(4)
        \\    n: int = nox.strings.byte_len(c)
        \\    if n == 0:
        \\        break
        \\    i: int = 0
        \\    while i < n:
        \\        sum = sum + nox.strings.byte_at(c, i)
        \\        i = i + 1
        \\    total = total + n
        \\print(total)
        \\print(sum)
        \\s.close()
        \\s.close()
        \\try:
        \\    s.read_chunk(1)
        \\except nox_http_HttpError:
        \\    print("kapali")
        \\
    , .{port});
    defer allocator.free(source);

    // a+b+c = 294, 0+1+255 = 256, d+e+f+g+h = 100+101+102+103+104 = 510
    try expectGolden(source, "200\nakis\n11\n1060\nkapali\n");
}

test "nox.http.stream: Content-Length tamamlanmadan kapanan bağlantı HttpError verir (kesik gövde sessiz başarı sayılmaz)" {
    const allocator = std.testing.allocator;

    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n";
    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);
    const server_thread = try std.Thread.spawn(.{}, testServePartial, .{ listen_fd, headers, "0123456789", false });
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\s: nox_http_HttpStream = nox.http.stream("GET", "http://127.0.0.1:{d}/x", {{}})
        \\print(s.read_chunk(100))
        \\try:
        \\    s.read_chunk(100)
        \\    print("sessiz basari")
        \\except nox_http_HttpError:
        \\    print("kesik")
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "0123456789\nkesik\n");
}

test "nox.http.stream: boşta zaman aşımı HttpTimeoutError verir (toplam süre değil, işlem başına)" {
    const allocator = std.testing.allocator;

    const headers = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n";
    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);
    const server_thread = try std.Thread.spawn(.{}, testServePartial, .{ listen_fd, headers, "xxxxxxxxxx", true });
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\s: nox_http_HttpStream = nox.http.stream("GET", "http://127.0.0.1:{d}/x", {{}}, "", 300)
        \\print(s.read_chunk(100))
        \\try:
        \\    s.read_chunk(100)
        \\except nox_http_HttpTimeoutError:
        \\    print("zaman asimi")
        \\try:
        \\    s.read_chunk(100)
        \\except nox_http_HttpError:
        \\    print("kapali")
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "xxxxxxxxxx\nzaman asimi\nkapali\n");
}

test "nox.http.stream_upload: sabit Content-Length ve chunked yükleme, eksik/fazla yazma hatası" {
    const allocator = std.testing.allocator;

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);
    const t1 = try std.Thread.spawn(.{}, testServeUploadEcho, .{listen_fd});
    defer t1.join();

    var port2: u16 = 0;
    const listen_fd2 = try testListenerOn127001(&port2);
    defer _ = sys.close(listen_fd2);
    const t2 = try std.Thread.spawn(.{}, testServeUploadEcho, .{listen_fd2});
    defer t2.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\a: nox_http_HttpStream = nox.http.stream_upload("PUT", "http://127.0.0.1:{d}/up", {{}}, 11)
        \\print(a.status)
        \\a.write("hello ")
        \\a.write("world")
        \\a.finish()
        \\print(a.status)
        \\print(a.read_chunk(100))
        \\a.close()
        \\
        \\b: nox_http_HttpStream = nox.http.stream_upload("POST", "http://127.0.0.1:{d}/up", {{}})
        \\b.write("abc\x00def")
        \\b.write("ghi")
        \\b.finish()
        \\print(b.read_chunk(100))
        \\b.close()
        \\
        \\try:
        \\    z: nox_http_HttpStream = nox.http.stream_upload("POST", "http://127.0.0.1:1/never", {{}}, 3)
        \\    z.write("toolong")
        \\except nox_http_HttpError:
        \\    print("baglanti hatasi")
        \\
    , .{ port, port2 });
    defer allocator.free(source);

    // "hello world" bayt toplamı = 1116; "abc\0defghi" = 97+98+99+0+100+101+102+103+104+105 = 909
    try expectGolden(source, "0\n201\nlen=11 sum=1116\nlen=10 sum=909\nbaglanti hatasi\n");
}

test "nox.transfer.download_to_file / upload_file: dosya akışla iner ve yüklenir, başarısızlıkta hedefe dokunulmaz" {
    const allocator = std.testing.allocator;

    // 3 chunk'lık ikili gövde: 70000 bayt (64 KiB döngü sınırını aşar).
    var body_list: std.ArrayList(u8) = .empty;
    defer body_list.deinit(allocator);
    var raw: [70000]u8 = undefined;
    for (&raw, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 256);
    try body_list.print(allocator, "{x}\r\n", .{raw.len});
    try body_list.appendSlice(allocator, &raw);
    try body_list.appendSlice(allocator, "\r\n0\r\n\r\n");
    const headers = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
    var expected_sum: u64 = 0;
    for (raw) |b| expected_sum += b;

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = sys.close(listen_fd);
    const t1 = try std.Thread.spawn(.{}, testServePartial, .{ listen_fd, headers, body_list.items, false });
    defer t1.join();

    var port2: u16 = 0;
    const listen_fd2 = try testListenerOn127001(&port2);
    defer _ = sys.close(listen_fd2);
    const nf_headers = "HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\nConnection: close\r\n\r\n";
    const t2 = try std.Thread.spawn(.{}, testServePartial, .{ listen_fd2, nf_headers, "nop", false });
    defer t2.join();

    var port3: u16 = 0;
    const listen_fd3 = try testListenerOn127001(&port3);
    defer _ = sys.close(listen_fd3);
    const t3 = try std.Thread.spawn(.{}, testServeUploadEcho, .{listen_fd3});
    defer t3.join();

    // `/tmp` Windows'ta yok: gerçek bir geçici dizin kullanılır; yoldaki `\` Nox string literal'inde kaçış sayılmasın diye `\\` yapılır.
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &tmp_buf);
    const tmp_lit = try std.mem.replaceOwned(u8, allocator, tmp_buf[0..tmp_len], "\\", "\\\\");
    defer allocator.free(tmp_lit);

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.transfer
        \\import nox.fs
        \\import nox.strings
        \\
        \\dst: str = "{s}/nox_stream_dl_test.bin"
        \\print(nox.transfer.download_to_file("http://127.0.0.1:{d}/f", dst, {{}}))
        \\r: nox_fs_FileReader = nox.fs.open_read(dst)
        \\print(r.size())
        \\sum: int = 0
        \\while True:
        \\    c: str = r.read_chunk(8192)
        \\    n: int = nox.strings.byte_len(c)
        \\    if n == 0:
        \\        break
        \\    i: int = 0
        \\    while i < n:
        \\        sum = sum + nox.strings.byte_at(c, i)
        \\        i = i + 1
        \\r.close()
        \\print(sum)
        \\
        \\print(nox.transfer.download_to_file("http://127.0.0.1:{d}/f", dst + ".none", {{}}))
        \\print(nox.fs.exists(dst + ".none"))
        \\print(nox.fs.exists(dst + ".none.nox-part"))
        \\
        \\resp: nox_http_HttpResponse = nox.transfer.upload_file("POST", "http://127.0.0.1:{d}/up", dst, {{}})
        \\print(resp.status)
        \\print(resp.body)
        \\nox.fs.remove_file(dst)
        \\
    , .{ tmp_lit, port, port2, port3 });
    defer allocator.free(source);

    const expected = try std.fmt.allocPrint(allocator, "200\n70000\n{d}\n404\nFalse\nFalse\n201\nlen=70000 sum={d}\n", .{ expected_sum, expected_sum });
    defer allocator.free(expected);
    try expectGolden(source, expected);
}
