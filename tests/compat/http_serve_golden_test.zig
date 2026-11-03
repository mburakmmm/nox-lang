//! `nox.http.serve(port, handle[, max_connections])` (D.1.6) uçtan uca golden
//! testi — bkz. nox-teknik-spesifikasyon.md §3.34. `tests/compat/
//! http_stdlib_golden_test.zig`nin `compileAndRun`ıyla AYNI derleme
//! (module_loader + checker + codegen + qbe + cc) altyapısını kullanır, ama
//! ÜRETİLEN ikiliyi `std.process.run` (bloklayan, süreç BİTENE kadar hiçbir
//! şey okunamaz) YERİNE `std.process.spawn` (bloklamayan) ile başlatır —
//! çünkü bu testte Nox PROGRAMININ KENDİSİ sunucu, Zig test kodu İSE
//! istemcidir: ikilinin (sunucunun) çalışırken GERÇEK istemci bağlantılarını
//! KABUL ETTİĞİNİ kanıtlamak için ikiliyi ARKA PLANDA çalıştırıp AYNI ANDA
//! istemci soketleri açmamız gerekir.
//!
//! Sıra kanıtı (`runtime/stdlib_shims/http_server.zig`nin KENDİ birim
//! testiyle AYNI desen, bkz. onun "iki eşzamanlı bağlantı" testi): "yavaş"
//! istemci bağlanır ama isteği göndermeden önce kısa bir süre bekler (sunucu
//! bu bağlantı için `EAGAIN` alıp `suspendForIo`ya düşer); "hızlı" istemci
//! HEMEN gönderir. Sunucu (kqueue reaktörü üzerinden) GERÇEKTEN eşzamanlı
//! çalışıyorsa, "hızlı" isteğin `handle`ı ("fast" çıktısı) "yavaş"ınkinden
//! ÖNCE tamamlanır — bu, TEK bir OS iş parçacığında (M:1 fiber modeli)
//! bloklayan bir `accept`/`read` YAPILMADIĞININ somut kanıtıdır.

const std = @import("std");
const sys = @import("sys_compat");
const nox = @import("nox");
const host_link = @import("host_link");
const child_watchdog = @import("child_watchdog.zig");
const h2 = @import("http2");

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

    // Faz B.2: closure handler testi İçİn `noxc`nin KENDİ derleme yolunun
    // (`compiler/main.zig`nin `buildOne`ı) AYNI closure/from_imports/
    // fonksiyon-değer bilgisini geçir — ÖNCEDEN hepsi `.empty` idi, ki bu
    // yalnızca closure/from-import KULLANMAYAN kaynaklar İçin yeterliydi.
    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try allocator.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(allocator, entry.key_ptr.*, names);
    }
    var fn_values: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = checker_state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try fn_values.append(allocator, k.*);

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, fn_values.items, checker_state.module_aliases, checker_state.decorated_functions.items, .qbe, .hosted, null, &.{}, .empty);

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

    return bin_path;
}

/// 127.0.0.1 üzerinde OS'un ATAYACAĞI (port 0) bir dinleyici açıp HEMEN
/// kapatarak boş bir port "sonda" eder (bkz. `tests/compat/
/// http_stdlib_golden_test.zig`nin AYNI adlı fonksiyonu — kasıtlı tekrar,
/// AYRI bir test dosyası) — Nox programının KENDİSİ bu port numarasını
/// derleme ZAMANINDA (kaynağa gömülü bir tamsayı literali olarak) bilmesi
/// GEREKTİĞİNDEN, D.1.3/D.1.4'ün Zig-seviyesi testlerinin `nox_http_server_
/// listen(rt, 0)` + `nox_http_server_port(server)` ile YAPTIĞI "gerçek zamanlı
/// OS ataması" burada MÜMKÜN DEĞİLDİR (bkz. `genHttpServe`nin belge notu —
/// `nox.http.serve` bağlı portu Nox tarafına GERİ DÖNDÜRMEZ).
fn probeFreePort() !u16 {
    const fd = sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    if (sys.badFd(fd)) return error.SocketFailed;
    defer _ = sys.close(fd);
    var reuse: c_int = 1;
    _ = sys.setsockopt(fd, sys.SOL.SOCKET, sys.SO.REUSEADDR, &reuse, @sizeOf(c_int));

    var addr: sys.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (sys.bind(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.in)) != 0) return error.BindFailed;

    var got: sys.sockaddr.in = undefined;
    var got_len: sys.socklen_t = @sizeOf(sys.sockaddr.in);
    if (sys.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    return std.mem.bigToNative(u16, got.port);
}

/// `std.process.spawn` ile arka planda başlatılan ikilinin `nox_http_server_
/// listen`i FİİLEN çağırıp dinlemeye BAŞLAMASI belirli bir süre alabilir
/// (süreç başlatma + çalışma zamanı/zamanlayıcı ilklendirmesi + `nox.http.
/// serve`nin kendisine kadar olan KOD) — bu süre boyunca `connect()`
/// `ECONNREFUSED` ile BAŞARISIZ olur (henüz KİMSE dinlemiyordur). Bu YARIŞI
/// (ikilinin başlatılmasıyla istemci bağlantısı arasında) gidermek için
/// bağlantı BAŞARILI olana ya da makul bir deneme sayısı tükenene kadar kısa
/// aralıklarla YENİDEN dener.
fn testConnect(port: u16) !sys.fd_t {
    // Pencere 2 sn (200 × 10ms) idi: TÜM test paketi paralel (yük ortalaması
    // 4-6) çalışırken ikili 2 sn İçİNDE dinlemeye BAŞLAYAMADIĞINDA istemci
    // SESSİZCE vazgeçiyor (`catch return`), sunucu BİR bağlantı beklerken
    // 45 sn'lik watchdog'a kadar ASILIYORDU (yük altında iki FARKLI http
    // testinde gözlendi) — 10 sn'ye çıkarıldı.
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        const fd = sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
        if (sys.badFd(fd)) return error.SocketFailed;
        var addr: sys.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        if (sys.connect(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.in)) == 0) return fd;
        _ = sys.close(fd);
        const ts: sys.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = sys.nanosleep(&ts, null);
    }
    return error.ConnectFailed;
}

fn testSendGet(fd: sys.fd_t, path: []const u8) void {
    var buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path}) catch unreachable;
    var off: usize = 0;
    while (off < req.len) {
        const n = sys.write(fd, req[off..].ptr, req.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn testReadAll(fd: sys.fd_t) void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf, buf.len);
        if (n <= 0) break;
    }
}

fn connectSendAndDrain(port: u16, path: []const u8, delay_ms: u32) void {
    const fd = testConnect(port) catch return;
    defer _ = sys.close(fd);
    if (delay_ms != 0) {
        const ts: sys.timespec = .{ .sec = 0, .nsec = @as(isize, delay_ms) * std.time.ns_per_ms };
        _ = sys.nanosleep(&ts, null);
    }
    testSendGet(fd, path);
    testReadAll(fd);
}

test "nox.http.serve: uctan uca, iki eszamanli baglanti GERCEKTEN cakisir (yavas hizliyi bloke etmez)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `dict[str, str]` literalinin DOĞRUDAN kurucu argümanı olarak
    // geçirilmesi (adlandırılmış bir yerele BAĞLANMADAN) bilinçli — bkz.
    // `stdlib/nox/http.nox`daki AYNI notun gerekçesi (D.1.5): `dict`in ARC-
    // yönetimli OLMAMASI (kapsam sonunda KOŞULSUZ yıkım) yüzünden, bu değer
    // önce `headers: dict[str,str] = {{"x":"x"}}` gibi adlandırılmış bir
    // yerele BAĞLANSAYDI, `handle`in kapsam-sonu temizliği onu yıkardı —
    // dönen `HttpResponse` örneği HÂLÂ ona işaret ederken (çifte serbest
    // bırakma). Geçici bir DEĞER olarak hiçbir yerele bağlanmadığından bu
    // tehlike ORTADAN KALKAR.
    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    print(req.target)
        \\    return nox_http_HttpResponse(200, "ok", {{"x": "x"}})
        \\
        \\nox.http.serve({d}, handle, 2)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    // "yavaş" istemci: bağlanır ama isteği göndermeden önce 150ms bekler —
    // sunucunun bu bağlantı İÇİN `EAGAIN` alıp `suspendForIo`ya düşmesini
    // ZORLAR. "hızlı" istemci HEMEN gönderir.
    const slow_thread = try std.Thread.spawn(.{}, connectSendAndDrain, .{ port, "/slow", @as(u32, 150) });
    const fast_thread = try std.Thread.spawn(.{}, connectSendAndDrain, .{ port, "/fast", @as(u32, 0) });
    slow_thread.join();
    fast_thread.join();

    // `stdout`/`stderr` `child.wait()`DEN ÖNCE okunmalıdır — `wait()`in
    // altındaki `childWait` uygulaması dönmeden ÖNCE (kanıtlandı, bkz. bu
    // düzeltmenin gerekçesi) bu tutamaçları KAPATIP `null`a çeviriyor.
    // `allocRemaining` zaten BLOKLAYICIDIR (çocuk süreç stdout'unu KAPATANA
    // — yani sonlanana — KADAR döner), bu yüzden `wait()`DEN önce okumak
    // erken bir EOF riski TAŞIMAZ.
    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi (olasi askidan sonra watchdog tarafindan oldurulmus), term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, stdout_data, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    // Sıra KANITI: "yavaş" bağlantı GÖNDERMEDEN önce beklerken, sunucu
    // BLOKE OLMADAN "hızlı" bağlantıyı ÖNCE tamamlayabildi.
    try std.testing.expectEqualStrings("/fast\n/slow\n", stdout_data);
}

/// Dinlemeye başlamış bir 127.0.0.1 dinleyicisi (OS'un atadığı port); üst-akım sunucu testi için.
fn upstreamListener(port_out: *u16) !sys.fd_t {
    const fd = sys.socket(sys.AF.INET, sys.SOCK.STREAM, 0);
    if (sys.badFd(fd)) return error.SocketFailed;
    var reuse: c_int = 1;
    _ = sys.setsockopt(fd, sys.SOL.SOCKET, sys.SO.REUSEADDR, &reuse, @sizeOf(c_int));
    var addr: sys.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (sys.bind(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.in)) != 0) return error.BindFailed;
    if (sys.listen(fd, 64) != 0) return error.ListenFailed;
    var got: sys.sockaddr.in = undefined;
    var got_len: sys.socklen_t = @sizeOf(sys.sockaddr.in);
    if (sys.getsockname(fd, @ptrCast(&got), &got_len) != 0) return error.GetsocknameFailed;
    port_out.* = std.mem.bigToNative(u16, got.port);
    return fd;
}

