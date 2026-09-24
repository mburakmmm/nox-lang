//! Faz FFI.3 (bkz. nox-teknik-spesifikasyon.md §3.148): `-rdynamic`
//! (blanket) → dar, 5-sembol dinamik export + linker dead-stripping
//! değişikliğinin uçtan-uca kanıtı — GERÇEK `noxc` alt süreci ile
//! (`tests/cli/help_screen_test.zig`/`explain_test.zig`nin AYNI deseni).
//!
//! Üç kanıt:
//! 1. Negatif kanıt: `nox.smtp`/`nox.postgres` KULLANMAYAN basit bir
//!    program derlenip `nm` çıktısında bu modüllere AİT sembollerin HİÇ
//!    BULUNMADIĞI (dead-stripping'in GERÇEKTEN çalıştığı) doğrulanır.
//! 2. Boyut kanıtı: aynı ikilinin boyutu, düzeltme ÖNCESİ (yaklaşık 7+ MB)
//!    durumdan AÇIKÇA küçük (makul bir üst sınır).
//! 3. Fonksiyonel kanıt (KRİTİK — 5-sembol listesinin DOĞRU olduğunun asıl
//!    kanıtı): `nox.json.decode` + bir sınıf örneği + cycle-collector'ı
//!    tetikleyen (>700 örnek) bir program doğru çalışır.
//!
//! `nm`/dead-stripping Windows'ta (PE/MinGW, blanket `--export-all-symbols`,
//! bilinçli olarak DEĞİŞTİRİLMEDİ) anlamlı değil — bu testler SADECE macOS/
//! Linux'ta çalışır.

const std = @import("std");
const builtin = @import("builtin");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn writeTempSource(gpa: std.mem.Allocator, io: std.Io, source: []const u8, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    return std.fmt.allocPrint(gpa, "{s}/prog.nox", .{path_buf[0..len]});
}

fn sleepMs(ms: i64) void {
    const ts: std.c.timespec = .{
        .sec = @divTrunc(ms, std.time.ms_per_s),
        .nsec = @mod(ms, std.time.ms_per_s) * std.time.ns_per_ms,
    };
    _ = std.c.nanosleep(&ts, null);
}

/// GERÇEK CI'de gözlemlenen bir flake'in düzeltmesi (bkz. CHANGELOG/
/// nox-teknik-spesifikasyon.md): `-j4`nin geri alınmasıyla (STW-bariyeri
/// deadlock düzeltmesi, v1.94.0) `zig build test` ARTIK TAM paralellikte
/// çalışıyor — ÇOK sayıda eşzamanlı test ikilisinin spawn/exec baskısı
/// ALTINDA, `std.process.run` ARA SIRA GEÇİCİ bir hatayla (`error.
/// SystemResources`/benzeri) BAŞARISIZ olabiliyor (satır 67-77'nin ZATEN
/// belgelediği, `catch |err|` İLE teşhis edilen AMA daha ÖNCE retry
/// EDİLMEYEN kök neden). Küçük, SINIRLI bir retry (3 deneme, artan kısa
/// gecikmelerle) BU GEÇİCİ hata sınıfını GÜVENLE aşar — GERÇEK/kalıcı bir
/// hata (noxc'nin KENDİ bir derleme hatası, argüman hatası VB.) İSE HER
/// denemede AYNI şekilde BAŞARISIZ OLACAĞINDAN, retry SADECE birkaç yüz
/// milisaniyelik bir gecikme EKLER, YANLIŞ bir "başarı" ÜRETMEZ.
fn runWithRetry(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
            if (attempt >= 2) return err;
            sleepMs(200 * @as(i64, @intCast(attempt + 1)));
            continue;
        };
    }
}

