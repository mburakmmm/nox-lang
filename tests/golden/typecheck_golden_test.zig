//! Tip denetleyici golden testleri: `tests/golden/typecheck_cases/*.nox`
//! kaynaklarını denetleyip sonucu (`OK` ya da `HATA <kod>: <mesaj>`)
//! `*.expected` ile karşılaştırır. AGENTS.md İlke #7.

const std = @import("std");
const nox = @import("nox");

/// v1.30.0: `expectGolden`in AYNISI, AMA `Checker.backend`i `.llvm`
/// olarak AYARLAR — `isSpawnParamSafeType`nin `list`/`dict`/`class`ı
/// spawn-parametresi olarak yalnızca `.llvm` (`--release`) altında
/// İZİN VERMESİ yüzünden (bkz. `checker.zig`nin `isSpawnParamSafeType`
/// belge notu), spawn-paylaşımlı mutasyon kontrolünün fixture'ları
/// (`err_spawn_shared_*`/`ok_spawn_shared_*`) BU backend'i GEREKTİRİR —
/// `.qbe`de (varsayılan `check()` yolu) bu tipler zaten `isSpawnParamSafeType`
/// TARAFINDAN `spawn`a argüman olarak REDDEDİLDİĞİNDEN, YENİ mutasyon
/// kontrolüne HİÇ ULAŞILMAZ. `llvm_golden_test.zig`nin `compileAndRunLlvm`ı
/// İLE AYNI `checker_state.backend = .llvm` deseni, AMA kodgen/`clang`
/// OLMADAN — SAF tip denetimi (`nox.checker.check`in KENDİ `.ok`/`.err`
/// seçim mantığının BİREBİR AYNISI, backend'i AYARLAYABİLMEK İçİn burada
/// yeniden üretilir).
fn expectGoldenLlvm(comptime source: []const u8, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

    var checker_state = nox.checker.Checker.init(allocator);
    checker_state.backend = .llvm;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    checker_state.checkModule(module) catch |e| {
        try aw.writer.print("HATA {t}: {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        try std.testing.expectEqualStrings(expected, aw.written());
        return;
    };
    if (checker_state.diagnostics.items.len > 0) {
        const first = checker_state.diagnostics.items[0];
        try aw.writer.print("HATA {t}: {s}\n", .{ first.code, first.message });
    } else {
        try aw.writer.writeAll("OK\n");
    }
    try std.testing.expectEqualStrings(expected, aw.written());
}

fn expectGolden(comptime source: []const u8, comptime expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    switch (nox.checker.check(allocator, module)) {
        .ok => try aw.writer.writeAll("OK\n"),
        .err => |e| try aw.writer.print("HATA {t}: {s}\n", .{ e.code, e.message }),
    }

    try std.testing.expectEqualStrings(expected, aw.written());
}

test "golden(typecheck): aritmetik ve kontrol akışı" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_arith_and_control_flow.nox"),
        @embedFile("typecheck_cases/ok_arith_and_control_flow.expected"),
    );
}

test "golden(typecheck): fonksiyon ve sınıf" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_function_and_class.nox"),
        @embedFile("typecheck_cases/ok_function_and_class.expected"),
    );
}

test "golden(typecheck): liste ve indeksleme" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_list_and_index.nox"),
        @embedFile("typecheck_cases/ok_list_and_index.expected"),
    );
}

test "golden(typecheck): var_decl tip uyuşmazlığı" {
    try expectGolden(
        @embedFile("typecheck_cases/err_var_decl_mismatch.nox"),
        @embedFile("typecheck_cases/err_var_decl_mismatch.expected"),
    );
}

test "golden(typecheck): Faz T.1 — pozisyon takibi ÖNCEKİ deyimlerde TAKILI KALMAZ, hatalı SONRAKİ deyimin satırını raporlar" {
    try expectGolden(
        @embedFile("typecheck_cases/err_position_tracks_later_statement.nox"),
        @embedFile("typecheck_cases/err_position_tracks_later_statement.expected"),
    );
}

test "golden(typecheck): tanımsız değişken" {
    try expectGolden(
        @embedFile("typecheck_cases/err_undefined_variable.nox"),
        @embedFile("typecheck_cases/err_undefined_variable.expected"),
    );
}

test "golden(typecheck): argüman sayısı uyuşmazlığı" {
    try expectGolden(
        @embedFile("typecheck_cases/err_arg_count_mismatch.nox"),
        @embedFile("typecheck_cases/err_arg_count_mismatch.expected"),
    );
}

test "golden(typecheck): bool olmayan koşul" {
    try expectGolden(
        @embedFile("typecheck_cases/err_condition_not_bool.nox"),
        @embedFile("typecheck_cases/err_condition_not_bool.expected"),
    );
}

test "golden(typecheck): tanımsız sınıf alanı" {
    try expectGolden(
        @embedFile("typecheck_cases/err_undefined_attribute.nox"),
        @embedFile("typecheck_cases/err_undefined_attribute.expected"),
    );
}

test "golden(typecheck): range için geçersiz argüman" {
    try expectGolden(
        @embedFile("typecheck_cases/err_range_bad_arg.nox"),
        @embedFile("typecheck_cases/err_range_bad_arg.expected"),
    );
}

test "golden(typecheck): tüm yollarda return olmayan fonksiyon" {
    try expectGolden(
        @embedFile("typecheck_cases/err_missing_return.nox"),
        @embedFile("typecheck_cases/err_missing_return.expected"),
    );
}

test "golden(typecheck): raise/try/except/finally" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_raise_try_except.nox"),
        @embedFile("typecheck_cases/ok_raise_try_except.expected"),
    );
}