/// `count` bağlantı kabul eder; her birine 100 ms gecikmeyle `ok` yanıtı verir (eşzamanlı istekler çakışsın diye bağlantı başına bir iş parçacığı).
fn upstreamServeMany(listen_fd: sys.fd_t, count: usize) void {
    var handlers: [32]?std.Thread = @splat(null);
    var i: usize = 0;
    while (i < count and i < handlers.len) : (i += 1) {
        var pfd = [1]sys.pollfd{.{ .fd = listen_fd, .events = sys.POLL.IN, .revents = 0 }};
        if (sys.poll(&pfd, 1, 30_000) <= 0) break;
        const conn = sys.accept(listen_fd, null, null);
        if (sys.badFd(conn)) break;
        handlers[i] = std.Thread.spawn(.{}, struct {
            fn run(c: sys.fd_t) void {
                defer _ = sys.close(c);
                var buf: [4096]u8 = undefined;
                var total: usize = 0;
                while (total < buf.len) {
                    const n = sys.read(c, buf[total..].ptr, buf.len - total);
                    if (n <= 0) break;
                    total += @intCast(n);
                    if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
                }
                const ts: sys.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
                _ = sys.nanosleep(&ts, null);
                const response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok";
                _ = sys.write(c, response.ptr, response.len);
            }
        }.run, .{conn}) catch null;
    }
    for (&handlers) |*h| if (h.*) |t| t.join();
}

test "nox.http.serve: handler İÇİNDEN giden nox.http.request (fiber, kooperatif) 8 eşzamanlı istemcide hepsi doğru yanıtlanır" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const N = 8;

    var up_port: u16 = 0;
    const up_fd = try upstreamListener(&up_port);
    defer _ = sys.close(up_fd);
    const up_thread = try std.Thread.spawn(.{}, upstreamServeMany, .{ up_fd, N });
    defer up_thread.join();

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Handler, üst-akım sunucuya bir istek atar (bu bir bağlantı fiber'ında çalışır: istek büyük yığınlı bir fiber'da, kooperatif ağ G/Ç'siyle yürür) ve yanıtını yazdırır.
    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    try:
        \\        up: nox_http_HttpResponse = nox.http.request("GET", "http://127.0.0.1:{d}/", "", {{}}, 5000)
        \\        print("up:" + up.body)
        \\        return nox_http_HttpResponse(200, "via:" + up.body, {{"x": "x"}})
        \\    except nox_http_HttpError:
        \\        print("up:error")
        \\        return nox_http_HttpResponse(502, "bad gateway", {{"x": "x"}})
        \\
        \\nox.http.serve({d}, handle, {d})
        \\
    , .{ up_port, port, N });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    var clients: [N]std.Thread = undefined;
    for (&clients) |*t| t.* = try std.Thread.spawn(.{}, connectSendAndDrain, .{ port, "/x", @as(u32, 0) });
    for (clients) |t| t.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) std.debug.print("cocuk surec normal cikmadi, term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, stdout_data, stderr_data });
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }
    // 8 handler'ın hepsi üst-akımdan "ok" aldı (hata/zaman aşımı yok).
    var ok_lines: usize = 0;
    var it = std.mem.splitScalar(u8, stdout_data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expectEqualStrings("up:ok", line);
        ok_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, N), ok_lines);
}

/// `path` için bir istek atıp yanıtın durum kodunu döndürür (bağlantı kapanana kadar okur); okunamazsa 0.
fn fetchStatus(port: u16, path: []const u8) u16 {
    const fd = testConnect(port) catch return 0;
    defer _ = sys.close(fd);
    testSendGet(fd, path);
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = sys.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total < 12 or !std.mem.startsWith(u8, buf[0..total], "HTTP/1.")) return 0;
    return std.fmt.parseInt(u16, buf[9..12], 10) catch 0;
}

