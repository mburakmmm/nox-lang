//! Faz HH.1 (bkz. plan dosyası "QBE↔LLVM backend conformance suite"):
//! `codegen_golden_test.zig` (QBE) + `llvm_golden_test.zig` (LLVM) İKİSİ
//! de KENDİ backend'lerinin AYRI AYRI "doğru" olduğunu kanıtlar — AMA
//! HİÇBİRİ İKİSİNİN AYNI davrandığını kanıtlamaz. Bu dosya İKİSİNİ
//! BİRDEN çalıştırıp stdout'ları KARŞILAŞTIRIR — GERÇEK bir örnek: GG.24'ün
//! (v1.48.0) araştırması SIRASINDA `llvm_emit.zig`nin `qbeOp1`sinin
//! `await` edilen bir `bool` sonucunu HER ZAMAN geçersiz LLVM IR'a
//! çevirdiği (QBE yolu HİÇBİR ZAMAN bu hatayı GÖSTERMEDİ) bulundu —
//! sistematik bir karşılaştırma OLMADAN bu tür hatalar AYLARCA gizli
//! kalabilir.
//!
//! Faz HH.1.2 (bkz. plan dosyası "QBE↔LLVM conformance suite'ini GÜNCEL
//! özellik yüzeyine genişletme"): v1.50.0'dan v1.80.0'a KADAR EKLENEN 6
//! büyük özellik AYRI AYRI değerlendirildi — 3'ü (Task istisna yayılımı,
//! Task iptali, `and`/`or` kısa-devre) TAMAMEN backend-agnostik, TEK bir
//! codegen yolu paylaştıkları KANITLANDIĞINDAN AŞAĞIYA `expectConformant`
//! fixture'ı OLARAK EKLENDİ. KALAN 3'ü (HPy çağrı yüzeyi — harici
//! `.hpy-venv`/`.so` bağımlılığı GEREKTİRİR; extern geçici sahiplik —
//! `codegen_ir_diff_test.zig`de ZATEN IR-seviyesinde doğrulanıyor;
//! ORM/generic çıkarım — SAF derleme-zamanı, generic'ler codegen'e
//! ULAŞMADAN monomorfize edilir) BİLİNÇLİ olarak KAPSAM DIŞI bırakıldı —
//! ÜÇÜ de backend-özel bir çalışma-zamanı sapma yüzeyi TAŞIMIYOR.
//!
//! v2.0 stabilizasyon yol haritası, madde 3 (bkz. nox-teknik-
//! spesifikasyon.md §3.191): 7 YENİ `expectConformant` fixture'ı (dict[K,V],
//! sınıf kalıtımı+hiyerarşik except, str işlemleri, birinci-sınıf fonksiyon
//! değeri, iç içe try/except/finally+with, defer, generic örnekleme'nin
//! KENDİ çalışma-zamanı davranışı — "ORM/generic çıkarım" hariç tutmasından
//! FARKLI bir şey) + 3 YENİ `expectDivergence` fixture'ı (`isSpawnParamSafeType`/
//! `isThreadTransferSafeType`nin LLVM-gevşetilmiş `list`/`class`/`dict`
//! kümesinin, ÖNCEDEN SADECE YARISI test edilen 2×3 kombinasyon matrisini
//! TAMAMLAR: dict×spawn, class×thread.start, dict×thread.start). `nox.http.
//! serve_multicore*` (M:N/LLVM vs M:1/QBE zamanlama farkı NEDENİYLE
//! `expectConformant`nin KATI stdout-eşitliği modeliyle test EDİLEMEZ)
//! BİLİNÇLİ olarak BU turda da KAPSAM DIŞI bırakıldı.
//!
//! **İKİ test kategorisi**:
//! - `expectConformant`: HER İKİ backend de ÇALIŞTIRILIR, stdout'ları
//!   HEM `expected`e HEM BİRBİRİNE eşit olmalı. SADECE deterministik-
//!   sıralı senaryolar (senkron kod, YA DA HER görev SIRADAKİ
//!   BAŞLAMADAN ÖNCE `await` edilen TEK spawn'lar) kullanılır — `--release`
//!   altında SIRADAN `spawn`/`Task[T]`/`Channel[T]` BİLE GERÇEK bir M:N
//!   work-stealing havuzunda çalışır (nox-teknik-spesifikasyon.md §3.87),
//!   `.qbe` İSE KATI M:1'dir — İKİ VEYA DAHA FAZLA eşzamanlı görevin
//!   KENDİ `print()` yaptığı bir senaryoda çıktı SIRASI backend'ler
//!   ARASINDA GARANTİLİ AYNI DEĞİLDİR.
//! - `expectDivergence`: BİLİNÇLİ, BELGELENMİŞ bir backend asimetrisi
//!   (`checker.zig`nin `isSpawnParamSafeType`/`isThreadTransferSafeType`si
//!   VEYA `codegen_qbe`nin `pool_run`/decorator KABUL-RED farkı) —
//!   HANGİ backend'in kabul/red ettiğini VE (kabul eden tarafta) beklenen
//!   çıktıyı DOĞRUDAN İDDİA eder. İncelemenin önerdiği "expected_backend_
//!   divergence.toml" fikrinin TİP-GÜVENLİ, KOD-İÇİ eşdeğeri — bir veri
//!   dosyası GERÇEKLİKTEN SESSİZCE SAPAMAZ, HER giriş KENDİ derlenen/
//!   çalıştırılan iddiasını taşır.

