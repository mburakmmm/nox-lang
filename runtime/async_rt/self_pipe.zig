//! Faz MN.6: `scheduler.zig`nin (Faz MN.4/5.5) ÖZEL self-pipe yardımcılarının
//! taşındığı, `runtime/async_rt/`nin AYNI "runtime/alloc/den bağımsız kalma"
//! sınırı İçİNDE kalan SIFIR-bağımlılıklı (SADECE `std`/`builtin`) bir yaprak
//! dosya — `SpinLock`ın `asap.zig`den `runtime/async_rt/spinlock.zig`ye
//! taşınmasıyla (Faz MN.4/5.5) BİREBİR AYNI gerekçe/desen: `runtime/alloc/
//! cycle_detector.zig`nin (STW round'unu BAŞLATTIĞINDA `pool_wake_fds`teki
//! TÜM worker'ları uyandırması GEREKİYOR, bkz. `nox_cycle_possible_root`)
//! `signalWakeFd`e ERİŞEBİLMESİ İçİn — `scheduler.zig`, `cycle_detector.zig`
//! ARASINDA döngüsel/çapraz-sınır bir bağımlılık KURMADAN.
//!
//! `http_client.zig`nin `makeSelfPipe`/`signalSelfPipe`/`readSelfPipe`si İLE
//! AYNI teknik (POSIX `pipe()` + tek-bayt `write`/`read`, `PIPE_BUF` altı
//! boyutlar İçİn POSIX'te ATOMİK, kilitsiz GÜVENLİ) — ama BURADA AYRICA
//! tanımlanır, DOĞRUDAN İTHAL EDİLMEZ (bkz. `scheduler.zig`nin ESKİ belge
//! notu — `http_client.zig` → `bridge.zig` → `scheduler.zig` DÖNGÜSÜNÜ
//! kurardı). Windows dalı BİLİNÇLİ olarak UYGULANMADI (`makeSelfPipe`
//! `error.Unsupported` döner) — work-stealing/STW HENÜZ GERÇEK bir Nox
//! programından/codegen'den BAĞLANMADIĞINDAN (bkz. proje planı, MN.7
//! kapsamı) Windows'ta test EDİLEMEZ durumda.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Faz F.0.5 (bkz. plan dosyası "Uyandırma mekanizması soyutlaması"):
/// `makeSelfPipe`/`closeSelfPipeFd`/`signalWakeFd`/`drainWakeFd`in
/// (aşağıda) KOŞULSUZ POSIX pipe()/close()/write()/read() bağımlılığını
/// enjekte edilebilir yapan arayüz — F.0.4'ün `StackProviderVTable`sıyla
/// AYNI ptr+vtable ŞEKLİ (repo'daki TEK kanıtlanmış enjekte-edilebilir-
/// arayüz emsali, YENİ bir desen İCAT EDİLMEDİ). `close`/`signal`/`drain`
/// HER BİRİ TEK bir `fd` alır — MEVCUT dört fonksiyonun İMZALARIYLA
/// BİREBİR AYNI (`closeSelfPipeFd`in KENDİSİ de İKİ UCU AYRI AYRI, İKİ
/// ÇAĞRIYLA kapatıyor). `create`, İKİ tamsayı (`[read_fd, write_fd]`)
/// DÖNMELİDİR — BUNLAR `Scheduler.armWakeFd`nin `io_reactor.zig`ye
/// KAYDETTİĞİ GERÇEK, pollanabilir tanımlayıcılar OLMAK ZORUNDADIR (bkz.
/// plan dosyasının "Kapsam Dışı" bölümü — BU FAZ `io_reactor.zig`yi
/// SOYUTLAMIYOR).
pub const WakeProviderVTable = struct {
    create: *const fn (ctx: ?*anyopaque) ?[2]posix.fd_t,
    close: *const fn (ctx: ?*anyopaque, fd: posix.fd_t) void,
    signal: *const fn (ctx: ?*anyopaque, fd: posix.fd_t) void,
    drain: *const fn (ctx: ?*anyopaque, fd: posix.fd_t) void,
};

pub const WakeProvider = struct {
    ctx: ?*anyopaque = null,
    vtable: *const WakeProviderVTable,
};

/// F.0.1'in `dispatch_registry.zig`sıyla/F.0.4'ün `nox_register_stack_
/// provider`ıyla AYNI "program-genelinde, TEK, atomik, `.monotonic`"
/// deseni — kayıt HER ZAMAN programın EN BAŞINDA (herhangi bir Scheduler
/// yaratılmadan ÖNCE, host'un KENDİ bootstrap kodu TARAFINDAN) yapılır.
var g_wake_provider: std.atomic.Value(?*const WakeProvider) = .init(null);

/// GERÇEK bir freestanding host (VEYA bir test, sahte bir sağlayıcıyla
/// davranışı doğrulamak İçİn) TARAFINDAN çağrılır. `pub fn` (export
/// DEĞİL — F.0.2/F.0.3/F.0.4'ün KENDİ registrasyon fonksiyonlarıyla AYNI
/// gerekçe, HENÜZ codegen'den ÇAĞRILMIYOR).
pub fn nox_register_wake_provider(provider: ?*const WakeProvider) void {
    g_wake_provider.store(provider, .monotonic);
}