test "nox.http.serve: handler'dan sızan yakalanmamış istisna 500 döner, sunucu ÖLMEZ ve sonraki istekleri sunar (IndexError/ZeroDivisionError/özel sınıf)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Eskiden bu üç yol da sarmalayıcının null yanıtın alanlarını okumasıyla tüm süreci SIGSEGV (139) ile sessizce öldürüyordu.
    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\class AppError(Exception):
        \\    pass
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    if req.target == "/boom":
        \\        raise AppError("kaboom")
        \\    if req.target == "/idx":
        \\        xs: list[int] = [1, 2]
        \\        return nox_http_HttpResponse(200, str(xs[5]), {{}})
        \\    if req.target == "/div":
        \\        z: int = len(req.body)
        \\        return nox_http_HttpResponse(200, str(10 // z), {{}})
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\nox.http.serve({d}, handle, 7)
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
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    // Sıralı istekler: her hata yolundan SONRA sunucu hâlâ yanıt vermeli.
    const paths = [_][]const u8{ "/ok", "/boom", "/ok", "/idx", "/ok", "/div", "/ok" };
    const want = [_]u16{ 200, 500, 200, 500, 200, 500, 200 };
    var got: [7]u16 = undefined;
    for (paths, 0..) |path, i| got[i] = fetchStatus(port, path);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) std.debug.print("cocuk surec normal cikmadi (sunucu oldu mu?), term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expectEqualSlices(u16, &want, &got);

    // stderr'de YALNIZCA üç istisna raporu olmalı (sızıntı/UAF çıktısı yok).
    var reports: usize = 0;
    var it = std.mem.splitScalar(u8, stderr_data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, line, "nox: uncaught exception in a server handler: "));
        reports += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), reports);
    try std.testing.expect(std.mem.indexOf(u8, stderr_data, "AppError (line 8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_data, "IndexError") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_data, "ZeroDivisionError") != null);
}

/// Ham `payload`'u gönderip (yazma tarafını kapatarak) yanıtın durum kodunu döndürür; yanıt yoksa/okunamazsa 0.
fn rawStatus(port: u16, payload: []const u8) u16 {
    const fd = testConnect(port) catch return 0;
    defer _ = sys.close(fd);
    var off: usize = 0;
    while (off < payload.len) {
        const n = sys.write(fd, payload[off..].ptr, payload.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = sys.shutdown(fd, 1); // SHUT_WR: eksik istekte sunucu EOF görsün
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = sys.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total < 12 or !std.mem.startsWith(u8, buf[0..total], "HTTP/1.")) return 0;
    return std.fmt.parseInt(u16, buf[9..12], 10) catch 0;
}

test "nox.http.serve: bozuk/saldırgan istekler (dev chunk boyutu, CL+TE, NUL, boşluklu başlık adı, kesik gövde, Host yok) reddedilir, sunucu ÖLMEZ" {
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
        \\    return nox_http_HttpResponse(200, str(len(req.body)), {{}})
        \\
        \\nox.http.serve({d}, handle, 10)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    const cases = [_]struct { payload: []const u8, want: u16 }{
        // Eskiden: Zig std chunked çözücüsünde `chunk_len + 2` taşması → tüm süreç panikle ölüyordu.
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nFFFFFFFFFFFFFFFF\r\nabc\r\n", .want = 413 },
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nZZ\r\nabc\r\n0\r\n\r\n", .want = 400 },
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5;ext=1\r\nhello\r\n0\r\nX-T: v\r\n\r\n", .want = 200 },
        // Request smuggling vektörleri.
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n", .want = 400 },
        .{ .payload = "GET /x HTTP/1.1\r\nHost: x\r\nX A: v\r\nConnection: close\r\n\r\n", .want = 400 },
        .{ .payload = "GET /x HTTP/1.1\r\nHost: x\r\nX-A: a\x00b\r\nConnection: close\r\n\r\n", .want = 400 },
        .{ .payload = "GET /x HTTP/1.1\r\nConnection: close\r\n\r\n", .want = 400 },
        // Kesik gövde handler'a tamamlanmış gibi verilmez.
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort", .want = 400 },
        // Hepsinden sonra sunucu hâlâ sağlıklı.
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello", .want = 200 },
        .{ .payload = "GET /x HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .want = 200 },
    };
    var got: [cases.len]u16 = undefined;
    var want: [cases.len]u16 = undefined;
    for (cases, 0..) |c, i| {
        got[i] = rawStatus(port, c.payload);
        want[i] = c.want;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);
    const term = try child.wait(io);
    if (term != .exited) std.debug.print("cocuk surec normal cikmadi (sunucu oldu mu?), term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expectEqualSlices(u16, &want, &got);
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

test "nox.http.serve: SIGTERM'de graceful shutdown — uçuştaki istek biter, boşta keep-alive kapanır, yeni bağlantı alınmaz, serve DÖNER" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // Windows'ta sinyal yok (yalnız nox.http.shutdown())
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\import nox.time
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    if req.target == "/slow":
        \\        nox.time.sleep_ms(700)
        \\        print("slow finished")
        \\        return nox_http_HttpResponse(200, "slow-done", {{}})
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\nox.http.serve({d}, handle)
        \\print("drained")
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    // Boşta keep-alive bağlantı: bir istek yapıp açık bırak.
    const idle_fd = try testConnect(port);
    defer _ = sys.close(idle_fd);
    {
        const req = "GET /x HTTP/1.1\r\nHost: x\r\n\r\n";
        _ = sys.write(idle_fd, req.ptr, req.len);
        var buf: [256]u8 = undefined;
        _ = sys.read(idle_fd, &buf, buf.len); // yanıt (bağlantı açık kalır)
    }

    // Uçuştaki yavaş istek.
    const slow_thread = try std.Thread.spawn(.{}, struct {
        fn run(pt: u16, out: *u16) void {
            out.* = fetchStatus(pt, "/slow");
        }
    }.run, .{ port, &slow_status });
    const ts: sys.timespec = .{ .sec = 0, .nsec = 250 * std.time.ns_per_ms };
    _ = sys.nanosleep(&ts, null);

    // Uçuş sürerken SIGTERM.
    try std.posix.kill(child.id.?, .TERM);
    slow_thread.join();

    // Boşta bağlantı sunucu tarafından kapatıldı (okuma EOF döner, 3 sn içinde).
    var pfd = [1]sys.pollfd{.{ .fd = idle_fd, .events = sys.POLL.IN, .revents = 0 }};
    const ready = sys.poll(&pfd, 1, 3000);
    var idle_closed = false;
    if (ready > 0) {
        var b: [16]u8 = undefined;
        idle_closed = sys.read(idle_fd, &b, b.len) <= 0;
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);
    const term = try child.wait(io);
    if (term != .exited) std.debug.print("cocuk surec temiz cikmadi, term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expectEqual(@as(u16, 200), slow_status); // uçuştaki istek tamamlandı
    try std.testing.expect(idle_closed);
    try std.testing.expectEqualStrings("slow finished\ndrained\n", stdout_data); // serve döndü ve temizlik kodu çalıştı
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

var slow_status: u16 = 0;

test "nox.http.configure: gövde/başlık sınırları ve nox.http.shutdown() çalışır (413/431, sonra graceful çıkış)" {
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
        \\    if req.target == "/stop":
        \\        nox.http.shutdown()
        \\    return nox_http_HttpResponse(200, str(len(req.body)), {{}})
        \\
        \\nox.http.configure(max_body_bytes=10, max_header_bytes=4096, drain_timeout_ms=2000)
        \\nox.http.serve({d}, handle)
        \\print("bye")
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    const big_header = try std.fmt.allocPrint(a, "GET /x HTTP/1.1\r\nHost: x\r\nCookie: {s}\r\nConnection: close\r\n\r\n", .{"c" ** 5000});
    const cases = [_]struct { payload: []const u8, want: u16 }{
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\nConnection: close\r\n\r\n0123456789", .want = 200 },
        .{ .payload = "POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\nConnection: close\r\n\r\n01234567890", .want = 413 },
        .{ .payload = big_header, .want = 431 },
        .{ .payload = "GET /stop HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .want = 200 },
    };
    var got: [cases.len]u16 = undefined;
    var want: [cases.len]u16 = undefined;
    for (cases, 0..) |c, i| {
        got[i] = rawStatus(port, c.payload);
        want[i] = c.want;
    }

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
    try std.testing.expectEqualSlices(u16, &want, &got);
    try std.testing.expectEqualStrings("bye\n", stdout_data);
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

/// Ham `payload`'u gönderip tüm yanıtı (bağlantı kapanana kadar) `buf`a okur; okunan bayt sayısını döndürür.
fn rawResponse(port: u16, payload: []const u8, buf: []u8) usize {
    const fd = testConnect(port) catch return 0;
    defer _ = sys.close(fd);
    _ = sys.write(fd, payload.ptr, payload.len);
    var total: usize = 0;
    while (total < buf.len) {
        const n = sys.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total;
}

test "nox.http: aynı adlı birden çok yanıt başlığı (multi → Set-Cookie ×2) ve yinelenen istek başlıkları birleşik gelir" {
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
        \\    h: dict[str, str] = {{}}
        \\    h["Set-Cookie"] = nox.http.multi(["a=1; Path=/", "b=2; Path=/; HttpOnly"])
        \\    h["X-Accept"] = req.headers["Accept"]
        \\    h["X-Cookie"] = req.headers["Cookie"]
        \\    return nox_http_HttpResponse(200, "ok", h)
        \\
        \\nox.http.serve({d}, handle, 1)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    var buf: [2048]u8 = undefined;
    const n = rawResponse(port, "GET / HTTP/1.1\r\nHost: x\r\nAccept: text/html\r\nAccept: application/json\r\nCookie: x=1\r\nCookie: y=2\r\nConnection: close\r\n\r\n", &buf);
    const resp = buf[0..n];

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);
    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Set-Cookie: a=1; Path=/\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Set-Cookie: b=2; Path=/; HttpOnly\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Accept: text/html, application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "X-Cookie: x=1; y=2\r\n") != null);
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

var stream_resp_buf: [8192]u8 = undefined;
var stream_resp_len: usize = 0;

test "nox.http: akışlı yanıt (SSE) — chunked çerçeveleme doğru, akış sürerken başka istek HIZLICA sunulur (kooperatif sleep_ms)" {
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
        \\    if req.target == "/events":
        \\        s: nox_http_ResponseStream = req.sse()
        \\        i: int = 0
        \\        while i < 3:
        \\            s.event("n" + str(i), "tick")
        \\            s.sleep_ms(300)
        \\            i = i + 1
        \\        print("stream done")
        \\        return s.end()
        \\    print("fast served")
        \\    return nox_http_HttpResponse(200, "fast", {{}})
        \\
        \\nox.http.serve({d}, handle, 2)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    const reader = try std.Thread.spawn(.{}, struct {
        fn run(pt: u16) void {
            stream_resp_len = rawResponse(pt, "GET /events HTTP/1.1\r\nHost: x\r\n\r\n", &stream_resp_buf);
        }
    }.run, .{port});
    const ts: sys.timespec = .{ .sec = 0, .nsec = 200 * std.time.ns_per_ms };
    _ = sys.nanosleep(&ts, null);
    const fast_status = fetchStatus(port, "/fast"); // akış (900 ms) sürerken
    reader.join();

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

    const resp = stream_resp_buf[0..stream_resp_len];
    try std.testing.expectEqual(@as(u16, 200), fast_status);
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(resp, "transfer-encoding: chunked\r\n") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(resp, "content-type: text/event-stream") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(resp, "connection: close\r\n") != null);
    // Her olay kendi chunk'ı: "<hex>\r\nevent: tick\ndata: nN\n\n\r\n"; sonda "0\r\n\r\n".
    try std.testing.expect(std.mem.indexOf(u8, resp, "event: tick\ndata: n0\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "event: tick\ndata: n1\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "event: tick\ndata: n2\n\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "0\r\n\r\n"));
    // Sıra kanıtı: hızlı istek akış BİTMEDEN sunuldu.
    try std.testing.expectEqualStrings("fast served\nstream done\n", stdout_data);
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

test "nox.http: akış sırasında istemci kopması handler'ı bitirir (send False), sunucu ÖLMEZ (SIGPIPE yok); SIGTERM açık akışı bitirir, serve döner" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // Windows'ta sinyal yok
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
        \\    s: nox_http_ResponseStream = req.sse()
        \\    while s.is_open():
        \\        if not s.comment("hb"):
        \\            print("peer gone")
        \\            return s.end()
        \\        s.sleep_ms(30)
        \\    print("shutdown")
        \\    return s.end()
        \\
        \\nox.http.serve({d}, handle)
        \\print("drained")
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    // 1) Akışı başlat, başlığı oku, kop.
    {
        const fd = try testConnect(port);
        const req = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n";
        _ = sys.write(fd, req.ptr, req.len);
        var head: [512]u8 = undefined;
        const n = sys.read(fd, &head, head.len);
        try std.testing.expect(n > 0);
        try std.testing.expect(std.mem.startsWith(u8, head[0..@intCast(n)], "HTTP/1.1 200 OK\r\n"));
        _ = sys.close(fd);
    }
    const ts: sys.timespec = .{ .sec = 0, .nsec = 700 * std.time.ns_per_ms };
    _ = sys.nanosleep(&ts, null);

    // 2) Sunucu hâlâ yaşıyor: ikinci akış açılır.
    const fd2 = try testConnect(port);
    defer _ = sys.close(fd2);
    {
        const req = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n";
        _ = sys.write(fd2, req.ptr, req.len);
        var head: [512]u8 = undefined;
        const n = sys.read(fd2, &head, head.len);
        try std.testing.expect(n > 0);
        try std.testing.expect(std.mem.startsWith(u8, head[0..@intCast(n)], "HTTP/1.1 200 OK\r\n"));
    }

    // 3) Açık akış sürerken SIGTERM: handler `is_open() == False` görüp çıkar, serve döner.
    try std.posix.kill(child.id.?, .TERM);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);
    const term = try child.wait(io);
    if (term != .exited) std.debug.print("cocuk surec temiz cikmadi, term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expectEqualStrings("peer gone\nshutdown\ndrained\n", stdout_data);
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

test "nox.http.serve: bağlantı başına izinli son (1000.) istek 'Connection: close' taşır, ondan önceki yanıtlar taşımaz; kapanış beklenmedik bir kopma değildir" {
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
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\nox.http.serve({d}, handle, 1)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    const fd = try testConnect(port);
    defer _ = sys.close(fd);
    const req = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    var closes_before: usize = 0;
    var last_has_close = false;
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = sys.write(fd, req.ptr, req.len);
        var buf: [512]u8 = undefined;
        var got: usize = 0;
        // Yanıt "ok" gövdesiyle biter.
        while (!std.mem.endsWith(u8, buf[0..got], "ok")) {
            const n = sys.read(fd, buf[got..].ptr, buf.len - got);
            if (n <= 0) break;
            got += @intCast(n);
        }
        const has_close = std.ascii.indexOfIgnoreCase(buf[0..got], "connection: close") != null;
        if (i + 1 < 1000) {
            if (has_close) closes_before += 1;
        } else last_has_close = has_close;
    }
    // Son yanıttan sonra sunucu bağlantıyı kapattı: okuma EOF döner.
    var tail: [8]u8 = undefined;
    const eof = sys.read(fd, &tail, tail.len);

    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(usize, 0), closes_before);
    try std.testing.expect(last_has_close);
    try std.testing.expect(eof <= 0);
}

test "nox.http.configure(max_connections): sınır dolunca yeni bağlantı 'Retry-After' içeren 503 alır, mevcut akış etkilenmez, kapanış temiz" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // Windows'ta sinyal yok
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
        \\    s: nox_http_ResponseStream = req.sse()
        \\    while s.is_open():
        \\        if not s.comment("hb"):
        \\            break
        \\        s.sleep_ms(30)
        \\    return s.end()
        \\
        \\nox.http.configure(max_connections=1)
        \\nox.http.serve({d}, handle)
        \\
    , .{port});

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try compileToBinary(a, &tmp, source);
    var child = try std.process.spawn(io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 60_000);
    defer watchdog.disarm();

    const hold = try testConnect(port);
    defer _ = sys.close(hold);
    {
        const req = "GET /a HTTP/1.1\r\nHost: x\r\n\r\n";
        _ = sys.write(hold, req.ptr, req.len);
        var head: [256]u8 = undefined;
        const n = sys.read(hold, &head, head.len);
        try std.testing.expect(n > 0);
        try std.testing.expect(std.mem.startsWith(u8, head[0..@intCast(n)], "HTTP/1.1 200 OK\r\n"));
    }

    var buf: [512]u8 = undefined;
    const n = rawResponse(port, "GET /b HTTP/1.1\r\nHost: x\r\n\r\n", &buf);
    const rejected = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, rejected, "HTTP/1.1 503 Service Unavailable\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, rejected, "Retry-After: 1\r\n") != null);

    try std.posix.kill(child.id.?, .TERM);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);
    const term = try child.wait(io);
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

// ---- HTTP/2 (v2.0.127) -------------------------------------------------------------------------------------------------------------------------------
//
// Sahte bir h2c istemcisi (`H2Conn`): bağlantı ön eki, çerçeve gönder/oku, HPACK (kodlama `http2.encodeField`, çözme `http2.Decoder`) ve yanıt toplama. Sunucu GERÇEK bir Nox ikilisidir.

const h2_program =
    \\import nox.http
    \\import nox.websocket
    \\from nox.websocket import WebSocketServerConn
    \\
    \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
    \\    if req.target == "/echo":
    \\        return nox_http_HttpResponse(200, req.method + ":" + str(len(req.body)), {{}})
    \\    if req.target == "/big":
    \\        return nox_http_HttpResponse(200, "x" * 300000, {{"Content-Type": "application/octet-stream"}})
    \\    if req.target == "/slow":
    \\        s: nox_http_ResponseStream = req.stream(200, {{}})
    \\        s.sleep_ms(300)
    \\        s.send("slow")
    \\        return s.end()
    \\    if req.target == "/events":
    \\        e: nox_http_ResponseStream = req.sse()
    \\        i: int = 0
    \\        while i < 3 and e.is_open():
    \\            e.event("tick " + str(i), "tick")
    \\            i = i + 1
    \\            e.sleep_ms(250)
    \\        if e.is_open():
    \\            print("events done")
    \\        else:
    \\            print("events aborted")
    \\        return e.end()
    \\    if req.target == "/forever":
    \\        f: nox_http_ResponseStream = req.stream(200, {{}})
    \\        while f.is_open():
    \\            if not f.comment("hb"):
    \\                break
    \\            f.sleep_ms(30)
    \\        print("forever closed")
    \\        return f.end()
    \\    if req.target == "/trailers":
    \\        t: nox_http_ResponseStream = req.stream(200, {{}})
    \\        t.send("body")
    \\        t.trailers({{"X-Checksum": "abc", "Grpc-Status": "0"}})
    \\        return t.end()
    \\    if req.target == "/reqtrailer":
    \\        return nox_http_HttpResponse(200, req.body + ":" + req.trailer("X-Sum"), {{}})
    \\    if req.target == "/boom":
    \\        raise ValueError("boom")
    \\    cookie: str = ""
    \\    if "Cookie" in req.headers:
    \\        cookie = req.headers["Cookie"]
    \\    return nox_http_HttpResponse(200, "hello " + req.method + " " + req.target, {{"X-Host": req.headers["Host"], "X-Cookie": cookie}})
    \\
    \\def ws_handle(conn: WebSocketServerConn) -> None:
    \\    msg: str = conn.recv()
    \\    conn.send_text("echo:" + msg)
    \\    msg2: str = conn.recv()
    \\    conn.send_text("echo:" + msg2)
    \\
    \\nox.http.serve_ws({d}, handle, ws_handle)
    \\print("drained")
    \\
;

const H2Server = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    child: std.process.Child,
    watchdog: child_watchdog.ChildWatchdog = .{},
    port: u16,

    fn start(allocator: std.mem.Allocator) !*H2Server {
        const self = try allocator.create(H2Server);
        errdefer allocator.destroy(self);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        errdefer self.arena.deinit();
        self.port = try probeFreePort();
        const a = self.arena.allocator();
        const source = try std.fmt.allocPrint(a, h2_program, .{self.port});
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const bin_path = try compileToBinary(a, &self.tmp, source);
        self.child = try std.process.spawn(std.testing.io, .{ .argv = &.{bin_path}, .stdout = .pipe, .stderr = .pipe });
        self.watchdog = .{};
        try self.watchdog.arm(&self.child, 90_000);
        return self;
    }

    /// SIGTERM (graceful) + çıktıyı topla. Çağıran tüm istemci soketlerini önce kapatmış olmalı.
    fn stop(self: *H2Server, allocator: std.mem.Allocator, out_stdout: *[]u8, expected_stderr_prefix: []const u8) !void {
        const io = std.testing.io;
        try std.posix.kill(self.child.id.?, .TERM);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_reader = self.child.stdout.?.reader(io, &stdout_buf);
        out_stdout.* = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
        var stderr_buf: [4096]u8 = undefined;
        var stderr_reader = self.child.stderr.?.reader(io, &stderr_buf);
        const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(stderr_data);
        const term = try self.child.wait(io);
        self.watchdog.disarm();
        if (term != .exited or term.exited != 0) std.debug.print("h2 sunucu temiz cikmadi: {any}\nstderr:\n{s}\n", .{ term, stderr_data });
        try std.testing.expect(term == .exited);
        try std.testing.expectEqual(@as(u8, 0), term.exited);
        // Sızıntı/çökme raporu yok: stderr boş olmalı (ya da yalnızca beklenen handler-istisnası satırlarını içermeli).
        if (expected_stderr_prefix.len == 0) {
            if (stderr_data.len != 0) std.debug.print("h2 sunucu stderr:\n{s}\n", .{stderr_data[0..@min(stderr_data.len, 3000)]});
            try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, stderr_data, expected_stderr_prefix));
            try std.testing.expect(std.mem.indexOf(u8, stderr_data, "leak") == null);
        }
    }

    fn deinit(self: *H2Server, allocator: std.mem.Allocator) void {
        self.tmp.cleanup();
        self.arena.deinit();
        allocator.destroy(self);
    }
};

const H2Frame = struct { kind: u8, flags: u8, stream_id: u32, payload: []const u8 };

const H2Resp = struct {
    status: u16 = 0,
    body: std.ArrayListUnmanaged(u8) = .empty,
    headers: std.ArrayListUnmanaged(h2.Header) = .empty,
    ended: bool = false,
    rst: ?u32 = null,
};

const H2Conn = struct {
    fd: sys.fd_t,
    a: std.mem.Allocator,
    buf: [32768]u8 = undefined,
    dec: h2.Decoder,
    goaway: ?u32 = null,
    /// Alınan DATA baytlarına karşılık otomatik WINDOW_UPDATE gönder.
    auto_window: bool = true,
    server_max_streams: u32 = 0,
    server_connect_protocol: bool = false,
    ping_acks: usize = 0,

    fn open(a: std.mem.Allocator, port: u16) !H2Conn {
        return .{ .fd = try testConnect(port), .a = a, .dec = h2.Decoder.init(a, 4096) };
    }

    fn close(self: *H2Conn) void {
        _ = sys.close(self.fd);
        self.dec.deinit();
    }

    fn sendRaw(self: *H2Conn, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = sys.write(self.fd, bytes[off..].ptr, bytes.len - off);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    fn sendFrame(self: *H2Conn, kind: u8, flags: u8, sid: u32, payload: []const u8) !void {
        var l: std.ArrayListUnmanaged(u8) = .empty;
        defer l.deinit(self.a);
        try h2.appendFrameHeader(&l, self.a, @intCast(payload.len), kind, flags, sid);
        try l.appendSlice(self.a, payload);
        self.sendRaw(l.items);
    }

    fn readExact(self: *H2Conn, dst: []u8, timeout_ms: i32) bool {
        var got: usize = 0;
        while (got < dst.len) {
            var pfd = [1]sys.pollfd{.{ .fd = self.fd, .events = sys.POLL.IN, .revents = 0 }};
            if (sys.poll(&pfd, 1, timeout_ms) <= 0) return false;
            const n = sys.read(self.fd, dst[got..].ptr, dst.len - got);
            if (n <= 0) return false;
            got += @intCast(n);
        }
        return true;
    }

    /// Sıradaki çerçeve (yük `self.buf`ta, sonraki okumaya kadar geçerli). `null` = zaman aşımı ya da bağlantı kapandı.
    fn readFrame(self: *H2Conn, timeout_ms: i32) ?H2Frame {
        var hdr: [9]u8 = undefined;
        if (!self.readExact(&hdr, timeout_ms)) return null;
        const fh = h2.parseFrameHeader(&hdr);
        if (fh.length > self.buf.len) return null;
        if (!self.readExact(self.buf[0..fh.length], timeout_ms)) return null;
        return .{ .kind = fh.kind, .flags = fh.flags, .stream_id = fh.stream_id, .payload = self.buf[0..fh.length] };
    }

    fn handshake(self: *H2Conn) !void {
        self.sendRaw(h2.preface);
        try self.sendFrame(h2.frame_settings, 0, 0, &.{});
        var saw_settings = false;
        while (!saw_settings) {
            const f = self.readFrame(5000) orelse return error.NoServerSettings;
            if (f.kind == h2.frame_settings and f.flags & h2.flag_ack == 0) {
                saw_settings = true;
                var off: usize = 0;
                while (off + 6 <= f.payload.len) : (off += 6) {
                    const sid_ = std.mem.readInt(u16, f.payload[off..][0..2], .big);
                    const val_ = std.mem.readInt(u32, f.payload[off + 2 ..][0..4], .big);
                    if (sid_ == h2.setting_max_concurrent_streams) self.server_max_streams = val_;
                    if (sid_ == h2.setting_enable_connect_protocol) self.server_connect_protocol = val_ == 1;
                }
                try self.sendFrame(h2.frame_settings, h2.flag_ack, 0, &.{});
            }
        }
    }

    /// İstek başlıkları (ve isteğe bağlı gövde). `extra`: [ad, değer] çiftleri (küçük harf).
    fn request(self: *H2Conn, sid: u32, method: []const u8, path: []const u8, extra: []const [2][]const u8, body: ?[]const u8) !void {
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        defer blk.deinit(self.a);
        try h2.encodeField(&blk, self.a, ":method", method);
        try h2.encodeField(&blk, self.a, ":scheme", "http");
        try h2.encodeField(&blk, self.a, ":path", path);
        try h2.encodeField(&blk, self.a, ":authority", "localhost");
        for (extra) |e| try h2.encodeField(&blk, self.a, e[0], e[1]);
        try self.sendFrame(h2.frame_headers, h2.flag_end_headers | (if (body == null) h2.flag_end_stream else 0), sid, blk.items);
        if (body) |b| {
            var off: usize = 0;
            while (off < b.len) {
                const take = @min(b.len - off, 16384);
                const last = off + take == b.len;
                try self.sendFrame(h2.frame_data, if (last) h2.flag_end_stream else 0, sid, b[off..][0..take]);
                off += take;
            }
        }
    }

    /// Bir çerçeveyi duruma işler; `resps` akış kimliğine göre toplanır. Döner: akışın bittiği (END_STREAM ya da RST) akış kimliği, yoksa 0.
    fn absorb(self: *H2Conn, f: H2Frame, resps: *std.AutoHashMapUnmanaged(u32, H2Resp)) !u32 {
        switch (f.kind) {
            h2.frame_settings => if (f.flags & h2.flag_ack == 0) try self.sendFrame(h2.frame_settings, h2.flag_ack, 0, &.{}),
            h2.frame_ping => if (f.flags & h2.flag_ack != 0) {
                self.ping_acks += 1;
            } else try self.sendFrame(h2.frame_ping, h2.flag_ack, 0, f.payload),
            h2.frame_goaway => self.goaway = std.mem.readInt(u32, f.payload[4..8], .big),
            h2.frame_headers => {
                const gop = try resps.getOrPut(self.a, f.stream_id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                var arena = std.heap.ArenaAllocator.init(self.a);
                defer arena.deinit();
                var hs: std.ArrayListUnmanaged(h2.Header) = .empty;
                _ = try self.dec.decode(f.payload, arena.allocator(), &hs, 1 << 20);
                for (hs.items) |h| {
                    if (std.mem.eql(u8, h.name, ":status")) gop.value_ptr.status = try std.fmt.parseInt(u16, h.value, 10);
                    try gop.value_ptr.headers.append(self.a, .{ .name = try self.a.dupe(u8, h.name), .value = try self.a.dupe(u8, h.value) });
                }
                if (f.flags & h2.flag_end_stream != 0) {
                    gop.value_ptr.ended = true;
                    return f.stream_id;
                }
            },
            h2.frame_data => {
                const gop = try resps.getOrPut(self.a, f.stream_id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                try gop.value_ptr.body.appendSlice(self.a, f.payload);
                if (self.auto_window and f.payload.len > 0) {
                    var inc: [4]u8 = undefined;
                    std.mem.writeInt(u32, &inc, @intCast(f.payload.len), .big);
                    try self.sendFrame(h2.frame_window_update, 0, 0, &inc);
                    try self.sendFrame(h2.frame_window_update, 0, f.stream_id, &inc);
                }
                if (f.flags & h2.flag_end_stream != 0) {
                    gop.value_ptr.ended = true;
                    return f.stream_id;
                }
            },
            h2.frame_rst_stream => {
                const gop = try resps.getOrPut(self.a, f.stream_id);
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.rst = std.mem.readInt(u32, f.payload[0..4], .big);
                return f.stream_id;
            },
            else => {},
        }
        return 0;
    }

    /// Verilen akışlar bitene (END_STREAM / RST) dek okur; bitiş sırasını `order`a yazar. `false`: zaman aşımı.
    fn awaitStreams(self: *H2Conn, sids: []const u32, resps: *std.AutoHashMapUnmanaged(u32, H2Resp), order: ?*std.ArrayListUnmanaged(u32), timeout_ms: i32) !bool {
        var remaining: usize = sids.len;
        while (remaining > 0) {
            const f = self.readFrame(timeout_ms) orelse return false;
            const done = try self.absorb(f, resps);
            if (done != 0) {
                for (sids) |sid| {
                    if (sid == done) {
                        remaining -= 1;
                        if (order) |o| try o.append(self.a, done);
                    }
                }
            }
        }
        return true;
    }

    fn get(self: *H2Conn, sid: u32, path: []const u8, resps: *std.AutoHashMapUnmanaged(u32, H2Resp)) !*H2Resp {
        try self.request(sid, "GET", path, &.{}, null);
        try std.testing.expect(try self.awaitStreams(&.{sid}, resps, null, 5000));
        return resps.getPtr(sid).?;
    }
};

test "HTTP/2 (h2c): GET/POST, çok parçalı gövde, yanıt başlıkları, PING/SETTINGS, bilinmeyen çerçeve yok sayılır" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srv = try H2Server.start(allocator);
    defer srv.deinit(allocator);

    var c = try H2Conn.open(a, srv.port);
    try c.handshake();
    try std.testing.expectEqual(@as(u32, 100), c.server_max_streams);
    var resps: std.AutoHashMapUnmanaged(u32, H2Resp) = .empty;

    const r1 = try c.get(1, "/hello", &resps);
    try std.testing.expectEqual(@as(u16, 200), r1.status);
    try std.testing.expectEqualStrings("hello GET /hello", r1.body.items);
    // :authority → Host başlığına dönüşür; çerez başlığı yok → boş.
    var host_ok = false;
    for (r1.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "x-host") and std.mem.eql(u8, h.value, "localhost")) host_ok = true;
        try std.testing.expect(!h2.isConnectionSpecific(h.name));
    }
    try std.testing.expect(host_ok);

    // PING → ACK; bilinmeyen çerçeve türü yok sayılır; ardından normal istek çalışır.
    try c.sendFrame(h2.frame_ping, 0, 0, "12345678");
    try c.sendFrame(0xfa, 0, 0, "ignored");
    const r3 = try c.get(3, "/hello", &resps);
    try std.testing.expectEqualStrings("hello GET /hello", r3.body.items);
    try std.testing.expectEqual(@as(usize, 1), c.ping_acks);

    // POST: 100 KiB gövde 7 DATA çerçevesinde.
    const body = try a.alloc(u8, 100 * 1024);
    @memset(body, 'p');
    try c.request(5, "POST", "/echo", &.{}, body);
    try std.testing.expect(try c.awaitStreams(&.{5}, &resps, null, 5000));
    try std.testing.expectEqualStrings("POST:102400", resps.getPtr(5).?.body.items);

    // Çerez başlıkları: iki ayrı `cookie` alanı Nox tarafında tek başlıkta görünür.
    try c.request(7, "GET", "/hello", &.{ .{ "cookie", "a=1" }, .{ "cookie", "b=2" } }, null);
    try std.testing.expect(try c.awaitStreams(&.{7}, &resps, null, 5000));
    var cookie_seen = false;
    for (resps.getPtr(7).?.headers.items) |h| {
        if (std.mem.eql(u8, h.name, "x-cookie")) cookie_seen = std.mem.indexOf(u8, h.value, "a=1") != null and std.mem.indexOf(u8, h.value, "b=2") != null;
    }
    try std.testing.expect(cookie_seen);

    // Handler istisnası: 500, bağlantı ve sunucu yaşar.
    const rb = try c.get(9, "/boom", &resps);
    try std.testing.expectEqual(@as(u16, 500), rb.status);
    const r11 = try c.get(11, "/hello", &resps);
    try std.testing.expectEqual(@as(u16, 200), r11.status);

    c.close();
    var out: []u8 = undefined;
    try srv.stop(allocator, &out, "nox: uncaught exception in a server handler");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("drained\n", out);
}

test "HTTP/2 (h2c): çoklama (yavaş akış hızlıyı bloklamaz), akış kontrolü (pencere dolunca durur, WINDOW_UPDATE ile sürer), 101. eşzamanlı akış reddedilir" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srv = try H2Server.start(allocator);
    defer srv.deinit(allocator);

    var c = try H2Conn.open(a, srv.port);
    try c.handshake();
    var resps: std.AutoHashMapUnmanaged(u32, H2Resp) = .empty;

    // Çoklama: 1 ve 3 yavaş (300 ms), 5 hızlı → 5 ÖNCE biter.
    try c.request(1, "GET", "/slow", &.{}, null);
    try c.request(3, "GET", "/slow", &.{}, null);
    try c.request(5, "GET", "/hello", &.{}, null);
    var order: std.ArrayListUnmanaged(u32) = .empty;
    try std.testing.expect(try c.awaitStreams(&.{ 1, 3, 5 }, &resps, &order, 5000));
    try std.testing.expectEqual(@as(u32, 5), order.items[0]);
    try std.testing.expectEqualStrings("slow", resps.getPtr(1).?.body.items);
    try std.testing.expectEqualStrings("slow", resps.getPtr(3).?.body.items);

    // Akış kontrolü: istemci WINDOW_UPDATE göndermez → sunucu tam 65535 bayt DATA yollayıp durur.
    c.auto_window = false;
    try c.request(7, "GET", "/big", &.{}, null);
    var data_total: usize = 0;
    var ended = false;
    while (c.readFrame(600)) |f| {
        if (f.stream_id != 7) continue;
        if (f.kind == h2.frame_data) {
            data_total += f.payload.len;
            if (f.flags & h2.flag_end_stream != 0) ended = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 65535), data_total);
    try std.testing.expect(!ended);
    // Pencereleri aç: kalan 300000 - 65535 bayt gelir ve akış biter.
    var inc: [4]u8 = undefined;
    std.mem.writeInt(u32, &inc, 1 << 20, .big);
    try c.sendFrame(h2.frame_window_update, 0, 0, &inc);
    try c.sendFrame(h2.frame_window_update, 0, 7, &inc);
    while (!ended) {
        const f = c.readFrame(5000) orelse break;
        if (f.stream_id == 7 and f.kind == h2.frame_data) {
            data_total += f.payload.len;
            if (f.flags & h2.flag_end_stream != 0) ended = true;
        }
    }
    try std.testing.expect(ended);
    try std.testing.expectEqual(@as(usize, 300000), data_total);
    c.auto_window = true;

    // 101 eşzamanlı akış: ilk 100 kabul edilir, 101. REFUSED_STREAM (7). (/slow 300 ms tutar.)
    var sid: u32 = 101;
    var n: usize = 0;
    while (n < 101) : (n += 1) {
        try c.request(sid, "GET", "/slow", &.{}, null);
        sid += 2;
    }
    var refused: usize = 0;
    var completed: usize = 0;
    var seen_done: usize = 0;
    while (seen_done < 101) {
        const f = c.readFrame(5000) orelse break;
        const done = try c.absorb(f, &resps);
        if (done != 0) {
            seen_done += 1;
            const r = resps.getPtr(done).?;
            if (r.rst) |code| {
                if (code == 7) refused += 1;
            } else completed += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), refused);
    try std.testing.expectEqual(@as(usize, 100), completed);

    c.close();
    var out: []u8 = undefined;
    try srv.stop(allocator, &out, "");
    defer allocator.free(out);
}

test "HTTP/2 (h2c): hatalı biçimli istekler akışı sıfırlar (bağlantı yaşar); çerçeve ihlalleri GOAWAY ile bağlantıyı bitirir; CONTINUATION; sel ve rapid-reset sınırı" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srv = try H2Server.start(allocator);
    defer srv.deinit(allocator);
    var resps: std.AutoHashMapUnmanaged(u32, H2Resp) = .empty;

    // (a) Akış hataları: büyük harfli ad, bağlantıya özgü başlık, :path yok → RST_STREAM(PROTOCOL_ERROR=1); bağlantı sağlam.
    {
        var c = try H2Conn.open(a, srv.port);
        defer c.close();
        try c.handshake();
        try c.request(1, "GET", "/hello", &.{.{ "X-Upper", "1" }}, null);
        try c.request(3, "GET", "/hello", &.{.{ "connection", "close" }}, null);
        // :path olmayan istek elle kodlanır.
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        try h2.encodeField(&blk, a, ":method", "GET");
        try h2.encodeField(&blk, a, ":scheme", "http");
        try c.sendFrame(h2.frame_headers, h2.flag_end_headers | h2.flag_end_stream, 5, blk.items);
        try std.testing.expect(try c.awaitStreams(&.{ 1, 3, 5 }, &resps, null, 5000));
        for ([_]u32{ 1, 3, 5 }) |sid| try std.testing.expectEqual(@as(?u32, 1), resps.getPtr(sid).?.rst);
        const ok = try c.get(7, "/hello", &resps);
        try std.testing.expectEqual(@as(u16, 200), ok.status);
    }

    // (b) Bağlantı hataları: GOAWAY(PROTOCOL_ERROR) ve kapanış. 0 numaralı akışta DATA; sıfır artışlı WINDOW_UPDATE; CONTINUATION arasına başka çerçeve.
    const violations = [_]struct { kind: u8, flags: u8, sid: u32, payload: []const u8 }{
        .{ .kind = h2.frame_data, .flags = 0, .sid = 0, .payload = "x" },
        .{ .kind = h2.frame_window_update, .flags = 0, .sid = 0, .payload = &[_]u8{ 0, 0, 0, 0 } },
        .{ .kind = h2.frame_settings, .flags = 0, .sid = 1, .payload = &.{} },
        .{ .kind = h2.frame_push_promise, .flags = 4, .sid = 1, .payload = &[_]u8{ 0, 0, 0, 2 } },
        .{ .kind = h2.frame_ping, .flags = 0, .sid = 0, .payload = "short" },
    };
    for (violations) |v| {
        var c = try H2Conn.open(a, srv.port);
        defer c.close();
        try c.handshake();
        try c.sendFrame(v.kind, v.flags, v.sid, v.payload);
        var got_goaway = false;
        while (c.readFrame(3000)) |f| {
            if (f.kind == h2.frame_goaway) {
                got_goaway = true;
                const code = std.mem.readInt(u32, f.payload[4..8], .big);
                try std.testing.expect(code == 1 or code == 6); // PROTOCOL_ERROR ya da FRAME_SIZE_ERROR
            }
        }
        try std.testing.expect(got_goaway);
    }

    // (c) CONTINUATION: başlık bloğu iki çerçeveye bölünür → normal yanıt. Araya başka çerçeve girerse GOAWAY.
    {
        var c = try H2Conn.open(a, srv.port);
        defer c.close();
        try c.handshake();
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        try h2.encodeField(&blk, a, ":method", "GET");
        try h2.encodeField(&blk, a, ":scheme", "http");
        try h2.encodeField(&blk, a, ":path", "/hello");
        try h2.encodeField(&blk, a, ":authority", "localhost");
        const mid = blk.items.len / 2;
        try c.sendFrame(h2.frame_headers, h2.flag_end_stream, 1, blk.items[0..mid]);
        try c.sendFrame(h2.frame_continuation, h2.flag_end_headers, 1, blk.items[mid..]);
        try std.testing.expect(try c.awaitStreams(&.{1}, &resps, null, 5000));
        try std.testing.expectEqualStrings("hello GET /hello", resps.getPtr(1).?.body.items);
        // Ara çerçeve: HEADERS (END_HEADERS yok) → PING → protokol hatası.
        try c.sendFrame(h2.frame_headers, h2.flag_end_stream, 3, blk.items[0..mid]);
        try c.sendFrame(h2.frame_ping, 0, 0, "12345678");
        var got_goaway = false;
        while (c.readFrame(3000)) |f| {
            if (f.kind == h2.frame_goaway) got_goaway = true;
        }
        try std.testing.expect(got_goaway);
    }

    // (d) SETTINGS seli → GOAWAY(ENHANCE_YOUR_CALM=11).
    {
        var c = try H2Conn.open(a, srv.port);
        defer c.close();
        try c.handshake();
        var batch: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < 5000) : (i += 1) try h2.appendFrameHeader(&batch, a, 0, h2.frame_settings, 0, 0);
        c.sendRaw(batch.items);
        var code: u32 = 0;
        while (c.readFrame(3000)) |f| {
            if (f.kind == h2.frame_goaway) code = std.mem.readInt(u32, f.payload[4..8], .big);
        }
        try std.testing.expectEqual(@as(u32, 11), code);
    }

    // (e) Rapid reset: 1000 × (HEADERS + RST_STREAM) → GOAWAY(ENHANCE_YOUR_CALM); sunucu başka bağlantıları sunmaya devam eder.
    {
        var c = try H2Conn.open(a, srv.port);
        defer c.close();
        try c.handshake();
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        try h2.encodeField(&blk, a, ":method", "GET");
        try h2.encodeField(&blk, a, ":scheme", "http");
        try h2.encodeField(&blk, a, ":path", "/slow");
        try h2.encodeField(&blk, a, ":authority", "localhost");
        var batch: std.ArrayListUnmanaged(u8) = .empty;
        var sid: u32 = 1;
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            try h2.appendFrameHeader(&batch, a, @intCast(blk.items.len), h2.frame_headers, h2.flag_end_headers | h2.flag_end_stream, sid);
            try batch.appendSlice(a, blk.items);
            try h2.appendFrameHeader(&batch, a, 4, h2.frame_rst_stream, 0, sid);
            try h2.appendU32(&batch, a, @intFromEnum(h2.ErrorCode.cancel));
            sid += 2;
        }
        c.sendRaw(batch.items);
        var code: u32 = 0;
        while (c.readFrame(3000)) |f| {
            if (f.kind == h2.frame_goaway) code = std.mem.readInt(u32, f.payload[4..8], .big);
        }
        try std.testing.expectEqual(@as(u32, 11), code);
    }
    {
        var c = try H2Conn.open(a, srv.port);
        defer c.close();
        try c.handshake();
        const ok = try c.get(1, "/hello", &resps);
        try std.testing.expectEqual(@as(u16, 200), ok.status);
    }

    // (f) Bozuk ön ek: yanıt yok, bağlantı kapanır.
    {
        const fd = try testConnect(srv.port);
        defer _ = sys.close(fd);
        const bad = "PRI * HTTP/2.0\r\n\r\nXX\r\n\r\n"; // 24 bayt, ama SM yerine XX
        _ = sys.write(fd, bad.ptr, bad.len);
        var b: [16]u8 = undefined;
        var pfd = [1]sys.pollfd{.{ .fd = fd, .events = sys.POLL.IN, .revents = 0 }};
        if (sys.poll(&pfd, 1, 3000) > 0) try std.testing.expect(sys.read(fd, &b, b.len) <= 0);
    }

    var out: []u8 = undefined;
    try srv.stop(allocator, &out, "");
    defer allocator.free(out);
}

