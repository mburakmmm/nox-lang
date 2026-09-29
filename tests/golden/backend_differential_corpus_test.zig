//! v3 sertleştirme yol haritası, madde 9 (bkz. nox-teknik-spesifikasyon.md
//! ilgili bölüm) — "derleyici fuzzing": dış analizin önerdiği "differential
//! (QBE vs LLVM, aynı geçerli rastgele programlar)" fikrinin GERÇEKÇİLEŞTİRİLMİŞ
//! hâli. Sıfırdan tip-doğru RASTGELE Nox programı ÜRETEN bir jeneratör (tam
//! bir gramer-farkında fuzzer) KAPSAM DIŞI bırakıldı — bunun yerine ZATEN
//! VAR OLAN, ZATEN tip-doğru, ZATEN QBE altında kanıtlanmış TÜM `codegen_
//! cases/` korpusu (`fixture_corpus.zig`, ~265 fixture) HEM QBE HEM LLVM'de
//! çalıştırılıp stdout'ları KARŞILAŞTIRILIR — `backend_conformance_test.zig`
//! (Faz HH.1, SADECE ~25 ELLE seçilmiş fixture) İLE AYNI FİKRİN, TÜM
//! korpusa GENİŞLETİLMİŞ hâli. Bu, "rastgele program" YERİNE "GENİŞ,
//! ÇEŞİTLİ, ZATEN VAR OLAN bir program KORPUSU" kullanır — pratikte AYNI
//! HEDEFİ (İKİ backend'in SESSİZCE FARKLI davranmadığını GENİŞ bir yüzeyde
//! doğrulamak) çok daha AZ risk/karmaşıklıkla karşılar (tip-doğru rastgele
//! Nox programı ÜRETMEK — ownership/sahiplik analizini de KARŞILAYACAK
//! şekilde — kendi başına AYRI, büyük bir proje olurdu).
//!
//! **Determinizm/kasıtlı-asimetri denylist'i (bkz. AŞAĞIDAKİ
//! `DENYLISTED_SOURCES`) — İLK ÇALIŞTIRMADA GERÇEKTEN bulundu, TAHMİN
//! DEĞİL:** 4 fixture BİLİNÇLİ olarak HARİÇ TUTULUR:
//! - `async_deadlock`/`thread_spawn_ordering`: GERÇEK zamanlama/
//!   zamanlayıcı-davranışına (kasıtlı deadlock TESPİTİ VEYA `sleep_ms`
//!   İLE yarışan eşzamanlı görevler) dayanır.
//! - `task_reassignment_frees_old` (İLK çalıştırmada GERÇEKTEN "1\n2\n"
//!   vs "2\n1\n" farkıyla YAKALANDI): `t = spawn worker(1)` HEMEN
//!   `t = spawn worker(2)` İLE değiştirilir — İLK görev (`worker(1)`)
//!   HİÇ await EDİLMEDEN bağımsız çalışır, bu YÜZDEN İKİ görevin YAZDIRMA
//!   SIRASI zamanlayıcıya bağlıdır (testin KENDİ amacı sızıntı/UAF
//!   OLMAMASI, çıktı SIRASI DEĞİL).
//! - `fixed_int_overflow_trap` (v2.0 madde 4/v3 madde 7, §3.204): sabit-
//!   genişlikli taşma QBE'de HER ZAMAN tuzağa düşer, LLVM'de HER ZAMAN
//!   sessizce sarar — KASITLI, KALICI bir tasarım kararı (bkz. §3.204),
//!   "düzeltilecek" bir hata DEĞİL.
//!
//! HER DÖRDÜ de GERÇEK zamanlayıcı/tasarım-kararı asimetrileridir — QBE'nin
//! KATI M:1 fiber zamanlayıcısı İLE `--release`in GERÇEK M:N iş-çalan
//! (work-stealing) havuzu (bkz. `backend_conformance_test.zig`nin AYNI
//! uyarısı) bu senaryolarda FARKLI (AMA HER İKİSİ de DOĞRU) davranabilir.
//! KALAN TÜM fixture'lar (`.golden`/`.uncaught_exception`/`.uncaught_
//! exception_with_stderr`, ThreadChannel/Channel/spawn+await İÇERENLER
//! DAHİL) TEK bir görev üretip HEMEN await ETTİĞİNDEN (veya sıralı
//! üretici/tüketici KULLANDIĞINDAN) DETERMİNİSTİKTİR.
//!
//! **Bu suite'in İLK çalıştırmasında GERÇEKTEN bulunup düzeltilen 2 hata
//! (bkz. nox-teknik-spesifikasyon.md ilgili bölüm):** `compiler/codegen_
//! qbe/llvm_emit.zig`nin `arithOpFor`/`cmpSpecFor` tabloları — bitwise
//! `<<`/`>>` (QBE "shl"/"sar"/"shr" mnemonikleri) VE TÜM `.w`-genişlikli
//! işaretli + HER İKİ genişlikte işaretsiz sıralama karşılaştırmaları
//! (`csltw`/.../`cugel`) HİÇ eşlenmemişti — `noxc build --release`
//! bitwise kaydırma VEYA fixed-width sıralama/işaretsiz karşılaştırma
//! İÇEREN HERHANGİ bir programı `error.Unsupported` İLE reddediyordu.

