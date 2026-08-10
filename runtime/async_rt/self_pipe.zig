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

pub fn makeSelfPipe() ![2]posix.fd_t {
    if (builtin.os.tag == .windows) return error.Unsupported;
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

pub fn closeSelfPipeFd(fd: posix.fd_t) void {
    if (builtin.os.tag != .windows) _ = std.c.close(fd);
}

pub fn signalWakeFd(fd: posix.fd_t) void {
    if (builtin.os.tag != .windows) {
        var signal_byte = [_]u8{1};
        _ = std.c.write(fd, &signal_byte, 1);
    }
}

pub fn drainWakeFd(fd: posix.fd_t) void {
    if (builtin.os.tag != .windows) {
        var buf: [1]u8 = undefined;
        _ = std.c.read(fd, &buf, 1);
    }
}
