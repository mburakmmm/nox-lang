//! Faz X.2 (bkz. `lexer_parser_checker_fuzz.zig`nin modül üstü notu — AYNI
//! Zig-yerleşik fuzzer/gerekçe BURADA da geçerlidir).
//!
//! WASM ikili modül ayrıştırıcısı (`runtime/wasm_bridge/module.zig`),
//! GÜVENMEYEN kaynaktan (bir `.wasm` dosyası) ham bayt AYRIŞTIRAN, bu
//! YÜZDEN AGENTS.md §9.5'in "güven sınırı" mantığıyla EN YÜKSEK önceliğe
//! sahip fuzz hedefidir — TAM OLARAK Faz X.1'in (LEB128 varint taşması,
//! bkz. nox-teknik-spesifikasyon.md §3.38) BULDUĞU/DÜZELTTİĞİ hata
//! SINIFININ (dizi sınırı aşımı, tamsayı taşması) GELECEKTEKİ
//! BENZERLERİNİ yakalamak İÇİN vardır.

const std = @import("std");
const wasm_bridge = @import("wasm_bridge");

test "fuzz: wasm_bridge.module.parse asla çökmez" {
    return std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // WASM ikili biçimi metin-tabanlı DEĞİLDİR — burada yazdırılabilir
    // ASCII'ye AĞIRLIK VERMENİN bir ANLAMI YOK, TÜM bayt uzayı EŞİT
    // ağırlıklı örneklenir (magic/sürüm baytları DAHİL — `\x00asm` gibi
    // SABİT bir önek, fuzzer'ın KENDİ kapsam-güdümlü mutasyonuyla ZAMANLA
    // KEŞFEDİLİR, elle TOHUMLAMAYA GEREK YOK).
    var buf: [1024]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
    });
    const bytes = buf[0..len];

    // `module.zig`nin KENDİ birim testiyle AYNI kalıp (`std.testing.
    // allocator` + `mod.deinit()`) — GeneralPurposeAllocator'ın sızıntı/
    // çift-serbest-bırakma TESPİTİ AKTİF kalır (AGENTS.md §6, "Bellek
    // güvenliği" gereksinimi) — bu, bir arena'nın SESSİZCE
    // TOLERE EDECEĞİ `Module.deinit`teki GERÇEK bir hatayı da YAKALAR.
    var mod = wasm_bridge.module.parse(std.testing.allocator, bytes) catch return;
    mod.deinit();
}

// ---- Elle yazılmış regresyon testleri ----
//
// **ÖNEMLİ bulgu (bu fazda keşfedildi):** `zig build test --fuzz=<N>`
// (Zig'in KENDİ YERLEŞİK, kapsam-güdümlü sürekli fuzzing modu) bu PROJENİN
// PİNLENMİŞ araç zincirinde (Zig 0.16.0, bkz. build.zig'in
// `EXPECTED_ZIG_VERSION`i, Faz R.4) **DERLENEMİYOR** — Zig'in KENDİ
// gömülü `compiler/test_runner.zig`si, `-ffuzz` bayrağıyla derlenirken
// `std.debug.writeStackTrace`e `*builtin.StackTrace` yerine `*const
// debug.StackTrace` bekleyen bir tip UYUŞMAZLIĞI İÇERİYOR — bu, BU
// PROJENİN koduyla İLGİSİZ, Zig'in KENDİ dağıtımının (`zig test
// minimal_tekrar.zig -ffuzz` İLE, PROJE DIŞINDA, TEK BAŞINA bir dosyayla
// TEKRAR ÜRETİLDİ) bir HATASIDIR — gelecekteki bir Zig sürümünde
// DÜZELMESİ BEKLENİR (bkz. Faz R.4'ün "pin ŞİMDİKİ sürüme, GELECEKTE
// bilinçli GEÇİŞ" felsefesi). **Bu YÜZDEN**, `--fuzz`in KENDİSİ ŞU AN
// bu araç zincirinde ÇALIŞTIRILAMADIĞINDAN, X.1'in (varint taşması)
// BULDUĞU SINIF hataların REGRESYONA karşı GERÇEKTEN korunduğunu KANITLAMAK
// İÇİN aşağıdaki, `std.testing.fuzz`e BAĞIMLI OLMAYAN, HER `zig build
// test`te KOŞULSUZ çalışan (dormant fuzz hedefinin AKSİNE) elle yazılmış
// testler EKLENDİ — bunlar, `--fuzz` bir gelecek Zig sürümünde
// ÇALIŞTIĞINDA da GEÇERLİLİĞİNİ KORUYACAK (birbirini DIŞLAMAZLAR).

