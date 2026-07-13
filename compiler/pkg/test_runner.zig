//! Faz O §P.3 (bkz. plan dosyası "Faz O" bölümü, nox-teknik-spesifikasyon.md
//! §3.6): `noxc test`in gerçek `*_test.nox` keşif kuralı. P.2'nin geçici
//! "tek dosya = `run` ile aynı" davranışının YERİNİ (yalnızca bir dizin/CWD
//! hedeflendiğinde) alır — tek bir `.nox` dosyası verildiğinde P.2'nin
//! basit davranışı (`main.zig`'in `cmdTest`i) KORUNUR.
//!
//! **Bilinçli olarak SALT KEŞİF (derleme/çalıştırma İÇERMEZ):** bu dosya
//! `qbe`/`cc` alt süreçlerine ya da `buildOne`e HİÇ dokunmaz — yalnızca
//! dosya sistemini gezip `*_test.nox` ile biten dosyaların MUTLAK yollarını
//! döner. Gerçek derleme+çalıştırma+özet orkestrasyonu `main.zig`'in
//! `cmdTest`inde yaşar (`buildOne`, `main.zig`'e ÖZEL bir fonksiyon
//! olduğundan, dairesel import'tan KAÇINMAK için).

const std = @import("std");

/// `root` (MUTLAK yol, bir DİZİN olmalı) altında `*_test.nox` ile biten
/// TÜM dosyaları özyinelemeli olarak bulur, MUTLAK yollarını döner. Sıra
/// TANIMSIZDIR (bkz. `std.Io.Dir.walk`'ın kendi notu) — çağıran sırayla
/// İLGİLENİYORSA (ör. deterministik test çıktısı İÇİN) kendi sıralamasını
/// uygulamalıdır.
pub fn discoverTestFiles(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]const []const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, "_test.nox")) continue;
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.path });
        try files.append(a, full);
    }
    return files.items;
}
