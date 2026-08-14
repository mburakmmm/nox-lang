//! `nox.http.serve_tls(port, handle, cert_path, key_path[, max_connections])`
//! uçtan uca golden testi — bkz. plan dosyası "Sunucu-tarafı TLS
//! terminasyonu (OpenSSL FFI) + WebSocket Upgrade — nox.http.serve".
//! `http_serve_golden_test.zig`nin AYNI derleme+arka-plan-süreç altyapısı,
//! AMA istemci taraf ham bir TCP soketi DEĞİL, Zig'in KENDİ `std.crypto.
//! tls.Client`ı — GERÇEK, BAĞIMSIZ bir TLS yığınıyla interop KANITI.
//! `tests/fixtures/tls/test_cert.pem` (sabit, `openssl req -x509 -newkey
//! rsa:2048 ... -days 36500 -nodes -subj "/CN=localhost"` İLE ELLE
//! üretilmiş, test-only self-signed) TEK-girdili bir `Certificate.Bundle`
//! olarak GÜVENİLİR KÖK yapılır (self-signed olduğu İçİn KENDİSİ hem cert
//! hem CA'dır).

const std = @import("std");
const posix = std.posix;
const nox = @import("nox");

const cert_path = "tests/fixtures/tls/test_cert.pem";
const key_path = "tests/fixtures/tls/test_key.pem";

fn compileToBinary(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, source: []const u8) ![]const u8 {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
    checker_state.checkModule(module) catch |e| {
        std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        return error.FixtureNotWellTyped;
    };
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ d.code, d.message });
        }
        return error.FixtureNotWellTyped;
    }

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(allocator, k.*);

    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try allocator.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(allocator, entry.key_ptr.*, names);
    }
    var functions_used_as_value: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = checker_state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try functions_used_as_value.append(allocator, k.*);

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, functions_used_as_value.items, checker_state.module_aliases, checker_state.decorated_functions.items, .qbe);

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

    return bin_path;
}

/// `http_serve_golden_test.zig`nin AYNI `probeFreePort`ı — kasıtlı tekrar.
fn probeFreePort() !u16 {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = std.c.close(fd);
    var reuse: c_int = 1;
    _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;

    var got: std.c.sockaddr.in = undefined;
    var got_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
    if (std.c.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, got.port);
}