fn maskedTextFrame(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const key = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    var out = try a.alloc(u8, 2 + 4 + text.len);
    out[0] = 0x81; // FIN + metin
    out[1] = @as(u8, @intCast(text.len)) | 0x80;
    @memcpy(out[2..6], &key);
    for (text, 0..) |ch, i| out[6 + i] = ch ^ key[i % 4];
    return out;
}

test "HTTP/2 (h2c): Expect: 100-continue ara yanıtı, yanıt trailer'ları (akışlı), istek trailer'ları (gövdeden sonra HEADERS)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srv = try H2Server.start(allocator);
    defer srv.deinit(allocator);

    var c = try H2Conn.open(a, srv.port);
    defer c.close();
    try c.handshake();
    try std.testing.expect(c.server_connect_protocol); // serve_ws sunucusu RFC 8441'i duyurur
    var resps: std.AutoHashMapUnmanaged(u32, H2Resp) = .empty;

    // 1) Expect: 100-continue → önce `:status 100`, sonra gövde, sonra 200.
    {
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        try h2.encodeField(&blk, a, ":method", "POST");
        try h2.encodeField(&blk, a, ":scheme", "http");
        try h2.encodeField(&blk, a, ":path", "/echo");
        try h2.encodeField(&blk, a, ":authority", "localhost");
        try h2.encodeField(&blk, a, "expect", "100-continue");
        try c.sendFrame(h2.frame_headers, h2.flag_end_headers, 1, blk.items);
        var got_100 = false;
        while (c.readFrame(3000)) |f| {
            _ = try c.absorb(f, &resps);
            if (f.kind == h2.frame_headers and f.stream_id == 1) {
                got_100 = resps.getPtr(1).?.status == 100;
                break;
            }
        }
        try std.testing.expect(got_100);
        try c.sendFrame(h2.frame_data, h2.flag_end_stream, 1, "hello");
        try std.testing.expect(try c.awaitStreams(&.{1}, &resps, null, 5000));
        try std.testing.expectEqual(@as(u16, 200), resps.getPtr(1).?.status);
        try std.testing.expectEqualStrings("POST:5", resps.getPtr(1).?.body.items);
    }

    // 2) Yanıt trailer'ları: DATA'da END_STREAM YOK, son HEADERS trailer'ları taşır.
    {
        try c.request(3, "GET", "/trailers", &.{}, null);
        var data_end_flag = false;
        var trailer_headers_end = false;
        var seen_trailers = false;
        while (c.readFrame(5000)) |f| {
            if (f.stream_id == 3 and f.kind == h2.frame_data and f.flags & h2.flag_end_stream != 0) data_end_flag = true;
            if (f.stream_id == 3 and f.kind == h2.frame_headers and resps.getPtr(3) != null and resps.getPtr(3).?.status == 200) {
                trailer_headers_end = f.flags & h2.flag_end_stream != 0;
                seen_trailers = true;
            }
            if ((try c.absorb(f, &resps)) == 3) break;
        }
        const r = resps.getPtr(3).?;
        try std.testing.expect(!data_end_flag);
        try std.testing.expect(seen_trailers and trailer_headers_end);
        try std.testing.expectEqualStrings("body", r.body.items);
        var cks = false;
        var gs = false;
        for (r.headers.items) |h| {
            if (std.mem.eql(u8, h.name, "x-checksum") and std.mem.eql(u8, h.value, "abc")) cks = true;
            if (std.mem.eql(u8, h.name, "grpc-status") and std.mem.eql(u8, h.value, "0")) gs = true;
        }
        try std.testing.expect(cks and gs);
    }

    // 3) İstek trailer'ları: HEADERS, DATA (END_STREAM yok), trailer HEADERS(END_STREAM).
    {
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        try h2.encodeField(&blk, a, ":method", "POST");
        try h2.encodeField(&blk, a, ":scheme", "http");
        try h2.encodeField(&blk, a, ":path", "/reqtrailer");
        try h2.encodeField(&blk, a, ":authority", "localhost");
        try c.sendFrame(h2.frame_headers, h2.flag_end_headers, 5, blk.items);
        try c.sendFrame(h2.frame_data, 0, 5, "hello");
        var tr: std.ArrayListUnmanaged(u8) = .empty;
        try h2.encodeField(&tr, a, "x-sum", "42");
        try c.sendFrame(h2.frame_headers, h2.flag_end_headers | h2.flag_end_stream, 5, tr.items);
        try std.testing.expect(try c.awaitStreams(&.{5}, &resps, null, 5000));
        try std.testing.expectEqualStrings("hello:42", resps.getPtr(5).?.body.items);
    }

    var out: []u8 = undefined;
    try srv.stop(allocator, &out, "");
    defer allocator.free(out);
}

