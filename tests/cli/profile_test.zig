//! Faz F.2 (bkz. plan dosyası "capability sistemi"): `noxc build/check
//! --profile <hosted|freestanding>`nin uçtan-uca davranışını, GERÇEK
//! `noxc` alt süreciyle (`tests/cli/explain_test.zig`nin AYNI deseni)
//! doğrular — HER senaryo GERÇEK module_loader birleştirmesinden (bkz.
//! `compiler/module_loader.zig`nin `loadImportsRecursive`ı) GEÇTİĞİNDEN,
//! bu testler `tests/golden/typecheck_golden_test.zig`nin (tek dosya,
//! HİÇ stdlib birleştirmesi YAPMAYAN) SAF tip-kontrolü testlerinin
//! KAPSAYAMADIĞI "transitif yakalama" mekanizmasını da (bkz. plan dosyası
//! "Kritik bulgu") GERÇEKTEN kanıtlar.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn writeTempSource(gpa: std.mem.Allocator, io: std.Io, source: []const u8, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    return std.fmt.allocPrint(gpa, "{s}/prog.nox", .{path_buf[0..len]});
}

test "noxc check --profile freestanding: izin verilen bir stdlib modülü (nox.strings) checker aşamasında KABUL EDİLİR" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.strings
        \\
        \\parts: list[str] = nox.strings.split("a,b,c", ",")
        \\print(len(parts))
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

// Faz R.3+F.1 tamamlama (bkz. plan dosyası "Faz R.3 + F.1'in
// tamamlanması"): `noxc build --profile freestanding` ARTIK (bu fazDAN
// ÖNCE hiç yapmadığı şekilde) GERÇEKTEN `runtime/lib_freestanding.zig`ye
// karşı LİNKLER — F.2'nin "izin verilen" (checker-seviyesi) capability
// allowlist'i İLE "bu modülün Zig runtime'ı GERÇEKTEN freestanding hedefte
// DERLENİP LİNKLENEBİLİR" SORUSU BİLİNÇLİ olarak AYRI eksenlerdir (bkz.
// F.2'nin KENDİ "capability profili HOST hedefinden BAĞIMSIZ bir eksen"
// notu VE BU planın "Kapsam Dışı" bölümü: "stdlib_shims/* GERÇEKTEN
// freestanding-hedefte derlenebilir olup OLMADIĞI BU turda doğrulanmadı").
// `nox.strings`nin Zig shim'i (`runtime/stdlib_shims/strings.zig`)
// `lib_freestanding.zig`ye HİÇ dahil DEĞİLDİR (F.0.7'nin KENDİ, bilinçli
// dar kapsamı) — bu YÜZDEN checker'ı GEÇEN BU program, linklemede
// (`nox_strings_split_raw` GİBİ sembollerin `noxrt-freestanding.o`da
// bulunmaması YÜZÜNDEN) BAŞARISIZ OLMALIDIR — bu, GELECEKTEKİ bir fazın
// (`stdlib_shims/*`nin freestanding-uyumluluğunu TEK TEK doğrulayıp
// `lib_freestanding.zig`ye eklemesi) konusudur.
test "noxc build --profile freestanding: izin verilen bir stdlib modülü (nox.strings) checker'i GEÇER ama linkleme HENÜZ başarısız olur (stdlib_shims/* henüz lib_freestanding.zig'e dahil değil)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.strings
        \\
        \\parts: list[str] = nox.strings.split("a,b,c", ",")
        \\print(len(parts))
        \\
    , &tmp);
    defer gpa.free(path);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{path_buf[0..dir_len]});
    defer gpa.free(out_path);

    const build_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path, "-o", out_path } });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, build_result.stderr, "zig cc basarisiz") != null);
}

test "noxc build --profile freestanding: dogrudan yasakli bir modul (nox.http) reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.http
        \\
        \\print("hic calismamali")
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.http") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "kullan") != null);
}

test "noxc build --profile freestanding: TRANSITIF olarak yasakli bir modul (nox.router -> nox.http) reddedilir, hata 'nox.http'yi gosterir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.router
        \\
        \\print("hic calismamali")
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    // KRİTİK: mesaj `nox.router`i DEĞİL `nox.http`yi göstermeli — router'ın
    // KENDİ, transitif bağımlılığı `module_loader.zig`nin merged body'sine
    // router'ın KENDİ statement'larından ÖNCE eklenir (bkz. plan dosyasının
    // "Kritik bulgu"), bu YÜZDEN `collectImports` router'a HİÇ ULAŞMADAN
    // http'yi yakalar.
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.http") != null);
}

