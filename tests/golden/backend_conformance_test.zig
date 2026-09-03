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