const std = @import("std");
const compile_helpers = @import("compile_helpers.zig");

fn expectConformant(comptime source: []const u8, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const qbe_result = try compile_helpers.compileAndRun(arena.allocator(), source);
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("QBE programi basarisiz cikti (stderr): {s}\n", .{qbe_result.stderr});
        return error.QbeProgramFailed;
    }
    if (qbe_result.stderr.len != 0) {
        std.debug.print("QBE programi stderr'e beklenmeyen bir cikti yazdi (olasi bellek sizintisi): {s}\n", .{qbe_result.stderr});
        return error.QbeUnexpectedStderr;
    }

    const llvm_result = try compile_helpers.compileAndRunLlvm(arena.allocator(), source);
    if (llvm_result.term != .exited or llvm_result.term.exited != 0) {
        std.debug.print("LLVM programi basarisiz cikti (stderr): {s}\n", .{llvm_result.stderr});
        return error.LlvmProgramFailed;
    }
    if (llvm_result.stderr.len != 0) {
        std.debug.print("LLVM programi stderr'e beklenmeyen bir cikti yazdi (olasi bellek sizintisi): {s}\n", .{llvm_result.stderr});
        return error.LlvmUnexpectedStderr;
    }

    try std.testing.expectEqualStrings(expected, qbe_result.stdout);
    // Ayrı bir iddia (yukarıdaki `expected` karşılaştırmasıyla teorik
    // olarak fazlalık — ikisi de `expected`e eşitse birbirlerine de
    // eşittirler — AMA bu iddia BAŞARISIZ OLDUĞUNDA hata mesajının
    // KENDİSİ "backend'ler birbirinden SAPTI" diye AÇIKÇA okunur, "QBE
    // yanlış"/"LLVM yanlış" belirsizliğini ORTADAN KALDIRIR).
    try std.testing.expectEqualStrings(qbe_result.stdout, llvm_result.stdout);
    try std.testing.expectEqualStrings(expected, llvm_result.stdout);
}

const DivergenceExpectation = union(enum) {
    /// Backend BU programı DERLEME-ZAMANINDA reddetmelidir (checker
    /// tip hatası YA DA codegen `error.Unsupported`) — HANGİ Zig hatası
    /// olduğu ÖNEMLİ DEĞİL, SADECE bir hata OLMASI (derlenip normal
    /// çalışması BEKLENMEMESİ).
    rejected,
    /// Backend BU programı DERLEYİP ÇALIŞTIRMALI, verilen stdout'u
    /// üretmeli.
    accepted: []const u8,
};