/// GERÇEK bir `std.crypto.tls.Client` İLE 127.0.0.1'e bağlanıp bir
/// `GET /hello` yollar, düz-metin (çözülmüş) yanıtı `out`a okur — sunucunun
/// (arka planda çalışan Nox ikilisinin) `nox_http_server_listen_tls`in
/// başlatması BELİRLİ bir süre alabileceğinden (bkz. `http_serve_golden_
/// test.zig`nin `testConnect`inin AYNI gerekçesi) bağlantı BAŞARILI olana
/// kadar YENİDEN dener.
fn tlsRequestAndRead(io: std.Io, port: u16, out: []u8) !usize {
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(std.heap.page_allocator);
    const now = std.Io.Timestamp.now(io, .real);
    try bundle.addCertsFromFilePath(std.heap.page_allocator, io, now, std.Io.Dir.cwd(), cert_path);

    var attempt: usize = 0;
    var addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    while (true) : (attempt += 1) {
        const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
            if (attempt >= 200) return err;
            const ts: posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            continue;
        };
        defer stream.close(io);

        var sock_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var sock_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var stream_reader = stream.reader(io, &sock_read_buf);
        var stream_writer = stream.writer(io, &sock_write_buf);

        var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buffer);

        var lock: std.Io.RwLock = .init;
        var client = try std.crypto.tls.Client.init(&stream_reader.interface, &stream_writer.interface, .{
            .host = .{ .explicit = "localhost" },
            .ca = .{ .bundle = .{
                .gpa = std.heap.page_allocator,
                .io = io,
                .lock = &lock,
                .bundle = &bundle,
            } },
            .ssl_key_log = null,
            .read_buffer = &tls_read_buf,
            .write_buffer = &tls_write_buf,
            .entropy = &random_buffer,
            .realtime_now = now,
            .allow_truncation_attacks = false,
        });

        // `client.writer.flush()` TEK BAŞINA YETERSİZDİR (bkz. `tls.zig`nin
        // AYNI belge notu) — bu SADECE TLS KATMANININ tamponunu boşaltır,
        // ALTTAKİ `stream_writer`in KENDİ tamponunu (`sock_write_buf`)
        // GERÇEK soketE YAZMAZ.
        const req = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        try client.writer.writeAll(req);
        try client.writer.flush();
        try stream_writer.interface.flush();

        var total: usize = 0;
        while (total < out.len) {
            const n = client.reader.readSliceShort(out[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        return total;
    }
}

/// `tlsRequestAndRead`nin İKİ-parçalı sürümü — isteği `part1`/`part2`ye
/// böler, ARADA `delay_ms` bekler (`http_serve_golden_test.zig`nin AYNI
/// gerekçeli "yavaş istemci" desenidir — bkz. onun "iki eşzamanlı bağlantı"
/// testi — AMA burada TLS katmanı ÜZERİNDEN, `tls_server.zig`nin `drive()`
/// döngüsünün `fillRbioOnce` yield noktasında ASKIYA ALINMASINI ZORLAMAK
/// İçİn). `part2` boşsa (`""`) tek-parçalı bir istek gibi davranır (`delay_ms`
/// = 0 İLE birlikte kullanılır).
fn tlsRequestSplitAndRead(io: std.Io, port: u16, part1: []const u8, part2: []const u8, delay_ms: u32, out: []u8) !usize {
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(std.heap.page_allocator);
    const now = std.Io.Timestamp.now(io, .real);
    try bundle.addCertsFromFilePath(std.heap.page_allocator, io, now, std.Io.Dir.cwd(), cert_path);

    var attempt: usize = 0;
    var addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    while (true) : (attempt += 1) {
        const stream = addr.connect(io, .{ .mode = .stream }) catch |err| {
            if (attempt >= 200) return err;
            const ts: posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            continue;
        };
        defer stream.close(io);

        var sock_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var sock_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var stream_reader = stream.reader(io, &sock_read_buf);
        var stream_writer = stream.writer(io, &sock_write_buf);

        var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buffer);

        var lock: std.Io.RwLock = .init;
        var client = try std.crypto.tls.Client.init(&stream_reader.interface, &stream_writer.interface, .{
            .host = .{ .explicit = "localhost" },
            .ca = .{ .bundle = .{
                .gpa = std.heap.page_allocator,
                .io = io,
                .lock = &lock,
                .bundle = &bundle,
            } },
            .ssl_key_log = null,
            .read_buffer = &tls_read_buf,
            .write_buffer = &tls_write_buf,
            .entropy = &random_buffer,
            .realtime_now = now,
            .allow_truncation_attacks = false,
        });

        try client.writer.writeAll(part1);
        try client.writer.flush();
        try stream_writer.interface.flush();

        if (delay_ms != 0) {
            const ts: posix.timespec = .{ .sec = 0, .nsec = @as(isize, delay_ms) * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }

        if (part2.len != 0) {
            try client.writer.writeAll(part2);
            try client.writer.flush();
            try stream_writer.interface.flush();
        }

        var total: usize = 0;
        while (total < out.len) {
            const n = client.reader.readSliceShort(out[total..]) catch break;
            if (n == 0) break;
            total += n;
        }
        return total;
    }
}

test "nox.http.serve_tls: uctan uca, GERCEK bir std.crypto.tls.Client ile el sikisma + istek/yanit" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // NOT: derlenen Nox ikilisi `std.process.spawn` İLE ÇAĞIRANIN (bu test
    // sürecinin) AYNI CWD'sinde çalıştırılır — bu YÜZDEN relative `cert_
    // path`/`key_path` sabitleri DOĞRUDAN kaynağa gömülebilir, MUTLAK bir
    // yola ÇEVİRMEYE gerek YOKTUR.
    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok-tls", {{"x": "x"}})
        \\
        \\nox.http.serve_tls({d}, handle, "{s}", "{s}", 1)
        \\
    , .{ port, cert_path, key_path });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var resp_buf: [1024]u8 = undefined;
    const resp_len = try tlsRequestAndRead(io, port, &resp_buf);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    const resp = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ok-tls") != null);
}

