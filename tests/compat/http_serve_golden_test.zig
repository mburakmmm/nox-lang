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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, null, .empty, .empty);

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

/// `std.process.spawn` ile arka planda başlatılan ikilinin `nox_http_server_
/// listen`i FİİLEN çağırıp dinlemeye BAŞLAMASI belirli bir süre alabilir
/// (süreç başlatma + çalışma zamanı/zamanlayıcı ilklendirmesi + `nox.http.
/// serve`nin kendisine kadar olan KOD) — bu süre boyunca `connect()`
/// `ECONNREFUSED` ile BAŞARISIZ olur (henüz KİMSE dinlemiyordur). Bu YARIŞI
/// (ikilinin başlatılmasıyla istemci bağlantısı arasında) gidermek için
/// bağlantı BAŞARILI olana ya da makul bir deneme sayısı tükenene kadar kısa
/// aralıklarla YENİDEN dener.
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

fn testReadAll(fd: posix.fd_t) void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
    }
}

fn connectSendAndDrain(port: u16, path: []const u8, delay_ms: u32) void {
    const fd = testConnect(port) catch return;
    defer _ = std.c.close(fd);
    if (delay_ms != 0) {
        const ts: posix.timespec = .{ .sec = 0, .nsec = @as(isize, delay_ms) * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
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

    var resp_buf: [512]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            var header_buf: [256]u8 = undefined;
            const body = "gövde-verisi";
            const header = std.fmt.bufPrint(&header_buf, "POST /yol HTTP/1.1\r\nHost: 127.0.0.1\r\nx-test: baslik-degeri\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch unreachable;
            var off: usize = 0;
            while (off < header.len) {
                const n = std.c.write(fd, header[off..].ptr, header.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            off = 0;
            while (off < body.len) {
                const n = std.c.write(fd, body[off..].ptr, body.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = std.c.read(fd, out[total..].ptr, out.len - total);
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

    var resp_buf: [512]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            const body = "canli-veri";
            var header_buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch unreachable;
            var off: usize = 0;
            while (off < header.len) {
                const n = std.c.write(fd, header[off..].ptr, header.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            off = 0;
            while (off < body.len) {
                const n = std.c.write(fd, body[off..].ptr, body.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = std.c.read(fd, out[total..].ptr, out.len - total);
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

    var resp_buf: [256]u8 = undefined;
    var resp_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out: []u8, out_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);
            const body = "onemsiz-govde";
            var header_buf: [160]u8 = undefined;
            const header = std.fmt.bufPrint(&header_buf, "POST /onemsiz-yol HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Onemsiz: deger\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch unreachable;
            var off: usize = 0;
            while (off < header.len) {
                const n = std.c.write(fd, header[off..].ptr, header.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            off = 0;
            while (off < body.len) {
                const n = std.c.write(fd, body[off..].ptr, body.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out.len) {
                const n = std.c.read(fd, out[total..].ptr, out.len - total);
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

    var resp1_buf: [256]u8 = undefined;
    var resp1_len: usize = 0;
    var resp2_buf: [256]u8 = undefined;
    var resp2_len: usize = 0;
    const client_thread = try std.Thread.spawn(.{}, struct {
        fn run(p: u16, out1: []u8, out1_len: *usize, out2: []u8, out2_len: *usize) void {
            const fd = testConnect(p) catch return;
            defer _ = std.c.close(fd);

            // İLK istek: `Connection: close` YOK — bağlantının AÇIK
            // KALMASI beklenir.
            const req1 = "GET /birinci HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
            var off: usize = 0;
            while (off < req1.len) {
                const n = std.c.write(fd, req1[off..].ptr, req1.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            const n1 = std.c.read(fd, out1.ptr, out1.len);
            if (n1 <= 0) return;
            out1_len.* = @intCast(n1);

            // AYNI bağlantı üzerinden İKİNCİ istek — bu SEFER `Connection:
            // close` İLE bağlantı kapanır.
            const req2 = "GET /ikinci HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
            off = 0;
            while (off < req2.len) {
                const n = std.c.write(fd, req2[off..].ptr, req2.len - off);
                if (n <= 0) return;
                off += @intCast(n);
            }
            var total: usize = 0;
            while (total < out2.len) {
                const n = std.c.read(fd, out2[total..].ptr, out2.len - total);
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