fn expectDivergence(comptime source: []const u8, qbe_expectation: DivergenceExpectation, llvm_expectation: DivergenceExpectation) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    switch (qbe_expectation) {
        .rejected => {
            if (compile_helpers.compileAndRun(arena.allocator(), source)) |_| {
                return error.ExpectedQbeRejectionButItCompiledAndRan;
            } else |_| {}
        },
        .accepted => |expected_stdout| {
            const result = try compile_helpers.compileAndRun(arena.allocator(), source);
            if (result.term != .exited or result.term.exited != 0) {
                std.debug.print("QBE programi basarisiz cikti (stderr): {s}\n", .{result.stderr});
                return error.QbeProgramFailed;
            }
            try std.testing.expectEqualStrings(expected_stdout, result.stdout);
        },
    }

    switch (llvm_expectation) {
        .rejected => {
            if (compile_helpers.compileAndRunLlvm(arena.allocator(), source)) |_| {
                return error.ExpectedLlvmRejectionButItCompiledAndRan;
            } else |_| {}
        },
        .accepted => |expected_stdout| {
            const result = try compile_helpers.compileAndRunLlvm(arena.allocator(), source);
            if (result.term != .exited or result.term.exited != 0) {
                std.debug.print("LLVM programi basarisiz cikti (stderr): {s}\n", .{result.stderr});
                return error.LlvmProgramFailed;
            }
            try std.testing.expectEqualStrings(expected_stdout, result.stdout);
        },
    }
}

// --- Uyum (conformance) testleri: HER İKİ backend de AYNI çıktıyı
// üretmeli — senkron/deterministik senaryolar. ---

test "conformance: fonksiyon dönüş tipleri (int/bool/float/str/class/list) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_function_return.nox"),
        @embedFile("conformance_cases/conformance_function_return.expected"),
    );
}

test "conformance: özel bir Exception alt sınıfının int/bool/float/str alanları her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_exception_payload.nox"),
        @embedFile("conformance_cases/conformance_exception_payload.expected"),
    );
}

test "conformance: closure yakalaması (int/bool/float/str/list/class) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_closure_capture.nox"),
        @embedFile("conformance_cases/conformance_closure_capture.expected"),
    );
}

test "conformance: sınıf alanları (int/bool/float/str/list) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_class_field.nox"),
        @embedFile("conformance_cases/conformance_class_field.expected"),
    );
}

test "conformance: list[T] elemanları (int/bool/float/str/class) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_list_elements.nox"),
        @embedFile("conformance_cases/conformance_list_elements.expected"),
    );
}

// GG.24'ün (v1.48.0) BULDUĞU tam hata sınıfı: `Task[bool]`nin await
// sonucu — BU test, o hatanın YENİDEN ORTAYA ÇIKMASI durumunda
// (kırmızı-takım kanıtı bkz. plan dosyası) BAŞARISIZ olacak TEK yerdir.
test "conformance: TEK spawn+await (int/bool/float/str), sıralı — her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_spawn_await_scalar.nox"),
        @embedFile("conformance_cases/conformance_spawn_await_scalar.expected"),
    );
}

// Faz HH.1.2: Faz SC.1 (v1.70.0) — spawn edilen bir Task'ın yakalanmamış
// istisnası, `await` eden tarafın `try`/`except`ine PAYLAŞILAN `bridge.
// zig`/`genAwaitExpr` yolu üzerinden ulaşır (backend-özel dallanma YOK).
test "conformance: Task istisna yayılımı (spawn+await+try/except) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_task_exception_propagation.nox"),
        @embedFile("conformance_cases/conformance_task_exception_propagation.expected"),
    );
}