test "golden(typecheck): sınıf örneği olmayan bir şeyi raise etmek" {
    try expectGolden(
        @embedFile("typecheck_cases/err_raise_non_class.nox"),
        @embedFile("typecheck_cases/err_raise_non_class.expected"),
    );
}

test "golden(typecheck): lowlevel bloğu normal kurallarla denetlenir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_lowlevel_block.nox"),
        @embedFile("typecheck_cases/ok_lowlevel_block.expected"),
    );
}

test "golden(typecheck): lowlevel içinde de tip uyuşmazlığı yakalanır" {
    try expectGolden(
        @embedFile("typecheck_cases/err_lowlevel_type_mismatch.nox"),
        @embedFile("typecheck_cases/err_lowlevel_type_mismatch.expected"),
    );
}

test "golden(typecheck): lowlevel içinde tanımlanan ad bloktan sonra kapsam dışı kalır" {
    try expectGolden(
        @embedFile("typecheck_cases/err_lowlevel_scope_leak.nox"),
        @embedFile("typecheck_cases/err_lowlevel_scope_leak.expected"),
    );
}

test "golden(typecheck): generic fonksiyon — birden çok somut tiple örnekleme" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_generic_function.nox"),
        @embedFile("typecheck_cases/ok_generic_function.expected"),
    );
}

test "golden(typecheck): generic tip parametresi çelişkili tiplere çözümlenirse hata" {
    try expectGolden(
        @embedFile("typecheck_cases/err_generic_conflicting_binding.nox"),
        @embedFile("typecheck_cases/err_generic_conflicting_binding.expected"),
    );
}

test "golden(typecheck): yalnızca dönüş tipinde kullanılan bir generic tip parametresi çıkarılamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_generic_unresolved_param.nox"),
        @embedFile("typecheck_cases/err_generic_unresolved_param.expected"),
    );
}

// Faz P2.2: BAĞLAM (var_decl/atama/çağrı/return) YOKSA boş liste literalinin
// tipi HÂLÂ çıkarılamaz — `checkExprExpected`in "TEK choke point" ilkesi
// (bkz. onun belge notu): `print([])` gibi bir bağlamsız kullanım, ESKİDEN
// OLDUĞU GİBİ, AYNI hatayı üretmeye devam eder.
test "golden(typecheck): bağlam yoksa boş liste literalinin tipi HÂLÂ çıkarılamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_empty_list_lit_no_context.nox"),
        @embedFile("typecheck_cases/err_empty_list_lit_no_context.expected"),
    );
}

test "golden(typecheck): metodlar generic olamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_generic_method_rejected.nox"),
        @embedFile("typecheck_cases/err_generic_method_rejected.expected"),
    );
}

test "golden(typecheck): protokol — iki farklı sınıfla yapısal eşleşme + monomorphization" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_protocol_dispatch.nox"),
        @embedFile("typecheck_cases/ok_protocol_dispatch.expected"),
    );
}

test "golden(typecheck): protokolü karşılamayan (eksik metod) sınıf reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_protocol_missing_method.nox"),
        @embedFile("typecheck_cases/err_protocol_missing_method.expected"),
    );
}

test "golden(typecheck): protokol imzasıyla uyuşmayan (dönüş tipi) metod reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_protocol_signature_mismatch.nox"),
        @embedFile("typecheck_cases/err_protocol_signature_mismatch.expected"),
    );
}

test "golden(typecheck): protokol metodu yalnızca 'pass' gövdesine sahip olabilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_protocol_method_bad_body.nox"),
        @embedFile("typecheck_cases/err_protocol_method_bad_body.expected"),
    );
}

test "golden(typecheck): extern def (C ABI FFI bildirimi) normal fonksiyon gibi çağrılabilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_extern_def.nox"),
        @embedFile("typecheck_cases/ok_extern_def.expected"),
    );
}

test "golden(typecheck): extern def, C ABI'de güvenli olmayan (list[T]) bir parametre reddeder" {
    try expectGolden(
        @embedFile("typecheck_cases/err_extern_unsafe_param.nox"),
        @embedFile("typecheck_cases/err_extern_unsafe_param.expected"),
    );
}

test "golden(typecheck): async def + spawn + await + Channel[T].send/recv" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_async_spawn_await_channel.nox"),
        @embedFile("typecheck_cases/ok_async_spawn_await_channel.expected"),
    );
}

test "golden(typecheck): 'await', 'async def' dışında reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_await_outside_async.nox"),
        @embedFile("typecheck_cases/err_await_outside_async.expected"),
    );
}

test "golden(typecheck): 'spawn', async olmayan bir fonksiyonu reddeder" {
    try expectGolden(
        @embedFile("typecheck_cases/err_spawn_non_async.nox"),
        @embedFile("typecheck_cases/err_spawn_non_async.expected"),
    );
}

test "golden(typecheck): bir 'async def' fonksiyonu doğrudan (spawn'sız) çağrılamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_call_async_directly.nox"),
        @embedFile("typecheck_cases/err_call_async_directly.expected"),
    );
}

test "golden(typecheck): extern def — opak ptr tipi (Faz 20 ikinci artım)" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_extern_ptr.nox"),
        @embedFile("typecheck_cases/ok_extern_ptr.expected"),
    );
}

test "golden(typecheck): __init__ içermeyen sınıf (alansız, yalnızca metod)" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_class_no_init.nox"),
        @embedFile("typecheck_cases/ok_class_no_init.expected"),
    );
}

