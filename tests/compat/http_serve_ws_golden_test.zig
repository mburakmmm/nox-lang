//! `nox.http.serve_ws(port, handle, ws_handle[, max_connections])` uçtan
//! uca golden testi — bkz. plan dosyası "Sunucu-tarafı TLS terminasyonu
//! (OpenSSL FFI) + WebSocket Upgrade — nox.http.serve". `http_serve_golden_
//! test.zig`nin AYNI derleme+arka-plan-süreç altyapısı, AMA istemci taraf
//! HAM bir RFC 6455 WebSocket istemcisidir (`runtime/stdlib_shims/
//! websocket.zig`nin İSTEMCİ mantığının BU dosyaya BAĞIMSIZ, minimal bir
//! kopyası — İKİNCİ bir Nox programı DERLEMEK YERİNE, `http_serve_golden_
//! test.zig`nin ham istemci deseniyle AYNI).

const std = @import("std");
const posix = std.posix;
const nox = @import("nox");

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

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

fn testConnect(port: u16) !posix.fd_t {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr: std.c.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) == 0) return fd;
        _ = std.c.close(fd);
        const ts: posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.ConnectFailed;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn readExact(fd: posix.fd_t, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fd, buf[off..].ptr, buf.len - off);
        if (n <= 0) return error.ReadFailed;
        off += @intCast(n);
    }
}

/// El sıkışma sonrası "\r\n\r\n"e kadar ham başlıkları OKUR (basit, TEK
/// baytlık bir sondaj döngüsü — testin küçük yanıtı İçİn yeterli).
fn readHttpHeaders(fd: posix.fd_t, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(fd, buf[total..].ptr, 1);
        if (n <= 0) return error.ReadFailed;
        total += 1;
        if (total >= 4 and std.mem.eql(u8, buf[total - 4 .. total], "\r\n\r\n")) {
            return buf[0..total];
        }
    }
    return error.HeadersTooLarge;
}

fn computeAcceptValue(key_b64: []const u8, out: *[28]u8) void {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(key_b64);
    sha1.update(websocket_guid);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// İstemci→sunucu frame'i — RFC 6455 gereği MASKELENMİŞ olmalı.
fn sendMaskedTextFrame(fd: posix.fd_t, payload: []const u8) !void {
    var header: [14]u8 = undefined;
    var hlen: usize = 0;
    header[0] = 0x81; // FIN=1, opcode=0x1 (text)
    hlen += 1;
    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
        hlen += 1;
    } else {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        hlen += 3;
    }
    var mask_key: [4]u8 = .{ 0x11, 0x22, 0x33, 0x44 };
    @memcpy(header[hlen .. hlen + 4], &mask_key);
    hlen += 4;
    try writeAll(fd, header[0..hlen]);

    const gpa = std.testing.allocator;
    const masked = try gpa.alloc(u8, payload.len);
    defer gpa.free(masked);
    for (payload, 0..) |b, i| masked[i] = b ^ mask_key[i % 4];
    try writeAll(fd, masked);
}

/// Sunucu→istemci frame'i — RFC 6455 gereği MASKELENMEMİŞ olmalı; bu test
/// yalnızca TEK, KÜÇÜK bir metin frame'i BEKLER (7-bit uzunluk alanı).
fn recvUnmaskedTextFrame(fd: posix.fd_t, out: []u8) !usize {
    var header: [2]u8 = undefined;
    try readExact(fd, &header);
    const masked = (header[1] & 0x80) != 0;
    if (masked) return error.UnexpectedMaskedServerFrame;
    const len: usize = header[1] & 0x7F;
    if (len > out.len) return error.PayloadTooLarge;
    try readExact(fd, out[0..len]);
    return len;
}

test "nox.http.serve_ws: uctan uca, RFC 6455 el sikismasi + maskeli metin frame yankisi" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\import nox.websocket
        \\from nox.websocket import WebSocketServerConn
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\def ws_handle(conn: WebSocketServerConn) -> None:
        \\    msg: str = conn.recv()
        \\    conn.send_text(msg)
        \\
        \\nox.http.serve_ws({d}, handle, ws_handle, 1)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    const fd = try testConnect(port);
    defer _ = std.c.close(fd);

    // Sabit (test-only) bir 16 baytlık anahtar — RFC gereği base64 ile
    // kodlanır (Sec-WebSocket-Key rastgele OLMASI GEREKMEZ, sunucu YALNIZCA
    // beklenen Accept değerini HESAPLAYIP DÖNDÜRÜR, kriptografik bir
    // ANLAMI yoktur).
    const raw_key = "0123456789ABCDEF";
    var key_b64_buf: [24]u8 = undefined;
    const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, raw_key);

    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{key_b64});
    try writeAll(fd, req);

    var headers_buf: [1024]u8 = undefined;
    const headers = try readHttpHeaders(fd, &headers_buf);

    try std.testing.expect(std.mem.indexOf(u8, headers, "101") != null);

    var expected_accept: [28]u8 = undefined;
    computeAcceptValue(key_b64, &expected_accept);
    try std.testing.expect(std.mem.indexOf(u8, headers, &expected_accept) != null);

    try sendMaskedTextFrame(fd, "merhaba-ws");
    var echo_buf: [64]u8 = undefined;
    const echo_len = try recvUnmaskedTextFrame(fd, &echo_buf);
    try std.testing.expectEqualStrings("merhaba-ws", echo_buf[0..echo_len]);

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
}

test "nox.http.serve_ws: maskesiz gelen bir istemci frame'i RFC 6455 geregi reddedilir (Close 1002)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\import nox.websocket
        \\from nox.websocket import WebSocketServerConn
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\def ws_handle(conn: WebSocketServerConn) -> None:
        \\    msg: str = conn.recv()
        \\
        \\nox.http.serve_ws({d}, handle, ws_handle, 1)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    const fd = try testConnect(port);
    defer _ = std.c.close(fd);

    const raw_key = "0123456789ABCDEF";
    var key_b64_buf: [24]u8 = undefined;
    const key_b64 = std.base64.standard.Encoder.encode(&key_b64_buf, raw_key);

    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{key_b64});
    try writeAll(fd, req);

    var headers_buf: [1024]u8 = undefined;
    _ = try readHttpHeaders(fd, &headers_buf);

    // BİLEREK maskesiz bir metin frame'i gönder (RFC 6455 İHLALİ) —
    // sunucu bunu REDDETMELİ: bir Close(1002) frame'i gönderip bağlantıyı
    // kapatmalı, ASLA payload'ı yankı olarak DÖNDÜRMEMELİ.
    var unmasked_frame: [12]u8 = undefined;
    unmasked_frame[0] = 0x81;
    unmasked_frame[1] = 10; // MASK=0
    @memcpy(unmasked_frame[2..12], "kural-ihlali"[0..10]);
    try writeAll(fd, &unmasked_frame);

    var resp: [16]u8 = undefined;
    const n = std.c.read(fd, &resp, resp.len);
    // Bağlantı ya HEMEN bir Close frame'i (opcode 0x8, İLK bayt 0x88) İLE
    // ya da doğrudan soket kapanışıyla (n <= 0) sonuçlanmalı — HER İKİSİ de
    // "reddedildi" kanıtıdır; yankılanan bir metin frame'i (0x81) ASLA
    // gelmemelidir.
    if (n > 0) {
        try std.testing.expect(resp[0] != 0x81);
    }

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
}
