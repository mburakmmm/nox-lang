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
    try std.testing.expectError(error.UnexpectedEof, result);
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
    try std.testing.expectError(error.UnexpectedEof, result);
}