// Faz SC.2 (v1.71.0) — `t.cancel()` + kooperatif `CancelledError`,
// `nox_task_cancel`/`nox_task_check_cancelled`nin İKİSİ de backend-özel
// dallanma TAŞIMIYOR (senkron/deterministik kontrol noktası).
test "conformance: Task iptali (t.cancel() + CancelledError) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_task_cancellation.nox"),
        @embedFile("conformance_cases/conformance_task_cancellation.expected"),
    );
}

// Faz FF.5 (v1.76.0, §3.143) — `and`/`or`'un GERÇEK kısa-devresi TEK,
// paylaşılan bir codegen yolunda (backend-agnostik) yaşıyor.
test "conformance: and/or kısa-devre (RHS'in yan-etkisi ÇALIŞMAZ) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_short_circuit_and_or.nox"),
        @embedFile("conformance_cases/conformance_short_circuit_and_or.expected"),
    );
}

// Faz F.3 (bkz. plan dosyası "Dil uzantısı: 'lowlevel:'in 'manuel
// katman'a genişletilmesi") — `ptr_add`/`ptr_read_int`/`ptr_write_int`/
// `detach`, `qbeOp2Imm`/`qbeLoad`/`qbeStore`'un PAYLAŞILAN, backend-
// soyutlanmış emitter'larını KULLANDIĞINDAN SIFIR EK kod İLE HER İKİ
// backend'de de ÇALIŞIR — BU testin SOMUT kanıtı.
test "conformance: Faz F.3 — detach/ptr_add/ptr_read_int/ptr_write_int her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_lowlevel_ptr_ops.nox"),
        @embedFile("conformance_cases/conformance_lowlevel_ptr_ops.expected"),
    );
}

// v2.0 madde 3 (bkz. nox-teknik-spesifikasyon.md §3.191): `dict[K,V]`
// (literal/indeksleme/`.keys()`/bir sınıf alanı olarak) ŞU ANA KADAR
// HİÇ conformance-test EDİLMEMİŞTİ — `conformance_list_elements`in dict
// eşdeğeri.
test "conformance: dict[K,V] (literal/indeksleme/.keys()/sınıf alanı) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_dict_elements.nox"),
        @embedFile("conformance_cases/conformance_dict_elements.expected"),
    );
}

// Faz 7'nin vtable/`class_id` hiyerarşik eşleştirmesinin (bir `except
// Base:`in bir `Derived` örneğini yakalaması) backend-bağımsız olduğunun
// kanıtı.
test "conformance: sınıf kalıtımı + hiyerarşik except (Faz 7) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_inheritance_exception_hierarchy.nox"),
        @embedFile("conformance_cases/conformance_inheritance_exception_hierarchy.expected"),
    );
}

// Mevcut fixture'lar SADECE str'i bir DEĞER olarak taşıyordu — bu, str'in
// KENDİ işlemlerini (birleştirme/indeksleme/f-string/dönüşümler) test
// eder.
test "conformance: str işlemleri (birleştirme/indeksleme/f-string/dönüşümler) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_string_ops.nox"),
        @embedFile("conformance_cases/conformance_string_ops.expected"),
    );
}

// `closures.zig`nin `__fnval` trampoline'ının (bkz. onun belge notu)
// backend-bağımsız olduğunun kanıtı — ŞU ANA KADAR sadece closure
// CAPTURE test ediliyordu, çıplak fonksiyon-DEĞERİ (atama/argüman/
// dolaylı çağrı) DEĞİL.
test "conformance: birinci-sınıf fonksiyon değeri (atama/argüman/dolaylı çağrı) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_function_value.nox"),
        @embedFile("conformance_cases/conformance_function_value.expected"),
    );
}

// ASAP destructor + istisna-unwinding codegen yolunun (bkz. exceptions.zig)
// İç İçE try/except/finally + with (context manager) kombinasyonunda
// backend-bağımsız olduğunun kanıtı.
test "conformance: iç içe try/except/finally + with (context manager) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_try_except_finally_with.nox"),
        @embedFile("conformance_cases/conformance_try_except_finally_with.expected"),
    );
}