// **Regresyon testi — `tls_server.zig`nin eski `threadlocal var tl_read_
// target`/`tl_write_source` tasarımının GERÇEK arabellek-karışması hatası.**
// Sunucu TEK worker'lı (M:1 fiber modeli, TÜM bağlantılar AYNI OS iş
// parçacığında kooperatif olarak zamanlanır). "yavaş" istemci TLS el
// sıkışmasını TAMAMLAR, isteğinin başlıklarını İKİ parçaya böler (aradaki
// `\r\n\r\n` bitiş satırını 150ms GECİKTİRİR) — bu, sunucunun bu bağlantı
// İÇİN `tlsRead`nin `drive()` döngüsü İÇİNDE (`fillRbioOnce` →
// `suspendForIoOrTimeout` yield noktasında) ASKIYA ALINMASINI ZORLAR. Bu
// ASKI SÜRESİNCE "hızlı" istemci TAMAMEN AYRI bir bağlantı üzerinden TAM
// bir el sıkışma + istek/yanıt döngüsünü BAŞTAN SONA tamamlar. ESKİ
// (threadlocal) tasarımda bu, "yavaş" bağlantının askıdan DÖNÜŞÜNDE
// `drive()`nin BİR SONRAKİ `op(conn.ssl)` çağrısının ARTIK "hızlı"nın
// (ÇOKTAN TAMAMLANMIŞ, potansiyel olarak serbest bırakılmış) arabelleğine
// İŞARET EDEN `tl_read_target`ı KULLANMASINA — yani "yavaş"ın yanıtının
// BOZULMASINA/karışmasına YA DA `stderr`e bir UAF/sızıntı belirtisi
// yazılmasına — yol açardı. Düzeltmeyle (`TlsConn.read_target`/`write_
// source`, threadlocal DEĞİL, bağlantı-yerel) HER bağlantı YALNIZCA
// KENDİ arabelleğini kullanır — bu test BUNU, HER istemcinin YALNIZCA
// KENDİ yanıtını (DİĞERİNİNKİNİ DEĞİL) aldığını doğrudan kontrol ederek
// kanıtlar.
test "nox.http.serve_tls: AYNI OS is parcaciginda ic ice gecen IKI TLS baglantisi BIRBIRINE KARISMAZ (threadlocal arabellek yarisi duzeltmesi)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "resp:" + req.target, {{"x": "x"}})
        \\
        \\nox.http.serve_tls({d}, handle, "{s}", "{s}", 2)
        \\
    , .{ port, cert_path, key_path });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var slow_buf: [1024]u8 = undefined;
    var slow_len: usize = 0;
    var fast_buf: [1024]u8 = undefined;
    var fast_len: usize = 0;

    const slow_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            out_len.* = tlsRequestSplitAndRead(std.testing.io, p, "GET /slow HTTP/1.1\r\nHost: localhost\r\n", "Connection: close\r\n\r\n", 150, out) catch 0;
        }
    }.run, .{ port, &slow_buf, &slow_len });

    const fast_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            // "yavaş"ın bağlanıp İLK parçasını GÖNDERMESİ İçİn kısa bir
            // baş payı — çakışma penceresinin GERÇEKTEN "yavaş" askıdayken
            // açılmasını sağlar.
            const ts: posix.timespec = .{ .sec = 0, .nsec = 30 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            out_len.* = tlsRequestSplitAndRead(std.testing.io, p, "GET /fast HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", "", 0, out) catch 0;
        }
    }.run, .{ port, &fast_buf, &fast_len });

    slow_thread.join();
    fast_thread.join();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    const slow_resp = slow_buf[0..slow_len];
    const fast_resp = fast_buf[0..fast_len];
    try std.testing.expect(std.mem.indexOf(u8, slow_resp, "resp:/slow") != null);
    try std.testing.expect(std.mem.indexOf(u8, fast_resp, "resp:/fast") != null);
    // Çapraz-bulaşma OLMADIĞININ ek kanıtı: hiçbiri DİĞERİNİN yanıtını
    // TAŞIMIYOR.
    try std.testing.expect(std.mem.indexOf(u8, slow_resp, "resp:/fast") == null);
    try std.testing.expect(std.mem.indexOf(u8, fast_resp, "resp:/slow") == null);
}
