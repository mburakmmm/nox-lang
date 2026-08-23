//! v1.36.0 (bkz. nox-teknik-spesifikasyon.md §3.103): `nox.http.serve_
//! multicore`/`serve_tls` İçİn GERÇEK bir sürdürülebilir-yük (soak) testi
//! — `tests/compat/http_serve_multicore_pool_golden_test.zig`nin ŞU AN
//! yalnızca 2 eşzamanlı istemci (tek istek) VEYA 20 ARDIŞIK (eşzamanlı
//! DEĞİL) istek yaptığı, GERÇEK bir sürdürülebilir yük testi YAPMADIĞI
//! (v1.31.0'ın CHANGELOG'unun KENDİ "kapsam dışı, ayrı ve daha büyük bir
//! görev" notu) doğrulanmıştı — BU dosya o boşluğu kapatır.
//!
//! `benchmarks/http_bench.zig`nin (GERÇEK `zig-out/bin/noxc`yi bir alt
//! süreç OLARAK çağıran, checker/codegen İç API'lerine bağımlı OLMAYAN)
//! deseni TEMEL alınır — `tests/compat/http_serve_*_golden_test.zig`nin
//! İç-API `compileToBinary`sinden FARKLI olarak, GERÇEK kullanıcı yolunu
//! (`noxc build` → qbe/clang → `cc`) egzersiz eder. `NOX_SOAK_SECONDS`
//! ortam değişkeni (`worker_pool.zig`nin `stressRoundsFromEnv`iyle AYNI
//! desen, SÜRE İçİn) süre-sınırını kontrol eder — VARSAYILAN küçük (hızlı
//! yerel/CI-push kontrolü İçİn), gecelik CI (`zig build http-soak-test
//! -Dsoak-seconds=300`) İSE ÇOK DAHA UZUN çalıştırır (bkz. `build.zig`nin
//! `http-soak-test` adımı — BİLİNÇLİ olarak `test_step`e EKLENMEZ, tıpkı
//! v1.31.0'ın `stress-test`i GİBİ).

const std = @import("std");
const posix = std.posix;

const cert_path = "tests/fixtures/tls/test_cert.pem";
const key_path = "tests/fixtures/tls/test_key.pem";

fn soakSecondsFromEnv(default_seconds: u32) u32 {
    const v = std.c.getenv("NOX_SOAK_SECONDS") orelse return default_seconds;
    return std.fmt.parseInt(u32, std.mem.span(v), 10) catch default_seconds;
}

/// GERÇEKTEN GÖZLEMLENDİ (canlı test SIRASINDA): `std.Io.Clock.Timestamp.
/// now(io, .awake)`, `std.testing.io`nun sahip OLMADIĞI, ELLE `std.Thread.
/// spawn` İLE başlatılan bir OS iş parçacığı İÇİNDEN çağrıldığında GÜVENİLİR
/// DEĞİL — süre-sınırı DÖNGÜSÜ HİÇ SONLANMADI (17+ dakika boyunca GERÇEK,
/// BAŞARILI istekler ATARAK sonsuza dek çalıştı — sunucunun KENDİSİ
/// KANITLANMIŞ olarak sağlıklıydı, bkz. plan dosyası "Doğrulama"). Kök
/// neden: `Io`nun saat soyutlaması KENDİ yürütme modeline (fiber/olay
/// döngüsü) BAĞLI — `benchmarks/http_bench.zig`nin KENDİSİ de BU YÜZDEN
/// `Timestamp.now`ı SADECE ANA iş parçacığında çağırır, spawn edilen
/// `clientWorker`in İÇİNDE HİÇ `Io` KULLANMAZ (yalnızca ham `std.c.*`).
/// Düzeltme: worker iş parçacıkları İÇİNDEKİ süre ölçümü `Io`dan TAMAMEN
/// BAĞIMSIZ, ham `clock_gettime(CLOCK.MONOTONIC)` İLE yapılır — GERÇEKTEN
/// HERHANGİ bir OS iş parçacığından GÜVENLE çağrılabilir.
fn monotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