test "golden(typecheck): 'obj.attr = değer' ataması self dışından, MEVCUT bir alana" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_attr_assign_external.nox"),
        @embedFile("typecheck_cases/ok_attr_assign_external.expected"),
    );
}

test "golden(typecheck): 'obj.attr = değer' self dışından YENİ bir alan tanımlayamaz" {
    try expectGolden(
        @embedFile("typecheck_cases/err_attr_assign_new_field_external.nox"),
        @embedFile("typecheck_cases/err_attr_assign_new_field_external.expected"),
    );
}

test "golden(typecheck): iki FARKLI sınıfı '==' ile karşılaştırmak reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_eq_type_mismatch.nox"),
        @embedFile("typecheck_cases/err_class_eq_type_mismatch.expected"),
    );
}

test "golden(typecheck): Faz T.2 — İKİ bağımsız fonksiyondaki hata TEK çalıştırmada BİRLİKTE raporlanır" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = @embedFile("typecheck_cases/err_multi_diagnostic_recovery.nox");
    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

    const outcome = nox.checker.check(allocator, module);
    const err = switch (outcome) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| e,
    };
    // İKİ bağımsız fonksiyon (`f`/`g`), HER İKİSİ de kendi gövdesinde TEK bir
    // `TypeMismatch` üretiyor — kurtarma OLMASAYDI yalnızca İLKİ (satır 2)
    // raporlanırdı, `g`nin (satır 5) hatası HİÇ görülmezdi.
    try std.testing.expectEqual(@as(usize, 2), err.all.len);
    try std.testing.expect(std.mem.indexOf(u8, err.all[0].message, "satır 2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.all[1].message, "satır 5:") != null);
}

// Gerçek span sistemi (bkz. plan dosyası "Gerçek span sistemi +
// yapılandırılmış tanılamalar") — Aşama 6 kabul kriteri: `checkArgs`nin
// argüman-uyuşmazlığı tanılamasının `span`ı, TÜM deyimi (`result: int =
// foo(1, "yanlış")`) DEĞİL, SPESİFİK yanlış argümanı (`"yanlış"`)
// İŞARET ETMELİ. `.message`/`.code` (mevcut 70+ fixture'ın DAYANDIĞI
// alanlar) DEĞİŞMEDİĞİNİ de AYRICA doğrular.
test "golden(typecheck): darboğaz #P0.3 — argüman tip uyuşmazlığı span'ı TÜM deyim DEĞİL SPESİFİK argümanı işaret eder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\def foo(a: int, b: int) -> int:
        \\    return a + b
        \\
        \\result: int = foo(1, "yanlis")
        \\
    ;
    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);

    const outcome = nox.checker.check(allocator, module);
    const err = switch (outcome) {
        .ok => return error.TestUnexpectedResult,
        .err => |e| e,
    };
    try std.testing.expectEqual(nox.checker.TypeError.TypeMismatch, err.code);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "satır 4:") != null);

    // Deyimin KENDİSİ 4. satırda BAŞLAR, ama "yanlis" (argüman) SÜTUN
    // 22'de başlar (`result: int = foo(1, "yanlis")`de `"` konumu) —
    // span'ın deyim BAŞLANGICINDAN (sütun 1) FARKLI, DAHA DAR olması
    // GEREKİR.
    try std.testing.expect(!err.all[0].span.isNone());
    try std.testing.expectEqual(@as(u32, 4), err.all[0].span.start_line);
    try std.testing.expect(err.all[0].span.start_col > 1);
    try std.testing.expectEqual(@as(u32, 22), err.all[0].span.start_col);
}

test "golden(typecheck): Faz U.1 — 'list.append()' alıcısı çıplak bir isim OLMALI (çağrı sonucu üzerinde çağrılamaz)" {
    try expectGolden(
        @embedFile("typecheck_cases/err_list_append_non_identifier_receiver.nox"),
        @embedFile("typecheck_cases/err_list_append_non_identifier_receiver.expected"),
    );
}

test "golden(typecheck): Faz U.3 — 'from X import Y' — Y kaynak modülde YOKSA açık hata" {
    try expectGolden(
        @embedFile("typecheck_cases/err_from_import_unknown_member.nox"),
        @embedFile("typecheck_cases/err_from_import_unknown_member.expected"),
    );
}

test "golden(typecheck): Faz U.4.1 — (int, int) -> int fonksiyon tipi imzada kabul edilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_func_type_signature.nox"),
        @embedFile("typecheck_cases/ok_func_type_signature.expected"),
    );
}

test "golden(typecheck): Faz U.4.4 — func tipi bir parametrenin DOLAYLI çağrısı kabul edilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_func_type_param_indirect_call.nox"),
        @embedFile("typecheck_cases/ok_func_type_param_indirect_call.expected"),
    );
}

test "golden(typecheck): Faz U.4.2 — iç içe def dış değişkeni yakalar (capture), kendisi çağrılmadan kabul edilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_nested_def_capture.nox"),
        @embedFile("typecheck_cases/ok_nested_def_capture.expected"),
    );
}

test "golden(typecheck): Faz U.4.2 — iç içe def'in gövdesindeki tanımsız serbest değişken açık hata verir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_nested_def_undefined_capture.nox"),
        @embedFile("typecheck_cases/err_nested_def_undefined_capture.expected"),
    );
}

test "golden(typecheck): Faz U.4.2 — yakalanan (capture) bir değişkene ATAMA reddedilir (yalnızca okunabilir)" {
    try expectGolden(
        @embedFile("typecheck_cases/err_nested_def_assign_to_capture.nox"),
        @embedFile("typecheck_cases/err_nested_def_assign_to_capture.expected"),
    );
}