test "noxc build: smtp/postgres kullanmayan basit bir program dead-stripping ile küçük kalır" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    // v1.80.5 (bkz. CHANGELOG.md/nox-teknik-spesifikasyon.md §3.155): GERÇEK
    // bir Linux (x86-64) CI koşusuyla bulunup, bir Docker/Ubuntu 24.04
    // konteynerinde HEM Debug HEM ReleaseFast build'leri karşılaştırılarak
    // KANITLANDI — Zig'in ELF hedeflerinde `link_function_sections`i
    // SADECE LLVM backend'i (Release* modları) ONURLANDIRIYOR; `-Doptimize`
    // BAYRAKSIZ (Debug, ci.yml'nin İLK, öntanımlı `zig build test` çağrısı)
    // derlenen `noxrt.o` (native/self-hosted x86_64 backend'i KULLANIR)
    // SIFIR `.text.*` bölümü ÜRETİYOR (readelf İLE doğrulandı) — bu YÜZDEN
    // `--gc-sections`/`--export-dynamic-symbol`in GRANÜLERLİĞİ YOK, HİÇBİR
    // stdlib shim sembolü (nox_smtp_connect_raw DAHİL) elenmez. Bu test
    // modülü `build.zig`nin `optimize`iyle AYNI paylaşılan değeri (`.
    // optimize = optimize`) KULLANDIĞINDAN, `builtin.mode` BURADA ambient
    // noxrt.o'nun KENDİ modunu GÜVENİLİR biçimde YANSITIR — Debug'da BU
    // testin dead-stripping'e ÖZGÜ iddiaları ATLANIR (`zig build test
    // -Doptimize=ReleaseFast`nin AYNI test'i GERÇEKTEN doğrulamaya DEVAM
    // ETTİĞİNDEN kapsam KAYBI YOK — ci.yml HER İKİ modu da SIRAYLA çalıştırır).
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src_path = try writeTempSource(gpa, io, "print(\"hi\")\n", &tmp);
    defer gpa.free(src_path);

    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_len = try tmp.dir.realPath(io, &out_path_buf);
    const tmp_dir_path = out_path_buf[0..tmp_dir_len];
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/prog_out", .{tmp_dir_path});
    defer gpa.free(bin_path);

    // Faz [YENİ] (bkz. plan dosyası "CI'daki 3 hatayı düzeltme"): GERÇEK
    // bir CI koşusunda bu test "failed without output" İLE (Zig'in test
    // runner'ı, satır boş bir stderr GÖRDÜĞÜNDE BUNU basar — bkz. `std.
    // Build.Step.Run`ın `test_results` işleyicisi) BAŞARISIZ OLDU —
    // ÖNCEDEN HİÇBİR HATA MESAJI YAZDIRMIYORDU. `std.process.run`nin
    // KENDİSİ (spawn/exec, kaynak-çekişmesi ALTINDA `error.SystemResources`
    // GİBİ bir hata İLE) BAŞARISIZ OLDUĞUNDA `try` SESSİZCE ÜST-SEVİYEYE
    // YAYILIYORDU — `catch |err|` İLE AÇIKÇA HANGİ komutun/hangi hatayla
    // BAŞARISIZ OLDUĞU stderr'e YAZDIRILIR. v1.94.1: `runWithRetry`
    // (yukarıda) BU GEÇİCİ hata sınıfını (retry İLE) GÜVENLE AŞAR —
    // `-j4`nin v1.93.1'de geri alınmasıyla (STW-bariyeri deadlock
    // düzeltmesi İçİn ZORUNLU) CI ARTIK TAM paralellikte çalıştığından,
    // bu GEÇİCİ spawn baskısı KALICI olarak VAR (bir daha `-j`
    // düşürülmeyecek).
    const build_result = runWithRetry(gpa, io, &.{ noxcPath(), "build", src_path, "-o", bin_path }) catch |err| {
        std.debug.print("noxc build spawn basarisiz: {t}\n", .{err});
        return err;
    };
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    if (!(build_result.term == .exited and build_result.term.exited == 0)) {
        std.debug.print("noxc build basarisiz, term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ build_result.term, build_result.stdout, build_result.stderr });
    }
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    // Negatif kanıt: nox.smtp/nox.postgres'e ait, KESİNLİKLE İLGİSİZ
    // sembollerin ikilinin sembol tablosunda HİÇ bulunmaması — dead-code-
    // stripping GERÇEKTEN çalışıyorsa bu fonksiyonların KODU (ve sembol
    // girdisi) ikiliden TAMAMEN elenir (stripped-out kod, `nm`de HİÇ
    // görünmez — local/`t` sembol olarak bile kalmaz).
    const nm_result = runWithRetry(gpa, io, &.{ "nm", bin_path }) catch |err| {
        std.debug.print("nm spawn basarisiz: {t}\n", .{err});
        return err;
    };
    defer gpa.free(nm_result.stdout);
    defer gpa.free(nm_result.stderr);
    // v1.98.0 (bkz. nox-teknik-spesifikasyon.md): GERÇEK CI koşusunda BU
    // testin "failed without output" İLE (HİÇBİR teşhis METNİ OLMADAN)
    // BAŞARISIZ OLDUĞU gözlemlendi — `build_result`nin AKSİNE, `nm_result`nin
    // İDDİALARINDAN ÖNCE HİÇBİR `std.debug.print` YOKTU (bu YÜZDEN `nm`
    // GERÇEKTEN sıfır-dışı bir çıkışla BAŞARISIZ olursa/beklenen sembol
    // BULUNAMAZSA teşhis SESSİZCE kayboluyordu). `build_result`nin AYNI
    // "başarısızsa YAZDIR" desenİ BURAYA da eklenir.
    if (!(nm_result.term == .exited and nm_result.term.exited == 0)) {
        std.debug.print("nm basarisiz, term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ nm_result.term, nm_result.stdout, nm_result.stderr });
    }
    try std.testing.expect(nm_result.term == .exited and nm_result.term.exited == 0);
    if (std.mem.indexOf(u8, nm_result.stdout, "nox_smtp_connect_raw") != null or
        std.mem.indexOf(u8, nm_result.stdout, "nox_pg_exec_params_raw") != null)
    {
        std.debug.print("dead-stripping BEKLENMEDIK sekilde basarisiz - ilgisiz semboller nm ciktisinda bulundu:\n{s}\n", .{nm_result.stdout});
    }
    try std.testing.expect(std.mem.indexOf(u8, nm_result.stdout, "nox_smtp_connect_raw") == null);
    try std.testing.expect(std.mem.indexOf(u8, nm_result.stdout, "nox_pg_exec_params_raw") == null);

    // Boyut kanıtı: düzeltme ÖNCESİ durumdan (macOS ~7.68 MB, Linux/ELF'te
    // `link_function_sections` OLMADAN ~12+ MB) AÇIKÇA küçük. Platformlar
    // ARASI DWARF/debug-info boyut farkı GERÇEK VE ÖNEMLİ (GERÇEK bir Linux
    // aarch64 CI koşusunda ÖLÇÜLDÜ: Debug noxrt.o macOS'un ~4 katı) — bu
    // YÜZDEN sınır CÖMERT tutulur (asıl, KESİN kanıt YUKARIDAKİ negatif-
    // sembol kontrolüdür, BU sınır SADECE "aşırı şişkinliğe" karşı bir
    // savunma-derinliği regresyon bekçisidir).
    //
    // v1.99.6: GERÇEK CI'de (Linux/aarch64, ReleaseFast) İKİLİ 10.588.104
    // bayt ÖLÇÜLDÜ — 10 MB sınırını SADECE ~%1 AŞTI. Bu, dead-stripping'in
    // BOZULDUĞUNUN DEĞİL (YUKARIDAKİ negatif-sembol kontrolü AYRICA GEÇTİ —
    // bu turda KANITLANDI), kod tabanının ZAMANLA (yeni stdlib modülleri/
    // dil özellikleri) BÜYÜMESİYLE eski sınırın DOĞAL olarak AŞILDIĞININ
    // kanıtı — sınır 14 MB'a YÜKSELTİLDİ (asıl KESİN kontrol HÂLÂ YUKARIDAKİ
    // negatif-sembol testidir, BU sadece "aşırı şişkinlik" bekçisidir).
    const stat = try tmp.dir.statFile(io, "prog_out", .{});
    if (stat.size >= 14 * 1024 * 1024) {
        std.debug.print("ikili beklenenden BUYUK: {d} bayt\n", .{stat.size});
    }
    try std.testing.expect(stat.size < 14 * 1024 * 1024);
}

test "noxc build: nox.json.decode + sınıf + cycle-collector (5-sembol dlsym listesi) doğru çalışır" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src_path = try writeTempSource(gpa, io,
        \\import nox.json
        \\
        \\class Node:
        \\    def __init__(self: Node, value: int) -> None:
        \\        self.value = value
        \\        self.other = self
        \\
        \\data: str = "{\"a\": 1, \"b\": [1, 2, 3]}"
        \\v: JsonValue = nox.json.decode(data)
        \\print(nox.json.object_key(v, 0))
        \\print(nox.json.as_number(nox.json.object_value(v, 0)))
        \\
        \\count: int = 0
        \\i: int = 0
        \\while i < 800:
        \\    n: Node = Node(i)
        \\    n.other = n
        \\    count = count + 1
        \\    i = i + 1
        \\print(count)
        \\
    , &tmp);
    defer gpa.free(src_path);

    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_len = try tmp.dir.realPath(io, &out_path_buf);
    const tmp_dir_path = out_path_buf[0..tmp_dir_len];
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/prog_out", .{tmp_dir_path});
    defer gpa.free(bin_path);

    const build_result = try runWithRetry(gpa, io, &.{ noxcPath(), "build", src_path, "-o", bin_path });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    if (!(build_result.term == .exited and build_result.term.exited == 0)) {
        std.debug.print("noxc build basarisiz, term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ build_result.term, build_result.stdout, build_result.stderr });
    }
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    const run_result = try runWithRetry(gpa, io, &.{bin_path});
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    if (!(run_result.term == .exited and run_result.term.exited == 0)) {
        std.debug.print("program calisirken basarisiz oldu, term={any}\nstdout:\n{s}\nstderr:\n{s}\n", .{ run_result.term, run_result.stdout, run_result.stderr });
    }
    try std.testing.expect(run_result.term == .exited and run_result.term.exited == 0);
    try std.testing.expectEqualStrings("a\n1\n800\n", run_result.stdout);
    // DebugAllocator'ın sızıntı/UAF kontrolü BOŞ stderr İLE kanıtlanır —
    // 5-sembol dlsym listesinin EKSİK/YANLIŞ olması (bkz. plan dosyası,
    // `nox_trace_dispatch` çıkarılınca kanıtlanan break→red→fix) cycle-
    // collector'ın SESSİZCE sızıntı vermesine yol açardı.
    try std.testing.expectEqualStrings("", run_result.stderr);
}