// v4 (Faz A madde 1, bkz. nox-teknik-spesifikasyon.md §3.2xx): capability
// modeline geçişin (`checker.zig`nin ESKİ 2 düz listesinin YERİNE `Modül →
// []Capability` tablosu) KENDİSİ, `nox.random`ın MODÜL-seviyesi capability
// kümesini BOŞ (`&.{}`) YAPTI — `random.nox`nin KENDİ `extern def`leri
// (seed/randint/random) OS-bağımsızdır. AMA `random.nox` KENDİ İÇİNDE
// `import nox.math` YAPAR (gaussian-benzeri fonksiyonlar İçİn sqrt/log/cos)
// — `nox.math`in `libc_math` capability'si freestanding'de SAĞLANMADIĞINDAN
// `nox.random` YİNE (TRANSİTİF olarak, `nox.router`->`nox.http`İLE AYNI
// mekanizma) reddedilir. BU test, `typecheck_golden_test.zig`nin (module_
// loader birleştirmesi YAPMAYAN) izole "nox.random dogrudan reddedilir"
// testinin ARTIK "OK" DÖNMESİNİN (modül-seviyesinde GERÇEKTEN capability-
// SİZ olduğu İçİn) bir REGRESYON OLMADIĞINI, GERÇEK uçtan-uca davranışın
// DEĞİŞMEDİĞİNİ kanıtlar.
test "noxc build --profile freestanding: nox.random TRANSITIF olarak (nox.math uzerinden) reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.random
        \\
        \\print("hic calismamali")
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.math") != null);
}

// v4 (Faz A madde 1): `@capability.requires("entropy")` — capability
// modelinin SEMBOL-seviyesi (alt-modül/fonksiyon) tarafı, MODÜL-seviyesi
// yukarıdaki testlerin AKSİNE. `nox.crypto`nin KENDİSİ HİÇBİR capability
// GEREKTİRMEZ (`sha256` GİBİ SAF hesaplama fonksiyonları HER profilde
// çalışır) — ama `secure_random_hex` GERÇEK OS entropisi istediğinden TEK
// BAŞINA işaretlenmiştir. Bu, ÖNERİNİN flagship örneğinin (`nox.crypto` vs
// `nox.crypto.random`) sembol-seviyesinde, HİÇBİR sembol yeniden adlandırma/
// TAŞIMA OLMADAN nasıl KARŞILANDIĞINI kanıtlar (madde 12'nin nyx/aether
// regresyonuyla AYNI hatayı TEKRARLAMAMAK İçİn BİLİNÇLİ bir tasarım kararı,
// bkz. proje belleği).
test "noxc build --profile freestanding: nox.crypto MODUL olarak serbest ama secure_random_hex CAGRISI capability eksikliginden reddedilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.crypto
        \\
        \\h: str = nox.crypto.secure_random_hex(16)
        \\print(h)
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "CapabilityNotGranted") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "entropy") != null);
}

test "noxc check --profile freestanding: nox.crypto.sha256 (capability-siz sembol) SERBESTCE kabul edilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.crypto
        \\
        \\h: str = nox.crypto.sha256("merhaba")
        \\print(h)
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", "--profile", "freestanding", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

test "noxc build (varsayilan profil = hosted): nox.http HALA serbestce kullanilabilir (regresyon-yok)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\import nox.router
        \\
        \\print("ok")
        \\
    , &tmp);
    defer gpa.free(path);

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const out_path = try std.fmt.allocPrint(gpa, "{s}/prog_bin", .{path_buf[0..dir_len]});
    defer gpa.free(out_path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", path, "-o", out_path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

test "noxc check --profile freestanding: izin verilen modul kabul, yasakli modul red (link gerekmeden)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const ok_path = try writeTempSource(gpa, io, "import nox.json\n\nprint(1)\n", &tmp);
        defer gpa.free(ok_path);
        const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", "--profile", "freestanding", ok_path } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
    }

    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    {
        const bad_path = try writeTempSource(gpa, io, "import nox.thread\n\nprint(1)\n", &tmp2);
        defer gpa.free(bad_path);
        const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "check", "--profile", "freestanding", bad_path } });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 1);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.thread") != null);
    }
}

test "noxc build --profile bilinmeyen-bir-isim: acik 'bilinmeyen profil' hatasiyla exit 1" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io, "print(1)\n", &tmp);
    defer gpa.free(path);

    const result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", "--profile", "bilinmeyen-bir-isim", path } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "bilinmeyen profil") != null);
}