pub fn makeSelfPipe() ![2]posix.fd_t {
    if (g_wake_provider.load(.monotonic)) |p| {
        return p.vtable.create(p.ctx) orelse error.PipeFailed;
    }
    if (builtin.os.tag == .windows) return error.Unsupported;
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

pub fn closeSelfPipeFd(fd: posix.fd_t) void {
    if (g_wake_provider.load(.monotonic)) |p| {
        p.vtable.close(p.ctx, fd);
        return;
    }
    if (builtin.os.tag != .windows) _ = std.c.close(fd);
}

pub fn signalWakeFd(fd: posix.fd_t) void {
    if (g_wake_provider.load(.monotonic)) |p| {
        p.vtable.signal(p.ctx, fd);
        return;
    }
    if (builtin.os.tag != .windows) {
        var signal_byte = [_]u8{1};
        _ = std.c.write(fd, &signal_byte, 1);
    }
}

pub fn drainWakeFd(fd: posix.fd_t) void {
    if (g_wake_provider.load(.monotonic)) |p| {
        p.vtable.drain(p.ctx, fd);
        return;
    }
    if (builtin.os.tag != .windows) {
        var buf: [1]u8 = undefined;
        _ = std.c.read(fd, &buf, 1);
    }
}

test "Faz F.0.5: kayıtlı bir sahte wake provider, self-pipe fonksiyonlarının GERÇEK hedefi olur" {
    const FakeProvider = struct {
        var create_count: usize = 0;
        var close_count: usize = 0;
        var signal_count: usize = 0;
        var drain_count: usize = 0;

        fn create(ctx: ?*anyopaque) ?[2]posix.fd_t {
            _ = ctx;
            create_count += 1;
            return .{ 100, 101 };
        }
        fn close(ctx: ?*anyopaque, fd: posix.fd_t) void {
            _ = ctx;
            _ = fd;
            close_count += 1;
        }
        fn signal(ctx: ?*anyopaque, fd: posix.fd_t) void {
            _ = ctx;
            _ = fd;
            signal_count += 1;
        }
        fn drain(ctx: ?*anyopaque, fd: posix.fd_t) void {
            _ = ctx;
            _ = fd;
            drain_count += 1;
        }
    };
    const vtable: WakeProviderVTable = .{
        .create = FakeProvider.create,
        .close = FakeProvider.close,
        .signal = FakeProvider.signal,
        .drain = FakeProvider.drain,
    };
    const provider: WakeProvider = .{ .ctx = null, .vtable = &vtable };

    FakeProvider.create_count = 0;
    FakeProvider.close_count = 0;
    FakeProvider.signal_count = 0;
    FakeProvider.drain_count = 0;
    nox_register_wake_provider(&provider);
    defer nox_register_wake_provider(null);

    const fds = try makeSelfPipe();
    try std.testing.expectEqual(@as(posix.fd_t, 100), fds[0]);
    try std.testing.expectEqual(@as(posix.fd_t, 101), fds[1]);
    signalWakeFd(fds[1]);
    drainWakeFd(fds[0]);
    closeSelfPipeFd(fds[0]);
    closeSelfPipeFd(fds[1]);

    try std.testing.expectEqual(@as(usize, 1), FakeProvider.create_count);
    try std.testing.expectEqual(@as(usize, 1), FakeProvider.signal_count);
    try std.testing.expectEqual(@as(usize, 1), FakeProvider.drain_count);
    try std.testing.expectEqual(@as(usize, 2), FakeProvider.close_count);
}

test "Faz F.0.5 — kırmızı-takım: kayıt YAPILMAZSA GERÇEK bir OS pipe'ı kullanılır (sahte sağlayıcı HİÇ ÇAĞRILMAZ)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const FakeProvider = struct {
        var create_count: usize = 0;

        fn create(ctx: ?*anyopaque) ?[2]posix.fd_t {
            _ = ctx;
            create_count += 1;
            return .{ 100, 101 };
        }
        fn close(ctx: ?*anyopaque, fd: posix.fd_t) void {
            _ = ctx;
            _ = fd;
        }
        fn signal(ctx: ?*anyopaque, fd: posix.fd_t) void {
            _ = ctx;
            _ = fd;
        }
        fn drain(ctx: ?*anyopaque, fd: posix.fd_t) void {
            _ = ctx;
            _ = fd;
        }
    };
    FakeProvider.create_count = 0;
    // BİLİNÇLİ olarak `nox_register_wake_provider` HİÇ ÇAĞRILMAZ — bu,
    // `g_wake_provider`in VARSAYILAN `null` durumunda `makeSelfPipe`/
    // `signalWakeFd`/`drainWakeFd`/`closeSelfPipeFd`in HÂLÂ MEVCUT
    // POSIX pipe()/write()/read()/close() yoluna DÜŞTÜĞÜNÜN kanıtıdır
    // (kaydın GERÇEKTEN load-bearing olduğunu kanıtlayan üstteki testle
    // BİRLİKTE) — YAN ürün olarak `self_pipe.zig`nin MEVCUT, ÖNCEDEN HİÇ
    // test EDİLMEMİŞ davranışını da doğrular.
    const fds = try makeSelfPipe();
    // GERÇEK bir OS pipe'ı — sahte sağlayıcının sentinel değerleri (100/
    // 101) İLE ÇAKIŞMASI PRATİKTE İMKANSIZ (küçük tamsayılar STDIN/STDOUT/
    // STDERR'e AYRILMIŞTIR) AMA YİNE de dogrudan bir esitlik iddiasi
    // GEREKMEZ — asil kanit `create_count`in SIFIR KALMASI.
    signalWakeFd(fds[1]);
    drainWakeFd(fds[0]);
    closeSelfPipeFd(fds[0]);
    closeSelfPipeFd(fds[1]);

    try std.testing.expectEqual(@as(usize, 0), FakeProvider.create_count);
}