const std = @import("std");
const compile_helpers = @import("compile_helpers.zig");
const fixture_corpus = @import("fixture_corpus.zig");

/// `fixture_corpus.Fixture`nin `source`i (bir `@embedFile` İçERİĞİ) TEK
/// BAŞINA dosya ADINI TAŞIMADIĞINDAN (İçERİK, yol DEĞİL), denylist eşleşmesi
/// `fx.name` (İnsan-okunaklı test adı, GENELLİKLE dosya adının BİR KISMINI
/// İçERMEZ) YERİNE — DAHA GÜVENİLİR bir yöntem: her fixture'ın `source`unun
/// KENDİSİYLE (bytes) eşleşmesi. Bu YÜZDEN denylist, `@embedFile` metnini
/// DOĞRUDAN taşır (dosya ADI DEĞİL, İÇERİK) — `fixture_corpus.zig`nin
/// AYNI dosyaları YENİDEN `@embedFile` ETMESİ, Zig'in KENDİ `@embedFile`
/// önbelleklemesi SAYESİNDE SIFIR EK maliyetlidir (AYNI dosya İKİ KEZ
/// gömülmez, TEK bir salt-okunur bellek bölgesi PAYLAŞILIR).
const DENYLISTED_SOURCES = [_][]const u8{
    @embedFile("codegen_cases/async_deadlock.nox"),
    @embedFile("codegen_cases/thread_spawn_ordering.nox"),
    @embedFile("codegen_cases/task_reassignment_frees_old.nox"),
    @embedFile("codegen_cases/fixed_int_overflow_trap.nox"),
};

fn isDenylistedSource(source: []const u8) bool {
    for (DENYLISTED_SOURCES) |s| {
        if (std.mem.eql(u8, s, source)) return true;
    }
    return false;
}

fn expectDifferential(fx: fixture_corpus.Fixture) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const qbe_result = try compile_helpers.compileAndRun(a, fx.source);
    const llvm_result = try compile_helpers.compileAndRunLlvm(a, fx.source);

    switch (fx.kind) {
        .golden => {
            if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
                std.debug.print("QBE basarisiz (stderr): {s}\n", .{qbe_result.stderr});
                return error.QbeProgramFailed;
            }
            if (llvm_result.term != .exited or llvm_result.term.exited != 0) {
                std.debug.print("LLVM basarisiz (stderr): {s}\n", .{llvm_result.stderr});
                return error.LlvmProgramFailed;
            }
            try std.testing.expectEqualStrings(fx.expected_stdout, qbe_result.stdout);
            try std.testing.expectEqualStrings(qbe_result.stdout, llvm_result.stdout);
            try std.testing.expectEqualStrings(fx.expected_stdout, llvm_result.stdout);
        },
        .uncaught_exception => {
            if (qbe_result.term != .exited or qbe_result.term.exited == 0) return error.ExpectedQbeNonZeroExit;
            if (llvm_result.term != .exited or llvm_result.term.exited == 0) return error.ExpectedLlvmNonZeroExit;
            try std.testing.expectEqualStrings(fx.expected_stdout, qbe_result.stdout);
            try std.testing.expectEqualStrings(qbe_result.stdout, llvm_result.stdout);
            try std.testing.expectEqualStrings(fx.expected_stdout, llvm_result.stdout);
        },
        .uncaught_exception_with_stderr => {
            // v3 madde 9 kapsamı: SADECE stdout karşılaştırılır — stderr
            // metni (`nox_unhandled_exception`in bastığı sınıf adı/satır),
            // `codegen_golden_test.zig`de ZATEN QBE'ye özel doğrulanıyor;
            // LLVM tarafında AYNI mekanizma AYRI bir amaçla (bkz. o testin
            // KENDİ notu) zaten kanıtlı, burada YENİDEN iddia etmek bu
            // testin "geniş korpus, davranışsal fark" odağının DIŞINA
            // taşardı.
            if (qbe_result.term != .exited or qbe_result.term.exited == 0) return error.ExpectedQbeNonZeroExit;
            if (llvm_result.term != .exited or llvm_result.term.exited == 0) return error.ExpectedLlvmNonZeroExit;
            try std.testing.expectEqualStrings(fx.expected_stdout, qbe_result.stdout);
            try std.testing.expectEqualStrings(qbe_result.stdout, llvm_result.stdout);
            try std.testing.expectEqualStrings(fx.expected_stdout, llvm_result.stdout);
        },
    }
}

test "differential(korpus): tüm codegen_cases fixture'ları QBE/LLVM arasında aynı davranır (denylist hariç)" {
    var failures: usize = 0;
    var skipped: usize = 0;
    for (fixture_corpus.fixtures) |fx| {
        if (isDenylistedSource(fx.source)) {
            skipped += 1;
            continue;
        }
        expectDifferential(fx) catch |e| {
            std.debug.print("FARK: '{s}' -> {t}\n", .{ fx.name, e });
            failures += 1;
        };
    }
    std.debug.print("differential(korpus): {d} fixture calistirildi, {d} atlandi (denylist), {d} FARK\n", .{ fixture_corpus.fixtures.len - skipped, skipped, failures });
    try std.testing.expectEqual(@as(usize, 0), failures);
}
