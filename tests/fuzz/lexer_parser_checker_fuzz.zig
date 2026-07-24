//! Faz X.2 (bkz. docs/uretim-hazirlik-analizi.md, "`tests/fuzz/`i DOLDUR:
//! lexer/parser/checker + WASM ayrıştırıcısı İÇİN... fuzz hedefleri" — bkz.
//! aşağıdaki modül üstü not, GERÇEK aracın SEÇİMİ İÇİN).
//!
//! **Zig'in KENDİ, YERLEŞİK, kapsam-güdümlü (coverage-guided) fuzzer'ı
//! kullanılır** (`std.testing.fuzz` + `std.testing.Smith`, `zig build test
//! --fuzz`) — HARİCİ bir libFuzzer/AFL KURULUMU (`-fsanitize=fuzzer` C
//! araç zinciri köprüsü, ayrı bir derleme hedefi) GEREKMEZ. Bu, projenin
//! GENEL "battle-tested/YERLEŞİK aracı SEÇ, YENİDEN İCAT ETME" ilkesiyle
//! (bkz. `nox.json`nin `std.json` seçimi, W.1'in tree-sitter-python
//! tarayıcısını uyarlaması) TUTARLIDIR — Zig 0.16 ARTIK KENDİ derleyicisinin
//! (`std/zig/tokenizer.zig`nin `test "fuzzable properties upheld"`si)
//! KULLANDIĞI AYNI mekanizmayı stdlib'in bir PARÇASI olarak sunuyor; BU
//! DOSYANIN test ŞEKLİ (`testOne` imzası, `Smith.sliceWeightedBytes`
//! ağırlık tablosu) O testTEN DOĞRUDAN UYARLANMIŞTIR.
//!
//! **Çalıştırma:** normal `zig build test` bu testleri TEK bir (varsayılan/
//! boş korpus) girdiyle ÇALIŞTIRIR — HIZLI bir regresyon testi GİBİ davranır,
//! CI'yi YAVAŞLATMAZ/askıya ALMAZ. GERÇEK, UZATILMIŞ fuzzing İÇİN TASARLANAN
//! yol `zig build test --fuzz`dır (yerel bir web arayüzü AÇAR, sürekli
//! mutasyonla arar).
//!
//! **Bilinen, ŞU AN İÇİN AŞILAMAYAN engel (bağımsız bir inceleme SIRASINDA,
//! 2026-07-22'de DOĞRUDAN doğrulandı — GERÇEK bir Zig 0.16.0 hatası, Nox'un
//! KENDİ kodunda DEĞİL):** `zig build test --fuzz=<N>` (SINIRLI, CI'ya UYGUN
//! toplu-iş modu) VE (dolaylı olarak, web arayüzü GERÇEKTEN bir fuzz
//! ÇALIŞTIRDIĞINDA) sınırsız `--fuzz`in KENDİSİ, Zig 0.16.0'ın KENDİ
//! `compiler/test_runner.zig`sinde (`std.debug.writeStackTrace(trace,
//! stderr)`, `*builtin.StackTrace` GEÇERKEN `*const debug.StackTrace`
//! BEKLEYEN bir tip UYUŞMAZLIĞI — Zig standart kütüphanesinin/derleyicisinin
//! KENDİ İÇİNDE, `-ffuzz` bayrağı AKTİFKEN TETİKLENEN bir DERLEME HATASI)
//! bir hata NEDENİYLE DERLENEMİYOR — `zig build test --fuzz=100` (yerelde
//! DOĞRUDAN denendi) "error: expected type '*const debug.StackTrace', found
//! '*builtin.StackTrace'" İLE BAŞARISIZ oluyor. Bu, projenin KENDİ
//! kodundan/yapılandırmasından KAYNAKLANMAYAN, YALNIZCA bir Zig 0.16.0
//! YAMASI/SONRAKİ sürümüyle ÇÖZÜLEBİLECEK bir engeldir — bu YÜZDEN BİLİNÇLİ
//! olarak (a) ayrı bir CI iş akışı EKLENMEDİ (Zig'in KENDİ hatası
//! DÜZELENE KADAR HER çalıştırmada BAŞARISIZ olacak, sürekli KIRMIZI bir
//! kontrol EKLEMENİN bir DEĞERİ yoktur), (b) yukarıdaki "sınırsız `--fuzz`"
//! açıklaması TARİHSEL bir NİYETİ yansıtır — GÜNCEL Zig 0.16.0 kurulumunda
//! GERÇEKTEN bir fuzz ÇALIŞTIRMAK (web arayüzü yalnızca AÇILMAK yerine)
//! AYNI hataya ÇARPAR. Zig'in bu hatayı düzelttiği bir SÜRÜME geçildiğinde
//! bu not KALDIRILMALI VE `--fuzz=<N>`e dayanan zamanlı bir CI iş akışı
//! (`.github/workflows/`) EKLENMELİDİR.
//!
//! **Doğrulanan ÖZELLİK — YALNIZCA "ÇÖKMEZ/sonsuz döngüye GİRMEZ":**
//! lex→parse→typecheck zincirinin HER aşaması KENDİ hata KÜMESİNİ (`LexError`/
//! `ParseError`/`TypeError`) DÖNDÜRDÜĞÜNDEN, GEÇERSİZ bir girdinin bir HATA
//! İLE reddedilmesi BEKLENEN/normal davranıştır — fuzz hedefi bunu BAŞARISIZLIK
//! SAYMAZ (`catch return`). YALNIZCA bir PANİK/segfault/sonsuz döngü (Zig'in
//! KENDİ güvenli-derleme tuzakları + fuzzer'ın kapsam-güdümlü zaman aşımı
//! tespiti ARACILIĞIYLA) bir BAŞARISIZLIK sayılır — bu, X.1'in (varint
//! taşması) bulunduğu AYNI KATEGORİDEKİ hataları (dizi sınırı aşımı, tamsayı
//! taşması, sonsuz özyineleme) YAKALAMAK İÇİN TASARLANMIŞTIR.