test "HTTP/1.1: chunked yanıt trailer'ları ve chunked istek trailer'ları (req.trailer)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const srv = try H2Server.start(allocator);
    defer srv.deinit(allocator);

    var buf: [2048]u8 = undefined;
    // Yanıt trailer'ları: son chunk'tan (0\r\n) SONRA başlık satırları gelir.
    const n = rawResponse(srv.port, "GET /trailers HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &buf);
    const resp = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    const zero = std.mem.indexOf(u8, resp, "\r\n0\r\n") orelse return error.NoFinalChunk;
    try std.testing.expect(std.mem.indexOf(u8, resp[0..zero], "body") != null);
    const tail = resp[zero + 5 ..];
    try std.testing.expect(std.ascii.indexOfIgnoreCase(tail, "x-checksum: abc\r\n") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(tail, "grpc-status: 0\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, resp, "\r\n\r\n"));

    // İstek trailer'ı: chunked gövde + "X-Sum: 42".
    const n2 = rawResponse(srv.port, "POST /reqtrailer HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTrailer: X-Sum\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\nX-Sum: 42\r\n\r\n", &buf);
    try std.testing.expect(std.mem.endsWith(u8, buf[0..n2], "hello:42"));

    var out: []u8 = undefined;
    try srv.stop(allocator, &out, "");
    defer allocator.free(out);
}

test "HTTP/2 (h2c): WebSocket üzerinden RFC 8441 — genişletilmiş CONNECT, maskeli çerçeveler akış DATA'sında, iki mesaj yankısı, düz CONNECT 501" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srv = try H2Server.start(allocator);
    defer srv.deinit(allocator);

    var c = try H2Conn.open(a, srv.port);
    defer c.close();
    try c.handshake();
    try std.testing.expect(c.server_connect_protocol);
    var resps: std.AutoHashMapUnmanaged(u32, H2Resp) = .empty;

    // Düz CONNECT (proxy tüneli) desteklenmez → 501; sunucu yaşar.
    {
        var blk: std.ArrayListUnmanaged(u8) = .empty;
        try h2.encodeField(&blk, a, ":method", "CONNECT");
        try h2.encodeField(&blk, a, ":authority", "example.com:443");
        try c.sendFrame(h2.frame_headers, h2.flag_end_headers | h2.flag_end_stream, 1, blk.items);
        try std.testing.expect(try c.awaitStreams(&.{1}, &resps, null, 5000));
        // :scheme/:path yok → hatalı biçimli (RST) ya da 501; her ikisi de reddir.
        const r = resps.getPtr(1).?;
        try std.testing.expect(r.status == 501 or r.rst != null);
    }

    // WebSocket el sıkışması.
    var blk: std.ArrayListUnmanaged(u8) = .empty;
    try h2.encodeField(&blk, a, ":method", "CONNECT");
    try h2.encodeField(&blk, a, ":protocol", "websocket");
    try h2.encodeField(&blk, a, ":scheme", "http");
    try h2.encodeField(&blk, a, ":path", "/ws");
    try h2.encodeField(&blk, a, ":authority", "localhost");
    try h2.encodeField(&blk, a, "sec-websocket-version", "13");
    try c.sendFrame(h2.frame_headers, h2.flag_end_headers, 3, blk.items);
    while (c.readFrame(3000)) |f| {
        _ = try c.absorb(f, &resps);
        if (f.kind == h2.frame_headers and f.stream_id == 3) break;
    }
    try std.testing.expectEqual(@as(u16, 200), resps.getPtr(3).?.status);
    try std.testing.expect(!resps.getPtr(3).?.ended);

    // İki mesaj: istemci→sunucu maskeli, sunucu→istemci maskesiz.
    for ([_][]const u8{ "merhaba", "tekrar" }) |msg| {
        try c.sendFrame(h2.frame_data, 0, 3, try maskedTextFrame(a, msg));
        var got: std.ArrayListUnmanaged(u8) = .empty;
        const want = try std.fmt.allocPrint(a, "echo:{s}", .{msg});
        while (got.items.len < 2 + want.len) {
            const f = c.readFrame(5000) orelse break;
            if (f.stream_id == 3 and f.kind == h2.frame_data) try got.appendSlice(a, f.payload);
            _ = try c.absorb(f, &resps);
        }
        try std.testing.expectEqual(@as(u8, 0x81), got.items[0]);
        try std.testing.expectEqual(@as(u8, @intCast(want.len)), got.items[1]);
        try std.testing.expectEqualStrings(want, got.items[2..][0..want.len]);
    }
    // Handler iki mesajdan sonra döner → sunucu akışı bitirir (END_STREAM; yankı okunurken zaten gelmiş olabilir).
    if (!resps.getPtr(3).?.ended) try std.testing.expect(try c.awaitStreams(&.{3}, &resps, null, 5000));
    try std.testing.expect(resps.getPtr(3).?.ended);

    var out: []u8 = undefined;
    try srv.stop(allocator, &out, "");
    defer allocator.free(out);
}

test "HTTP/2 (h2c): SSE parça parça akar; istemci RST_STREAM'i handler'ı bitirir; SIGTERM açık akışı bitirir ve GOAWAY(NO_ERROR) gönderir" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srv = try H2Server.start(allocator);
    defer srv.deinit(allocator);

    var c = try H2Conn.open(a, srv.port);
    defer c.close();
    try c.handshake();
    var resps: std.AutoHashMapUnmanaged(u32, H2Resp) = .empty;

    // 1) /events: ilk olay handler bitmeden (≈750 ms) çok önce gelir.
    try c.request(1, "GET", "/events", &.{}, null);
    var first_data_ms: ?i64 = null;
    const t0 = std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
    var done = false;
    while (!done) {
        const f = c.readFrame(5000) orelse break;
        if (f.stream_id == 1 and f.kind == h2.frame_data and first_data_ms == null and f.payload.len > 0) first_data_ms = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() - t0;
        if ((try c.absorb(f, &resps)) == 1) done = true;
    }
    try std.testing.expect(done);
    try std.testing.expect(first_data_ms != null and first_data_ms.? < 400);
    const r1 = resps.getPtr(1).?;
    try std.testing.expectEqualStrings("event: tick\ndata: tick 0\n\nevent: tick\ndata: tick 1\n\nevent: tick\ndata: tick 2\n\n", r1.body.items);

    // 2) İstemci akışı yarıda keser → handler is_open()==false görüp çıkar ("events aborted").
    try c.request(3, "GET", "/events", &.{}, null);
    while (c.readFrame(3000)) |f| {
        if (f.stream_id == 3 and f.kind == h2.frame_data) break;
    }
    var cancel: [4]u8 = undefined;
    std.mem.writeInt(u32, &cancel, @intFromEnum(h2.ErrorCode.cancel), .big);
    try c.sendFrame(h2.frame_rst_stream, 0, 3, &cancel);
    // Handler bir sonraki olay aralığında (250 ms) iptali görüp "events aborted" yazar; SIGTERM'den ÖNCE yazılması için bekle.
    const settle: sys.timespec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
    _ = sys.nanosleep(&settle, null);

    // 3) /forever açıkken SIGTERM: GOAWAY(NO_ERROR) gelir, handler çıkar, bağlantı kapanır, serve döner.
    try c.request(5, "GET", "/forever", &.{}, null);
    while (c.readFrame(3000)) |f| {
        if (f.stream_id == 5 and f.kind == h2.frame_data) break;
    }
    try std.posix.kill(srv.child.id.?, .TERM);
    while (c.readFrame(8000)) |f| {
        _ = try c.absorb(f, &resps);
    }
    try std.testing.expectEqual(@as(?u32, 0), c.goaway);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = srv.child.stdout.?.reader(std.testing.io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = srv.child.stderr.?.reader(std.testing.io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);
    const term = try srv.child.wait(std.testing.io);
    srv.watchdog.disarm();
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    try std.testing.expectEqualStrings("events done\nevents aborted\nforever closed\ndrained\n", stdout_data);
    try std.testing.expectEqual(@as(usize, 0), stderr_data.len);
}

// Faz HH.2 (bkz. nox-teknik-spesifikasyon.md §3.68): `nox_http_request_
// method/target/body/headers`in ARTIK kopyalamayıp `retain` ETTİĞİ yeni
// yolu, `HttpRequest`nin DÖRT alanının TAMAMINI (method/target/body/
// headers) GERÇEKTEN OKUYAN bir handler İLE uçtan uca doğrular — yalnızca
// "çökmedi" değil, DEĞERLERİN DOĞRU geldiği VE `stderr`e sızıntı/UAF
// belirtisi YAZILMADIĞI kontrol edilir.
test "nox.http.serve: HttpRequest'in DÖRT alanı da (method/target/body/headers) dogru okunur, sizinti/UAF yok" {
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
        \\    h: dict[str, str] = req.headers
        \\    line: str = req.method + " " + req.target + " " + req.body + " " + h["x-test"]
        \\    print(line)
        \\    return nox_http_HttpResponse(200, "echo:" + req.body, {{"y": "y"}})
        \\
        \\nox.http.serve({d}, handle, 1)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    var resp_buf: [512]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = sys.close(fd);
            var header_buf: [256]u8 = undefined;
            const body = "gövde-verisi";
            const header = std.fmt.bufPrint(&header_buf, "POST /yol HTTP/1.1\r\nHost: 127.0.0.1\r\nx-test: baslik-degeri\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch unreachable;
            var off: usize = 0;
            while (off < header.len) {
                const n = sys.write(fd, header[off..].ptr, header.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            off = 0;
            while (off < body.len) {
                const n = sys.write(fd, body[off..].ptr, body.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = sys.read(fd, out[total..].ptr, out.len - total);
                if (n <= 0) break;
                total += @intCast(n);
            }
            out_len.* = total;
        }
    }.run, .{ port, &resp_buf, &resp_len });
    client_thread.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi (olasi askidan sonra watchdog tarafindan oldurulmus), term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, stdout_data, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    // DÖRT alanın da (method/target/body/headers) DOĞRU geldiğinin kanıtı.
    try std.testing.expectEqualStrings("POST /yol gövde-verisi baslik-degeri\n", stdout_data);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..resp_len], "echo:gövde-verisi") != null);
}

