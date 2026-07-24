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
const posix = std.posix;
const nox = @import("nox");

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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, .empty, .empty, .empty, &.{});

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
        .argv = &.{ "qbe", "-t", nox.qbe_target.name(), "-o", asm_path, ssa_path },
    });
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz: {s}\n", .{qbe_result.stderr});
        return error.QbeFailed;
    }

    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{ "cc", "-rdynamic", "-o", bin_path, asm_path, "zig-out/lib/noxrt.o", "-lm" },
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

fn testServeOnce(listen_fd: posix.fd_t) void {
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

    const response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Nox-Test: merhaba\r\nConnection: close\r\n\r\nhello";
    var written: usize = 0;
    while (written < response.len) {
        const n = std.c.write(conn, response[written..].ptr, response.len - written);
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
fn testServeOnceRaw(listen_fd: posix.fd_t, headers: []const u8, body: []const u8) void {
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

    var written: usize = 0;
    while (written < headers.len) {
        const n = std.c.write(conn, headers[written..].ptr, headers.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
    written = 0;
    while (written < body.len) {
        const n = std.c.write(conn, body[written..].ptr, body.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

test "nox.http.get: gercek bir yerel sunucuya karsi uctan uca (import + extern def + with_rt + dict[str,str] donus)" {
    const allocator = std.testing.allocator;

    var port: u16 = 0;
    const listen_fd = try testListenerOn127001(&port);
    defer _ = std.c.close(listen_fd);

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
    _ = std.c.close(listen_fd);

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
    defer _ = std.c.close(listen_fd);

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

// Düzeltme 2 (bkz. plan dosyası): `identity` kodlamalı ama gövdesinde HAM
// bir `\0` baytı bulunan bir yanıt, sessizce bir Nox `str`ine kopyalanıp
// (`str`, `strlen()` tabanlı boyut hesabı YÜZÜNDEN gömülü NUL'a GÜVENSİZ,
// bkz. `str.zig`nin modül belge notu) `Invalid free` çökmesine yol AÇMAK
// yerine TEMİZ bir `HttpError` olarak reddedilmeli.
test "nox.http.get: govdede gomulu NUL bayti varsa temiz HttpError (Duzeltme 2 — sessiz heap bozulmasi degil)" {
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
    defer _ = std.c.close(listen_fd);

    const server_thread = try std.Thread.spawn(.{}, testServeOnceRaw, .{ listen_fd, response_headers, body_with_nul });
    defer server_thread.join();

    const source = try std.fmt.allocPrint(allocator,
        \\import nox.http
        \\
        \\headers: dict[str, str] = {{"X-Req": "1"}}
        \\try:
        \\    resp: nox_http_HttpResponse = nox.http.get("http://127.0.0.1:{d}/hello", headers)
        \\    print(resp.status)
        \\except nox_http_HttpError as e:
        \\    print("hata yakalandi")
        \\
    , .{port});
    defer allocator.free(source);

    try expectGolden(source, "hata yakalandi\n");
}