test "golden(typecheck): Faz U.4.2 — generic iç içe def reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_nested_def_generic.nox"),
        @embedFile("typecheck_cases/err_nested_def_generic.expected"),
    );
}

test "golden(typecheck): Faz U.4.2 — async iç içe def reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_nested_def_async.nox"),
        @embedFile("typecheck_cases/err_nested_def_async.expected"),
    );
}

test "golden(typecheck): Faz U.5 — 'with EXPR as NAME:' __enter__/__exit__ çifti olan bir sınıfla kabul edilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_with_basic.nox"),
        @embedFile("typecheck_cases/ok_with_basic.expected"),
    );
}

test "golden(typecheck): Faz U.5 — '__enter__' metodu OLMAYAN bir sınıfla 'with' reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_with_missing_enter.nox"),
        @embedFile("typecheck_cases/err_with_missing_enter.expected"),
    );
}

test "golden(typecheck): Faz U.5 — '__exit__' metodu OLMAYAN bir sınıfla 'with' reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_with_missing_exit.nox"),
        @embedFile("typecheck_cases/err_with_missing_exit.expected"),
    );
}

test "golden(typecheck): Faz U.5 — sınıf örneği OLMAYAN bir ifadeyle 'with' reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_with_not_a_class.nox"),
        @embedFile("typecheck_cases/err_with_not_a_class.expected"),
    );
}

test "golden(typecheck): Faz BB.3 — nox.thread.start + ThreadHandle[T].join() kabul edilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_thread_start_join.nox"),
        @embedFile("typecheck_cases/ok_thread_start_join.expected"),
    );
}

test "golden(typecheck): Faz BB.3 — nox.thread.start yanlış argüman sayısını reddeder" {
    try expectGolden(
        @embedFile("typecheck_cases/err_thread_start_arg_count.nox"),
        @embedFile("typecheck_cases/err_thread_start_arg_count.expected"),
    );
}

test "golden(typecheck): Faz BB.3 — nox.thread.start'ın 'entry'i çıplak bir tanımlayıcı OLMALI" {
    try expectGolden(
        @embedFile("typecheck_cases/err_thread_start_entry_not_identifier.nox"),
        @embedFile("typecheck_cases/err_thread_start_entry_not_identifier.expected"),
    );
}

test "golden(typecheck): Faz BB.3 — nox.thread.start'ın 'entry'i 'async def' OLMALI" {
    try expectGolden(
        @embedFile("typecheck_cases/err_thread_start_entry_not_async.nox"),
        @embedFile("typecheck_cases/err_thread_start_entry_not_async.expected"),
    );
}

test "golden(typecheck): Faz BB.3 — nox.thread.start'ın 'entry'i tam olarak bir parametre almalı" {
    try expectGolden(
        @embedFile("typecheck_cases/err_thread_start_param_count.nox"),
        @embedFile("typecheck_cases/err_thread_start_param_count.expected"),
    );
}

test "golden(typecheck): Faz BB.3 — nox.thread.start güvenli olmayan (list[int]) bir parametre tipini reddeder" {
    try expectGolden(
        @embedFile("typecheck_cases/err_thread_start_unsafe_type.nox"),
        @embedFile("typecheck_cases/err_thread_start_unsafe_type.expected"),
    );
}

// Faz MN.9.4: `Checker.backend`in VARSAYILANI (`.qbe`) İLE `nox.thread.
// start`ın `list[int]` DÖNÜŞ tipi REDDEDİLİR — `tests/golden/llvm_golden_
// test.zig`nin AYNI (BİREBİR) kaynağını `.llvm` backend'iyle BAŞARIYLA
// derleyip ÇALIŞTIRAN pozitif testinin negatif KARŞILIĞI (bkz. onun MN.9.4
// notu) — backend sınırının GERÇEKTEN ZORLANDIĞININ kanıtı: `noxc check`
// (HER ZAMAN `.qbe`) BUNU HATA olarak İŞARETLER, AYNI kaynak `noxc build
// --release` İLE GERÇEKTEN DERLENEBİLİR (bilinçli taşınabilirlik-maliyeti).
test "golden(typecheck): Faz MN.9.4 — nox.thread.start list[int] SADECE --release'de güvenli, .qbe varsayılanında reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_thread_start_release_only_list.nox"),
        @embedFile("typecheck_cases/err_thread_start_release_only_list.expected"),
    );
}

test "golden(typecheck): Faz BB.3 — nox.thread.start tanımsız 'entry' fonksiyonunu reddeder" {
    try expectGolden(
        @embedFile("typecheck_cases/err_thread_start_undefined_entry.nox"),
        @embedFile("typecheck_cases/err_thread_start_undefined_entry.expected"),
    );
}

test "golden(typecheck): Faz FF.4 — çıplak self, sınıf metotlarında açık self ile AYNI şekilde tip-denetiminden geçer" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_bare_self_method.nox"),
        @embedFile("typecheck_cases/ok_bare_self_method.expected"),
    );
}

test "golden(typecheck): Faz FF.4 — çıplak self, protokol metot imzalarında da GEÇERLİ (dispatch çalışır)" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_bare_self_protocol.nox"),
        @embedFile("typecheck_cases/ok_bare_self_protocol.expected"),
    );
}

// Faz FF.4: çıplak self EKLENİRKEN kapatılan bir boşluk — bu davranışı
// (AÇIKÇA YANLIŞ bir `self: X` tipinin reddedildiğini) test eden HİÇBİR
// mevcut fixture YOKTU.
test "golden(typecheck): Faz FF.4 — AÇIKÇA yanlış self tipi (sınıf) HÂLÂ reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_self_wrong_type.nox"),
        @embedFile("typecheck_cases/err_class_self_wrong_type.expected"),
    );
}