const std = @import("std");
const nox = @import("nox");

test "fuzz: lexer→parser→checker asla çökmez" {
    return std.testing.fuzz({}, testOne, .{});
}

fn testOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // Ağırlık tablosu `std/zig/tokenizer.zig`nin KENDİ fuzz hedefiyle AYNI
    // fikirdir: Nox kaynağının BÜYÜK çoğunluğu yazdırılabilir ASCII + boşluk/
    // yeni-satır/girinti karakterleridir — bunlara AĞIRLIK VERMEK, fuzzer'ın
    // "gerçekçi" (lexer'ın erken reddetmeyeceği, derinlere İNEBİLEN) girdiler
    // üretme OLASILIĞINI ARTIRIR; KEYFİ baytlar (ağırlık 1) yine de bir
    // miktar dahil edilir (kaçış dizileri/UTF-8 dışı bozukluklar İÇİN).
    var source_buf: [2048]u8 = undefined;
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 6), // yazdırılabilir ASCII
        .value(u8, ' ', 8),
        .value(u8, '\n', 6),
        .value(u8, '\t', 1), // lexer'ın KENDİ TabsNotAllowed hata yolu
        .value(u8, ':', 3),
        .value(u8, '"', 2),
    });
    const source = source_buf[0..len];

    // Lexer/parser/checker'ın TÜMÜ, AST/token dizilerini bireysel serbest
    // bırakma İÇİN TASARLANMAMIŞTIR (bkz. `tests/unit/lexer_test.zig`/
    // `parser_test.zig`nin AYNI kalıbı — main.zig'in KENDİ derleme
    // boru hattı da HER ZAMAN bir arena kullanır) — bu YÜZDEN burada da
    // `std.testing.allocator` YERİNE bir arena KULLANILIR (sızıntı
    // TESPİTİ bu modüller İÇİN uygulanabilir DEĞİLDİR, bilinçli tasarım).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = nox.lexer.tokenize(a, source) catch return;
    const module = nox.parser.parseModule(a, tokens) catch return;

    var checker_state = nox.checker.Checker.init(a);
    checker_state.checkModule(module) catch {};
    // `checkModule`nin BAŞARILI dönüşü TEK BAŞINA "tip hatasız" anlamına
    // GELMEZ (bkz. checker.zig'in Faz T.2 notu) — ama bu fuzz hedefi
    // İÇİN ÖNEMLİ DEĞİL, `checker_state.diagnostics`e HİÇ bakılmaz;
    // TEK ilgilenilen ÖZELLİK yukarıdaki modül üstü nottaki "ÇÖKMEZ".
}

// ---- Elle yazılmış regresyon testleri ----
//
// `wasm_parser_fuzz.zig`nin AYNI notuna bkz.: `zig build test --fuzz=<N>`
// bu PROJENİN pinlenmiş Zig 0.16.0 araç zincirinde `compiler/test_runner.
// zig`nin KENDİ (bu projeyle İLGİSİZ) bir tip uyuşmazlığı YÜZÜNDEN
// DERLENEMİYOR — bu YÜZDEN aşağıdaki, `std.testing.fuzz`e BAĞIMLI OLMAYAN
// elle yazılmış testler, HER `zig build test`te KOŞULSUZ çalışan GERÇEK
// regresyon KORUMASI sağlar.

fn assertDoesNotCrash(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = nox.lexer.tokenize(a, source) catch return;
    const module = nox.parser.parseModule(a, tokens) catch return;
    var checker_state = nox.checker.Checker.init(a);
    checker_state.checkModule(module) catch {};
}

test "regresyon: cok derin girinti cokmeden/sonsuz donguye girmeden islenir" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var depth: usize = 0;
    while (depth < 500) : (depth += 1) {
        try buf.appendNTimes(std.testing.allocator, ' ', depth * 4);
        try buf.appendSlice(std.testing.allocator, "if True:\n");
    }
    try assertDoesNotCrash(buf.items);
}

test "regresyon: sonlandirilmamis string + saf ikili cop cokmeden islenir" {
    try assertDoesNotCrash("x: str = \"sonsuz");
    try assertDoesNotCrash(&[_]u8{ 0x00, 0xff, 0x80, 0x13, 0x37, 0x0a, 0x09, 0xde, 0xad });
}

test "regresyon: cok uzun tek satirlik ifade cokmeden islenir" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "x: int = 1");
    var i: usize = 0;
    while (i < 2000) : (i += 1) try buf.appendSlice(std.testing.allocator, " + 1");
    try buf.append(std.testing.allocator, '\n');
    try assertDoesNotCrash(buf.items);
}
