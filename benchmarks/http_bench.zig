//! noxhttpbench — `nox.http.serve` için basit bir verim (throughput) ölçümü.
//!
//! `benchmarks/run.zig`nin (tek bir sürecin baştan sona duvar-saati süresini
//! ölçen) aksine, BURADA ölçülen şey UZUN SÜRE çalışan bir sunucu sürecinin
//! GERÇEK ağ isteklerini ne HIZDA işlediğidir — bu yüzden AYRI bir
//! yürütülebilir/derleme adımı (`zig build bench-http`) olarak tutuldu.
//!
//! Yöntem: `nox.http.serve(port, handle, N)` kullanan GERÇEK bir `.nox`
//! sunucu programı `noxc` ile derlenip arka planda başlatılır; `T` istemci
//! iş parçacığı, HER BİRİ `N/T` isteği SIRAYLA (bağlan → gönder → yanıtı
//! oku → bağlantıyı kapat — sunucunun KENDİSİ zaten bağlantı başına TEK
//! istek işleyip kapatacak şekilde tasarlı, bkz. `connectionEntry`) atar.
//! Ölçülen süre YALNIZCA istemcilerin çalıştığı ARALIKTIR (sunucunun
//! derleme/başlatma süresi HARİÇ). Rapor: toplam istek, geçen süre,
//! istek/saniye, ortalama gecikme.
//!
//! **Hız için:** `zig build bench-http -Doptimize=ReleaseFast` kullanın —
//! Debug modunda `DebugAllocator` (bkz. `benchmarks/run.zig`nin AYNI notu)
//! sayıları YAPAY OLARAK YAVAŞ gösterir.
//!
//! Proje kökünden çalıştırılmalıdır (`zig-out/bin/noxc`/`zig-out/lib/noxrt.o`ya
//! göreli yollar kullanır).

const std = @import("std");
const posix = std.posix;