// Faz HH.3 (bkz. nox-teknik-spesifikasyon.md §3.68): `nox_http_response_
// new`in ARTIK `body`/`headers`i kopyalamayıp `retain` ETTİĞİ yeni yolu,
// DİNAMİK olarak inşa edilmiş (str birleştirme İLE, salt literal DEĞİL —
// pinned-refcount kısayolunu ATLAYAN) bir yanıt gövdesi VE BİRDEN FAZLA
// yanıt başlığı İLE uçtan uca doğrular.
test "nox.http.serve: yanit govdesi/basliklari DINAMIK insa edildiginde de dogru gelir, sizinti/UAF yok" {
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
        \\    govde: str = "yanki:" + req.body
        \\    return nox_http_HttpResponse(200, govde, {{"birinci": "1-degeri", "ikinci": "2-degeri"}})
        \\
        \\nox.http.serve({d}, handle, 1)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    var resp_buf: [512]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = sys.close(fd);
            const body = "canli-veri";
            var header_buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch unreachable;
            var off: usize = 0;
            while (off < header.len) {
                const n = sys.write(fd, header[off..].ptr, header.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            off = 0;
            while (off < body.len) {
                const n = sys.write(fd, body[off..].ptr, body.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = sys.read(fd, out[total..].ptr, out.len - total);
                if (n <= 0) break;
                total += @intCast(n);
            }
            out_len.* = total;
        }
    }.run, .{ port, &resp_buf, &resp_len });
    client_thread.join();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi (olasi askidan sonra watchdog tarafindan oldurulmus), term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    const resp = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "yanki:canli-veri") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "birinci: 1-degeri") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ikinci: 2-degeri") != null);
}

