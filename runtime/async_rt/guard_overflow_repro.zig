//! Faz MN.8, Bulgu C — `fiber.zig`nin (`allocGuardedStack`/`freeGuardedStack`)
//! guard-page güvenlik ağının GERÇEK, GÖZLEMLENEBİLİR bir çökme İLE
//! DOĞRULANMASI İçİn KASITLI olarak yığın taşıran, AYRI bir çalıştırılabilir
//! üreten fixture. `fiber.zig`nin KENDİ testinden (bkz. "Faz MN.8, Bulgu C:
//! ...") AYRI bir SÜREÇ olarak (`zig build-exe` + çalıştır) çağrılır —
//! taşma İçİNDE ÇALIŞTIĞIMIZ test binary'sinin KENDİSİNİ çökertirdi,
//! İZOLASYON bu YÜZDEN ZORUNLU.
const std = @import("std");
const fiber = @import("fiber.zig");

/// `+1` (çağrıdan SONRA) kuyruk-çağrısı (tail-call) OPTİMİZASYONUNU
/// engeller — DERİN, GERÇEK bir özyineleme yığını GEREKİR, düz bir
/// döngüye İNDİRGENEMEZ.
fn recurseDeep(depth: usize) usize {
    var buf: [4096]u8 = undefined;
    std.mem.doNotOptimizeAway(&buf);
    if (depth == 0) return 0;
    return recurseDeep(depth - 1) + 1;
}

fn entry(arg: *anyopaque) void {
    _ = arg;
    _ = recurseDeep(1_000_000);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const f = try fiber.Fiber.create(allocator, entry, undefined);
    var root_ctx: fiber.Context = .{};
    f.resume_(&root_ctx);
    // BURAYA ulaşılması BEKLENMEZ — guard page taşmayı BELİRLİ bir
    // erişim-ihlaline dönüştürmeliydi. Ulaşılırsa, çağıran test bunu
    // (temiz çıkış kodu 0) BAŞARISIZLIK olarak yorumlar.
    std.debug.print("UNEXPECTED: overflow did not crash\n", .{});
}