const TOTAL_REQUESTS: usize = 4000;
const CLIENT_THREADS: usize = 20;
const REQUESTS_PER_THREAD: usize = TOTAL_REQUESTS / CLIENT_THREADS;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    try out.writeAll("nox.http.serve verim (throughput) ölçümü\n");
    try out.writeAll("=========================================\n");
    try out.print("istek sayısı: {d}, istemci iş parçacığı: {d}\n\n", .{ TOTAL_REQUESTS, CLIENT_THREADS });
    try out.flush();

    const port = try probeFreePort();

    const source = try std.fmt.allocPrint(gpa,
        \\import nox.http
        \\
        \\def handle(req: nox_http_HttpRequest) -> nox_http_HttpResponse:
        \\    return nox_http_HttpResponse(200, "ok", {{"x": "x"}})
        \\
        \\nox.http.serve({d}, handle, {d})
        \\
    , .{ port, TOTAL_REQUESTS });
    defer gpa.free(source);

    const nox_path = "benchmarks/.http_bench_gen.nox";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = nox_path, .data = source });

    try out.writeAll("derleniyor...\n");
    try out.flush();
    const compile_result = try std.process.run(gpa, io, .{
        .argv = &.{ "zig-out/bin/noxc", nox_path },
    });
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);
    if (compile_result.term != .exited or compile_result.term.exited != 0) {
        try out.print("DERLEME BAŞARISIZ:\n{s}\n", .{compile_result.stderr});
        std.process.exit(1);
    }

    const bin_path = "benchmarks/.http_bench_gen";

    try out.writeAll("sunucu başlatılıyor...\n");
    try out.flush();

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .stdout = .pipe,
        .stderr = .pipe,
    });

    // İstemci soketlerinin sunucuya karşı GERÇEKTEN eşzamanlı çalışması
    // İÇİN önce TÜM iş parçacıkları oluşturulur — `Thread.spawn`ın KENDİSİ
    // bir miktar zaman alabileceğinden, saat YALNIZCA hepsi hazır olduktan
    // sonra BAŞLATILIR (bkz. aşağıdaki `start_flag` — bu Zig sürümünde
    // `std.Thread.ResetEvent` YOK, bu yüzden basit bir atomik bayrak +
    // spin-wait kullanılıyor; çok kısa bir bekleme olduğundan kabul edilebilir).
    var start_flag = std.atomic.Value(bool).init(false);
    var threads: [CLIENT_THREADS]std.Thread = undefined;
    var results: [CLIENT_THREADS]ThreadResult = undefined;
    for (0..CLIENT_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, clientWorker, .{ port, REQUESTS_PER_THREAD, &start_flag, &results[i] });
    }

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    start_flag.store(true, .release);
    for (threads) |t| t.join();
    const end = std.Io.Clock.Timestamp.now(io, .awake);

    const elapsed_ns: f64 = @floatFromInt(start.durationTo(end).raw.nanoseconds);
    const elapsed_s = elapsed_ns / 1_000_000_000.0;

    var total_ok: usize = 0;
    for (results) |r| total_ok += r.ok_count;

    // `stdout`/`stderr` `child.wait()`DEN ÖNCE okunmalı — Zig 0.16'da
    // `wait()` bu tutamaçları `null`a çeviriyor (bkz. `tests/compat/
    // http_serve_golden_test.zig`nin AYNI notu). Sunucu bu benchmarkta HİÇ
    // `print` çağırmadığından stdout boş kalır, yine de tutarlılık için
    // TÜKETİLİR.
    var stderr_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
    const stderr_data = try stderr_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(stderr_data);

    var discard_buf: [4096]u8 = undefined;
    var stdout_reader2 = child.stdout.?.reader(io, &discard_buf);
    const stdout_leftover = try stdout_reader2.interface.allocRemaining(gpa, .unlimited);
    gpa.free(stdout_leftover);

    const term = try child.wait(io);

    try out.print("\nsunucu çıkış kodu: {any}\n", .{term});
    if (stderr_data.len != 0) {
        try out.print("sunucu stderr'e yazdı (olası hata/sızıntı):\n{s}\n", .{stderr_data});
    }

    try out.print("\nbaşarılı istek: {d}/{d}\n", .{ total_ok, TOTAL_REQUESTS });
    try out.print("geçen süre: {d:.3}s\n", .{elapsed_s});
    try out.print("verim: {d:.0} istek/saniye\n", .{@as(f64, @floatFromInt(total_ok)) / elapsed_s});
    try out.print("ortalama gecikme: {d:.3}ms\n", .{(elapsed_s * 1000.0) / @as(f64, @floatFromInt(@max(total_ok, 1))) * @as(f64, @floatFromInt(CLIENT_THREADS))});
    try out.flush();

    std.Io.Dir.cwd().deleteFile(io, nox_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, bin_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, "benchmarks/.http_bench_gen.ssa") catch {};
    std.Io.Dir.cwd().deleteFile(io, "benchmarks/.http_bench_gen.s") catch {};

    if (total_ok != TOTAL_REQUESTS) std.process.exit(1);
}

const ThreadResult = struct {
    ok_count: usize = 0,
};

fn clientWorker(port: u16, count: usize, start_flag: *std.atomic.Value(bool), result: *ThreadResult) void {
    while (!start_flag.load(.acquire)) std.Thread.yield() catch {};
    var ok: usize = 0;
    for (0..count) |_| {
        if (doOneRequest(port)) ok += 1;
    }
    result.ok_count = ok;
}

fn doOneRequest(port: u16) bool {
    const fd = testConnect(port) catch return false;
    defer _ = std.c.close(fd);

    const req = "GET /bench HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    var off: usize = 0;
    while (off < req.len) {
        const n = std.c.write(fd, req[off..].ptr, req.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }

    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        total += @intCast(n);
    }
    return total > 0;
}

/// Sunucu (çocuk süreç) henüz `listen()`e ULAŞMAMIŞ olabilir — bağlantı
/// BAŞARILI olana kadar kısa aralıklarla YENİDEN dener (bkz.
/// `tests/compat/http_serve_golden_test.zig`nin AYNI adlı fonksiyonu —
/// kasıtlı tekrar, AYRI bir dosya/derleme birimi).
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