// Faz HH.4 (bkz. nox-teknik-spesifikasyon.md §3.68): `genHttpServeWrapper`nin
// KULLANILMAYAN `HttpRequest` alanları İçin pahalı `nox_http_request_*`
// çağrıları YERİNE ucuz varsayılanlar (`""`/boş dict) ürettiği "tembel"
// yolu doğrular — `req`i HİÇ REFERANS ALMAYAN bir handler (benchmark'taki
// GERÇEK deseninin AYNISI) GERÇEK bir istek/başlık/gövdeyle GÖNDERİLDİĞİNDE
// hâlâ doğru yanıt vermeli VE sızıntı/UAF OLMAMALI (bkz. `genHttpServeWrapper`,
// atlanan alanlar için ÜRETİLEN `nox_dict_new`/`emitStringLiteral`nin
// `HttpRequest.__init__`in KENDİ retain/release döngüsüyle DOĞRU
// dengelendiğinin kanıtı).
test "nox.http.serve: req HIC referans alinmayan handler'da tembel alan insasi dogru calisir, sizinti/UAF yok" {
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
        \\nox.http.serve({d}, handle, 1)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    var resp_buf: [256]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = sys.close(fd);
            const body = "onemsiz-govde";
            var header_buf: [160]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "POST /onemsiz-yol HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Onemsiz: deger\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch unreachable;
            var off: usize = 0;
            while (off < header.len) {
                const n = sys.write(fd, header[off..].ptr, header.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            off = 0;
            while (off < body.len) {
                const n = sys.write(fd, body[off..].ptr, body.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = sys.read(fd, out[total..].ptr, out.len - total);
                if (n <= 0) break;
                total += @intCast(n);
            }
            out_len.* = total;
        }
    }.run, .{ port, &resp_buf, &resp_len });
    client_thread.join();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi (olasi askidan sonra watchdog tarafindan oldurulmus), term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    const resp = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "x: x") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ok") != null);
}