test "golden(typecheck): Faz FF.4 — AÇIKÇA yanlış self tipi (protokol) HÂLÂ reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_protocol_self_wrong_type.nox"),
        @embedFile("typecheck_cases/err_protocol_self_wrong_type.expected"),
    );
}

test "golden(typecheck): Faz FF.5 — açıkça bildirilen sınıf alanları, __init__de TAM atanınca GEÇERLİ" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_class_declared_fields.nox"),
        @embedFile("typecheck_cases/ok_class_declared_fields.expected"),
    );
}

test "golden(typecheck): Faz FF.5 — bildirilen VE çıkarılan alanlar AYNI sınıfta BİRLİKTE çalışır" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_class_declared_and_inferred_mixed.nox"),
        @embedFile("typecheck_cases/ok_class_declared_and_inferred_mixed.expected"),
    );
}

test "golden(typecheck): Faz FF.5 — bildirilen bir alan __init__de HİÇ atanmazsa reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_declared_field_unassigned.nox"),
        @embedFile("typecheck_cases/err_class_declared_field_unassigned.expected"),
    );
}

test "golden(typecheck): Faz FF.5 — bildirilen alanı OLAN ama __init__i OLMAYAN sınıf reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_declared_field_no_init.nox"),
        @embedFile("typecheck_cases/err_class_declared_field_no_init.expected"),
    );
}

test "golden(typecheck): Faz FF.5 — bildirilen tip İLE __init__deki atama ÇATIŞIRSA reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_declared_field_type_conflict.nox"),
        @embedFile("typecheck_cases/err_class_declared_field_type_conflict.expected"),
    );
}

test "golden(typecheck): Faz FF.5 — AYNI alan İKİ kez bildirilirse reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_duplicate_field_decl.nox"),
        @embedFile("typecheck_cases/err_class_duplicate_field_decl.expected"),
    );
}

test "golden(typecheck): Faz FF.6 — öz-referanslı Node.next: Node | None + while-narrowing traversal" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_optional_heap_field.nox"),
        @embedFile("typecheck_cases/ok_optional_heap_field.expected"),
    );
}

test "golden(typecheck): Faz FF.6 — int | None (auto-wrap atama + if-narrowing)" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_optional_primitive.nox"),
        @embedFile("typecheck_cases/ok_optional_primitive.expected"),
    );
}

test "golden(typecheck): Faz FF.6 — daraltılmamış Optional'a alan erişimi OptionalNotNarrowed İLE reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_optional_unnarrowed_access.nox"),
        @embedFile("typecheck_cases/err_optional_unnarrowed_access.expected"),
    );
}

test "golden(typecheck): Faz FF.6 — Optional'a uyumsuz tip atanması reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_optional_type_mismatch.nox"),
        @embedFile("typecheck_cases/err_optional_type_mismatch.expected"),
    );
}

test "golden(typecheck): Faz GG.3 — 'defer' modül seviyesinde (fonksiyon/metod dışında) reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_defer_outside_function.nox"),
        @embedFile("typecheck_cases/err_defer_outside_function.expected"),
    );
}

test "golden(typecheck): Faz 7 (tekli kalıtım) — override taban sınıftaki imzayla eşleşmezse reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_override_signature_mismatch.nox"),
        @embedFile("typecheck_cases/err_class_override_signature_mismatch.expected"),
    );
}

test "golden(typecheck): Faz 7 — bilinmeyen bir taban sınıf adı reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_unknown_base.nox"),
        @embedFile("typecheck_cases/err_class_unknown_base.expected"),
    );
}

test "golden(typecheck): Faz 7 — generic sınıf + taban sınıf birlikte reddedilir (v1 kapsamı dışı)" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_generic_with_base.nox"),
        @embedFile("typecheck_cases/err_class_generic_with_base.expected"),
    );
}

test "golden(typecheck): Faz 7 — 'super()' bir metod gövdesi DIŞINDA reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_class_super_outside_method.nox"),
        @embedFile("typecheck_cases/err_class_super_outside_method.expected"),
    );
}

// Faz 1 decorator (bkz. plan dosyası "Decorator sözdizimi + metadata-tabanlı
// metaprogramming"): checker doğrulama testleri.

test "golden(decorator): argümansız + string-literal argümanlı decorator'lar üst-düzey fonksiyonlarda kabul edilir" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_decorator_basic.nox"),
        @embedFile("typecheck_cases/ok_decorator_basic.expected"),
    );
}

test "golden(decorator): literal-olmayan bir decorator argümanı reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_decorator_non_literal_arg.nox"),
        @embedFile("typecheck_cases/err_decorator_non_literal_arg.expected"),
    );
}

test "golden(decorator): bir sınıf üzerindeki decorator v1'de AÇIKÇA reddedilir" {
    try expectGolden(
        @embedFile("typecheck_cases/err_decorator_on_class.nox"),
        @embedFile("typecheck_cases/err_decorator_on_class.expected"),
    );
}

// v1.30.0 (bkz. plan dosyası "list[T]/dict[K,V]/class — spawn-paylaşımlı
// mutasyonun DERLEME-ZAMANINDA reddi"): bir `spawn` hedefi fonksiyonun
// `list`/`dict`/`class` tipli paylaşılan parametresinin kendi gövdesinde
// mutasyona uğratılması derleme zamanında reddedilir.

test "golden(spawn-shared-mutation): 'spawn' hedefinin list parametresine .append() reddedilir" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_list_append.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_list_append.expected"),
    );
}

