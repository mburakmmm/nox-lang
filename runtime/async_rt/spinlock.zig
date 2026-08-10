//! Faz MN.4/5.8: `SpinLock`in TEK doğruluk kaynağı (Faz P1.2'nin AYNI
//! ilkesi) — ÖNCEDEN `runtime/alloc/asap.zig`nin İÇİNDE tanımlıydı, BURAYA
//! taşındı: `scheduler.zig`nin (Faz MN.4/5.5, `Scheduler.ready_lock`)
//! `asap.SpinLock`ı KULLANABİLMESİ İçİn `../alloc/asap.zig`yi İTHAL ETMESİ
//! GEREKİYORDU — AMA `fiber.zig`/`scheduler.zig`/`channel.zig`/`io.zig`
//! BİLİNÇLİ olarak `runtime/alloc/`den (dolayısıyla `runtime/stdlib_shims`den)
//! BAĞIMSIZ kalacak şekilde tasarlanmıştır (bkz. `build.zig`nin `async-rt-
//! test` adımı — Windows CI'ın `windows-frontend` işinin ÇAĞIRDIĞI, `noxrt`in
//! TAMAMINI BEKLEMEDEN SADECE fiber/reaktör/zamanlayıcı katmanını doğrulayan
//! İZOLE hedef) — `scheduler.zig`nin `../alloc/asap.zig` İTHAL ETMESİ bu
//! standalone hedefi (VE `runtime/async_rt/scheduler.zig`yi KENDİ modül
//! KÖKÜ olarak kullanan `scheduler_test`/`channel_test`i) "import of file
//! outside module path" hatasıyla KIRDI (GERÇEKTEN denenip DOĞRULANDI).
//! `SpinLock`ın KENDİSİ zaten `runtime/alloc/`e/`stdlib_shims`e HİÇBİR
//! bağımlılığı OLMAYAN saf bir `std.atomic` sarmalayıcısı OLDUĞUNDAN,
//! `runtime/async_rt/` İÇİNE (scheduler.zig'in KENDİ dizinine, SIFIR
//! yeni sınır-aşımı İLE) taşınması doğru çözümdür — `asap.zig` BUNU
//! `../async_rt/spinlock.zig` ÜZERİNDEN İTHAL EDİP `pub const SpinLock`
//! olarak YENİDEN DIŞA AÇAR (mevcut `asap.SpinLock` kullanım siteleri —
//! `thread_channel.zig`, `RuntimeState`nin `*_lock` alanları — SIFIR
//! değişiklik GÖRÜR).

const std = @import("std");

pub const SpinLock = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};