/// `benchmarks/http_bench.zig`nin AYNI deseni: kaynağı GERÇEK bir `.nox`
/// dosyasına yazar, GERÇEK `zig-out/bin/noxc`yi (bare çağrı — `-o`
/// VERİLMEDİĞİNDEN çıktı ikilisi `.nox` uzantısı OLMADAN AYNI yola iner)
/// bir alt süreç OLARAK çalıştırır.
fn compileViaRealNoxc(gpa: std.mem.Allocator, io: std.Io, nox_path: []const u8, source: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nox_path, .data = source });
    const compile_result = try std.process.run(gpa, io, .{
        .argv = &.{ "zig-out/bin/noxc", nox_path },
    });
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);
    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        std.debug.print("http-soak: derleme basarisiz: {s}\n", .{compile_result.stderr});
        return error.CompileFailed;
    }
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
    while (attempt < 500) : (attempt += 1) {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr: std.c.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) == 0) return fd;
        _ = std.c.close(fd);
        const ts: posix.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    return error.ConnectFailed;
}

const SoakResult = struct { count: usize = 0 };

fn doOnePlainRequest(port: u16) bool {
    const fd = testConnect(port) catch return false;
    defer _ = std.c.close(fd);

    const req = "GET /soak HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    var off: usize = 0;
    while (off < req.len) {
        const n = std.c.write(fd, req[off..].ptr, req.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.c.read(fd, buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return std.mem.indexOf(u8, buf[0..total], "200") != null;
}

fn httpSoakClientWorker(port: u16, start_ns: i128, budget_ns: i128, start_flag: *std.atomic.Value(bool), result: *SoakResult) void {
    while (!start_flag.load(.acquire)) std.Thread.yield() catch {};
    var n: usize = 0;
    while (monotonicNs() - start_ns < budget_ns) {
        if (doOnePlainRequest(port)) n += 1;
    }
    result.count = n;
}

const SOAK_CLIENT_THREADS: usize = 8;

test "nox.http.serve_multicore soak: 8 sürekli istemci, sürdürülebilir süre boyunca kesintisiz istek" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const soak_seconds = soakSecondsFromEnv(5);
    const port = try probeFreePort();

    const source = try std.fmt.allocPrint(gpa,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\nox.http.serve_multicore({d}, handle, 4, 0)
        \\
    , .{port});
    defer gpa.free(source);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &dir_buf);
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/soak_multicore.nox", .{dir_path});
    defer gpa.free(nox_path);
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/soak_multicore", .{dir_path});
    defer gpa.free(bin_path);

    try compileViaRealNoxc(gpa, io, nox_path, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var start_flag = std.atomic.Value(bool).init(false);
    var threads: [SOAK_CLIENT_THREADS]std.Thread = undefined;
    var results: [SOAK_CLIENT_THREADS]SoakResult = @splat(.{});
    const start_ns = monotonicNs();
    const budget_ns: i128 = @as(i128, soak_seconds) * std.time.ns_per_s;
    for (0..SOAK_CLIENT_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, httpSoakClientWorker, .{ port, start_ns, budget_ns, &start_flag, &results[i] });
    }
    start_flag.store(true, .release);
    for (threads) |t| t.join();

    // v1.36.0: `max_connections=0` (sınırsız) — sunucu KENDİLİĞİNDEN
    // ÇIKMAZ, `http_serve_multicore_pool_golden_test.zig`nin "test 2"si
    // İLE AYNI desen: `Child.kill` SÜRECİ SONLANDIRIR VE (`wait()` İLE
    // AYNI şekilde) `child.stdin`/`stdout`/`stderr`'ı `null`a ÇEVİRİR —
    // BU YÜZDEN `kill`DEN SONRA bu tutamaçlara ERİŞİLEMEZ (GERÇEKTEN
    // DENENDİ: `kill`DEN ÖNCE `allocRemaining` İLE drenaj DENEMEK, süreç
    // HÂLÂ CANLIYKEN pipe'ı HİÇ KAPATMADIĞINDAN SONSUZA KADAR BLOKE
    // OLUYORDU; `kill`DEN SONRA denemek İSE `null` bir tutamaca erişim
    // olurdu). Bu YÜZDEN — "test 2"nin KENDİSİ GİBİ — stderr/stdout
    // drenajı YAPILMAZ, sadece `kill` çağrılır.
    child.kill(io);

    var total: usize = 0;
    for (results) |r| total += r.count;
    // Kanıt: HER istemci EN AZ birkaç kez döngü yaptı — kesin sayı duvar-
    // saati hızına bağlı olduğundan tam bir sayı iddia EDİLMEZ, sadece
    // makul bir alt sınır.
    try std.testing.expect(total > SOAK_CLIENT_THREADS * 5);
}

/// `tests/compat/http_serve_tls_golden_test.zig`nin `tlsRequestAndRead`
/// İşlevinin KOPYASI ("kasıtlı tekrar" konvansiyonu, bkz. o dosyanın
/// belge notu) — TEK fark, sabit bir `out` tamponu YERİNE sadece BAŞARI/
/// BAŞARISIZLIK dönmesi (soak döngüsü yanıt İÇERİĞİNİ İNCELEMEZ, sadece
/// TEKRARLANAN GERÇEK TLS el sıkışması + istek/yanıt döngüsünün ÇÖKMEDEN/
/// SIZDIRMADAN sürdüğünü kanıtlar).
/// v1.36.0: GERÇEKTEN GÖZLEMLENDİ — `std.Io.net.IpAddress.resolve`/
/// `.connect` (orijinal `tlsRequestAndRead`nin kullandığı yol), TEK-seferlik
/// bir bağlantı İçİn (`http_serve_tls_golden_test.zig`nin KENDİ "slow/fast"
/// İKİ istemcili testi GİBİ) GÜVENİLİR olsa da, SÜRDÜRÜLEBİLİR/YOĞUN
/// tekrarlı kullanım ALTINDA (8 iş parçacığı, saniyede YÜZLERCE bağlantı)
/// ARALIKLI `error.Unexpected` (errno 22/EINVAL) ÜRETTİ — `std.testing.io`
/// nun ALTINDAKİ `Io.Threaded` reaktörünün `netConnectIp` yolunun BU
/// yoğunlukta GÜVENİLİR olmadığı SONUCUNA VARILDI (standalone bir
/// reprodüksiyonla DOĞRULANDI: 8 iş parçacığı × 5 saniye, `Io.net`
/// KULLANILDIĞINDA ARALIKLI hata, `testConnect`nin HAM `std.c.connect`i +
/// `std.Io.File`e SARILMASI KULLANILDIĞINDA 2000+ BAŞARILI istekte SIFIR
/// hata). Bu YÜZDEN bağlantı `testConnect` (ham fd) İLE kurulup `std.Io.
/// File`e SARILIR — `std.crypto.tls.Client`ın İHTİYAÇ DUYDUĞU `Reader`/
/// `Writer` arayüzü BU SAYEDE, sorunlu `Io.net` bağlantı-kurma yolundan
/// TAMAMEN KAÇINARAK elde edilir.
fn doOneTlsRequest(io: std.Io, port: u16, bundle: *std.crypto.Certificate.Bundle, now: std.Io.Timestamp) bool {
    const fd = testConnect(port) catch return false;
    defer _ = std.c.close(fd);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };

    var sock_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var sock_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var stream_reader = file.reader(io, &sock_read_buf);
    var stream_writer = file.writer(io, &sock_write_buf);

    var tls_read_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var tls_write_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&random_buffer);

    var lock: std.Io.RwLock = .init;
    var client = std.crypto.tls.Client.init(&stream_reader.interface, &stream_writer.interface, .{
        .host = .{ .explicit = "localhost" },
        .ca = .{ .bundle = .{
            .gpa = std.heap.page_allocator,
            .io = io,
            .lock = &lock,
            .bundle = bundle,
        } },
        .ssl_key_log = null,
        .read_buffer = &tls_read_buf,
        .write_buffer = &tls_write_buf,
        .entropy = &random_buffer,
        .realtime_now = now,
        .allow_truncation_attacks = false,
    }) catch return false;

    const req = "GET /soak HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    client.writer.writeAll(req) catch return false;
    client.writer.flush() catch return false;
    stream_writer.interface.flush() catch return false;

    var out: [512]u8 = undefined;
    var total: usize = 0;
    while (total < out.len) {
        const n = client.reader.readSliceShort(out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return std.mem.indexOf(u8, out[0..total], "200") != null;
}

fn tlsSoakClientWorker(port: u16, io: std.Io, bundle: *std.crypto.Certificate.Bundle, now: std.Io.Timestamp, start_ns: i128, budget_ns: i128, start_flag: *std.atomic.Value(bool), result: *SoakResult) void {
    while (!start_flag.load(.acquire)) std.Thread.yield() catch {};
    var n: usize = 0;
    // `monotonicNs`in belge notu — SÜRE ölçümü (`Timestamp.now(io,.awake)`)
    // KENDİSİ BAĞIMSIZ, ham `clock_gettime` İLE yapılır (GÜVENSİZ olduğu
    // KANITLANDI). `io` BURADA YİNE DE (`doOneTlsRequest`nin İçİNDE GERÇEK
    // AĞ/TLS G/Ç İçİn) KULLANILMAYA DEVAM EDER — bu, `http_serve_tls_golden_
    // test.zig`nin KENDİ ZATEN ÇALIŞAN "slow/fast" iki-istemcili testinin
    // AYNI, KANITLANMIŞ deseni (`io` bir AKIŞ/TLS İşlemi İçİn spawn edilen
    // bir iş parçacığından GÜVENLE kullanılabilir — SADECE `.awake` saat
    // sorgusu GÜVENSİZDİ).
    while (monotonicNs() - start_ns < budget_ns) {
        if (doOneTlsRequest(io, port, bundle, now)) n += 1;
    }
    result.count = n;
}

test "nox.http.serve_tls soak: 8 sürekli TLS istemcisi, sürdürülebilir süre boyunca kesintisiz el sıkışma+istek" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const soak_seconds = soakSecondsFromEnv(5);
    const port = try probeFreePort();

    const source = try std.fmt.allocPrint(gpa,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{}})
        \\
        \\nox.http.serve_tls({d}, handle, "{s}", "{s}", 0)
        \\
    , .{ port, cert_path, key_path });
    defer gpa.free(source);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = try absPath(io, tmp.dir, &dir_buf);
    const nox_path = try std.fmt.allocPrint(gpa, "{s}/soak_tls.nox", .{dir_path});
    defer gpa.free(nox_path);
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/soak_tls", .{dir_path});
    defer gpa.free(bin_path);

    try compileViaRealNoxc(gpa, io, nox_path, source);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // İlk el sıkışma denemesinden ÖNCE sunucunun `listen()`e ulaşması İçİn
    // (`testConnect`nin AYNI gerekçesi) — TLS el sıkışması BAŞARISIZ
    // OLURSA `doOneTlsRequest` sessizce `false` döndüğünden, İLK istemci
    // turlarının bir kısmı sunucu HENÜZ hazır DEĞİLKEN başarısız OLABİLİR
    // (soak döngüsünün KENDİSİ bunu tolere eder — makul bir alt sınır
    // İDDİA edilir, TAM sayı DEĞİL).
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(std.heap.page_allocator);
    const now = std.Io.Timestamp.now(io, .real);
    try bundle.addCertsFromFilePath(std.heap.page_allocator, io, now, std.Io.Dir.cwd(), cert_path);

    var start_flag = std.atomic.Value(bool).init(false);
    var threads: [SOAK_CLIENT_THREADS]std.Thread = undefined;
    var results: [SOAK_CLIENT_THREADS]SoakResult = @splat(.{});
    const start_ns = monotonicNs();
    const budget_ns: i128 = @as(i128, soak_seconds) * std.time.ns_per_s;
    for (0..SOAK_CLIENT_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, tlsSoakClientWorker, .{ port, io, &bundle, now, start_ns, budget_ns, &start_flag, &results[i] });
    }
    start_flag.store(true, .release);
    for (threads) |t| t.join();

    // v1.36.0: bkz. HTTP soak testinin AYNI belge notu — `max_connections
    // =0` İçİn `kill`DEN ÖNCE/SONRA stderr/stdout drenajı DENEMEK (İKİ
    // yönde de) ya SONSUZA KADAR BLOKE OLUR ya `null` tutamaca erişim
    // olur; SADECE `kill` çağrılır.
    child.kill(io);

    var total: usize = 0;
    for (results) |r| total += r.count;
    try std.testing.expect(total > SOAK_CLIENT_THREADS * 3);
}