// Go-tarzı `defer`in (checker'ın sentetik FuncDef'ine dayalı `genDeferStmt`,
// bkz. closures.zig) LIFO sırasının backend-bağımsız olduğunun kanıtı.
test "conformance: defer (LIFO sırası, birden fazla defer) her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_defer.nox"),
        @embedFile("conformance_cases/conformance_defer.expected"),
    );
}

// Dosyanın üst-notunun "ORM/generic çıkarım SAF derleme-zamanı, sıfır
// sapma yüzeyi" iddiasını VARSAYIM'DAN KANITLANMIŞ hale getirir —
// monomorfizasyon SONRASI üretilen somut fonksiyonun/sınıfın KENDİ
// çalışma-zamanı davranışı (generic çıkarımın KENDİSİ DEĞİL) ŞİMDİYE
// KADAR dual-backend doğrulanmamıştı.
test "conformance: generic fonksiyon/sınıf örneklemesinin ÇALIŞMA-ZAMANI davranışı her iki backend'de aynı" {
    try expectConformant(
        @embedFile("conformance_cases/conformance_generic_instantiation.nox"),
        @embedFile("conformance_cases/conformance_generic_instantiation.expected"),
    );
}

// --- Belgelenmiş sapma (divergence) testleri: checker.zig'in
// `isSpawnParamSafeType`/`isThreadTransferSafeType`si + codegen_qbe'nin
// `pool_run`/decorator KABUL-RED asimetrisi. ---

test "divergence: spawn'a list[int] parametresi — QBE reddeder, LLVM kabul eder" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_spawn_list_param.nox"),
        .rejected,
        .{ .accepted = "6\n" },
    );
}

test "divergence: spawn'a class parametresi — QBE reddeder, LLVM kabul eder" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_spawn_class_param.nox"),
        .rejected,
        .{ .accepted = "7\n" },
    );
}

test "divergence: nox.thread.start'a list[int] parametresi — QBE reddeder, LLVM kabul eder" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_thread_start_list_param.nox"),
        .rejected,
        .{ .accepted = "60\n" },
    );
}

test "divergence: nox.thread.pool_run — QBE reddeder (codegen error.Unsupported), LLVM kabul eder" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_pool_run.nox"),
        .rejected,
        .{ .accepted = "42\n" },
    );
}

// TERS yön — bu paketteki TEK "LLVM daha KISITLI" örneği.
test "divergence: decorator kullanımı — QBE kabul eder, LLVM reddeder (Faz LLVM.4'ün bilinçli kapsam-dışı bırakması)" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_decorator.nox"),
        .{ .accepted = "1\n" },
        .rejected,
    );
}

// v2.0 madde 3 (bkz. nox-teknik-spesifikasyon.md §3.191): `isSpawnParamSafeType`/
// `isThreadTransferSafeType`nin LLVM altında gevşetilen kümesi `list`/
// `class`/`dict`'İN ÜÇÜNÜ de içeriyor — yukarıdaki 3 mevcut divergence
// testi SADECE list (HER İKİ mekanizma İçİn) + class (spawn İçİn)
// kapsıyordu. Bu ÜÇ YENİ test, 2 mekanizma × 3 tip = 6 kombinasyonluk
// matrisin KALAN yarısını (dict×spawn, class×thread.start, dict×
// thread.start) tamamlar.

test "divergence: spawn'a dict[str,str] parametresi — QBE reddeder, LLVM kabul eder" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_spawn_dict_param.nox"),
        .rejected,
        .{ .accepted = "merhaba\n" },
    );
}

test "divergence: nox.thread.start'a sınıf parametresi — QBE reddeder, LLVM kabul eder" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_thread_start_class_param.nox"),
        .rejected,
        .{ .accepted = "70\n" },
    );
}

test "divergence: nox.thread.start'a dict[str,str] parametresi — QBE reddeder, LLVM kabul eder" {
    try expectDivergence(
        @embedFile("conformance_cases/divergence_thread_start_dict_param.nox"),
        .rejected,
        .{ .accepted = "merhaba\n" },
    );
}