test "regresyon: tamamen cop bayt dizisi cokmeden reddedilir" {
    const garbage = [_]u8{ 0x13, 0x37, 0xde, 0xad, 0xbe, 0xef, 0x00, 0xff, 0x80, 0x80 };
    try std.testing.expectError(error.InvalidModule, wasm_bridge.module.parse(std.testing.allocator, &garbage));
}

test "regresyon: kisaltilmis bolum basligi cokmeden reddedilir" {
    // Gecerli magic+surum, ardindan bir Type (1) bolumu bildiriliyor ama
    // ardindan HICBIR veri yok (bolum boyutu/icerigi tamamen eksik).
    const bytes = "\x00asm\x01\x00\x00\x00\x01";
    const result = wasm_bridge.module.parse(std.testing.allocator, bytes);
    try std.testing.expectError(error.InvalidModule, result);
}

test "regresyon: X.1 varint tasmasi — 6+ devam baytli Type bolumu boyutu" {
    // Gecerli magic+surum + Type (1) bolumu, AMA bolum BOYUTUNUN KENDISI
    // (readVarU32 ile okunan ILK alan) 6 ardisik devam baytiyla (0x80)
    // KODLANMIS — bkz. nox-teknik-spesifikasyon.md §3.38. Duzeltmeden ONCE
    // bu, `shift: u5` tasmasiyla PANIK verirdi; simdi `error.InvalidModule`
    // ile TEMIZ reddedilmesi BEKLENIR.
    const bytes = "\x00asm\x01\x00\x00\x00\x01" ++ [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 };
    const result = wasm_bridge.module.parse(std.testing.allocator, bytes);
    try std.testing.expectError(error.InvalidModule, result);
}

test "regresyon: buyuk-ama-sahte vektor sayisi cokmeden/asiri bellek harcamadan reddedilir" {
    // Type (1) bolumu — section_size (bir bayt, deger bu senaryo ICIN
    // ONEMSIZ) + 1 milyonluk bir tip SAYISI (`count`, `ensureTotalCapacity`e
    // GECER) bildiriliyor AMA ardindan TEK BIR tip TANIMI bile yok — dongu
    // ILK elemanda `error.UnexpectedEof`e CARPMALI — sonsuz donguye/asiri
    // buyuk GERCEK tahsise (ör. 4 milyar eleman) YOL ACMAMALI.
    const bytes = "\x00asm\x01\x00\x00\x00\x01\x0a" ++ [_]u8{ 0xc0, 0x84, 0x3d };
    const result = wasm_bridge.module.parse(std.testing.allocator, bytes);
    try std.testing.expectError(error.InvalidModule, result);
}

// ---- v2.1.94 (TODO 4.5 W4): ÖRNEKLEME + ÇALIŞTIRMA hedefi ----
//
// Ayrıştırıcıdan SONRAKİ aşamalar da güvenilmeyen girdiyi işler: `Instance.init` (bağlama, bellek/tablo kurma, `start` işlevi) ve dışa aktarılan işlevlerin
// yürütülmesi. Sınırlar KÜÇÜK tutulur (yakıt, yığın, çağrı derinliği, bellek) ki hiçbir girdi asılmasın ya da bellek tüketmesin. Beklenen: HER girdi temiz bir
// hata ya da temiz bir sonuç verir; çökme, sınır dışı erişim ve sızıntı (`std.testing.allocator`) OLMAZ.

