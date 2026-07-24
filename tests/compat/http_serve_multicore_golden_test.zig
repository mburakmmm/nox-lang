//! Çok-çekirdekli `nox.http.serve` (Faz DD.1, bkz. nox-teknik-
//! spesifikasyon.md §3.60) uçtan uca golden testleri — `http_serve_
//! golden_test.zig`nin AYNI `compileToBinary`/`probeFreePort`/`testConnect`
//! deseninin KASITLI TEKRARI (bkz. o dosyanın `probeFreePort`ının belge
//! notu, "AYRI bir test dosyası" gerekçesi).
//!
//! **Neden yavaş/hızlı-sıra ispatı DEĞİL, "her ikisi de GERÇEKTEN sunulur"
//! ispatı:** `http_serve_golden_test.zig`nin TEK-iş-parçacıklı testi, TEK
//! bir OS iş parçacığında (M:1 fiber modeli) bloklayan bir `accept`/`read`
//! YAPILMADIĞINI (fiber-seviyesi eşzamanlılık) stdout SIRASIYLA kanıtlar.
//! BURADA farklı bir özellik test ediliyor — GERÇEK OS-düzeyi paralellik
//! (İKİ BAĞIMSIZ iş parçacığı) — ve `handle` İÇİNDEKİ `print` çağrılarının
//! FARKLI OS iş parçacıklarından GELDİĞİNDE stdout'a YAZILMA SIRASI/
//! ATOMİKLİĞİ garantisi bu testin KAPSAMI DIŞINDADIR (ayrı bir soru). Bunun
//! yerine, `num_threads=2` VE İş-parçacığı-başına `max_connections=1` İLE:
//! İKİ EŞZAMANLI istemci bağlantısının İKİSİNİN DE gerçek bir "200 OK"
//! yanıtı ALDIĞI doğrulanır — bu, YALNIZCA paylaşılan `fd`yi SARAN İKİNCİ
//! (arka planda `nox.thread` İLE başlatılan) bağımsız iş parçacığının
//! KENDİ `accept()`inin GERÇEKTEN çalıştığı durumda MÜMKÜNDÜR (ana iş
//! parçacığının KENDİ döngüsü ZATEN 1 bağlantıyla SINIRLI, ikinci bir
//! bağlantıyı ASLA kabul edemez) — mekanizma BOZUKSA test bir YANIT
//! ALINAMADAN (bağlantı sonsuza dek asılı kalır) BAŞARISIZ olur, sessizce
//! yanlış-pozitif VERMEZ.

const std = @import("std");
const posix = std.posix;
const nox = @import("nox");

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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, .empty, .empty, .empty);

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

fn testSendGet(fd: posix.fd_t, path: []const u8) void {
    var buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path}) catch unreachable;
    var off: usize = 0;
    while (off < req.len) {
        const n = std.c.write(fd, req[off..].ptr, req.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

/// `testReadAll`den FARKLI: yanıtı ATAR değil, İLK baytların "HTTP/1.1 200"
/// İLE BAŞLADIĞINI (GERÇEK bir 200 yanıtı ALINDIĞINI) doğrular — bu testin
/// ÇEKİRDEK iddiası TAM OLARAK BUDUR (bkz. modül üstü not).
fn testSendGetAndExpectOk(port: u16, path: []const u8, results: *[2]bool, idx: usize) void {
    const fd = testConnect(port) catch {
        results[idx] = false;
        return;
    };
    defer _ = std.c.close(fd);
    testSendGet(fd, path);
    var buf: [256]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    results[idx] = n > 0 and std.mem.startsWith(u8, buf[0..@intCast(n)], "HTTP/1.1 200");
}

test "nox.http.serve_multicore: uctan uca, N=2 is parcacigi, iki EZSAMANLI istemci de GERCEKTEN sunulur" {
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
        \\    return nox_http_HttpResponse(200, "ok", {{"x": "x"}})
        \\
        \\nox.http.serve_multicore({d}, handle, 2, 1)
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

    var results: [2]bool = .{ false, false };
    const t1 = try std.Thread.spawn(.{}, testSendGetAndExpectOk, .{ port, "/a", &results, 0 });
    const t2 = try std.Thread.spawn(.{}, testSendGetAndExpectOk, .{ port, "/b", &results, 1 });
    t1.join();
    t2.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    try std.testing.expect(results[0]);
    try std.testing.expect(results[1]);
}

test "nox.http.listen + nox.thread.start + nox.http.serve_fd: birlestirilebilir ilkeller DOGRUDAN kullanildiginda da calisir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\import nox.thread
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{"x": "x"}})
        \\
        \\async def worker(fd: int) -> None:
        \\    nox.http.serve_fd(fd, handle, 1)
        \\
        \\fd: int = nox.http.listen({d})
        \\t: ThreadHandle[None] = nox.thread.start(worker, fd)
        \\nox.http.serve_fd(fd, handle, 1)
        \\await t.join()
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

    var results: [2]bool = .{ false, false };
    const t1 = try std.Thread.spawn(.{}, testSendGetAndExpectOk, .{ port, "/a", &results, 0 });
    const t2 = try std.Thread.spawn(.{}, testSendGetAndExpectOk, .{ port, "/b", &results, 1 });
    t1.join();
    t2.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    try std.testing.expect(results[0]);
    try std.testing.expect(results[1]);
}

// Kenar durumu: `num_threads=1` HİÇBİR ek `nox.thread` başlatmaz — sıradan
// TEK-iş-parçacıklı `nox.http.serve`İLE ÖZDEŞ davranışa DEĞİŞTİRİLMEDEN
// indirgenir (bkz. `genHttpServeMulticore`nin belge notu, döngü SIFIR kez
// çalışır).
test "nox.http.serve_multicore: num_threads=1 sıradan tek-iş-parçacıklı sunuma İNDİRGENİR" {
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
        \\    return nox_http_HttpResponse(200, "ok", {{"x": "x"}})
        \\
        \\nox.http.serve_multicore({d}, handle, 1, 1)
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

    var results: [1]bool = .{false};
    const fd = try testConnect(port);
    defer _ = std.c.close(fd);
    testSendGet(fd, "/only");
    var buf: [256]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    results[0] = n > 0 and std.mem.startsWith(u8, buf[0..@intCast(n)], "HTTP/1.1 200");

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    try std.testing.expect(results[0]);
}