test "golden(spawn-shared-mutation): 'spawn' hedefinin list parametresine index-atama (xs[i]=) reddedilir" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_list_index_assign.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_list_index_assign.expected"),
    );
}

test "golden(spawn-shared-mutation): 'spawn' hedefinin dict parametresine index-atama (d[k]=) reddedilir" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_dict_mutation.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_dict_mutation.expected"),
    );
}

test "golden(spawn-shared-mutation): 'spawn' hedefinin class parametresine alan-atama (obj.alan=) reddedilir" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_class_mutation.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_class_mutation.expected"),
    );
}

test "golden(spawn-shared-mutation): spawn-hedefi tespiti METİNSEL sıradan bağımsızdır (fonksiyon çağrıdan SONRA tanımlansa bile yakalanır)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_target_defined_after_call.nox"),
        @embedFile("typecheck_cases/err_spawn_target_defined_after_call.expected"),
    );
}

test "golden(spawn-shared-mutation): 'spawn' hedefi OLMAYAN sıradan fonksiyonların kendi list/dict/class parametrelerini mutasyona uğratması ETKİLENMEZ (regresyon yok)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_mutation_no_spawn_target.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_mutation_no_spawn_target.expected"),
    );
}

// v1.34.0 (bkz. plan dosyası "SpawnSharedMutation'ı iç içe (nested) alan
// erişimine genelleştirme"): `resolveExprSharedType`nin ARBİTRER derinlikte
// bir attribute zincirini (`b.xs`, `o.inner.xs`, ...) çözebildiğini
// kanıtlayan testler — ESKİDEN "v1 kapsamı DIŞINDA, bilinçli olarak
// yakalanmaz" diye test edilen `b.xs[0]=` deseni ARTIK YAKALANIR (bkz.
// `err_spawn_shared_nested_field_mutation`, YENİDEN ADLANDIRILDI/davranışı
// TERSİNE DÖNDÜ). Çağrı-grafiği tabanlı transitif analiz (bir helper
// fonksiyon ÇAĞRISI ÜZERİNDEN mutasyon) HÂLÂ kapsam DIŞI — AYRI bir test
// bunu KANITLAR.

test "golden(spawn-shared-mutation): TEK seviye iç içe alan (`b.xs[i]=`) ARTIK yakalanır (v1.34.0)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_nested_field_mutation.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_nested_field_mutation.expected"),
    );
}

test "golden(spawn-shared-mutation): İKİ seviye iç içe sınıf zinciri (`o.inner.xs.append()`) de yakalanır — arbitrer derinlik" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_deep_nested_field_mutation.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_deep_nested_field_mutation.expected"),
    );
}

// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): `computeMutatesGraph`
// artık BİR yardımcı fonksiyon ÇAĞRISI üzerinden mutasyonu da (worklist/
// ters-grafik yayılımıyla, ARBİTRER derinlikte) yakalıyor — YUKARIDAKİ
// eski "hâlâ kapsam dışı" testinin SENARYOSU AYNI kaldı, AMA davranışı
// TERSİNE DÖNDÜ (dosya YENİDEN ADLANDIRILDI: err_spawn_shared_transitive_
// mutation_now_caught). Metod çağrıları/dolaylı çağrılar HÂLÂ kapsam
// DIŞI (bkz. plan).
test "golden(spawn-shared-mutation): BİR yardımcı fonksiyon çağrısı üzerinden mutasyon ARTIK yakalanır (v1.44.0, GG.20)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_transitive_mutation_now_caught.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_transitive_mutation_now_caught.expected"),
    );
}

test "golden(spawn-shared-mutation): İKİ SEVİYELİ yardımcı fonksiyon zinciri üzerinden mutasyon da yakalanır (transitif kanıt)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_two_level_transitive_mutation.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_two_level_transitive_mutation.expected"),
    );
}

test "golden(spawn-shared-mutation): SALT-OKUNUR bir yardımcı (len() ÇAĞIRAN) hâlâ yakalanmaz — regresyon-yok kanıtı" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_read_only_helper_not_caught.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_read_only_helper_not_caught.expected"),
    );
}

// GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"): salt-okunur,
// override EDİLMEYEN (final) bir METOD üzerinden argüman-yönlendirme
// ARTIK yakalanmıyor (v1.44.0'da HER metod çağrısı koşulsuz kaçış/mutasyon
// sayılırdı).
test "golden(spawn-shared-mutation): final (override-suz) bir metoda argüman olarak geçen paylaşılan parametre yakalanmaz" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_final_method_read_only_not_caught.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_final_method_read_only_not_caught.expected"),
    );
}

test "golden(spawn-shared-mutation): final bir metodun KENDİSİ mutasyona uğratıyorsa HÂLÂ yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_final_method_mutation_caught.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_final_method_mutation_caught.expected"),
    );
}

// KIRMIZI-TAKIM (KRİTİK): `Helper.peek` KENDİSİ salt-okunur AMA `SubHelper`
// ONU override EDİP mutasyona uğratıyor — `peek` bu YÜZDEN final DEĞİL,
// muhafazakâr kalınmalı. `forward(h, xs): h.peek(xs)`nin KENDİSİ bu
// YÜZDEN (metod polimorfik OLDUĞUNDAN) `computeMutatesGraph`nin "çözülemeyen
// çağrı" tohum-yoluna düşer — `worker`nin `forward`u ÇAĞIRMASI ÜZERİNDEN
// BU tohum transitif olarak yayılıp YİNE DE yakalanır.
test "golden(spawn-shared-mutation): KIRMIZI-TAKIM — override edilen bir metot üzerinden yönlendirme muhafazakâr kalır (final YANLIŞ kanıtlanmaz)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_overridden_method_stays_conservative.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_overridden_method_stays_conservative.expected"),
    );
}