// v1.32.0 (bkz. nox-teknik-spesifikasyon.md §3.98): checker'ın `nox.http.
// serve` eşleştirmesi (`matchesNoxHttpCall`/`matchesNoxAttrCall`)
// `substituteAlias` ÜZERİNDEN modül TAKMA ADLARINI (`import nox.http as h`)
// çözer — AMA codegen'in KENDİ intrinsic sınıflandırıcısı (`matchesNoxAttr`,
// async_thread.zig) alias-FARKINDA DEĞİL, callee'nin KELİMESİ KELİMESİNE
// `nox.<modül>.<ad>` OLMASINI şart koşar. Araştırma SIRASINDA bulunan GERÇEK
// bir bug: takma-ad İLE yazılan bir `serve` çağrısı checker'dan GEÇERDİ ama
// codegen'de SIRADAN bir metod çağrısı SANILIP YANLIŞ/çökme İLE
// SONUÇLANIRDI. Düzeltme: checker artık eşleşen bir intrinsic çağrısının
// callee'sini (takma ad NE olursa olsun) KANONİK `nox.http.serve` şekline
// YENİDEN YAZAR (`rewriteIntrinsicCalleeToCanonical`) — BU test, `import
// nox.http as h; h.serve(...)`nin (yukarıdaki, alias'sız testle AYNI temel
// senaryo) UÇTAN UCA doğru derlendiğini/çalıştığını/doğru yanıt verdiğini
// kanıtlar.
test "nox.http.serve: modul takma adiyla (`import nox.http as h; h.serve(...)`) da dogru derlenir/calisir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http as h
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok-alias", {{}})
        \\
        \\h.serve({d}, handle, 1)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    var resp_buf: [256]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = sys.close(fd);
            testSendGet(fd, "/");
            var total: usize = 0;
            while (total < out.len) {
                const n = sys.read(fd, out[total..].ptr, out.len - total);
                if (n <= 0) break;
                total += @intCast(n);
            }
            out_len.* = total;
        }
    }.run, .{ port, &resp_buf, &resp_len });
    client_thread.join();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi (olasi askidan sonra watchdog tarafindan oldurulmus), term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    const resp = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ok-alias") != null);
}

// Faz HH.6 (bkz. nox-teknik-spesifikasyon.md §3.68): `nox.http.serve`nin
// keep-alive DESTEĞİNİ uçtan uca doğrular — `max_connections=1` (yalnızca
// TEK bir `accept()` İZİN VERİLİR) OLMASINA RAĞMEN, `Connection: close`
// GÖNDERMEDEN İKİ ARDIŞIK istek AYNI TCP bağlantısı üzerinden GÖNDERİLDİĞİNDE
// HER İKİSİ de sunulmalıdır (bkz. `connectionEntry`nin `while` döngüsü) —
// bu, YALNIZCA TEK bir `accept()`in GERÇEKLEŞTİĞİNİN (sunucu `max_
// connections=1`i AŞMADIĞININ) dolaylı ama KESİN kanıtıdır: sunucu İKİNCİ
// bir bağlantı KABUL ETMEDEN İKİNCİ isteği yanıtlayabiliyorsa, TEK
// bağlantı ÜZERİNDEN birden çok istek sunma ÇALIŞIYOR demektir.
test "nox.http.serve: Connection: close GONDERILMEDEN ayni baglanti uzerinden IKI istek de sunulur (keep-alive)" {
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
        \\    print(req.target)
        \\    return nox_http_HttpResponse(200, "ok:" + req.target, {{"x": "x"}})
        \\
        \\nox.http.serve({d}, handle, 1)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    var resp1_buf: [256]u8 = undefined;
    var resp1_len: usize = 0;
    var resp2_buf: [256]u8 = undefined;
    var resp2_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out1: []u8, out1_len: *usize, out2: []u8, out2_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = sys.close(fd);

            // İLK istek: `Connection: close` YOK — bağlantının AÇIK
            // KALMASI beklenir.
            const req1 = "GET /birinci HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            var off: usize = 0;
            while (off < req1.len) {
                const n = sys.write(fd, req1[off..].ptr, req1.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            const n1 = sys.read(fd, out1.ptr, out1.len);
            if (n1 <= 0) return;
            out1_len.* = @intCast(n1);

            // AYNI bağlantı üzerinden İKİNCİ istek — bu SEFER `Connection:
            // close` İLE bağlantı kapanır.
            const req2 = "GET /ikinci HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
            off = 0;
            while (off < req2.len) {
                const n = sys.write(fd, req2[off..].ptr, req2.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out2.len) {
                const n = sys.read(fd, out2[total..].ptr, out2.len - total);
                if (n <= 0) break;
                total += @intCast(n);
            }
            out2_len.* = total;
        }
    }.run, .{ port, &resp1_buf, &resp1_len, &resp2_buf, &resp2_len });
    client_thread.join();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi (olasi askidan sonra watchdog tarafindan oldurulmus), term={any}\nstderr:\n{s}\n", .{ term, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    // İKİ isteğin de GERÇEKTEN sunulduğunun kanıtı — TEK `accept()` İLE.
    const resp1 = resp1_buf[0..resp1_len];
    const resp2 = resp2_buf[0..resp2_len];
    try std.testing.expect(std.mem.indexOf(u8, resp1, "ok:/birinci") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "ok:/ikinci") != null);
    // İLK yanıt keep-alive OLMALI (`connection: close` YAZILMAMALI),
    // İKİNCİ yanıt İSE İSTEMCİNİN talebine UYGUN olarak kapanmalı.
    try std.testing.expect(std.mem.indexOf(u8, resp1, "connection: close") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp2, "connection: close") != null);
}

// Aether NOX_LIMITATIONS.md yol haritası, Faz A.3 (madde 10, bkz. nox-
// teknik-spesifikasyon.md ilgili bölüm): `req.peer_addr`in `accept()`in
// KENDİSİNİN doldurduğu GERÇEK istemci adresini (`127.0.0.1:<istemcinin
// KENDİ yerel portu>`) taşıdığını, istemcinin KENDİ `getsockname()`'iyle
// (bağlandığı KENDİ yerel adresi) ÇAPRAZ doğrular.
test "nox.http.serve: req.peer_addr GERCEK istemci adresini (ip:port) tasir" {
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
        \\    print(req.peer_addr)
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\nox.http.serve({d}, handle, 1)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    var client_local_port: u16 = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, local_port_out: *u16) void {
            const fd = testConnect(p) catch return;
            defer _ = sys.close(fd);
            var got: sys.sockaddr.in = undefined;
            var got_len: sys.socklen_t = @sizeOf(sys.sockaddr.in);
            if (sys.getsockname(fd, @ptrCast(&got), &got_len) == 0) {
                local_port_out.* = std.mem.bigToNative(u16, got.port);
            }
            testSendGet(fd, "/");
            testReadAll(fd);
        }
    }.run, .{ port, &client_local_port });
    client_thread.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi (olasi askidan sonra watchdog tarafindan oldurulmus), term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, stdout_data, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    try std.testing.expect(client_local_port != 0);
    const expected = try std.fmt.allocPrint(a, "127.0.0.1:{d}\n", .{client_local_port});
    try std.testing.expectEqualStrings(expected, stdout_data);
}

// Aether NOX_LIMITATIONS.md yol haritası, Faz B.2 (madde 4+19, bkz. nox-
// teknik-spesifikasyon.md ilgili bölüm): `nox.http.serve`e bir CLOSURE
// handler'ı — `app` (bir sınıf örneği) yakalayan, bir fonksiyonun DÖNDÜRDÜĞÜ
// closure DOĞRUDAN geçici olarak verilir. "Yavaş" istemci bağlantıyı açıp
// isteği 150ms SONRA gönderir: `serve(.., 2)` ikinci bağlantıyı kabul edip
// DÖNER, yavaş bağlantının fiber'ı handler'ı `serve` döndükten SONRA
// çağırır — closure'ın ömrünü `HandlerCtx` referans sayacı korumalıdır
// (aksi halde kullanım-sonrası-serbest-bırakma). stderr BOŞ olmalı.
test "nox.http.serve: closure handler (sinif yakalayan, gecici donus degeri) — serve dondukten sonra calisan baglanti guvenli" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\class App:
        \\    def __init__(self: App, greeting: str) -> None:
        \\        self.greeting = greeting
        \\        self.hits = 0
        \\
        \\def make_handler(app: App) -> (nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\        app.hits = app.hits + 1
        \\        print(app.greeting + req.target + " " + str(app.hits))
        \\        return nox_http_HttpResponse(200, "ok", {{"x": "y"}})
        \\    return handle
        \\
        \\app: App = App("merhaba ")
        \\nox.http.serve({d}, make_handler(app), 2)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    const slow_thread = try std.Thread.spawn(.{}, connectSendAndDrain, .{ port, "/slow", @as(u32, 150) });
    const fast_thread = try std.Thread.spawn(.{}, connectSendAndDrain, .{ port, "/fast", @as(u32, 0) });
    slow_thread.join();
    fast_thread.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi, term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, stdout_data, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);

    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası sızıntı/UAF): {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }

    // Yakalanan `app` HER iki bağlantıda PAYLAŞILIR (hits 1 sonra 2).
    try std.testing.expectEqualStrings("merhaba /fast 1\nmerhaba /slow 2\n", stdout_data);
}

// Faz B.2: `serve_fd` + closure'ın bir YEREL DEĞİŞKENDE tutulması
// (`h: (...) -> ... = make_handler(app)`; geçici DEĞİL, ödünç alınan bir
// değişken — `HandlerCtx` onu RETAIN eder, ifade-geçici release'i YOK).
test "nox.http.serve_fd: closure handler yerel degiskenden" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const port = try probeFreePort();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = try std.fmt.allocPrint(a,
        \\import nox.http
        \\
        \\class App:
        \\    def __init__(self: App, greeting: str) -> None:
        \\        self.greeting = greeting
        \\
        \\def make_handler(app: App) -> (nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\        print(app.greeting + req.target)
        \\        return nox_http_HttpResponse(200, "ok", {{"x": "y"}})
        \\    return handle
        \\
        \\app: App = App("selam ")
        \\h: (nox_http_HttpRequest) -> nox_http_HttpResponse = make_handler(app)
        \\fd: int = nox.http.listen({d})
        \\nox.http.serve_fd(fd, h, 1)
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

    var watchdog: child_watchdog.ChildWatchdog = .{};
    try watchdog.arm(&child, 45_000);
    defer watchdog.disarm();

    const client = try std.Thread.spawn(.{}, connectSendAndDrain, .{ port, "/fd", @as(u32, 0) });
    client.join();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_data = try stdout_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stdout_data);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(stderr_data);

    const term = try child.wait(io);
    if (term != .exited) {
        std.debug.print("cocuk surec normal cikmadi, term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ term, stdout_data, stderr_data });
    }
    try std.testing.expect(term == .exited);
    try std.testing.expectEqual(@as(u8, 0), term.exited);
    if (stderr_data.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir cikti yazdi: {s}\n", .{stderr_data});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings("selam /fd\n", stdout_data);
}