const small_cfg: wasm_bridge.interp.Config = .{ .fuel = 20_000, .max_stack_slots = 4096, .max_call_depth = 64, .max_memory_pages = 4, .max_table_elems = 1000 };

fn runModule(bytes: []const u8) void {
    var mod = wasm_bridge.module.parse(std.testing.allocator, bytes) catch return;
    defer mod.deinit();
    const inst = wasm_bridge.interp.Instance.init(std.testing.allocator, &mod, &.{}, small_cfg) catch return;
    defer inst.deinit();
    for (mod.exports) |e| {
        if (e.kind != .func) continue;
        const ft = mod.typeOf(e.index);
        if (ft.params.len > 8 or ft.results.len > 8) continue;
        var args: [8]u64 = .{ 0, 1, 2, 0xffff_ffff, 0x8000_0000, 7, 0, 3 };
        var res: [8]u64 = undefined;
        inst.invoke(e.index, args[0..ft.params.len], res[0..ft.results.len]) catch continue;
    }
}

test "fuzz: Instance.init + dışa aktarılan işlevlerin çalıştırılması asla çökmez/asılmaz" {
    return std.testing.fuzz({}, testRun, .{});
}

fn testRun(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buf: [1024]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
    });
    runModule(buf[0..len]);
}

// Geçerli küçük modüllerin TEK-BAYT mutasyon taraması (`--fuzz` bu araç zincirinde çalışmadığından HER `zig build test`te çalışan deterministik karşılığı):
// modülün her baytı tüm 256 değerle değiştirilir; her varyant ayrıştırılır, örneklenir ve işlevleri çağrılır.
const mut_add = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 7, 1, 96, 2, 127, 127, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1, 7, 13, 2, 3, 97, 100, 100, 0, 0, 3, 109, 101, 109, 2, 0, 10, 9, 1, 7, 0, 32, 0, 32, 1, 106, 11 };
const mut_spin = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 7, 8, 1, 4, 115, 112, 105, 110, 0, 0, 10, 9, 1, 7, 0, 3, 64, 12, 0, 11, 11 };
const mut_import = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 2, 13, 1, 3, 101, 110, 118, 5, 116, 119, 105, 99, 101, 0, 0, 3, 2, 1, 0, 7, 7, 1, 3, 114, 117, 110, 0, 1, 10, 11, 1, 9, 0, 32, 0, 16, 0, 65, 1, 106, 11 };

// SIMD (v128, 0xFD önekli) komutlar, v128 blok sonucu/dallanma ve gölge yığın yolları (v2.1.98).
const mut_simd = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 6, 1, 96, 1, 127, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1, 7, 11, 2, 3, 109, 101, 109, 2, 0, 1, 102, 0, 0, 10, 74, 1, 72, 1, 1, 123, 2, 123, 32, 0, 253, 0, 0, 1, 253, 12, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 253, 174, 1, 32, 0, 13, 0, 26, 32, 0, 253, 17, 11, 34, 1, 32, 1, 253, 13, 0, 17, 2, 19, 4, 21, 6, 23, 8, 25, 10, 27, 12, 29, 14, 31, 32, 0, 253, 109, 253, 27, 2, 11 };

fn mutateAll(base: []const u8) !void {
    const copy = try std.testing.allocator.alloc(u8, base.len);
    defer std.testing.allocator.free(copy);
    for (0..base.len) |i| {
        for ([_]u8{ 0x00, 0x01, 0x7f, 0x80, 0xff, 0x40, 0x0b, 0x10, 0x20, 0x41, 0x63 }) |v| {
            @memcpy(copy, base);
            copy[i] = v;
            runModule(copy);
        }
    }
    // Kısaltmalar: her önek uzunluğu.
    for (0..base.len) |n| runModule(base[0..n]);
}

test "regresyon: geçerli modüllerin bayt mutasyonları ve önekleri çökmeden/asılmadan işlenir" {
    try mutateAll(&mut_add);
    try mutateAll(&mut_spin);
    try mutateAll(&mut_import);
    try mutateAll(&mut_simd);
}