// HH.2 (bkz. plan dosyası "post-spawn çağıran-tarafı mutasyon
// denetleyicisini CFG-farkındalı yapma"): `checkNoPostSpawnCallerMutation`
// ARTIK `if`/`elif`/`else` VE `while`/`for` gövdelerine ÖZYİNELER —
// harici bir incelemenin işaret ettiği, ÖNCEDEN yakalanmayan TAM örnek.
test "golden(post-spawn-caller-mutation): spawn'dan SONRA bir if gövdesi İÇİNDEKİ mutasyon ARTIK yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_mutation_inside_if.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_mutation_inside_if.expected"),
    );
}

test "golden(post-spawn-caller-mutation): if gövdesi SADECE okuyorsa regresyon yok" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_mutation_if_read_only.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_mutation_if_read_only.expected"),
    );
}

// "İki-geçiş" yaklaşımı: mutasyon döngü gövdesinin BAŞINDA, spawn AYNI
// gövdenin SONUNDA — TEK geçiş bu geri-kenarı KAÇIRIRDI.
test "golden(post-spawn-caller-mutation): döngü geri-kenarındaki mutasyon (gövde başı, spawn gövde sonu) yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_mutation_loop_back_edge.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_mutation_loop_back_edge.expected"),
    );
}

test "golden(post-spawn-caller-mutation): elif dalındaki mutasyon da yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_mutation_in_elif.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_mutation_in_elif.expected"),
    );
}

// Tasarımın BİLİNÇLİ, kabul edilen aşırı-muhafazakârlığı — bkz. fixture'ın
// KENDİ belge notu.
test "golden(post-spawn-caller-mutation): if İÇİNDE spawn edilen bir paylaşım, if KAPANDIKTAN SONRA da uçuşta sayılır (bilinçli aşırı-muhafazakârlık)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_mutation_after_if_conservative.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_mutation_after_if_conservative.expected"),
    );
}

// HH.5 (bkz. plan dosyası "v1.51'in [HH.2] post-spawn checker'ında
// fork/merge soundness düzeltmesi"): harici bir incelemenin BULDUĞU,
// v1.51.0/v1.53.0'da SESSİZCE derlenen GERÇEK bir false-negative — bir
// daldaki `await`, TEK, paylaşılan bir durum YÜZÜNDEN KARDEŞ dalın
// mutasyon kontrolünü YANLIŞLIKLA "temizliyordu". Branch-başına klon +
// çıkışta union-birleştirme BUNU ARTIK YAKALAR.
test "golden(post-spawn-caller-mutation): HH.5 — bir daldaki await, kardeş dalın mutasyonunu GİZLEYEMEZ (branch-leak false-negative düzeltmesi)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_mutation_branch_leak.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_mutation_branch_leak.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.5 — TERS yönde de (mutasyon then, await else) yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_mutation_branch_leak_reverse.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_mutation_branch_leak_reverse.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.5 — hiçbir dalda mutasyon yoksa regresyon yok" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_mutation_branch_no_leak.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_mutation_branch_no_leak.expected"),
    );
}

// HH.6 (bkz. plan dosyası "post-spawn checker'ına çoklu-sahip [multi-
// owner] kaynak takibi"): harici bir incelemenin BULDUĞU, v1.54.0'da
// (HH.5) SESSİZCE derlenen GERÇEK bir false-negative — bir kaynağı İKİ
// AYRI spawn PAYLAŞTIĞINDA, BİRİNİN await edilmesi kaynağı TAMAMEN
// "temiz" saymamalı (DİĞER spawn HÂLÂ ÇALIŞIYOR olabilir).
test "golden(post-spawn-caller-mutation): HH.6 — iki task aynı kaynağı paylaşıyor, birini await etmek diğerinin sahipliğini SİLMEZ" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_multi_owner_await_one_mutate.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_multi_owner_await_one_mutate.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.6 — her iki task da await edildikten sonra mutasyon güvenlidir" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_multi_owner_await_both_mutate.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_multi_owner_await_both_mutate.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.6 — fire-and-forget + isimli task aynı kaynağı paylaşırsa isimli task await edilse de HÂLÂ reddedilir" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_fire_and_forget_plus_named_task.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_fire_and_forget_plus_named_task.expected"),
    );
}

// HH.7 (bkz. plan dosyası "post-spawn checker'ına döngü-tekrarlı spawn-
// site kilitlemesi"): harici bir incelemenin BULDUĞU, v1.55.0'da (HH.6)
// SESSİZCE derlenen GERÇEK bir false-negative — döngü GÖVDESİ HER
// iterasyonda AYNI (STATİK) AST-düğümünden spawn ediyor, döngü SONRASI
// TEK bir await SADECE SON iterasyonun task'ını joinliyor.
test "golden(post-spawn-caller-mutation): HH.7 — döngü içinde tekrarlanan spawn-site, döngü sonrası tek bir await ile TEMİZLENEMEZ" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_loop_repeated_site_await_after.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_loop_repeated_site_await_after.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.7 — her iterasyon KENDİ task'ını döngü İÇİNDE join ederse regresyon yok" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_loop_repeated_site_await_inside_iteration.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_loop_repeated_site_await_inside_iteration.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.7 — döngü içinde koşullu await hâlâ yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_loop_conditional_await.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_loop_conditional_await.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.7 — for döngüsü varyantı da yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_for_loop_repeated_site.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_for_loop_repeated_site.expected"),
    );
}

// HH.8 (bkz. plan dosyası "post-spawn checker'ına takma-ad [alias]
// farkındalığı"): harici bir incelemenin BULDUĞU, v1.56.0'da (HH.7)
// SESSİZCE derlenen GERÇEK bir false-negative — checker paylaşılan
// kaynağı DEĞİŞKEN İSMİYLE takip ediyordu, `ys = xs` (GERÇEK aliasing)
// SONRASI `ys` ÜZERİNDEN yapılan bir mutasyon `xs`i spawn'a paylaşan
// checker'ı ATLATABİLİYORDU.
test "golden(post-spawn-caller-mutation): HH.8 — alias (ys=xs) ÜZERİNDEN mutasyon YAKALANIR" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_alias_mutation.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_alias_mutation.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.8 — TERS yönde de (spawn alias ile, mutasyon kaynak isimle) yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_alias_mutation_reverse.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_alias_mutation_reverse.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.8 — sınıf örneği alias'ı ÜZERİNDEN attribute-atama yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_alias_class_attribute_mutation.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_alias_class_attribute_mutation.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.8 — bağımsız (alias OLMAYAN) iki liste yanlışlıkla reddedilmez" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_no_alias_independent_lists.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_no_alias_independent_lists.expected"),
    );
}

// HH.9 (bkz. plan dosyası "post-spawn checker'ının alias-takibindeki 2
// boşluk"): harici bir incelemenin BULDUĞU İKİ boşluk — (1) düz yeniden-
// atama (`ys = xs`, `.var_decl` DEĞİL) alias olarak izlenmiyordu, (2)
// BOŞ liste/dict literalleri kaynak-kimliği ÇAKIŞABİLİYORDU (BENİM KENDİ
// HH.8 hatam — YENİ bir false-positive).
test "golden(post-spawn-caller-mutation): HH.9 — düz yeniden-atama (ys = xs) İLE alias mutasyonu YAKALANIR" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_alias_reassignment.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_alias_reassignment.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.9 — bağımsız BOŞ listeler yanlışlıkla reddedilmez (kaynak-kimliği çakışması DÜZELTİLDİ)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_independent_empty_lists.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_independent_empty_lists.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.9 — bağımsız BOŞ dict'ler yanlışlıkla reddedilmez" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_independent_empty_dicts.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_independent_empty_dicts.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.9 — alias SONRASI YENİ bir kaynağa yeniden-atama artık BAĞIMSIZDIR" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_reassign_alias_then_fresh.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_reassign_alias_then_fresh.expected"),
    );
}

// HH.10 (bkz. plan dosyası "post-spawn checker'ına dönüş-alias etkileri"):
// bir fonksiyonun dönüş değerinin KENDİ parametrelerinden hangileriyle
// alias OLABİLECEĞİNİN analizi — `identity(xs): return xs` GİBİ bir
// fonksiyonun dönüş değerinin ARTIK KENDİ parametresiyle alias
// SAYILDIĞININ kanıtı (HH.8/HH.9'un KENDİ "Kapsam DIŞI" bölümünde
// BİLİNÇLİ olarak ERTELENMİŞTİ).
test "golden(post-spawn-caller-mutation): HH.10 — identity(xs) dönüşü xs İLE alias, mutasyon YAKALANIR" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_return_alias_identity.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_return_alias_identity.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.10 — choose(a,b,flag) İKİ parametrenin UNION'ı, HER İKİSİ de yakalanır" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/err_spawn_shared_return_alias_choose_union.nox"),
        @embedFile("typecheck_cases/err_spawn_shared_return_alias_choose_union.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.10 — make() fresh döner, mutasyon GÜVENLİDİR (regresyon-yok)" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_return_alias_fresh.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_return_alias_fresh.expected"),
    );
}

test "golden(post-spawn-caller-mutation): HH.10 — transitif çağrı (wrapper->helper) unknown sayılır, YENİ false-positive YOK" {
    try expectGoldenLlvm(
        @embedFile("typecheck_cases/ok_spawn_shared_return_alias_transitive_unknown.nox"),
        @embedFile("typecheck_cases/ok_spawn_shared_return_alias_transitive_unknown.expected"),
    );
}

// v1.30.1 (bkz. plan dosyası "Checker'a ifade-derinliği koruması"):
// `checkExpr`/`checkBinary`nin GERÇEK bir yığın-taşması SIGABRT'ına yol
// açan (`tests/fuzz/lexer_parser_checker_fuzz.zig`nin 2000-derin
// `1+1+1+...` regresyon testi) sınırsız özyinelemesi artık `MAX_EXPR_DEPTH`
// (500) ile derleme-zamanında TEMİZ bir `TooDeeplyNested` hatasına dönüşür.

test "golden(expr-depth): MAX_EXPR_DEPTH'i aşan bir ifade TooDeeplyNested ile temiz reddedilir (çökmez)" {
    try expectGolden(
        @embedFile("typecheck_cases/err_expr_too_deeply_nested.nox"),
        @embedFile("typecheck_cases/err_expr_too_deeply_nested.expected"),
    );
}

test "golden(expr-depth): MAX_EXPR_DEPTH'in ALTINDA, gerçekçi derecede derin bir ifade ETKİLENMEDEN derlenir (regresyon yok)" {
    try expectGolden(
        @embedFile("typecheck_cases/ok_expr_nested_within_depth_limit.nox"),
        @embedFile("typecheck_cases/ok_expr_nested_within_depth_limit.expected"),
    );
}
