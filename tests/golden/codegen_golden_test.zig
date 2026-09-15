//! Codegen golden testleri: kaynağı gerçekten `qbe` + sistem `cc`'siyle
//! native bir binary'ye derler, çalıştırır ve stdout'unu karşılaştırır.
//! AGENTS.md'nin izin verdiği "kaynak → beklenen davranış" golden test
//! biçimidir (yalnızca IR metni değil, gerçek çalışma zamanı davranışı).
//!
//! Önkoşul: `qbe` ve `cc` sistemde PATH üzerinde bulunmalıdır (bkz. AGENTS.md,
//! Faz 0 karar notları — `brew install qbe`).

const std = @import("std");
const nox = @import("nox");
const compile_helpers = @import("compile_helpers.zig");

/// Faz HH.1'de `compile_helpers.zig`ye TAŞINDI (bkz. o dosyanın belge
/// notu — `backend_conformance_test.zig`nin DE ihtiyaç duyduğu, ÜÇÜNCÜ
/// bir bağımsız kopya YERİNE PAYLAŞILAN bir yardımcı). DAVRANIŞ SIFIR
/// değişti — AYNI fonksiyon gövdesi, SADECE YERİ değişti.
const compileAndRun = compile_helpers.compileAndRun;

fn expectGolden(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    // AGENTS.md §13: bellek yönetimiyle ilgili değişikliklerde leak testi
    // yeşil olmalı — runtime bir sızıntı tespit ederse bunu stderr'e yazar
    // (bkz. runtime/alloc/asap.zig, nox_runtime_deinit).
    if (run_result.stderr.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{run_result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings(expected, run_result.stdout);
}

/// Yakalanmamış bir istisnayla sonlanması BEKLENEN programlar için: çıkış
/// kodunun sıfırdan farklı olduğunu ve istisnaya kadarki stdout'un doğru
/// olduğunu doğrular (bkz. runtime/errors/handle.zig, nox_unhandled_exception).
fn expectUncaughtException(source: []const u8, expected_stdout: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited == 0) {
        std.debug.print("program beklenenden farklı sonlandı (sıfırdan farklı bir çıkış kodu bekleniyordu)\n", .{});
        return error.ExpectedNonZeroExit;
    }
    try std.testing.expectEqualStrings(expected_stdout, run_result.stdout);
}

/// `expectUncaughtException`in AYNISI ama Faz OO.3 (bkz. nox-teknik-
/// spesifikasyon.md §3.84) İçİn: STDERR'in `nox_unhandled_exception`ın
/// ARTIK RAPORLADIĞI GERÇEK sınıf adı + `raise` satır numarasını TAM
/// olarak TAŞIDIĞINI da doğrular (`expectGolden`nin AKSİNE — burada
/// sıfırdan-farklı çıkış YÜZÜNDEN stderr'in DOLU olması ZATEN BEKLENİR,
/// bu YÜZDEN "boş stderr = sızıntı" kontrolü UYGULANMAZ).
fn expectUncaughtExceptionWithStderr(source: []const u8, expected_stdout: []const u8, expected_stderr: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited == 0) {
        std.debug.print("program beklenenden farklı sonlandı (sıfırdan farklı bir çıkış kodu bekleniyordu)\n", .{});
        return error.ExpectedNonZeroExit;
    }
    try std.testing.expectEqualStrings(expected_stdout, run_result.stdout);
    try std.testing.expectEqualStrings(expected_stderr, run_result.stderr);
}

/// Faz TEST.2 (bkz. plan dosyası "codegen_golden_test.zig'in 300 sıralı
/// testini gerçek iş-parçacığı paralelliğiyle hızlandırma"): bu 3 tip
/// SADECE 265 UNIFORM fixture'ı (aşağıdaki `fixtures` dizisi) tek bir
/// veri şemasında temsil eder — 33 heterojen "codegen: ..." testi (IR
/// metnini doğrudan inceleyen) BU şemaya UYMADIĞINDAN dokunulmadan,
/// olduğu gibi kalır.
const FixtureKind = enum { golden, uncaught_exception, uncaught_exception_with_stderr };

const Fixture = struct {
    name: []const u8,
    kind: FixtureKind,
    source: []const u8,
    expected_stdout: []const u8,
    expected_stderr: []const u8 = "",
};

const FixtureResult = struct {
    ok: bool = false,
    err_name: []const u8 = "",
};

const fixtures = [_]Fixture{
    .{ .name = "codegen(çalıştır): fibonacci (özyineleme + while + print)", .kind = .golden, .source = @embedFile("codegen_cases/fibonacci.nox"), .expected_stdout = @embedFile("codegen_cases/fibonacci.expected") },
    .{ .name = "codegen(çalıştır): tam bölme ve mod işaret düzeltmesi (negatif işlenenler)", .kind = .golden, .source = @embedFile("codegen_cases/floordiv_mod_signs.nox"), .expected_stdout = @embedFile("codegen_cases/floordiv_mod_signs.expected") },
    .{ .name = "codegen(çalıştır): üs alma (pow) ve karışık int/float aritmetik", .kind = .golden, .source = @embedFile("codegen_cases/pow_and_float_mix.nox"), .expected_stdout = @embedFile("codegen_cases/pow_and_float_mix.expected") },
    .{ .name = "codegen(çalıştır): bool yazdırma ve mantıksal operatörler", .kind = .golden, .source = @embedFile("codegen_cases/bool_logic.nox"), .expected_stdout = @embedFile("codegen_cases/bool_logic.expected") },
    .{ .name = "codegen(çalıştır): and/or gerçekten kısa devre yapar (yan etkili sağ operand)", .kind = .golden, .source = @embedFile("codegen_cases/short_circuit_and_or.nox"), .expected_stdout = @embedFile("codegen_cases/short_circuit_and_or.expected") },
    .{ .name = "codegen(çalıştır): str[pos] sınır koruması and ile kısa devre — sınırda/boş dizede çökmez", .kind = .golden, .source = @embedFile("codegen_cases/str_index_guard_short_circuit.nox"), .expected_stdout = @embedFile("codegen_cases/str_index_guard_short_circuit.expected") },
    .{ .name = "codegen(çalıştır): return s[i] (str char-at) sızdırmaz", .kind = .golden, .source = @embedFile("codegen_cases/str_index_return_no_leak.nox"), .expected_stdout = @embedFile("codegen_cases/str_index_return_no_leak.expected") },
    .{ .name = "codegen(çalıştır): for-range ve if/elif/else", .kind = .golden, .source = @embedFile("codegen_cases/for_range_and_if.nox"), .expected_stdout = @embedFile("codegen_cases/for_range_and_if.expected") },
    .{ .name = "codegen(çalıştır): str parametresi ve yazdırma", .kind = .golden, .source = @embedFile("codegen_cases/str_param_and_print.nox"), .expected_stdout = @embedFile("codegen_cases/str_param_and_print.expected") },
    .{ .name = "codegen(çalıştır): list[int] oluşturma, indeksleme, iterasyon", .kind = .golden, .source = @embedFile("codegen_cases/list_build_index_iterate.nox"), .expected_stdout = @embedFile("codegen_cases/list_build_index_iterate.expected") },
    .{ .name = "codegen(çalıştır): Faz S.2 — list[T] indeksleme sınır dışı erişimde IndexError raise eder", .kind = .golden, .source = @embedFile("codegen_cases/list_index_out_of_bounds_raises.nox"), .expected_stdout = @embedFile("codegen_cases/list_index_out_of_bounds_raises.expected") },
    .{ .name = "codegen(çalıştır): Faz U.1 — list[T].append() büyür VE kapasite yeterliyken alias'lar arasında paylaşılır", .kind = .golden, .source = @embedFile("codegen_cases/list_append_grows_and_shares.nox"), .expected_stdout = @embedFile("codegen_cases/list_append_grows_and_shares.expected") },
    .{ .name = "codegen(çalıştır): Faz U.1 — list[str].append() heap-yönetimli elemanlarla büyümede sızmaz", .kind = .golden, .source = @embedFile("codegen_cases/list_append_str_elements.nox"), .expected_stdout = @embedFile("codegen_cases/list_append_str_elements.expected") },
    .{ .name = "codegen(çalıştır): nox.router fazı — sınıf alanı list[T].append() büyürken alan HÂLÂ eski bloğu görüyor (erken serbest bırakma regresyonu)", .kind = .golden, .source = @embedFile("codegen_cases/list_append_growth_while_field_aliased.nox"), .expected_stdout = @embedFile("codegen_cases/list_append_growth_while_field_aliased.expected") },
    .{ .name = "codegen(çalıştır): nox.router fazı — closure-elemanlı list[T] sınıf alanı, otomatik üretilen ClassName_eq'de çökmez", .kind = .golden, .source = @embedFile("codegen_cases/class_eq_with_closure_list_field.nox"), .expected_stdout = @embedFile("codegen_cases/class_eq_with_closure_list_field.expected") },
    .{ .name = "codegen(çalıştır): nox.router — path parametreli rota + before/after middleware uçtan-uca", .kind = .golden, .source = @embedFile("codegen_cases/router_basic_routing_and_middleware.nox"), .expected_stdout = @embedFile("codegen_cases/router_basic_routing_and_middleware.expected") },
    .{ .name = "codegen(çalıştır): nox.validate — şema doğrulama (geçerli/eksik alan/yanlış tip/geçersiz JSON/object-olmayan kök)", .kind = .golden, .source = @embedFile("codegen_cases/validate_schema_json_body.nox"), .expected_stdout = @embedFile("codegen_cases/validate_schema_json_body.expected") },
    .{ .name = "codegen(çalıştır): nox.template — HTML kaçırma (varsayılan), render_unescaped, tanımsız değişken hatası", .kind = .golden, .source = @embedFile("codegen_cases/template_render_and_escaping.nox"), .expected_stdout = @embedFile("codegen_cases/template_render_and_escaping.expected") },
    .{ .name = "codegen(çalıştır): Faz U.1 — list[T] indeksli atama (xs[i] = v), sınır dışında IndexError raise eder", .kind = .golden, .source = @embedFile("codegen_cases/list_index_assign_basic.nox"), .expected_stdout = @embedFile("codegen_cases/list_index_assign_basic.expected") },
    .{ .name = "codegen(çalıştır): liste yeniden ataması eskisini serbest bırakır (çift serbest bırakma yok)", .kind = .golden, .source = @embedFile("codegen_cases/list_reassignment_frees_old.nox"), .expected_stdout = @embedFile("codegen_cases/list_reassignment_frees_old.expected") },
    .{ .name = "codegen(çalıştır): liste parametre/dönüş/takma ad (ARC ödünç alma + retain)", .kind = .golden, .source = @embedFile("codegen_cases/list_param_return_alias.nox"), .expected_stdout = @embedFile("codegen_cases/list_param_return_alias.expected") },
    .{ .name = "codegen(çalıştır): sınıf — kurucu, metod, alan okuma/yazma, takma ad", .kind = .golden, .source = @embedFile("codegen_cases/class_point.nox"), .expected_stdout = @embedFile("codegen_cases/class_point.expected") },
    .{ .name = "codegen(çalıştır): list[str] (açıkça anotasyonlu, iç içe heap OLMAYAN tip)", .kind = .golden, .source = @embedFile("codegen_cases/list_str_elements.nox"), .expected_stdout = @embedFile("codegen_cases/list_str_elements.expected") },
    .{ .name = "codegen(çalıştır): list[Sınıf] — heap-yönetimli elemanlar, özyinelemeli ARC release (Faz 21 ön-koşulu)", .kind = .golden, .source = @embedFile("codegen_cases/list_class_elements.nox"), .expected_stdout = @embedFile("codegen_cases/list_class_elements.expected") },
    .{ .name = "codegen(çalıştır): list[list[int]] — iç içe liste elemanları, özyinelemeli ARC release", .kind = .golden, .source = @embedFile("codegen_cases/list_nested_list_elements.nox"), .expected_stdout = @embedFile("codegen_cases/list_nested_list_elements.expected") },
    .{ .name = "codegen(çalıştır): raise/try/except/finally — eşleşen tip, eşleşmeyen tip, finally her zaman çalışır", .kind = .golden, .source = @embedFile("codegen_cases/try_except_finally.nox"), .expected_stdout = @embedFile("codegen_cases/try_except_finally.expected") },
    .{ .name = "codegen(çalıştır): yakalanmamış istisna programı sıfırdan farklı bir kodla sonlandırır", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/uncaught_exception.nox"), .expected_stdout = @embedFile("codegen_cases/uncaught_exception.expected") },
    .{ .name = "codegen(çalıştır): performans fazı — 'raise etmez' analizi, dolaylı (transitif) raise yine de yakalanır", .kind = .golden, .source = @embedFile("codegen_cases/indirect_raise_propagation.nox"), .expected_stdout = @embedFile("codegen_cases/indirect_raise_propagation.expected") },
    .{ .name = "codegen(çalıştır): Faz M.8 — closure değişkeni üzerinden çağrılan raise, sessizce YUTULMAZ", .kind = .golden, .source = @embedFile("codegen_cases/closure_raise_not_swallowed.nox"), .expected_stdout = @embedFile("codegen_cases/closure_raise_not_swallowed.expected") },
    .{ .name = "codegen(çalıştır): performans fazı — dolaylı (3 katmanlı) yakalanmamış istisna hâlâ net şekilde sonlanır", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/indirect_uncaught_exception.nox"), .expected_stdout = @embedFile("codegen_cases/indirect_uncaught_exception.expected") },
    .{ .name = "codegen(çalıştır): Faz M.8 — metod-zinciri (self. VE yerel değişken) üzerinden dolaylı raise yine de yakalanır", .kind = .golden, .source = @embedFile("codegen_cases/method_indirect_raise_propagation.nox"), .expected_stdout = @embedFile("codegen_cases/method_indirect_raise_propagation.expected") },
    .{ .name = "codegen(çalıştır): Faz M.8 — metod-zinciri üzerinden dolaylı yakalanmamış istisna hâlâ net şekilde sonlanır", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/method_indirect_uncaught_exception.nox"), .expected_stdout = @embedFile("codegen_cases/method_indirect_uncaught_exception.expected") },
    .{ .name = "codegen(çalıştır): Faz M.8 — aynı isim farklı sınıflarla yeniden bildirilirse (zehirlenme) davranış doğru kalır", .kind = .golden, .source = @embedFile("codegen_cases/method_redeclared_var_poisoning.nox"), .expected_stdout = @embedFile("codegen_cases/method_redeclared_var_poisoning.expected") },
    .{ .name = "codegen(çalıştır): Faz M.8 — provably-safe metod zinciri (self. VE yerel değişken), davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/method_call_elision_positive.nox"), .expected_stdout = @embedFile("codegen_cases/method_call_elision_positive.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.3 — for-loop metod çağrısı (b.get()), davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/for_loop_method_call_elision_positive.nox"), .expected_stdout = @embedFile("codegen_cases/for_loop_method_call_elision_positive.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.5 — döngü içinde str[i], davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/str_index_loop_licm_positive.nox"), .expected_stdout = @embedFile("codegen_cases/str_index_loop_licm_positive.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.5 — döngü içinde yeniden atanan str önbelleklenmiyor (güvenlik)", .kind = .golden, .source = @embedFile("codegen_cases/str_index_loop_reassign_safety.nox"), .expected_stdout = @embedFile("codegen_cases/str_index_loop_reassign_safety.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.9 — for i in range(len(x)): x[i], davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/bounds_check_elision_positive.nox"), .expected_stdout = @embedFile("codegen_cases/bounds_check_elision_positive.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.9 (while genellemesi) — while j < len(xs): xs[j], davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/bounds_check_elision_while_len.nox"), .expected_stdout = @embedFile("codegen_cases/bounds_check_elision_while_len.expected") },
    .{ .name = "codegen(çalıştır): f-string interpolasyonu + augmented atama + genişletilmiş str()", .kind = .golden, .source = @embedFile("codegen_cases/fstring_and_aug_assign.nox"), .expected_stdout = @embedFile("codegen_cases/fstring_and_aug_assign.expected") },
    .{ .name = "codegen(çalıştır): \\r kaçışı düz string VE f-string içinde doğru CR baytı üretir", .kind = .golden, .source = @embedFile("codegen_cases/escape_sequences.nox"), .expected_stdout = @embedFile("codegen_cases/escape_sequences.expected") },
    .{ .name = "codegen(çalıştır): list[dict[K,V]] — insa, cift-indeksleme, indeksle atama, kapsam-sonu", .kind = .golden, .source = @embedFile("codegen_cases/list_of_dict.nox"), .expected_stdout = @embedFile("codegen_cases/list_of_dict.expected") },
    .{ .name = "codegen(çalıştır): ciplak except: + as-baglamasiz except (sizinti yok)", .kind = .golden, .source = @embedFile("codegen_cases/bare_except.nox"), .expected_stdout = @embedFile("codegen_cases/bare_except.expected") },
    .{ .name = "codegen(çalıştır): modül-seviyesi int global iki fonksiyondan okunup yazilir", .kind = .golden, .source = @embedFile("codegen_cases/module_global_int.nox"), .expected_stdout = @embedFile("codegen_cases/module_global_int.expected") },
    .{ .name = "codegen(çalıştır): modül-seviyesi heap-yönetimli global (list[str]) sizintisiz büyür", .kind = .golden, .source = @embedFile("codegen_cases/module_global_heap_list.nox"), .expected_stdout = @embedFile("codegen_cases/module_global_heap_list.expected") },
    .{ .name = "codegen(çalıştır): yerel degisken/parametre modül-global'ini gölgeler, kardes fonksiyon global'i görür", .kind = .golden, .source = @embedFile("codegen_cases/module_global_shadowing.nox"), .expected_stdout = @embedFile("codegen_cases/module_global_shadowing.expected") },
    .{ .name = "codegen(çalıştır): modül-global VE terfi ETMEMİŞ sıradan üst-düzey değişken AYNI programda çöker miydi (P1c)", .kind = .golden, .source = @embedFile("codegen_cases/module_global_plus_unpromoted_local.nox"), .expected_stdout = @embedFile("codegen_cases/module_global_plus_unpromoted_local.expected") },
    .{ .name = "codegen(çalıştır): (T) -> dict[K,V] fonksiyon-tipli parametre üzerinden dolaylı çağrı, sonucu inline BAŞKA çağrıya argüman olarak geçtiğinde çökmez (C2)", .kind = .golden, .source = @embedFile("codegen_cases/inline_closure_call_returns_dict.nox"), .expected_stdout = @embedFile("codegen_cases/inline_closure_call_returns_dict.expected") },
    .{ .name = "codegen(çalıştır): list.pop() — cıplak degisken + sinif alani + bos liste IndexError", .kind = .golden, .source = @embedFile("codegen_cases/list_pop.nox"), .expected_stdout = @embedFile("codegen_cases/list_pop.expected") },
    .{ .name = "codegen(çalıştır): nox.collections Stack/Queue/Deque", .kind = .golden, .source = @embedFile("codegen_cases/collections_stack_queue_deque.nox"), .expected_stdout = @embedFile("codegen_cases/collections_stack_queue_deque.expected") },
    .{ .name = "codegen(çalıştır): nox.collections Set/Counter/OrderedDict", .kind = .golden, .source = @embedFile("codegen_cases/collections_set_counter_ordereddict.nox"), .expected_stdout = @embedFile("codegen_cases/collections_set_counter_ordereddict.expected") },
    .{ .name = "codegen(çalıştır): nox.collections LRUCache/Heap/PriorityQueue", .kind = .golden, .source = @embedFile("codegen_cases/collections_lru_heap_priority.nox"), .expected_stdout = @embedFile("codegen_cases/collections_lru_heap_priority.expected") },
    .{ .name = "codegen(çalıştır): nox.url parse/percent-encode-decode/query/join", .kind = .golden, .source = @embedFile("codegen_cases/url_parse_encode_decode.nox"), .expected_stdout = @embedFile("codegen_cases/url_parse_encode_decode.expected") },
    .{ .name = "codegen(çalıştır): gecici alici uzerinde istisna firlatan metod/pop()/indeksleme sizmaz", .kind = .golden, .source = @embedFile("codegen_cases/temporary_receiver_raises_no_leak.nox"), .expected_stdout = @embedFile("codegen_cases/temporary_receiver_raises_no_leak.expected") },
    .{ .name = "codegen(çalıştır): nox.postgres/nox.mysql — ulasilamayan baglantida temiz hata", .kind = .golden, .source = @embedFile("codegen_cases/postgres_mysql_connect_error.nox"), .expected_stdout = @embedFile("codegen_cases/postgres_mysql_connect_error.expected") },
    .{ .name = "codegen(çalıştır): nox.tls/nox.websocket — ulasilamayan baglantida temiz hata", .kind = .golden, .source = @embedFile("codegen_cases/tls_websocket_connect_error.nox"), .expected_stdout = @embedFile("codegen_cases/tls_websocket_connect_error.expected") },
    .{ .name = "codegen(çalıştır): UTF-8 farkındalığı — len()/s[i] codepoint-tabanlı (café/日本語, düz + for + while erişimi)", .kind = .golden, .source = @embedFile("codegen_cases/utf8_len_index.nox"), .expected_stdout = @embedFile("codegen_cases/utf8_len_index.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.9 (while genellemesi) — while j < SABİT: xs[j] (araya giren yerelle), davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/bounds_check_elision_while_literal.nox"), .expected_stdout = @embedFile("codegen_cases/bounds_check_elision_while_literal.expected") },
    .{ .name = "codegen(çalıştır): darboğaz #3 — inline-sınır ötesi i%3 CSE'si, davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/mod_cse_positive.nox"), .expected_stdout = @embedFile("codegen_cases/mod_cse_positive.expected") },
    .{ .name = "codegen(çalıştır): darboğaz #3 güvenlik — if dalı içinde yeniden atama, if SONRASI CSE YANLIŞ değeri yeniden kullanmaz", .kind = .golden, .source = @embedFile("codegen_cases/mod_cse_if_reassign_safety.nox"), .expected_stdout = @embedFile("codegen_cases/mod_cse_if_reassign_safety.expected") },
    .{ .name = "codegen(çalıştır): darboğaz #3 güvenlik — while gövdesi içinde yeniden atama, CSE YANLIŞ değeri yeniden kullanmaz", .kind = .golden, .source = @embedFile("codegen_cases/mod_cse_while_reassign_safety.nox"), .expected_stdout = @embedFile("codegen_cases/mod_cse_while_reassign_safety.expected") },
    .{ .name = "codegen(çalıştır): darboğaz #3 güvenlik — for döngü değişkeni, CSE YANLIŞ değeri yeniden kullanmaz", .kind = .golden, .source = @embedFile("codegen_cases/mod_cse_for_reassign_safety.nox"), .expected_stdout = @embedFile("codegen_cases/mod_cse_for_reassign_safety.expected") },
    .{ .name = "codegen(çalıştır): darboğaz #3 güvenlik — if/elif/else zincirinin HER dalı farklı yeniden atama, CSE sızdırmaz", .kind = .golden, .source = @embedFile("codegen_cases/mod_cse_elif_branch_safety.nox"), .expected_stdout = @embedFile("codegen_cases/mod_cse_elif_branch_safety.expected") },
    .{ .name = "codegen(çalıştır): lowlevel — arena üzerinden sınıf + liste, alan okuma, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/lowlevel_basic.nox"), .expected_stdout = @embedFile("codegen_cases/lowlevel_basic.expected") },
    .{ .name = "codegen(çalıştır): Faz U.4.3 — iç içe def bir int'i yakalar (capture), inşa+release döngüsü sızıntısız", .kind = .golden, .source = @embedFile("codegen_cases/nested_def_capture_primitive.nox"), .expected_stdout = @embedFile("codegen_cases/nested_def_capture_primitive.expected") },
    .{ .name = "codegen(çalıştır): Faz U.4.3 — iç içe def bir str'i (heap-yönetimli) yakalar, döngü içinde tekrar tekrar inşa+release sızıntısız", .kind = .golden, .source = @embedFile("codegen_cases/nested_def_capture_heap.nox"), .expected_stdout = @embedFile("codegen_cases/nested_def_capture_heap.expected") },
    .{ .name = "codegen(çalıştır): iç içe def, çevreleyen fonksiyonun FONKSİYON-TİPLİ bir parametresini yakalayıp çağırır (ÖNCEDEN 'desteklenmeyen yapı')", .kind = .golden, .source = @embedFile("codegen_cases/nested_def_captures_func_typed_value.nox"), .expected_stdout = @embedFile("codegen_cases/nested_def_captures_func_typed_value.expected") },
    .{ .name = "codegen(çalıştır): Faz U.4.4 — döndürülen bir closure func-tipli değişkene atanır, DOLAYLI çağrılır (birden çok kez, birden çok somut closure)", .kind = .golden, .source = @embedFile("codegen_cases/closure_returned_and_called_indirectly.nox"), .expected_stdout = @embedFile("codegen_cases/closure_returned_and_called_indirectly.expected") },
    .{ .name = "codegen(çalıştır): Faz U.4.4 — closure func-tipli bir PARAMETRE olarak geçirilir, çağrılanın İÇİNDE dolaylı çağrılır", .kind = .golden, .source = @embedFile("codegen_cases/closure_passed_as_param_called_indirectly.nox"), .expected_stdout = @embedFile("codegen_cases/closure_passed_as_param_called_indirectly.expected") },
    .{ .name = "codegen(çalıştır): Faz U.5 — 'with EXPR as NAME:' temel __enter__/__exit__ akışı", .kind = .golden, .source = @embedFile("codegen_cases/with_basic_enter_exit.nox"), .expected_stdout = @embedFile("codegen_cases/with_basic_enter_exit.expected") },
    .{ .name = "codegen(çalıştır): Faz U.5 — 'with' gövdesi içindeki 'return', __exit__'i BEKLEYİP SONRA dönüş yapar", .kind = .golden, .source = @embedFile("codegen_cases/with_return_inside_runs_exit.nox"), .expected_stdout = @embedFile("codegen_cases/with_return_inside_runs_exit.expected") },
    .{ .name = "codegen(çalıştır): Faz U.5 — 'with' içinde raise edilen istisna DIŞ bir try/except tarafından yakalanır, __exit__ ARADA çalışır", .kind = .golden, .source = @embedFile("codegen_cases/with_exception_caught_by_outer_try_runs_exit.nox"), .expected_stdout = @embedFile("codegen_cases/with_exception_caught_by_outer_try_runs_exit.expected") },
    .{ .name = "codegen(çalıştır): Faz U.5 — heap-yönetimli bir bağlam değeri döngü içinde tekrar tekrar with'lenir, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/with_heap_capture_loop_no_leak.nox"), .expected_stdout = @embedFile("codegen_cases/with_heap_capture_loop_no_leak.expected") },
    .{ .name = "codegen(çalıştır): Faz U.5 — 'as NAME' OLMADAN 'with EXPR:' (yalnızca yan etki İÇİN)", .kind = .golden, .source = @embedFile("codegen_cases/with_no_binding.nox"), .expected_stdout = @embedFile("codegen_cases/with_no_binding.expected") },
    .{ .name = "codegen(çalıştır): except X as e bir döngü içinde yeniden kullanılır — eski istisna sızmaz", .kind = .golden, .source = @embedFile("codegen_cases/except_bind_reused_in_loop.nox"), .expected_stdout = @embedFile("codegen_cases/except_bind_reused_in_loop.expected") },
    .{ .name = "codegen(çalıştır): iç içe sınıf tipli alanlar — inşa, zincirleme okuma, yeniden atama, passthrough, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/nested_class_fields.nox"), .expected_stdout = @embedFile("codegen_cases/nested_class_fields.expected") },
    .{ .name = "codegen(çalıştır): bir döngü içindeki '%' yığın taşmasına yol açmaz (milyonlarca yineleme)", .kind = .golden, .source = @embedFile("codegen_cases/mod_in_loop_no_stack_growth.nox"), .expected_stdout = @embedFile("codegen_cases/mod_in_loop_no_stack_growth.expected") },
    .{ .name = "codegen(çalıştır): bir döngü içine gömülü 'for ... in list' yığın taşmasına yol açmaz", .kind = .golden, .source = @embedFile("codegen_cases/nested_forlist_no_stack_growth.nox"), .expected_stdout = @embedFile("codegen_cases/nested_forlist_no_stack_growth.expected") },
    .{ .name = "codegen(çalıştır): bir döngü içindeki list[T]/sınıf '==' yığın taşmasına yol açmaz (milyonlarca yineleme)", .kind = .golden, .source = @embedFile("codegen_cases/deep_equality_in_loop_no_stack_growth.nox"), .expected_stdout = @embedFile("codegen_cases/deep_equality_in_loop_no_stack_growth.expected") },
    .{ .name = "codegen(çalıştır): GG.14 — pinned string passthrough (pozitif) + dinamik string passthrough (negatif), sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/pinned_string_passthrough.nox"), .expected_stdout = @embedFile("codegen_cases/pinned_string_passthrough.expected") },
    .{ .name = "codegen(çalıştır): GG.15 — lowlevel bloğunda sabit-boyutlu inşalar (yığın slotu), davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/lowlevel_stack_construct.nox"), .expected_stdout = @embedFile("codegen_cases/lowlevel_stack_construct.expected") },
    .{ .name = "codegen(çalıştır): GG.15 — karışık lowlevel bloğu (identifier elemanlı liste), arena elenmez", .kind = .golden, .source = @embedFile("codegen_cases/lowlevel_mixed_no_stack_construct.nox"), .expected_stdout = @embedFile("codegen_cases/lowlevel_mixed_no_stack_construct.expected") },
    .{ .name = "codegen(çalıştır): GG.16 — çağrı-sınırı ötesi yığın slotu (kaçmayan parametre), davranış değişmedi", .kind = .golden, .source = @embedFile("codegen_cases/cross_call_stack_slot.nox"), .expected_stdout = @embedFile("codegen_cases/cross_call_stack_slot.expected") },
    .{ .name = "codegen(çalıştır): GG.16 — parametresini döndüren callee (kaçış), yığın slotuna DÖNÜŞTÜRÜLMEZ", .kind = .golden, .source = @embedFile("codegen_cases/cross_call_param_escapes.nox"), .expected_stdout = @embedFile("codegen_cases/cross_call_param_escapes.expected") },
    .{ .name = "codegen(çalıştır): GG.20 — salt-okunur bir SERBEST fonksiyona geçen yerel ARTIK stack'e dönüşür", .kind = .golden, .source = @embedFile("codegen_cases/gg20_local_forwarded_to_read_only_helper.nox"), .expected_stdout = @embedFile("codegen_cases/gg20_local_forwarded_to_read_only_helper.expected") },
    .{ .name = "codegen(çalıştır): GG.20 — mutasyona uğratan bir SERBEST fonksiyona geçen yerel HÂLÂ nox_rc_alloc'ta kalır", .kind = .golden, .source = @embedFile("codegen_cases/gg20_local_forwarded_to_mutating_helper_stays_arc.nox"), .expected_stdout = @embedFile("codegen_cases/gg20_local_forwarded_to_mutating_helper_stays_arc.expected") },
    .{ .name = "codegen(çalıştır): GG.20 — İKİ SEVİYELİ güvenli yönlendirme zinciri de yerel'i stack'e dönüştürür", .kind = .golden, .source = @embedFile("codegen_cases/gg20_two_level_safe_forwarding.nox"), .expected_stdout = @embedFile("codegen_cases/gg20_two_level_safe_forwarding.expected") },
    .{ .name = "codegen(çalıştır): GG.21 — final bir metoda sibling-parametre üzerinden geçen yerel ARTIK stack'e dönüşür", .kind = .golden, .source = @embedFile("codegen_cases/gg21_local_forwarded_to_final_method_read_only.nox"), .expected_stdout = @embedFile("codegen_cases/gg21_local_forwarded_to_final_method_read_only.expected") },
    .{ .name = "codegen(çalıştır): GG.21 — final AMA mutasyona uğratan bir metoda geçen yerel HÂLÂ nox_rc_alloc'ta kalır", .kind = .golden, .source = @embedFile("codegen_cases/gg21_local_forwarded_to_final_method_mutating_stays_arc.nox"), .expected_stdout = @embedFile("codegen_cases/gg21_local_forwarded_to_final_method_mutating_stays_arc.expected") },
    .{ .name = "codegen(çalıştır): GG.21 — KIRMIZI-TAKIM — override edilen bir metoda geçen yerel muhafazakâr kalır", .kind = .golden, .source = @embedFile("codegen_cases/gg21_overridden_method_stays_conservative.nox"), .expected_stdout = @embedFile("codegen_cases/gg21_overridden_method_stays_conservative.expected") },
    .{ .name = "codegen(çalıştır): zincirlenmiş alan okuması bir çağrı sonucu üzerinde — ara nesne sızmaz", .kind = .golden, .source = @embedFile("codegen_cases/chained_attr_temporary_release.nox"), .expected_stdout = @embedFile("codegen_cases/chained_attr_temporary_release.expected") },
    .{ .name = "codegen(çalıştır): list[T] tipli bir sınıf alanı — inşa, takma ad, passthrough, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/list_class_field.nox"), .expected_stdout = @embedFile("codegen_cases/list_class_field.expected") },
    .{ .name = "codegen(çalıştır): bos [] literali DORT bağlamda (var_decl/atama/çağrı/return) bağlamsal çıkarım, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/empty_list_lit_contextual_inference.nox"), .expected_stdout = @embedFile("codegen_cases/empty_list_lit_contextual_inference.expected") },
    .{ .name = "codegen(çalıştır): TAZE olmayan bir tabandan alan/indeks okuması yeni bir yerele atanınca retain edilir", .kind = .golden, .source = @embedFile("codegen_cases/attr_index_read_into_local_retain.nox"), .expected_stdout = @embedFile("codegen_cases/attr_index_read_into_local_retain.expected") },
    .{ .name = "codegen(çalıştır): generic fonksiyonlar — birden çok somut tip, list[T], sınıf argümanı, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/generic_functions.nox"), .expected_stdout = @embedFile("codegen_cases/generic_functions.expected") },
    .{ .name = "codegen(çalıştır): generic sınıflar — ayni siniftan iki farkli somut tip, sizinti yok", .kind = .golden, .source = @embedFile("codegen_cases/generic_classes.nox"), .expected_stdout = @embedFile("codegen_cases/generic_classes.expected") },
    .{ .name = "codegen(çalıştır): generic sınıf öz-başvurulu metod + ayni programda degismemis Channel[T]/regresyon", .kind = .golden, .source = @embedFile("codegen_cases/generic_class_self_reference.nox"), .expected_stdout = @embedFile("codegen_cases/generic_class_self_reference.expected") },
    .{ .name = "codegen(calistir): generic sinif __init__ icinde raise sessizce YUTULMAZ", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/generic_class_init_raise_not_swallowed.nox"), .expected_stdout = @embedFile("codegen_cases/generic_class_init_raise_not_swallowed.expected") },
    .{ .name = "codegen(çalıştır): Faz 7 — tekli kalıtım temel: super().__init__, override, miras alınan alan", .kind = .golden, .source = @embedFile("codegen_cases/inheritance_basic.nox"), .expected_stdout = @embedFile("codegen_cases/inheritance_basic.expected") },
    .{ .name = "codegen(çalıştır): Faz 7 — tekli kalıtım polimorfizm: taban-tipli liste/parametre üzerinden vtable dispatch", .kind = .golden, .source = @embedFile("codegen_cases/inheritance_polymorphism.nox"), .expected_stdout = @embedFile("codegen_cases/inheritance_polymorphism.expected") },
    .{ .name = "codegen(çalıştır): Faz 7 — hiyerarşik except: taban sınıf yan tümcesi bir alt sınıf örneğini yakalar", .kind = .golden, .source = @embedFile("codegen_cases/inheritance_hierarchical_except.nox"), .expected_stdout = @embedFile("codegen_cases/inheritance_hierarchical_except.expected") },
    .{ .name = "codegen(çalıştır): Faz 7 — super().metod(...) her zaman doğrudan atanın implementasyonuna gider", .kind = .golden, .source = @embedFile("codegen_cases/inheritance_super_method.nox"), .expected_stdout = @embedFile("codegen_cases/inheritance_super_method.expected") },
    .{ .name = "codegen(çalıştır): yapısal protokol — iki farklı sınıf, monomorphize edilmiş dispatch, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/protocol_dispatch.nox"), .expected_stdout = @embedFile("codegen_cases/protocol_dispatch.expected") },
    .{ .name = "codegen(çalıştır): wasm_call — gerçek bir .nox programından gerçek bir WASM modülü çağrılır", .kind = .golden, .source = @embedFile("codegen_cases/wasm_call_builtin.nox"), .expected_stdout = @embedFile("codegen_cases/wasm_call_builtin.expected") },
    .{ .name = "codegen(çalıştır): async — spawn + await, i64 payload, sızıntı yok (Faz 21 aşama 4)", .kind = .golden, .source = @embedFile("codegen_cases/async_spawn_await.nox"), .expected_stdout = @embedFile("codegen_cases/async_spawn_await.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.1 — spawn edilen görevdeki YAKALANMAMIŞ istisna, bağlı except İLE await'te yakalanır", .kind = .golden, .source = @embedFile("codegen_cases/spawn_await_exception_caught.nox"), .expected_stdout = @embedFile("codegen_cases/spawn_await_exception_caught.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.1 — aynı, BAĞLANMAMIŞ (bare) except İLE, sızıntı/double-free yok", .kind = .golden, .source = @embedFile("codegen_cases/spawn_await_exception_bare_except.nox"), .expected_stdout = @embedFile("codegen_cases/spawn_await_exception_bare_except.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.1 — hiçbir try içinde olmayan await, yakalanmamış istisnayla (main'e kadar) net sonlanır", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/spawn_await_exception_unhandled.nox"), .expected_stdout = @embedFile("codegen_cases/spawn_await_exception_unhandled.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.1 — aynı Task'ı İKİNCİ kez await etmek istisnayı TEKRARLAMAZ (v1 bilinçli sınırı)", .kind = .golden, .source = @embedFile("codegen_cases/spawn_await_exception_second_await_no_reraise.nox"), .expected_stdout = @embedFile("codegen_cases/spawn_await_exception_second_await_no_reraise.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.2 — t.cancel() SONRASI task'ın KENDİ await checkpoint'inde CancelledError fırlatılır, bağlı except yakalar", .kind = .golden, .source = @embedFile("codegen_cases/task_cancel_caught.nox"), .expected_stdout = @embedFile("codegen_cases/task_cancel_caught.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.2 — cancel HİÇ çağrılmazsa normal sonuç döner (regresyon-yok)", .kind = .golden, .source = @embedFile("codegen_cases/task_cancel_not_requested_regression.nox"), .expected_stdout = @embedFile("codegen_cases/task_cancel_not_requested_regression.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.2 — t.cancel() birden fazla kez çağrılabilir (idempotent bayrak)", .kind = .golden, .source = @embedFile("codegen_cases/task_cancel_idempotent.nox"), .expected_stdout = @embedFile("codegen_cases/task_cancel_idempotent.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.2 — hiçbir try içinde olmayan iptal, yakalanmamış istisnayla (main'e kadar) net sonlanır", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/task_cancel_unhandled.nox"), .expected_stdout = @embedFile("codegen_cases/task_cancel_unhandled.expected") },
    .{ .name = "codegen(çalıştır): Faz SC.2 — task ZATEN tamamlandıktan SONRA t.cancel() çağırmak güvenli bir no-op'tur", .kind = .golden, .source = @embedFile("codegen_cases/task_cancel_after_completed_noop.nox"), .expected_stdout = @embedFile("codegen_cases/task_cancel_after_completed_noop.expected") },
    .{ .name = "codegen(çalıştır): nox.csv — basit, tırnaksız satırların ayrıştırılması", .kind = .golden, .source = @embedFile("codegen_cases/csv_parse_basic.nox"), .expected_stdout = @embedFile("codegen_cases/csv_parse_basic.expected") },
    .{ .name = "codegen(çalıştır): nox.csv — alıntılı alanlar (virgül/kaçırılmış tırnak/gömülü satır-sonu)", .kind = .golden, .source = @embedFile("codegen_cases/csv_parse_quoted.nox"), .expected_stdout = @embedFile("codegen_cases/csv_parse_quoted.expected") },
    .{ .name = "codegen(çalıştır): nox.csv — CRLF satır sonları + sondaki temiz satır-sonu sahte satır ÜRETMEZ", .kind = .golden, .source = @embedFile("codegen_cases/csv_parse_crlf_and_trailing_newline.nox"), .expected_stdout = @embedFile("codegen_cases/csv_parse_crlf_and_trailing_newline.expected") },
    .{ .name = "codegen(çalıştır): nox.csv — parse_dicts, başlık satırından isimle erişim", .kind = .golden, .source = @embedFile("codegen_cases/csv_parse_dicts.nox"), .expected_stdout = @embedFile("codegen_cases/csv_parse_dicts.expected") },
    .{ .name = "codegen(çalıştır): nox.csv — write+parse bir tur, özel karakterli alanlar dahil", .kind = .golden, .source = @embedFile("codegen_cases/csv_write_roundtrip.nox"), .expected_stdout = @embedFile("codegen_cases/csv_write_roundtrip.expected") },
    .{ .name = "codegen(çalıştır): nox.csv — sonlandırılmamış tırnak CsvError fırlatır", .kind = .golden, .source = @embedFile("codegen_cases/csv_unterminated_quote_raises.nox"), .expected_stdout = @embedFile("codegen_cases/csv_unterminated_quote_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.gzip — compress/decompress (str), bir tur", .kind = .golden, .source = @embedFile("codegen_cases/gzip_compress_decompress_str_roundtrip.nox"), .expected_stdout = @embedFile("codegen_cases/gzip_compress_decompress_str_roundtrip.expected") },
    .{ .name = "codegen(çalıştır): nox.gzip — compress_bytes/decompress_bytes, 0 ve 255 dahil keyfi baytlar", .kind = .golden, .source = @embedFile("codegen_cases/gzip_compress_bytes_roundtrip.nox"), .expected_stdout = @embedFile("codegen_cases/gzip_compress_bytes_roundtrip.expected") },
    .{ .name = "codegen(çalıştır): nox.gzip — tekrarlayan metin GERÇEKTEN daha küçük sıkıştırılır", .kind = .golden, .source = @embedFile("codegen_cases/gzip_output_smaller_for_repetitive_text.nox"), .expected_stdout = @embedFile("codegen_cases/gzip_output_smaller_for_repetitive_text.expected") },
    .{ .name = "codegen(çalıştır): nox.gzip — geçersiz (gzip olmayan) veri GzipError fırlatır", .kind = .golden, .source = @embedFile("codegen_cases/gzip_decompress_invalid_data_raises.nox"), .expected_stdout = @embedFile("codegen_cases/gzip_decompress_invalid_data_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.gzip — 255'i aşan bir bayt değeri GzipError fırlatır", .kind = .golden, .source = @embedFile("codegen_cases/gzip_compress_bytes_invalid_value_raises.nox"), .expected_stdout = @embedFile("codegen_cases/gzip_compress_bytes_invalid_value_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.toml — temel key=value (str/int/float/bool)", .kind = .golden, .source = @embedFile("codegen_cases/toml_parse_basic_key_value.nox"), .expected_stdout = @embedFile("codegen_cases/toml_parse_basic_key_value.expected") },
    .{ .name = "codegen(çalıştır): nox.toml — iç içe [a]/[a.b]/[a.b.c] tabloları", .kind = .golden, .source = @embedFile("codegen_cases/toml_parse_nested_tables.nox"), .expected_stdout = @embedFile("codegen_cases/toml_parse_nested_tables.expected") },
    .{ .name = "codegen(çalıştır): nox.toml — tek-satırlık ve çok-satırlık dizi", .kind = .golden, .source = @embedFile("codegen_cases/toml_parse_array.nox"), .expected_stdout = @embedFile("codegen_cases/toml_parse_array.expected") },
    .{ .name = "codegen(çalıştır): nox.toml — yorum/boş satır arasına serpiştirilmiş değerler", .kind = .golden, .source = @embedFile("codegen_cases/toml_parse_comments_and_blank_lines.nox"), .expected_stdout = @embedFile("codegen_cases/toml_parse_comments_and_blank_lines.expected") },
    .{ .name = "codegen(çalıştır): nox.toml — get() dotted-path yardımcısı", .kind = .golden, .source = @embedFile("codegen_cases/toml_get_dotted_path_helper.nox"), .expected_stdout = @embedFile("codegen_cases/toml_get_dotted_path_helper.expected") },
    .{ .name = "codegen(çalıştır): nox.toml — array-of-tables ([[...]]) TomlError fırlatır", .kind = .golden, .source = @embedFile("codegen_cases/toml_array_of_tables_raises.nox"), .expected_stdout = @embedFile("codegen_cases/toml_array_of_tables_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.toml — sonlandırılmamış string TomlError fırlatır", .kind = .golden, .source = @embedFile("codegen_cases/toml_unterminated_string_raises.nox"), .expected_stdout = @embedFile("codegen_cases/toml_unterminated_string_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.smtp — erişilemeyen adrese bağlantı SmtpError fırlatır", .kind = .golden, .source = @embedFile("codegen_cases/smtp_connect_error.nox"), .expected_stdout = @embedFile("codegen_cases/smtp_connect_error.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — temel esleme (str/int/float/bool/null)", .kind = .golden, .source = @embedFile("codegen_cases/yaml_parse_basic_mapping.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_parse_basic_mapping.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — girintiyle ic ice eslemeler", .kind = .golden, .source = @embedFile("codegen_cases/yaml_parse_nested_mapping.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_parse_nested_mapping.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — skaler VE nesne-listesi dizileri", .kind = .golden, .source = @embedFile("codegen_cases/yaml_parse_sequence.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_parse_sequence.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — akis-stili dizi/esleme (ic ice DAHIL)", .kind = .golden, .source = @embedFile("codegen_cases/yaml_parse_flow_style.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_parse_flow_style.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — cift-tirnakli (kacis) VE tek-tirnakli string'ler", .kind = .golden, .source = @embedFile("codegen_cases/yaml_parse_quoted_strings.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_parse_quoted_strings.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — yorum/bos satirlar + bastaki '---'", .kind = .golden, .source = @embedFile("codegen_cases/yaml_parse_comments_and_blank_lines.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_parse_comments_and_blank_lines.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — get() dotted-path yardimcisi", .kind = .golden, .source = @embedFile("codegen_cases/yaml_get_dotted_path_helper.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_get_dotted_path_helper.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — TAB girintisi YamlError firlatir", .kind = .golden, .source = @embedFile("codegen_cases/yaml_tab_indent_raises.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_tab_indent_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.yaml — ikinci bir '---' (coklu-belge) YamlError firlatir", .kind = .golden, .source = @embedFile("codegen_cases/yaml_multi_document_raises.nox"), .expected_stdout = @embedFile("codegen_cases/yaml_multi_document_raises.expected") },
    .{ .name = "codegen(çalıştır): async — Channel[T] (rendezvous) iki görev arasında, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/async_channel.nox"), .expected_stdout = @embedFile("codegen_cases/async_channel.expected") },
    .{ .name = "codegen(çalıştır): v1.29.12 — Channel[T] bir spawn'a geçilip sahip erken dönse BİLE çökmez, refcount ile hayatta kalır", .kind = .golden, .source = @embedFile("codegen_cases/channel_spawn_outlives_owner.nox"), .expected_stdout = @embedFile("codegen_cases/channel_spawn_outlives_owner.expected") },
    .{ .name = "codegen(çalıştır): Faz BB.4 — nox.thread.start/ThreadHandle[int]/.join(), gerçek OS iş parçacığı, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/thread_spawn_join_int.nox"), .expected_stdout = @embedFile("codegen_cases/thread_spawn_join_int.expected") },
    .{ .name = "codegen(çalıştır): Faz BB.4 — nox.thread.start/ThreadHandle[str]/.join(), çapraz-iş-parçacığı str transferi, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/thread_spawn_join_str.nox"), .expected_stdout = @embedFile("codegen_cases/thread_spawn_join_str.expected") },
    .{ .name = "codegen(çalıştır): Faz BB.4 — ThreadHandle.join() fiber-farkında askıya alır, ebeveynin DİĞER fiber'ı ilerlemeye devam eder", .kind = .golden, .source = @embedFile("codegen_cases/thread_spawn_ordering.nox"), .expected_stdout = @embedFile("codegen_cases/thread_spawn_ordering.expected") },
    .{ .name = "codegen(çalıştır): Faz BB.4 — join edilmeden scope'tan çıkan ThreadHandle (fire-and-forget), sızıntı/UAF yok", .kind = .golden, .source = @embedFile("codegen_cases/thread_spawn_detached_leak.nox"), .expected_stdout = @embedFile("codegen_cases/thread_spawn_detached_leak.expected") },
    .{ .name = "codegen(çalıştır): Faz BB.6 — ThreadChannel[int], iki gerçek OS iş parçacığı arasında, tamponlu (kapasite 2)", .kind = .golden, .source = @embedFile("codegen_cases/thread_channel_int.nox"), .expected_stdout = @embedFile("codegen_cases/thread_channel_int.expected") },
    .{ .name = "codegen(çalıştır): Faz BB.6 — ThreadChannel[str], çapraz-iş-parçacığı str transferi, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/thread_channel_str.nox"), .expected_stdout = @embedFile("codegen_cases/thread_channel_str.expected") },
    .{ .name = "codegen(çalıştır): Faz BB.6 — ThreadChannel[int] geri basınç (kapasite 1, 20 değer), tam boru hattından, sıra/kayıp yok", .kind = .golden, .source = @embedFile("codegen_cases/thread_channel_backpressure.nox"), .expected_stdout = @embedFile("codegen_cases/thread_channel_backpressure.expected") },
    .{ .name = "codegen(çalıştır): Faz S.1 — Task[T] yeniden ataması, ilk görev await edilmeden önce, sızıntı/UAF yok", .kind = .golden, .source = @embedFile("codegen_cases/task_reassignment_frees_old.nox"), .expected_stdout = @embedFile("codegen_cases/task_reassignment_frees_old.expected") },
    .{ .name = "codegen(çalıştır): Faz S.1 — Channel[T] yeniden ataması, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/channel_reassignment_frees_old.nox"), .expected_stdout = @embedFile("codegen_cases/channel_reassignment_frees_old.expected") },
    .{ .name = "codegen(çalıştır): async — kasıtlı deadlock, net hatayla sonlanır (asılı KALMAZ)", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/async_deadlock.nox"), .expected_stdout = @embedFile("codegen_cases/async_deadlock.expected") },
    .{ .name = "codegen(çalıştır): __init__ içermeyen sınıf (alansız, yalnızca metod)", .kind = .golden, .source = @embedFile("codegen_cases/class_no_init.nox"), .expected_stdout = @embedFile("codegen_cases/class_no_init.expected") },
    .{ .name = "codegen(çalıştır): Faz S.3 — gerçek A<->B sınıf referans döngüsü, Katman 3 sızmadan toplar", .kind = .golden, .source = @embedFile("codegen_cases/class_reference_cycle_collected.nox"), .expected_stdout = @embedFile("codegen_cases/class_reference_cycle_collected.expected") },
    .{ .name = "codegen(çalıştır): 'obj.attr = değer' ataması self dışından — değer tipli VE sınıf tipli alan, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/attr_assign_external.nox"), .expected_stdout = @embedFile("codegen_cases/attr_assign_external.expected") },
    .{ .name = "codegen(çalıştır): str == str / != — gerçek içerik karşılaştırması (strcmp), işaretçi karşılaştırması DEĞİL", .kind = .golden, .source = @embedFile("codegen_cases/str_equality.nox"), .expected_stdout = @embedFile("codegen_cases/str_equality.expected") },
    .{ .name = "codegen(çalıştır): list[T]/sınıf için derin yapısal == / != — int/str/iç içe liste/sınıf/list[sınıf], sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/deep_equality.nox"), .expected_stdout = @embedFile("codegen_cases/deep_equality.expected") },
    .{ .name = "codegen(çalıştır): print(list)/print(sınıf) — Python benzeri görüntüleme, iç içe, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/print_list_class.nox"), .expected_stdout = @embedFile("codegen_cases/print_list_class.expected") },
    .{ .name = "codegen(çalıştır): import nox.testmod — nitelikli fonksiyon/sınıf çağrıları, iç modül içi çapraz-başvurular", .kind = .golden, .source = @embedFile("codegen_cases/import_basic.nox"), .expected_stdout = @embedFile("codegen_cases/import_basic.expected") },
    .{ .name = "codegen(çalıştır): import nox.testmod — kullanıcının aynı adlı KENDİ fonksiyonuyla ÇAKIŞMAZ", .kind = .golden, .source = @embedFile("codegen_cases/import_name_collision.nox"), .expected_stdout = @embedFile("codegen_cases/import_name_collision.expected") },
    .{ .name = "codegen(çalıştır): Faz U.3 — import nox.testmod as tm (takma ad üzerinden nitelikli çağrı)", .kind = .golden, .source = @embedFile("codegen_cases/import_as_alias.nox"), .expected_stdout = @embedFile("codegen_cases/import_as_alias.expected") },
    .{ .name = "codegen(çalıştır): Faz U.3 — from nox.testmod import double/quadruple as quad (çıplak çağrı)", .kind = .golden, .source = @embedFile("codegen_cases/from_import_basic.nox"), .expected_stdout = @embedFile("codegen_cases/from_import_basic.expected") },
    .{ .name = "codegen(çalıştır): Faz U.3 — from import ile gelen isim, KULLANICININ yerel tanımıyla GÖLGELENİR", .kind = .golden, .source = @embedFile("codegen_cases/from_import_shadowed_by_local.nox"), .expected_stdout = @embedFile("codegen_cases/from_import_shadowed_by_local.expected") },
    .{ .name = "codegen(çalıştır): str + str birleştirme (zincirleme) + len(), sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/str_concat_basic.nox"), .expected_stdout = @embedFile("codegen_cases/str_concat_basic.expected") },
    .{ .name = "codegen(çalıştır): str yeniden ataması eskisini serbest bırakır (çift serbest bırakma yok)", .kind = .golden, .source = @embedFile("codegen_cases/str_concat_reassignment_frees_old.nox"), .expected_stdout = @embedFile("codegen_cases/str_concat_reassignment_frees_old.expected") },
    .{ .name = "codegen(çalıştır): len(str) — literal ve değişken üzerinde", .kind = .golden, .source = @embedFile("codegen_cases/str_len.nox"), .expected_stdout = @embedFile("codegen_cases/str_len.expected") },
    .{ .name = "codegen(çalıştır): dict[int, int] — literal, indeksleme, contains/len, üzerine yazma", .kind = .golden, .source = @embedFile("codegen_cases/dict_int_key_basic.nox"), .expected_stdout = @embedFile("codegen_cases/dict_int_key_basic.expected") },
    .{ .name = "codegen(çalıştır): dict[str, int] — anahtar İÇERİK eşitliğiyle bulunur (pointer eşitliği DEĞİL)", .kind = .golden, .source = @embedFile("codegen_cases/dict_str_key_basic.nox"), .expected_stdout = @embedFile("codegen_cases/dict_str_key_basic.expected") },
    .{ .name = "codegen(çalıştır): dict[str, str] — str anahtar/değer ARC doğruluğu (üzerine yazma eskiyi serbest bırakır, sızıntı yok)", .kind = .golden, .source = @embedFile("codegen_cases/dict_str_key_str_value_arc.nox"), .expected_stdout = @embedFile("codegen_cases/dict_str_key_str_value_arc.expected") },
    .{ .name = "codegen(çalıştır): Faz S.1 — dict[K,V] DEĞİŞKENİNİN yeniden ataması eskisini serbest bırakır (sızıntı yok)", .kind = .golden, .source = @embedFile("codegen_cases/dict_reassignment_frees_old.nox"), .expected_stdout = @embedFile("codegen_cases/dict_reassignment_frees_old.expected") },
    .{ .name = "codegen(çalıştır): Faz FF.3 — dict[K,V] sınıf alanı, kaynak yerelden UZUN YAŞAR (sallanan işaretçi YOK)", .kind = .golden, .source = @embedFile("codegen_cases/dict_field_outlives_local_no_dangling.nox"), .expected_stdout = @embedFile("codegen_cases/dict_field_outlives_local_no_dangling.expected") },
    .{ .name = "codegen(çalıştır): Faz FF.3 — dict[K,V] İKİ AYRI sınıf örneğine + kaynak yerele PAYLAŞILIR (retain/release dengede)", .kind = .golden, .source = @embedFile("codegen_cases/dict_shared_across_two_class_instances.nox"), .expected_stdout = @embedFile("codegen_cases/dict_shared_across_two_class_instances.expected") },
    .{ .name = "codegen(çalıştır): Faz III.6 — dict[K,V].keys()/.values() (str/int/bool eleman tipleri)", .kind = .golden, .source = @embedFile("codegen_cases/dict_keys_values.nox"), .expected_stdout = @embedFile("codegen_cases/dict_keys_values.expected") },
    .{ .name = "codegen(çalıştır): Güvenlik H-2 — dict[K,V] eksik anahtar KeyError raise eder (null-pointer çökmesi YERİNE)", .kind = .golden, .source = @embedFile("codegen_cases/dict_missing_key_raises.nox"), .expected_stdout = @embedFile("codegen_cases/dict_missing_key_raises.expected") },
    .{ .name = "codegen(çalıştır): Faz FF.4 — çıplak self'li metod bir alanı GERÇEKTEN okur/yazar", .kind = .golden, .source = @embedFile("codegen_cases/bare_self_method_field_mutation.nox"), .expected_stdout = @embedFile("codegen_cases/bare_self_method_field_mutation.expected") },
    .{ .name = "codegen(çalıştır): Faz FF.5 — açıkça bildirilen sınıf alanları class_point.nox İLE AYNI davranır", .kind = .golden, .source = @embedFile("codegen_cases/class_declared_field_point.nox"), .expected_stdout = @embedFile("codegen_cases/class_declared_field_point.expected") },
    .{ .name = "codegen(çalıştır): Faz FF.5 — bildirilen alan inferFieldType'ın ele ALAMADIĞI (if içi atama) bir örüntüde ÇALIŞIR", .kind = .golden, .source = @embedFile("codegen_cases/class_declared_field_beyond_inference.nox"), .expected_stdout = @embedFile("codegen_cases/class_declared_field_beyond_inference.expected") },
    .{ .name = "codegen(çalıştır): str(int)/int(str) roundtrip", .kind = .golden, .source = @embedFile("codegen_cases/str_int_roundtrip.nox"), .expected_stdout = @embedFile("codegen_cases/str_int_roundtrip.expected") },
    .{ .name = "codegen(çalıştır): str(float)/float(str) roundtrip", .kind = .golden, .source = @embedFile("codegen_cases/str_float_roundtrip.nox"), .expected_stdout = @embedFile("codegen_cases/str_float_roundtrip.expected") },
    .{ .name = "codegen(çalıştır): int(s)/float(s) geçersiz girdide ValueError raise eder, try/except yakalar", .kind = .golden, .source = @embedFile("codegen_cases/int_parse_error_raises.nox"), .expected_stdout = @embedFile("codegen_cases/int_parse_error_raises.expected") },
    .{ .name = "codegen(çalıştır): str indeksleme s[i] — adlandırılmış/temporary taban, yeniden atama (sızıntı yok)", .kind = .golden, .source = @embedFile("codegen_cases/str_index_basic.nox"), .expected_stdout = @embedFile("codegen_cases/str_index_basic.expected") },
    .{ .name = "codegen(çalıştır): str indeksleme sınır dışı erişimde IndexError raise eder", .kind = .golden, .source = @embedFile("codegen_cases/str_index_out_of_bounds_raises.nox"), .expected_stdout = @embedFile("codegen_cases/str_index_out_of_bounds_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.strings.split/join", .kind = .golden, .source = @embedFile("codegen_cases/strings_split_join.nox"), .expected_stdout = @embedFile("codegen_cases/strings_split_join.expected") },
    .{ .name = "codegen(çalıştır): nox.strings.trim/upper/lower/replace", .kind = .golden, .source = @embedFile("codegen_cases/strings_case_trim_replace.nox"), .expected_stdout = @embedFile("codegen_cases/strings_case_trim_replace.expected") },
    .{ .name = "codegen(çalıştır): nox.strings.starts_with/ends_with/contains/index_of (str[i] karşılaştırma sızıntısı yok)", .kind = .golden, .source = @embedFile("codegen_cases/strings_search.nox"), .expected_stdout = @embedFile("codegen_cases/strings_search.expected") },
    .{ .name = "codegen(çalıştır): Faz III.2 — nox.strings trim_start/trim_end/splitn/rsplit/repeat/eq_ignore_case", .kind = .golden, .source = @embedFile("codegen_cases/strings_new_helpers.nox"), .expected_stdout = @embedFile("codegen_cases/strings_new_helpers.expected") },
    .{ .name = "codegen(çalıştır): list[T].sort() — int/str/float elemanlar", .kind = .golden, .source = @embedFile("codegen_cases/list_sort.nox"), .expected_stdout = @embedFile("codegen_cases/list_sort.expected") },
    .{ .name = "codegen(çalıştır): nox.math — sqrt/pow/floor/ceil (çıplak) + min/max/abs (nitelikli)", .kind = .golden, .source = @embedFile("codegen_cases/math_basic.nox"), .expected_stdout = @embedFile("codegen_cases/math_basic.expected") },
    .{ .name = "codegen(çalıştır): Faz III.1 — nox.math trigonometri/log/exp (çıplak) + pi/e (nitelikli)", .kind = .golden, .source = @embedFile("codegen_cases/math_trig_log_constants.nox"), .expected_stdout = @embedFile("codegen_cases/math_trig_log_constants.expected") },
    .{ .name = "codegen(çalıştır): nox.os.arg_count/arg (argc/argv $main'e taşınmış)", .kind = .golden, .source = @embedFile("codegen_cases/os_args_basic.nox"), .expected_stdout = @embedFile("codegen_cases/os_args_basic.expected") },
    .{ .name = "codegen(çalıştır): nox.os.getenv eksik değişken OsError raise eder", .kind = .golden, .source = @embedFile("codegen_cases/os_getenv_missing_raises.nox"), .expected_stdout = @embedFile("codegen_cases/os_getenv_missing_raises.expected") },
    .{ .name = "codegen(çalıştır): Faz III.5 — nox.os set_var/current_dir", .kind = .golden, .source = @embedFile("codegen_cases/os_new_operations.nox"), .expected_stdout = @embedFile("codegen_cases/os_new_operations.expected") },
    .{ .name = "codegen(çalıştır): nox.fs.write_string/read_to_string round-trip", .kind = .golden, .source = @embedFile("codegen_cases/fs_read_write_roundtrip.nox"), .expected_stdout = @embedFile("codegen_cases/fs_read_write_roundtrip.expected") },
    .{ .name = "codegen(çalıştır): Faz III.3 — nox.fs append/metadata/read_dir/copy/rename/remove_file/create_dir", .kind = .golden, .source = @embedFile("codegen_cases/fs_new_operations.nox"), .expected_stdout = @embedFile("codegen_cases/fs_new_operations.expected") },
    .{ .name = "codegen(çalıştır): nox.fs.read_to_string eksik dosya FsError raise eder", .kind = .golden, .source = @embedFile("codegen_cases/fs_read_missing_raises.nox"), .expected_stdout = @embedFile("codegen_cases/fs_read_missing_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.fs.exists/is_file/is_dir — raise ETMEDEN sorgu", .kind = .golden, .source = @embedFile("codegen_cases/fs_exists_queries.nox"), .expected_stdout = @embedFile("codegen_cases/fs_exists_queries.expected") },
    .{ .name = "codegen(çalıştır): nox.path.join/basename/dirname/extension/is_absolute", .kind = .golden, .source = @embedFile("codegen_cases/path_manipulation.nox"), .expected_stdout = @embedFile("codegen_cases/path_manipulation.expected") },
    .{ .name = "codegen(çalıştır): Faz III.4 — nox.path canonicalize/strip_prefix/components", .kind = .golden, .source = @embedFile("codegen_cases/path_new_operations.nox"), .expected_stdout = @embedFile("codegen_cases/path_new_operations.expected") },
    .{ .name = "codegen(çalıştır): nox.time.now_ms/sleep_ms (monoton artış)", .kind = .golden, .source = @embedFile("codegen_cases/time_now_monotonic_increases.nox"), .expected_stdout = @embedFile("codegen_cases/time_now_monotonic_increases.expected") },
    .{ .name = "codegen(çalıştır): nox.log.format — seviye etiketi + zaman damgası + mesaj yapısı (nox.strings ile deterministik doğrulama)", .kind = .golden, .source = @embedFile("codegen_cases/log_format_structure.nox"), .expected_stdout = @embedFile("codegen_cases/log_format_structure.expected") },
    .{ .name = "codegen(çalıştır): nox.random.seed/randint/random — aralık sınırları + aynı tohumla deterministik tekrar", .kind = .golden, .source = @embedFile("codegen_cases/random_seeded_reproducible.nox"), .expected_stdout = @embedFile("codegen_cases/random_seeded_reproducible.expected") },
    .{ .name = "codegen(çalıştır): Faz III.8 — nox.random.normal/exponential + shuffle (int/str list[T])", .kind = .golden, .source = @embedFile("codegen_cases/random_normal_exponential_shuffle.nox"), .expected_stdout = @embedFile("codegen_cases/random_normal_exponential_shuffle.expected") },
    .{ .name = "codegen(çalıştır): nox.crypto.sha256 — bilinen test vektörleri (\"\"/\"abc\")", .kind = .golden, .source = @embedFile("codegen_cases/crypto_sha256_known_vectors.nox"), .expected_stdout = @embedFile("codegen_cases/crypto_sha256_known_vectors.expected") },
    .{ .name = "codegen(çalıştır): Faz III.9 — nox.crypto.sha1/sha512 bilinen test vektörleri (\"\"/\"abc\")", .kind = .golden, .source = @embedFile("codegen_cases/crypto_sha1_sha512_known_vectors.nox"), .expected_stdout = @embedFile("codegen_cases/crypto_sha1_sha512_known_vectors.expected") },
    .{ .name = "codegen(çalıştır): Güvenlik M-4/M-6 — nox.crypto.hmac_sha256/constant_time_eq/secure_random_hex", .kind = .golden, .source = @embedFile("codegen_cases/crypto_hmac_and_secure_random.nox"), .expected_stdout = @embedFile("codegen_cases/crypto_hmac_and_secure_random.expected") },
    .{ .name = "codegen(çalıştır): nox.crypto.argon2_hash/bcrypt_hash/scrypt_hash + verify", .kind = .golden, .source = @embedFile("codegen_cases/crypto_password_hashing.nox"), .expected_stdout = @embedFile("codegen_cases/crypto_password_hashing.expected") },
    .{ .name = "codegen(çalıştır): nox.uuid.uuid4 + is_valid", .kind = .golden, .source = @embedFile("codegen_cases/uuid_v4.nox"), .expected_stdout = @embedFile("codegen_cases/uuid_v4.expected") },
    .{ .name = "codegen(çalıştır): nox.time.DateTime — bilinen epoch-ms'in doğru takvim bileşenlerine ayrıştırılması", .kind = .golden, .source = @embedFile("codegen_cases/time_datetime_from_epoch_ms.nox"), .expected_stdout = @embedFile("codegen_cases/time_datetime_from_epoch_ms.expected") },
    .{ .name = "codegen(çalıştır): Faz III.7 — DateTime.to_str() + Instant/Duration", .kind = .golden, .source = @embedFile("codegen_cases/time_datetime_to_str_and_instant.nox"), .expected_stdout = @embedFile("codegen_cases/time_datetime_to_str_and_instant.expected") },
    .{ .name = "codegen(çalıştır): nox.test.TestSuite — check_* HİÇ raise ETMEZ (setup/teardown HER ZAMAN çalışır) + JUnit XML raporu", .kind = .golden, .source = @embedFile("codegen_cases/test_suite_setup_teardown_junit.nox"), .expected_stdout = @embedFile("codegen_cases/test_suite_setup_teardown_junit.expected") },
    .{ .name = "codegen(çalıştır): nox.regex.is_match/find — temel alt küme (karakter sınıfları, */+/?, ^/$)", .kind = .golden, .source = @embedFile("codegen_cases/regex_basic_patterns.nox"), .expected_stdout = @embedFile("codegen_cases/regex_basic_patterns.expected") },
    .{ .name = "codegen(çalıştır): nox.test.assert_eq_*/assert_true (başarılı yol)", .kind = .golden, .source = @embedFile("codegen_cases/test_assert_eq_pass.nox"), .expected_stdout = @embedFile("codegen_cases/test_assert_eq_pass.expected") },
    .{ .name = "codegen(çalıştır): nox.test.assert_eq_int başarısız olursa AssertionError raise eder", .kind = .golden, .source = @embedFile("codegen_cases/test_assert_eq_fail_raises.nox"), .expected_stdout = @embedFile("codegen_cases/test_assert_eq_fail_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.json.decode — iç içe dizi/obje, sayı/string/bool/null karışık", .kind = .golden, .source = @embedFile("codegen_cases/json_decode_nested.nox"), .expected_stdout = @embedFile("codegen_cases/json_decode_nested.expected") },
    .{ .name = "codegen(çalıştır): nox.json.decode TEKRARLANAN çağrılar — İLK çağrı yavaş/keşif yolunu, SONRAKİLER hızlı doğrudan-inşa yolunu (class_id önbelleği) egzersiz eder", .kind = .golden, .source = @embedFile("codegen_cases/json_decode_repeated_calls.nox"), .expected_stdout = @embedFile("codegen_cases/json_decode_repeated_calls.expected") },
    .{ .name = "codegen(çalıştır): nox.json — decode/encode round-trip", .kind = .golden, .source = @embedFile("codegen_cases/json_encode_roundtrip.nox"), .expected_stdout = @embedFile("codegen_cases/json_encode_roundtrip.expected") },
    .{ .name = "codegen(çalıştır): Faz III.10 — nox.json.encode_pretty (iç içe/boş dizi-nesne/skaler)", .kind = .golden, .source = @embedFile("codegen_cases/json_encode_pretty.nox"), .expected_stdout = @embedFile("codegen_cases/json_encode_pretty.expected") },
    .{ .name = "codegen(çalıştır): nox.json.decode bozuk JSON JsonError raise eder", .kind = .golden, .source = @embedFile("codegen_cases/json_decode_malformed_raises.nox"), .expected_stdout = @embedFile("codegen_cases/json_decode_malformed_raises.expected") },
    .{ .name = "codegen(çalıştır): nox.json.decode derinlik sinirini asan girdiyi cokmeden reddeder", .kind = .golden, .source = @embedFile("codegen_cases/json_decode_too_deeply_nested_raises.nox"), .expected_stdout = @embedFile("codegen_cases/json_decode_too_deeply_nested_raises.expected") },
    .{ .name = "codegen(çalıştır): Faz II devamı — nox.json string encode'da \\t/CR escape (GERÇEK düzeltilen boşluk)", .kind = .golden, .source = @embedFile("codegen_cases/json_string_control_char_escaping.nox"), .expected_stdout = @embedFile("codegen_cases/json_string_control_char_escaping.expected") },
    .{ .name = "codegen(çalıştır): Faz II devamı — nox.json boş obje/dizi decode+encode", .kind = .golden, .source = @embedFile("codegen_cases/json_empty_containers.nox"), .expected_stdout = @embedFile("codegen_cases/json_empty_containers.expected") },
    .{ .name = "codegen(çalıştır): Faz II devamı — nox.json negatif/iç içe sayılar", .kind = .golden, .source = @embedFile("codegen_cases/json_negative_and_nested_numbers.nox"), .expected_stdout = @embedFile("codegen_cases/json_negative_and_nested_numbers.expected") },
    .{ .name = "codegen(çalıştır): Faz FF.6 — Node.next: Node | None ile bağlı liste inşası + traversal + find", .kind = .golden, .source = @embedFile("codegen_cases/optional_linked_list.nox"), .expected_stdout = @embedFile("codegen_cases/optional_linked_list.expected") },
    .{ .name = "codegen(çalıştır): Faz FF.6 — kutulanmış int | None: None dönüşü + auto-wrap + narrowing round-trip", .kind = .golden, .source = @embedFile("codegen_cases/optional_primitive_box.nox"), .expected_stdout = @embedFile("codegen_cases/optional_primitive_box.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.2 — küçük serbest fonksiyonlar çağrı sitesine inline edilir", .kind = .golden, .source = @embedFile("codegen_cases/inline_small_free_function.nox"), .expected_stdout = @embedFile("codegen_cases/inline_small_free_function.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.2 — aynı fonksiyon HEM inline-uygun HEM değişkene atanarak çağrılır", .kind = .golden, .source = @embedFile("codegen_cases/inline_same_function_both_paths.nox"), .expected_stdout = @embedFile("codegen_cases/inline_same_function_both_paths.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.2 — caller/callee isim çakışması gölgeleme/geri-yükleme ile doğru ele alınır", .kind = .golden, .source = @embedFile("codegen_cases/inline_name_collision_hygiene.nox"), .expected_stdout = @embedFile("codegen_cases/inline_name_collision_hygiene.expected") },
    .{ .name = "codegen(çalıştır): Faz GG.2 — döngülü/özyinelemeli gövdeler inline edilmeden doğru derlenip çalışır", .kind = .golden, .source = @embedFile("codegen_cases/inline_ineligible_fallback.nox"), .expected_stdout = @embedFile("codegen_cases/inline_ineligible_fallback.expected") },
    .{ .name = "codegen(çalıştır): Faz JJ — list[str] yerelli küçük fonksiyon, 2+ yinelemeli döngüde İKİ KEZ inline çağrılır (ÖNCEDEN SIGSEGV)", .kind = .golden, .source = @embedFile("codegen_cases/inline_loop_list_str_local_double_call.nox"), .expected_stdout = @embedFile("codegen_cases/inline_loop_list_str_local_double_call.expected") },
    .{ .name = "codegen(çalıştır): Faz NN — list[str] döndüren fonksiyon 'return xs' ile döngüde tekrar tekrar inline çağrılır (ÖNCEDEN SIGSEGV)", .kind = .golden, .source = @embedFile("codegen_cases/inline_loop_list_return_identifier.nox"), .expected_stdout = @embedFile("codegen_cases/inline_loop_list_return_identifier.expected") },
    .{ .name = "codegen(çalıştır): defer — tek bir defer fonksiyon sonunda çalışır", .kind = .golden, .source = @embedFile("codegen_cases/defer_single.nox"), .expected_stdout = @embedFile("codegen_cases/defer_single.expected") },
    .{ .name = "codegen(çalıştır): defer — birden fazla defer LIFO sırasıyla çalışır", .kind = .golden, .source = @embedFile("codegen_cases/defer_lifo_order.nox"), .expected_stdout = @embedFile("codegen_cases/defer_lifo_order.expected") },
    .{ .name = "codegen(çalıştır): defer — bir döngü içinde defer, dinamik sayıda bekleyen çağrıyı doğru LIFO sırasıyla çalıştırır", .kind = .golden, .source = @embedFile("codegen_cases/defer_in_loop.nox"), .expected_stdout = @embedFile("codegen_cases/defer_in_loop.expected") },
    .{ .name = "codegen(çalıştır): defer — try/except/finally İLE etkileşim (defer finally/except SONRASI, fonksiyon dönüşünden HEMEN ÖNCE çalışır)", .kind = .golden, .source = @embedFile("codegen_cases/defer_try_finally_interaction.nox"), .expected_stdout = @embedFile("codegen_cases/defer_try_finally_interaction.expected") },
    .{ .name = "codegen(çalıştır): defer — yakalanmamış bir istisna fonksiyondan DIŞARI sızarken de çalışır", .kind = .uncaught_exception, .source = @embedFile("codegen_cases/defer_exception_propagation.nox"), .expected_stdout = @embedFile("codegen_cases/defer_exception_propagation.expected") },
    .{ .name = "codegen(çalıştır): TaskLocal[T] — iki fiber arasında GERÇEK per-fiber izolasyon, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/task_local_basic.nox"), .expected_stdout = @embedFile("codegen_cases/task_local_basic.expected") },
    .{ .name = "codegen(çalıştır): Faz OO.3 — yakalanmamış istisna GERÇEK sınıf adını ve satır numarasını raporlar", .kind = .uncaught_exception_with_stderr, .source = @embedFile("codegen_cases/exception_line_and_name.nox"), .expected_stdout = @embedFile("codegen_cases/exception_line_and_name.expected"), .expected_stderr = "nox: yakalanmamış istisna: ShoppingCartError (satır 6) — program sonlandırılıyor\n" },
    .{ .name = "codegen(çalıştır): dict[int, class] — inşa+oku+üzerine-yaz+values(), sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/dict_int_key_class_value.nox"), .expected_stdout = @embedFile("codegen_cases/dict_int_key_class_value.expected") },
    .{ .name = "codegen(çalıştır): GG.17 — sınıf ÖRNEĞİ + liste literali BİRLİKTE stack yereline dönüşür, sızıntı yok", .kind = .golden, .source = @embedFile("codegen_cases/stack_local_class_and_list_positive.nox"), .expected_stdout = @embedFile("codegen_cases/stack_local_class_and_list_positive.expected") },
    .{ .name = "codegen(çalıştır): GG.17 — stack yereli BÜYÜK bir döngü boyunca TEK slotla güvenle yeniden kullanılır", .kind = .golden, .source = @embedFile("codegen_cases/stack_local_loop_safety.nox"), .expected_stdout = @embedFile("codegen_cases/stack_local_loop_safety.expected") },
    .{ .name = "codegen(çalıştır): GG.17 — return edilen bir yerel stack'e dönüştürülmez (kaçış)", .kind = .golden, .source = @embedFile("codegen_cases/stack_local_return_escape.nox"), .expected_stdout = @embedFile("codegen_cases/stack_local_return_escape.expected") },
    .{ .name = "codegen(çalıştır): GG.17 — başka bir fonksiyona argüman olarak geçen yerel stack'e dönüştürülmez (kaçış)", .kind = .golden, .source = @embedFile("codegen_cases/stack_local_arg_escape.nox"), .expected_stdout = @embedFile("codegen_cases/stack_local_arg_escape.expected") },
    .{ .name = "codegen(çalıştır): GG.17 — takma ad verilen bir yerel stack'e dönüştürülmez (kaçış)", .kind = .golden, .source = @embedFile("codegen_cases/stack_local_alias_escape.nox"), .expected_stdout = @embedFile("codegen_cases/stack_local_alias_escape.expected") },
    .{ .name = "codegen(çalıştır): GG.17/18 — boyut tavanını aşan bir liste stack'e DEĞİL ama arenaya dönüşür", .kind = .golden, .source = @embedFile("codegen_cases/stack_local_size_cap.nox"), .expected_stdout = @embedFile("codegen_cases/stack_local_size_cap.expected") },
    .{ .name = "codegen(çalıştır): GG.17 hotfix + GG.19 — yerel-inşa içeren fonksiyon artık GÜVENLE inline ediliyor", .kind = .golden, .source = @embedFile("codegen_cases/gg17_hotfix_no_inline_local_construct.nox"), .expected_stdout = @embedFile("codegen_cases/gg17_hotfix_no_inline_local_construct.expected") },
    .{ .name = "codegen(çalıştır): GG.18 — boş listeden .append() ile büyüyen yerel, fonksiyon-kapsamlı arenaya dönüşür", .kind = .golden, .source = @embedFile("codegen_cases/growable_arena_positive.nox"), .expected_stdout = @embedFile("codegen_cases/growable_arena_positive.expected") },
    .{ .name = "codegen(çalıştır): GG.18 — büyük N'de sık create/destroy döngüsü güvenle çalışır", .kind = .golden, .source = @embedFile("codegen_cases/growable_arena_loop_safety.nox"), .expected_stdout = @embedFile("codegen_cases/growable_arena_loop_safety.expected") },
    .{ .name = "codegen(çalıştır): GG.18 — return edilen büyüyen bir liste arenaya dönüştürülmez (kaçış)", .kind = .golden, .source = @embedFile("codegen_cases/growable_arena_return_escape.nox"), .expected_stdout = @embedFile("codegen_cases/growable_arena_return_escape.expected") },
    .{ .name = "codegen(çalıştır): GG.18 — argüman olarak geçen büyüyen bir liste arenaya dönüştürülmez (kaçış)", .kind = .golden, .source = @embedFile("codegen_cases/growable_arena_arg_escape.nox"), .expected_stdout = @embedFile("codegen_cases/growable_arena_arg_escape.expected") },
    .{ .name = "codegen(çalıştır): GG.18 — .pop() kullanan bir liste arenaya dönüştürülmez (kaçış)", .kind = .golden, .source = @embedFile("codegen_cases/growable_arena_pop_escape.nox"), .expected_stdout = @embedFile("codegen_cases/growable_arena_pop_escape.expected") },
    .{ .name = "codegen(çalıştır): GG.18 — heap-yönetimli eleman tipi (list[str]) arenaya dönüştürülmez", .kind = .golden, .source = @embedFile("codegen_cases/growable_arena_heap_element_excluded.nox"), .expected_stdout = @embedFile("codegen_cases/growable_arena_heap_element_excluded.expected") },
    .{ .name = "codegen(çalıştır): GG.19 — inline + stack-promotion BİRLİKTE çalışır", .kind = .golden, .source = @embedFile("codegen_cases/gg19_inline_and_stack_together.nox"), .expected_stdout = @embedFile("codegen_cases/gg19_inline_and_stack_together.expected") },
    .{ .name = "codegen(çalıştır): GG.19 — aynı helper'ın birden fazla çağrı sitesi çakışmadan inline edilir", .kind = .golden, .source = @embedFile("codegen_cases/gg19_same_helper_multiple_callsites.nox"), .expected_stdout = @embedFile("codegen_cases/gg19_same_helper_multiple_callsites.expected") },
    .{ .name = "codegen(çalıştır): GG.19 — aynı helper'ın iki farklı caller'dan çağrılması çakışmadan çalışır", .kind = .golden, .source = @embedFile("codegen_cases/gg19_same_helper_two_callers.nox"), .expected_stdout = @embedFile("codegen_cases/gg19_same_helper_two_callers.expected") },
    .{ .name = "codegen(çalıştır): GG.19 — aggregate stack bütçesini aşan sınıf örnekleri arenaya düşer", .kind = .golden, .source = @embedFile("codegen_cases/gg19_aggregate_stack_budget.nox"), .expected_stdout = @embedFile("codegen_cases/gg19_aggregate_stack_budget.expected") },
    .{ .name = "codegen(çalıştır): GG.22 — yerel bir func-değeri, FARKLI imzalı aynı-adlı bir global fonksiyonu gölgeler", .kind = .golden, .source = @embedFile("codegen_cases/local_func_value_shadows_global_diff_arity.nox"), .expected_stdout = @embedFile("codegen_cases/local_func_value_shadows_global_diff_arity.expected") },
    .{ .name = "codegen(çalıştır): GG.24 — eşiği aşan derin bir sınıf-zinciri release'i çökmeden tamamlanır", .kind = .golden, .source = @embedFile("codegen_cases/gg24_deep_class_chain_release.nox"), .expected_stdout = @embedFile("codegen_cases/gg24_deep_class_chain_release.expected") },
    .{ .name = "codegen(çalıştır): GG.24 — eşiğin altında sığ bir sınıf-zinciri regresyonsuz çalışır", .kind = .golden, .source = @embedFile("codegen_cases/gg24_shallow_class_chain_release.nox"), .expected_stdout = @embedFile("codegen_cases/gg24_shallow_class_chain_release.expected") },
    .{ .name = "codegen(çalıştır): GG.24 — list[Node] elemanının derin zinciri çökmeden release edilir", .kind = .golden, .source = @embedFile("codegen_cases/gg24_list_of_class_deep_chain_release.nox"), .expected_stdout = @embedFile("codegen_cases/gg24_list_of_class_deep_chain_release.expected") },
    .{ .name = "codegen(çalıştır): GG.24 — polimorfik bir sınıfın derin zinciri çökmeden release edilir", .kind = .golden, .source = @embedFile("codegen_cases/gg24_polymorphic_deep_chain_release.nox"), .expected_stdout = @embedFile("codegen_cases/gg24_polymorphic_deep_chain_release.expected") },
    .{ .name = "codegen(çalıştır): GG.24 — bare except ile yakalanan derin zincirli bir istisna çökmeden release edilir", .kind = .golden, .source = @embedFile("codegen_cases/gg24_bare_except_deep_chain_release.nox"), .expected_stdout = @embedFile("codegen_cases/gg24_bare_except_deep_chain_release.expected") },
    .{ .name = "codegen(çalıştır): GG.25.1 — 1000 seviyelik sıradan kullanıcı özyinelemesi fiber yığınında çökmeden tamamlanır", .kind = .golden, .source = @embedFile("codegen_cases/gg25_user_recursion_depth_1000.nox"), .expected_stdout = @embedFile("codegen_cases/gg25_user_recursion_depth_1000.expected") },
    .{ .name = "codegen(çalıştır): liste literali sondaki virgülü kabul eder (çok satırlı ve tek satırlı)", .kind = .golden, .source = @embedFile("codegen_cases/list_lit_trailing_comma.nox"), .expected_stdout = @embedFile("codegen_cases/list_lit_trailing_comma.expected") },
};

fn runOneFixture(fx: *const Fixture, result: *FixtureResult) void {
    const outcome = switch (fx.kind) {
        .golden => expectGolden(fx.source, fx.expected_stdout),
        .uncaught_exception => expectUncaughtException(fx.source, fx.expected_stdout),
        .uncaught_exception_with_stderr => expectUncaughtExceptionWithStderr(fx.source, fx.expected_stdout, fx.expected_stderr),
    };
    outcome catch |e| {
        result.* = .{ .ok = false, .err_name = @errorName(e) };
        return;
    };
    result.* = .{ .ok = true };
}

test "codegen(çalıştır): TÜM golden fixture'lar (gerçek iş-parçacığı paralelliğiyle)" {
    const results = try std.testing.allocator.alloc(FixtureResult, fixtures.len);
    defer std.testing.allocator.free(results);
    @memset(results, .{});

    var next_index: std.atomic.Value(usize) = .init(0);
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const n_workers = @min(fixtures.len, cpu_count * 2);

    const WorkerCtx = struct {
        next_index: *std.atomic.Value(usize),
        results: []FixtureResult,
        fn run(ctx: @This()) void {
            while (true) {
                const i = ctx.next_index.fetchAdd(1, .monotonic);
                if (i >= fixtures.len) return;
                runOneFixture(&fixtures[i], &ctx.results[i]);
            }
        }
    };
    const ctx: WorkerCtx = .{ .next_index = &next_index, .results = results };

    const threads = try std.testing.allocator.alloc(std.Thread, n_workers);
    defer std.testing.allocator.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, WorkerCtx.run, .{ctx});
    for (threads) |t| t.join();

    var any_failed = false;
    for (fixtures, results) |fx, r| {
        if (!r.ok) {
            any_failed = true;
            std.debug.print("BAŞARISIZ: {s} ({s})\n", .{ fx.name, r.err_name });
        }
    }
    if (any_failed) return error.GoldenFixturesFailed;
}









// `and`/`or`ın artık GERÇEKTEN kısa devre yaptığını doğrular (bkz.
// nox-teknik-spesifikasyon.md'nin güncellenen notu) — yan etkili (print
// eden) bir sağ operand, sol operand sonucu ZATEN belirliyorsa HİÇ
// çalıştırılmamalı; belirlemiyorsa çalışmalı VE `and`/`or`ın birleştirdiği
// DEĞER sağ operandın KENDİ değeri olmalı (sadece bir kısa-devre
// sentinel'i değil).


// Orijinal hata raporundaki çökme örüntüsünün AYNISI: `pos < n and
// text[pos] != "X"` — `and` kısa devre YAPMIYORSA `pos == n`/`pos > n`
// iken `text[pos]` yine de değerlendirilir (boş dizede ya da dizenin TAM
// SONUNDA bir IndexError'a/NULL-işaretçi çökmesine yol açardı).


// `return s[i]` (bir str char-at ifadesini DOĞRUDAN döndürmek) artık
// sızdırmıyor — `returnNeedsRetain`in `.index` dalı ARTIK `Value.always_fresh`i
// kontrol ediyor (bkz. ownership.zig). Sıkı bir döngüde 50000 çağrı —
// düzeltme ÖNCESİ her çağrı başına 1 tahsis sızdırırdı, bu da
// `expectGolden`in "stderr boş olmalı" kontrolünü (DebugAllocator'ın
// sızıntı raporu) tetiklerdi.












































// Faz M.8 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md §3.59):
// `collectRaiseInfoExpr`in `.call => .identifier` dalı, isim ne
// `self.classes` ne `self.functions`se (ör. bir closure değişkeni — bu
// fixture'daki `f`) SESSİZCE hiçbir şey YAPMIYORDU (ne `direct_unsafe`
// işaretliyor NE `callees`e ekliyordu) — bu, `f()`in İÇİNDE bulunduğu
// `outer`in YANLIŞLIKLA "asla raise etmez" kümesine girmesine, dolayısıyla
// `compute`nin `outer(i - 5)` çağrı sitesindeki istisna kontrolünün
// YANLIŞLIKLA elenmesine yol açan GERÇEK, ÖNCEDEN VAR OLAN bir hataydı —
// `except MyError` HİÇ tetiklenmiyor, `MyError` nesneleri sessizce
// SIZIYORDU (GERÇEK bir denemeyle DOĞRULANDI). Bu test DÜZELTMEDEN ÖNCE
// KIRMIZI olmalı (beklenen "5" yerine yanlış bir değer/sızıntı hatası).




// Faz M.8 (yeniden ele alındı, bkz. nox-teknik-spesifikasyon.md §3.59): BU,
// TASARIMIN "istisna asla yutulmaz" ANA garantisini doğrulayan EN KRİTİK
// testtir. `Chain.level1`in `self.level2()` çağırması VE `compute`nin
// (serbest fonksiyon) `c.level1(...)`u YEREL bir değişken üzerinden
// çağırması — HER İKİ çözümleme yolu (`self.` VE yerel değişken) da AYNI
// testte kullanılır. `level3` GERÇEKTEN raise ettiğinden (`x < 0` dalı),
// bu bilgi `computeMustNotRaise`in sabit-nokta hesabıyla `level2`/`level1`/
// `compute`ye TRANSİTİF olarak yayılıp HEPSİNİ güvensiz işaretlemelidir —
// hiçbir çağrı sitesinde kontrol YANLIŞLIKLA elenmemeli, `except MyError`
// HER ZAMAN tetiklenmelidir (5 kez, her biri `e.code`=99 katkı yapar).




// Güvenlik testi: `obj` önce `A` sonra (yalnızca `if` dalında) `B` olarak
// YENİDEN bildiriliyor — `checker.zig`nin `Scope.declare`si bunu YASAKLAMAZ
// (bkz. `declareVarType`in belge notu). Bu, `obj`in `var_types`den
// ÇIKARILIP `poisoned`e EKLENMESİNİ tetiklemeli, `obj.get()` çağrısı
// MUHAFAZAKÂR (`direct_unsafe`) kalmalı — davranış (doğru sınıfın `get`i
// çağrılması) BUNDAN HİÇ ETKİLENMEMELİDİR, yalnızca kontrol FAZLADAN kalır.


// Pozitif (GERÇEKTEN elenen) durum: `Adder`in HİÇBİR metodu raise ETMEZ —
// hem `self.inc(x)` (metod içinden) hem `a.double_inc(x)` (yerel değişken
// üzerinden, `use_local` serbest fonksiyonu içinde) çağrıları DOĞRU
// çalışmaya devam eder (davranış değişmedi). IR-metni düzeyinde GERÇEKTEN
// elenmenin gerçekleştiğinin doğrulanması için bkz. aşağıdaki AYRI
// "IR'da nox_exception_pending YOK" testi (aynı fixture'ı KULLANIR).


test "codegen: Faz M.8 — provably-safe metod çağrılarının ÜRETTİĞİ IR'da nox_exception_pending GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/method_call_elision_positive.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    // `Adder`in ne `__init__`i ne `inc`i ne `double_inc`i HİÇBİR ZAMAN raise
    // ETMEZ (kod içinde tek bir `raise` bile YOK) — bu yüzden bu programın
    // ÜRETTİĞİ IR'da `nox_exception_pending`e TEK bir çağrı bile
    // OLMAMALIDIR (elenmenin GERÇEKTEN gerçekleştiğinin doğrudan kanıtı,
    // yalnızca davranışın değişmediğinin DEĞİL).
    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_exception_pending") == null);
}

// Faz GG.3: `for b in boxes: ... b.get() ...` deseni — `boxes` parametresi
// `list[Box]` tipinde OLDUĞUNDAN döngü değişkeni `b`nin sınıfı ARTIK
// `list_elem_types` ÜZERİNDEN çözümlenir (GG.3 ÖNCESİ her zaman `null`
// olurdu, `b.get()` DAİMA `direct_unsafe` sayılıp TÜM `sum_boxes`
// fonksiyonunu zehirlerdi). `Box`in ne `__init__`i ne `get`i HİÇBİR ZAMAN
// raise ETMEZ — davranış (doğru toplamın hesaplanması) GG.3'TEN
// ETKİLENMEMELİDİR, yalnızca kontrol elenmelidir (bkz. aşağıdaki AYRI
// "IR'da nox_exception_pending YOK" testi).


test "codegen: Faz GG.3 — for-loop içindeki provably-safe metod çağrısının ÜRETTİĞİ IR'da nox_exception_pending GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/for_loop_method_call_elision_positive.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    // GG.3 ÖNCESİ: `for_stmt` HER ZAMAN döngü değişkeninin sınıfını `null`
    // olarak bildirirdi, bu yüzden `b.get()` ÇÖZÜMLENEMEZ sayılıp
    // `sum_boxes`u zehirlerdi VE bu IR'da `nox_exception_pending` çağrısı
    // görünürdü. GG.3 SONRASI: `boxes: list[Box]` parametresinden `b`nin
    // `Box` olduğu çözümlenir, `Box.get` çağrı-grafiğine GERÇEK bir kenar
    // olarak eklenir, `Box.__init__`/`Box.get` İKİSİ DE raise ETMEDİĞİNDEN
    // `sum_boxes` `must_not_raise` kümesine girer — TEK bir
    // `nox_exception_pending` çağrısı bile OLMAMALIDIR.
    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_exception_pending") == null);
}

// Faz GG.5 (manuel LICM): `s[i]`nin sınır kontrolü İçin GEREKEN `strlen(s)`
// artık `s` bir döngü İÇİNDE HİÇ yeniden atanmayan `str`-tipli bir kimlikse
// döngüye girmeden ÖNCE BİR KEZ hesaplanıp önbelleklenir — `count_two`nun
// gövdesinde AYNI `s`ye AYRI İKİ `s[i]` erişimi VAR (`== "a"` VE `== "n"`),
// `count_via_for`de İSE `for i in range(len(s)): ... s[i] ...` deseni. Her
// ikisi de davranış DEĞİŞMEDEN (doğru sayım) çalışır.


test "codegen: Faz GG.5 — döngü içinde AYNI str için TEK bir strlen çağrısı (deduplike edildi)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/str_index_loop_licm_positive.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    // `s[i]`nin sınır-dışı dalı `IndexError`ı (bir `nox.core` yerleşiği,
    // bkz. `stdlib/nox/core.nox`) İNŞA EDER — `compileAndRun`in AYNI
    // `resolveImports` çağrısı GEREKİR, aksi halde `genStrIndex`
    // `self.classes.get("IndexError")`ı BULAMAYIP `error.Unsupported`
    // döner (M.8/GG.3'ün IR-metni fixture'ları HİÇ indeksleme
    // İÇERMEDİĞİNDEN bu adıma İHTİYAÇ DUYMAMIŞTI).
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    // `count_two`nun gövdesinde `s[i]` İKİ AYRI ifade konumunda GÖRÜNÜR
    // (`== "a"` VE `== "n"` karşılaştırmaları) — GG.5 ÖNCESİ bu İKİ AYRI
    // `call $strlen` ÜRETİRDİ (döngünün HER yinelemesinde İKİ KEZ
    // çalışırdı). GG.5 SONRASI: `enterStrLenCacheScope` döngüye girmeden
    // ÖNCE TEK bir çağrı üretir, HER İKİ `s[i]` erişimi de AYNI önceden-
    // hesaplanmış temp'i YENİDEN KULLANIR — bu FONKSİYONUN ÜRETTİĞİ IR'da
    // bu çağrı TAM OLARAK BİR KEZ görünmelidir. Bulundu (bkz. proje belleği
    // "UTF-8 farkındalığı" görevi): arananın adı `$strlen`DEN
    // `$nox_str_char_count`e DEĞİŞTİ (bkz. `calls.zig`/`expr.zig`/
    // `optimizations.zig`nin AYNI notu) — SAYIM MANTIĞI DEĞİŞMEDİ, yalnızca
    // aranan LİTERAL isim güncellendi.
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, ir, search_from, "call $nox_str_char_count")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    // Elle `.ssa` dökümüyle DOĞRULANDI: `count_two` GG.5 ÖNCESİ 2 STATİK
    // çağrı üretirdi (`s[i]`nin İKİ AYRI ifade konumu, `== "a"`/`== "n"`) —
    // GG.5 SONRASI TEK bir hoisted çağrıya (`@while_cond0`DAN ÖNCE) DÜŞTÜ.
    // `count_via_for`, `range(len(s))`in builtin `len()` çağrısından
    // (`genStrIndex`DEN BAĞIMSIZ, AYRI bir çağrı sitesi — dokunulmadı) 1
    // VE döngü-içi TEK `s[i]`si İçin hoisted 1 = 2 (statik sayı DEĞİŞMEZ,
    // tek konum zaten dedupe EDİLECEK İKİNCİ bir konum YOK — ama çalışma
    // zamanında artık döngü GÖVDESİ İçinde DEĞİL). TOPLAM (1 + 2) = **3** —
    // GG.5 ÖNCESİ bu SAYI 4 OLURDU (`count_two`nun dedupe EDİLMEMİŞ 2
    // statik konumu YÜZÜNDEN).
    try std.testing.expect(count == 3);
}

// Faz GG.5 — KRİTİK güvenlik testi: `s` döngü GÖVDESİ İÇİNDE (bir `if`
// dalında) yeniden atanıyor — `collectReassignedNames` bunu YAKALAYIP
// `s`yi önbellek ADAYLARINDAN ÇIKARMALIDIR (aksi halde İKİNCİ yinelemede
// `s[1]`, ESKİ `"abcdef"`nin `s[1]`i OLAN `'b'`yi (YANLIŞLIKLA
// ÖNBELLEKLENMİŞ bir işaretçi/uzunluktan) döndürürdü — YENİ atanan
// `"xyz"`nin KENDİ `s[1]`i OLAN `'y'` YERİNE). Beklenen çıktı `"by"` —
// `"b"` (1. yineleme, `s="abcdef"`) + `"y"` (2. yineleme, `s="xyz"`e
// atandıktan SONRA). Kasıtlı olarak `try/except`/sınır-dışı erişim
// İÇERMEZ — bunlar `s` yeniden atamasıyla BİRLİKTE kullanıldığında
// GG.5'TEN BAĞIMSIZ, ÖNCEDEN VAR OLAN bir sızıntıyı (`git stash` İLE
// pre-GG.5 codegen'DE DE aynı şekilde yeniden üretildi, bkz. GG.5'in
// spec notu) TETİKLEDİĞİ keşfedildi — o AYRI hata KENDİ takip görevine
// (bkz. spawn edilen görev) bırakıldı, BU test YALNIZCA GG.5'in KENDİ
// güvenlik özelliğini (yeniden atanan isimlerin ÖNBELLEKLENMEMESİ) izole
// doğrular.


// Faz GG.5 — YUKARIDAKİ testin KAÇIRDIĞI durumu (BAYAT bir UZUNLUĞUN, DOĞRU
// bir erişimi YANLIŞLIKLA `IndexError` OLARAK reddetmesi) KAPATIR: `s`
// KISA (`"ab"`, uzunluk 2) BAŞLAR, döngünün 2. yinelemesinde DAHA UZUN
// (`"abcdef"`, uzunluk 6) bir dizeye atanır. `collectReassignedNames`
// (DOĞRU çalışıyorsa) `s`yi önbelek ADAYLARINDAN ÇIKARIR — `s[3]` HER
// yinelemede GERÇEK/TAZE `strlen`e göre kontrol edilir: 1. yinelemede
// (`"ab"`, uzunluk 2) 3 SINIR-DIŞI → `IndexError` YAKALANIR (ok+=100);
// 2. yinelemede (`"abcdef"`e atandıktan SONRA, uzunluk 6) 3 GEÇERLİDİR
// (ok+=1). Beklenen TOPLAM: 101. **`s` YANLIŞLIKLA önbelleklenseydi**
// (döngüye girmeden ÖNCEKİ, `"ab"`nin BAYAT uzunluğu — 2 — SONSUZA DEK
// kullanılsaydı), 2. yineleme de (bayat uzunluk 2 İLE 3 HÂLÂ sınır-dışı
// GÖRÜNDÜĞÜNDEN) YANLIŞLIKLA `IndexError` fırlatırdı: TOPLAM 200 olurdu
// (`if (true or !reassigned.contains(...))` İLE elle DOĞRULANDI —
// break→red→fix ritüeli, bkz. bu dosyanın en altındaki spec notu).
//
// `expectGolden` KULLANILMAZ: bu fixture (`str` yeniden atanan bir
// isimken AYNI döngüde `try/except` İLE indekslenmesi — YUKARIDAKİ
// testin AKSİNE, TEK önbellekleme senaryosunun `try/except`SİZ
// izole EDİLEMEDİĞİ bu durumda) GG.5'TEN BAĞIMSIZ, ÖNCEDEN VAR OLAN
// AYRI bir sızıntıyı (bkz. spawn edilen takip görevi) TETİKLER — bu
// testin AMACI o sızıntıyı DOĞRULAMAK DEĞİL, yalnızca bayat-uzunluk
// güvenliğini (çıkış KODU + stdout üzerinden) doğrulamaktır.
test "codegen(çalıştır): Faz GG.5 — bayat önbelleklenmiş uzunluk YANLIŞ IndexError fırlatmaz" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), @embedFile("codegen_cases/str_index_loop_reassign_stale_len.nox"));
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    try std.testing.expectEqualStrings("101\n", run_result.stdout);
}

// Faz GG.9 (kanıtlanabilir sınır-içi erişimlerde bounds-check elemesi):
// `for i in range(len(xs)): ... xs[i] ...` deseninde `i`nin `[0, len(xs))`
// ARALIĞINDA olduğu döngünün KENDİ sınırından ZATEN KANITLANMIŞTIR —
// `sum_list` (`list[int]`) VE `count_char` (`str`) İKİSİ de bu deseni
// kullanır, davranış (doğru toplam/sayım) DEĞİŞMEDEN çalışır.


test "codegen: Faz GG.9 — kanıtlanabilir sınır-içi erişimde IndexError dalı GERÇEKTEN ÜRETİLMEZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/bounds_check_elision_positive.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    // `IndexError`ın (bir `nox.core` yerleşiği) çözümlenmesi İçin — bkz.
    // GG.5'in AYNI IR-metni testindeki `resolveImports` notu.
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    // `sum_list`in `xs[i]`si VE `count_char`in `s[i]`si İKİSİ de TAM OLARAK
    // GG.9'un hedeflediği desendedir — bu programın ÜRETTİĞİ IR'da NE
    // `list_idx_err` NE DE `str_idx_err` (sınır-DIŞI dalının etiket
    // ÖNEKLERİ) TEK bir kez bile GÖRÜNMEMELİDİR (elenmenin GERÇEKTEN
    // gerçekleştiğinin doğrudan kanıtı).
    try std.testing.expect(std.mem.indexOf(u8, ir, "list_idx_err") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "str_idx_err") == null);
}

// Faz GG.9 — KRİTİK güvenlik testi: `xs` döngü GÖVDESİ İÇİNDE (bir `if`
// dalında) yeniden atanıyor — `collectReassignedNames` bunu YAKALAYIP
// `bounds_elide_ctx`i BU döngü İçin HİÇ KURMAMALIDIR (aksi halde `xs[i]`
// YENİ listenin GERÇEK sınırları İçin KONTROL EDİLMEDEN sınır-DIŞI
// okurdu). **Bu fixture BİLİNÇLİ olarak ÇALIŞTIRILMAZ** (yalnızca IR-metni
// DÜZEYİNDE doğrulanır) — `xs`nin yeniden atanmasıyla BİRLEŞTİĞİNDE
// GG.9'DAN TAMAMEN BAĞIMSIZ, ÖNCEDEN VAR OLAN bir bellek sızıntısı
// (GG.5'in `str` İçin bulduğu AYNI hatanın `list` KARŞILIĞI — `git stash`
// İLE pre-GG.9 codegen'de de AYNEN yeniden üretildi) KEŞFEDİLDİ; bu
// programı GERÇEKTEN çalıştırmak o AYRI hatayı tetiklerdi. Statik kontrol
// GG.9'un GÜVENLİK özelliğini (yeniden atanan bir listenin ASLA
// elenmemesi) TAM olarak izole doğrular, İLGİSİZ hatadan ETKİLENMEZ.
test "codegen: Faz GG.9 — döngü içinde yeniden atanan liste İçin IndexError dalı KORUNUR (elenmez)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/bounds_check_elision_reassign_safety.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    // `xs` döngü İÇİNDE yeniden atandığından `bounds_elide_ctx` BU döngü
    // İçin HİÇ KURULMAMALIDIR — `list_idx_err` dalı NORMAL şekilde
    // ÜRETİLMELİDİR (elenmenin GERÇEKLEŞMEDİĞİNİN doğrudan kanıtı).
    try std.testing.expect(std.mem.indexOf(u8, ir, "list_idx_err") != null);
}

// Darboğaz analizi (bkz. benchmarks/RESULTS.md, 2026-07-22) — GG.9'un
// bounds-check elemesi ÖNCEDEN yalnızca `for i in range(len(xs)): xs[i]`
// idiomunu tanıyordu; elle yazılmış eşdeğer bir `while j < ...: xs[j]`
// deseni (`benchmarks/compare/lowlevel_arena.nox`nin GERÇEK kalıbı)
// HİÇ faydalanamıyordu. `detectWhileBoundsElideCtx` bu iki alt-deseni
// (üst sınır `len(xs)` bir ÇAĞRI, YA DA `xs`nin KENDİ bilinen literal
// uzunluğuna eşit bir `int_lit`) GENELLEŞTİRİR.


// Bulundu (bkz. proje belleği "f-string + augmented atama" görevi): TÜM 7
// augmented-atama operatörü, düz f-string, interpolasyonlu f-string, `{{`/
// `}}` kaçışı, Python klasik iç-içe-tırnak kuralı (`f"{d['key']}"`), VE
// genişletilmiş `str()`nin (str/bool kabulü) uçtan uca doğru çalıştığını
// TEK bir fixture'da doğrular.


// Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
// incelemesi", C5): `\r` İKİ AYRI yerde eksikti — `parser.zig`nin
// `decodeEscapes`i (düz VE f-string literalleri) VE `codegen_qbe/abi.zig`nin
// `escapeForQbeString`i (parser DOĞRU çözse BİLE, ham CR baytı `.ssa`
// METİN dosyasına gömülünce QBE/`as` tarafından BOZULUYORDU — GERÇEK bir
// tekrar-üretimle DOĞRULANDI). Bu test HEM düz string HEM f-string
// içindeki `\r`nin UÇTAN UCA (derle+çalıştır) doğru bayt (13) ürettiğini
// kanıtlar.


// Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
// incelemesi", C1): `list[dict[K,V]]` (bir dict listesi) ÖNCEDEN
// codegen'de "desteklenmeyen bir yapı" hatasıyla ÇÖKÜYORDU — checker
// ZATEN kabul ediyordu (`Type`, `list`nin eleman tipini KISITLAMAZ),
// yalnızca `ElemHeapInfo`nun (codegen'in KENDİ, checker'dan AYRI, daha
// küçük "elemanın şekli" betimleyicisi) `.dict` durumunu HİÇ TAŞIMAMASI
// (dict'in KENDİ `key_is_str`/`value_is_str` "şeklini" saklayacak bir
// alanı YOKTU) EKSİKTİ. Bu test boş listeden inşa+append, listeler ARASI
// eleman OKUMA (`rows[i]["ad"]` — İKİ KAT indeksleme, dict eleman `Value`
// sinin `dict_info`sinin `list` okumasından SONRA da AKMASI GEREKTİĞİNİ
// kanıtlar), İNDEKSLE ATAMA (`xs[0] = {...}`, eski dict elemanının DOĞRU
// serbest bırakılması) VE kapsam-sonu temizliğinin (fonksiyon dönüşü +
// döngü içi taze listeler) hiçbirinin ÇÖKMEDİĞİNİ/SIZDIRMADIĞINI
// (`--summary all`ın ReleaseFast koşusunda leak-detector'lı derleyici
// binary'si ÜZERİNDEN) kanıtlar.


// Bulundu (nyx framework — bkz. proje belleği "NOX_LIMITATIONS.md
// incelemesi", P5): ÇIPLAK `except:` (tipsiz, HERHANGİ bir istisnayla
// eşleşen bir yakalama) ARTIK destekleniyor — `finally` ZATEN
// çalışıyordu (bu test AYRICA `finally`nin yakalanmamış BİR istisnadan
// SONRA da çalıştığını yeniden doğrular). Bu test AYRICA `as e:`
// bağlaması OLMAYAN (tipli VEYA ÇIPLAK) bir `except`in yakaladığı
// istisna nesnesini GERÇEKTEN serbest bıraktığını (`nox_class_release_
// dispatch` — bkz. `layout.zig`nin belge notu) kanıtlar: `expectGolden`
// stderr'in BOŞ olmasını zorunlu kıldığından (bkz. onun belge notu),
// bu test aynı zamanda GERÇEK bir bellek-sızıntısı regresyon testidir.


// Bulundu (bkz. proje belleği "modül-seviyesi global durum" planı):
// üst-düzey bir `int` global'in İKİ AYRI fonksiyondan (biri yazar,
// biri okur) doğru çalıştığını kanıtlar.


// Heap-yönetimli bir global (`list[str]`) birden fazla çağrı boyunca
// doğru büyüdüğünü VE sızıntısız olduğunu (`expectGolden`nin BOŞ-stderr
// kontrolü — `$nox_deinit_globals`in `releaseValueIfSet` çağrısını
// doğrular) kanıtlar.


// Bir fonksiyonun KENDİ yerelinin AYNI isimde bir global'i gölgelediğini
// (`shadowed()`), KARDEŞ bir fonksiyonun İSE (`unshadowed()`, hiç yerel
// bildirmez) AYNI global'i GERÇEKTEN okuyup/yazdığını kanıtlar.


// P1c (bkz. kullanıcı repro'su, "P1c — package-module globals + nested
// closure" olarak bildirildi) — `genNoxInitGlobals`, `module.body`deki HER
// `var_decl`nin `module_globals`e TERFİ ETTİĞİNİ (`collectModuleGlobals`nin
// yalnızca bir fonksiyondan REFERANS ALINAN isimleri terfi ETTİĞİNİ görmeyip)
// VARSAYIYORDU — `y` gibi SAF bir üst-düzey betik değişkeni (hiçbir
// fonksiyondan erişilmeyen) `_x` GİBİ GERÇEK terfi eden bir global İLE AYNI
// PROGRAMDA olduğunda `.get(v.name).?` panige/segfault'a yol açıyordu.


// C2 (bkz. kullanıcı repro'su, "C2 — package function-type param → import
// SIGSEGV" olarak bildirildi) — `genIndirectCallThroughClosurePtr` (bir
// `(T) -> dict[K,V]` FONKSİYON-TİPLİ parametre/değişken ÜZERİNDEN dolaylı
// çağrı) döndürdüğü `Value`de `dict_info`yi KOPYALAMAYI unutuyordu — dönüş
// değeri BAŞKA bir çağrıya İNLINE argüman olarak geçirildiğinde (ör.
// `use_ctx(to_context_fn(rows[i]))`), `releaseTemporaryArgs` bu TAZE
// `dict` değerini serbest bırakmaya çalışırken `dict_info.?`nin null
// olması yüzünden çöküyordu (derleme-zamanı panik/ReleaseFast'te SIGSEGV).


// Bulundu (bkz. proje belleği "4 yeni stdlib modülü" planı): YENİ `list[T].
// pop()` ilkeli — `.append`in AKSİNE HİÇBİR ZAMAN yeniden ayırmadığından
// alıcı keyfi bir ifade olabilir (`self.items.pop()` doğrudan, "yerele
// kopyala-mutasyona uğrat-geri yaz" dansı GEREKMEZ). Boş listede `IndexError`
// fırlattığını da kanıtlar.


// nox.collections — Stack[T]/Queue[T]/Deque[T]: LIFO/FIFO/çift-uçlu sıra
// semantiğinin (iki-yığın hilesi DAHİL) doğru çalıştığını kanıtlar. Bu,
// çok-parametreli (`Pair[K,V]` benzeri) generic sınıfların `from X import Y`
// İLE getirilip bir TİP ANNOTASYONUNDA kullanılmasının İLK gerçek testidir
// — bu SIRADA `checker.zig`nin `typeExprToType`indeki VE `codegen_qbe/
// registration.zig`nin `resolveType`indeki `.generic` dalının `from_imports`
// geri düşüşü EKSİK olduğu bulunup İKİSİ de düzeltildi (`from nox.collections
// import Stack` + `s: Stack[int] = ...` ÖNCEDEN "bilinmeyen generic tip"/
// "desteklenmeyen bir yapı" hatalarıyla ÇÖKERDİ).


// nox.collections — Set[T]/Counter[T]/OrderedDict[K,V]: hepsi `list[T]`
// üzerinde DOĞRUSAL TARAMA (`==` İLE) kullanır (Nox'ta kullanıcı sınıfları
// İçin `__hash__` YOK) — bu test tekrarlı `add`ın idempotent kaldığını,
// `remove`nin çalıştığını VE `OrderedDict`in ekleme SIRASINI koruduğunu
// kanıtlar.


// nox.collections — LRUCache[K,V]/Heap[T]/PriorityQueue[T]: LRU'nun
// kapasite-aşımında en-eski-kullanılanı tahliye ettiğini, `Heap`in artan
// sırayla `pop_min` verdiğini (ikili min-heap sift-up/sift-down) VE
// `PriorityQueue`nun `T`ye HİÇ dokunmadan yalnızca `priority: int` alanına
// göre sıraladığını kanıtlar. **GERÇEK bir hata bulunup düzeltildi**
// (bu fixture'ın geliştirilmesi sırasında): Nox'ta `and`/`or` kısa devre
// YAPMAZ (bkz. nox-teknik-spesifikasyon.md, bilinçli v0.1 kararı) — ilk
// `_sift_down` uygulaması `left < n and self._items[left] < ...` yazıyordu,
// bu da `left >= n` OLSA BİLE `self._items[left]`i (sınır dışı) okuyup
// GERÇEK bir `IndexError`a yol açıyordu; düzeltme İÇ İÇE `if`lere geçti.


// nox.url — `URL.parse` (şema/userinfo/host/port/yol/sorgu/fragment),
// `percent_encode`/`percent_decode` (çok-baytlı UTF-8 DAHİL round-trip),
// `query_encode`/`query_decode`, VE basit `join` göreli-yol çözümlemesi.
// Bozuk bir URL'de (`://` yok) `UrlError` fırlattığını da kanıtlar.


// nox.process — `Command.run()`: stdout yakalama, sıfır-olmayan çıkış
// koduyla stderr yakalama, `set_cwd`, VE bulunamayan bir programda
// `ProcessError`. **GERÇEK bir bellek sızıntısı bulunup düzeltildi**
// (bu fixture'ın geliştirilmesi sırasında, `Command("yok").run()` GİBİ
// GEÇİCİ bir alıcı üzerinde ÇAĞRILAN VE istisna FIRLATAN bir metodun
// alıcısının/argümanlarının HİÇ serbest bırakılmadığı — `emitExceptionCheck`
// KAÇIŞ dalının serbest-bırakma kodunu HER ZAMAN atladığı — GENEL bir
// derleyici hatası, bkz. `calls.zig`nin `genMethodCall`/`genListPop`
// belge notları): düzeltme serbest-bırakmayı istisna KONTROLÜNDEN ÖNCEYE
// taşıdı (`genMethodCall`) / hata dalına DA ekledi (`genListPop`).
// NOT (pre-existing, Linux CI'de bulundu, bu oturumda düzeltildi):
// `Command("pwd").set_cwd("/tmp").run()`nin çıktısı PLATFORM'a göre
// DEĞİŞİR — macOS'ta `/tmp` bir SEMBOLİK BAĞDIR (`/private/tmp`e); `pwd`
// (bir alt süreç olarak, `getcwd()` ÜZERİNDEN) HER ZAMAN FİZİKSEL
// (sembolik bağı ÇÖZÜLMÜŞ) yolu DÖNDÜRÜR, bu YÜZDEN macOS'ta
// "/private/tmp" yazdırır. Linux'ta `/tmp` GENELDE bir sembolik bağ
// DEĞİLDİR, bu YÜZDEN DÜZ "/tmp" yazdırır. ÖNCEDEN `expectGolden`nin
// SABİT `.expected` metin dosyası "/private/tmp"i SABİTLİYORDU — bu, bu
// TEK satır DIŞINDA platform-bağımsız olan bir testi Linux'ta HER ZAMAN
// BAŞARISIZ kılıyordu. Düzeltme: bu satırı AYRI doğrula (iki bilinen
// GERÇEK çözünürlükten biriyle eşleşmeli), geri kalanı TAM eşleştir.
test "codegen(çalıştır): nox.process Command.run() — stdout/stderr/cwd/ProcessError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/process_command_run.nox");

    const run_result = try compileAndRun(allocator, source);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    if (run_result.stderr.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{run_result.stderr});
        return error.UnexpectedStderrOutput;
    }

    const expected_prefix = "merhaba dunya\n\n0\nTrue\n7\nhata-mesaji\n\nFalse\n";
    const expected_suffix = "\n\nProcessError yakalandi\n";
    if (!std.mem.startsWith(u8, run_result.stdout, expected_prefix)) {
        std.debug.print("beklenmeyen on-ek:\n{s}\n", .{run_result.stdout});
        return error.UnexpectedOutput;
    }
    const after_prefix = run_result.stdout[expected_prefix.len..];
    if (!std.mem.endsWith(u8, after_prefix, expected_suffix)) {
        std.debug.print("beklenmeyen son-ek:\n{s}\n", .{after_prefix});
        return error.UnexpectedOutput;
    }
    const cwd_line = after_prefix[0 .. after_prefix.len - expected_suffix.len];
    if (!std.mem.eql(u8, cwd_line, "/tmp") and !std.mem.eql(u8, cwd_line, "/private/tmp")) {
        std.debug.print("beklenmeyen cwd satiri: '{s}'\n", .{cwd_line});
        return error.UnexpectedCwdLine;
    }
}

// `genMethodCall`/`genListPop` (önceki oturum) VE `genIndirectCallThroughClosurePtr`/
// `genCall`nin serbest-fonksiyon dalı/`genConstruct` (bir önceki oturum)
// VE `genIndex`/`genStrIndex`/`genListAssign`/`genDictGet`nin sınır-kontrolü/
// eksik-anahtar hata dalları + `genIndex`nin `dict` dispatch'inin KENDİSİ
// (Faz NN, bu oturum — bkz. proje belleği "ARC sızıntı düzeltmeleri
// follow-up") düzeltmelerinin KENDİSİ İçin AYRI bir regresyon testi —
// `expectGolden`nin BOŞ-stderr kontrolü (DebugAllocator sızıntı uyarılarını
// YAKALAR) bu YÜZDEN bu test AYNI ZAMANDA bir bellek-sızıntısı regresyon
// testidir: geçici bir sınıf ÖRNEĞİ/liste/str/sözlük/argüman üzerinde
// ÇAĞRILAN VE istisna FIRLATAN bir metod/serbest fonksiyon/dolaylı-closure-
// çağrısı/kurucu/indeksleme/sözlük-erişimi (__init__ — HEM argümanı HEM
// alan-atamasından SONRA raise eden `self`in KENDİSİ DAHİL), hiçbir şeyi
// SIZDIRMAMALIDIR. `genIndex`/`genStrIndex`/`genListAssign`/`genDictGet`nin
// hata dallarındaki düzeltmeler ÖNCE (Faz JJ benzeri bir çift-serbest-
// bırakma çökmesi yüzünden) GERİ ALINMIŞTI — kök neden (`ownership.zig`nin
// `releaseNamedLocalsExcept`i, bkz. `inline_loop_list_return_identifier`
// testi) BULUNUP DÜZELTİLDİKTEN SONRA GÜVENLE yeniden eklendi, HER BİRİ
// 50 iterasyonluk döngü testiyle AYRICA doğrulandı. Ayrıca `genIndex`nin
// `dict` dispatch'inde (`d[key]`) taban sözlüğün TEMPORARY İSE HİÇ serbest
// bırakılmadığı — tamamen AYRI ve önceden BİLİNMEYEN bir sızıntı — bu
// oturumda bulunup düzeltildi (retain-önce-serbest-bırak koruması DAHİL,
// `str`-değerli sözlükler İçin kullanım-sonrası-serbest-bırakmayı önler).


// nox.postgres/nox.mysql — ULAŞILAMAYAN bir adrese karşı `open`/`open_url`nin
// HER ZAMAN temiz bir PostgresError/MysqlError fırlattığını (çökme YOK)
// doğrular — CI'da libpq/libmysqlclient KURULU OLMASA (ensureLoaded
// başarısız) YA DA kurulu olup bağlantı başarısız olsa (her iki durumda
// da AYNI temiz hata yolu) BİLE ÇALIŞIR, GERÇEK bir sunucu GEREKTİRMEZ.
// TAM CRUD doğrulaması (Docker'daki gerçek postgres:16/mysql:8'e karşı)
// ELLE yapıldı — bkz. proje belleği "4 yeni stdlib modülü" planı
// (postgres: INSERT/SELECT/tip-NULL/hatalı-sorgu/hatalı-baglanti hepsi
// doğru; mysql: AYNI senaryolar + `MYSQL_FIELD.name`in ham-ofset
// okumasının GERÇEKTEN doğru sütun adlarını döndürdüğü doğrulandı).


// Faz NN.5 (bkz. proje belleği "nyx v2 limitasyon listesi doğrulaması"):
// `nox.tls`/`nox.websocket`nin ULAŞILAMAYAN bir adrese karşı HER ZAMAN
// temiz bir TlsError/WebSocketError fırlattığını (çökme/sızıntı YOK)
// doğrular — `postgres_mysql_connect_error`in AYNI deseni. GERÇEK bir uzak
// sunucuya karşı (`example.com` — ham TLS+HTTP/1.1, VE `wss://ws.postman-
// echo.com/raw` — TAM WebSocket el sıkışması+metin frame round-trip) TAM
// doğrulama ELLE yapıldı (bu oturumda): TLS handshake/sertifika doğrulaması,
// `Sec-WebSocket-Accept` SHA1/base64 hesaplaması, frame maskeleme/çözme
// hepsi GERÇEK bir sunucuya karşı ÇALIŞTI.


// Bulundu (bkz. proje belleği "UTF-8 farkındalığı" görevi): `len(s)`/`s[i]`
// ÖNCEDEN bayt-tabanlıydı (çok baytlı UTF-8 karakterleri — "café"nin
// "é"si, "日本語"nin her karakteri — ORTADAN kesiyordu). ARTIK codepoint-
// tabanlı; bu fixture HEM düz erişimi HEM `for i in range(len(s))` (GG.9
// bounds-elision) HEM `while j < len(s)` (GG.5/GG.9 while-genellemesi)
// desenlerini TEK bir fixture'da doğrular — üçünün de YENİ (codepoint)
// `len()` semantiğiyle TUTARLI kaldığının kanıtı.


test "codegen: Faz GG.9 (while genellemesi) — while j < len(xs): xs[j] IR'ında IndexError dalı GERÇEKTEN ÜRETİLMEZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/bounds_check_elision_while_len.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "list_idx_err") == null);
}

// `nums`in kendi `var_decl`i İLE `while`in ARASINA (AYNI gövdede) BAŞKA
// bir yerel bildirimi (`inner: int = 0`) GİREN — `benchmarks/compare/
// lowlevel_arena.nox`nin TAM OLARAK ürettiği GERÇEK kalıp (idx_var'ın
// var_decl'i "HEMEN ÖNCEKİ deyim" OLMAYABİLİR — bkz. `detectWhileBounds
// ElideCtx`nin belge notu).


test "codegen: Faz GG.9 (while genellemesi) — while j < SABİT: xs[j] IR'ında IndexError dalı GERÇEKTEN ÜRETİLMEZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/bounds_check_elision_while_literal.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "list_idx_err") == null);
}

// KRİTİK güvenlik testi — `xs` döngü GÖVDESİ İÇİNDE (bir `if` dalında)
// yeniden atanıyor: `collectReassignedNames` bunu YAKALAYIP `bounds_
// elide_ctx`i BU döngü İçin HİÇ KURMAMALIDIR. Fixture BİLİNÇLİ olarak
// ÇALIŞTIRILMAZ (`bounds_check_elision_reassign_safety.nox`nin AYNI
// gerekçesi) — yalnızca IR-metni düzeyinde doğrulanır.
test "codegen: Faz GG.9 (while genellemesi) — döngü içinde yeniden atanan liste İçin IndexError dalı KORUNUR (elenmez)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/bounds_check_elision_while_reassign_safety.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "list_idx_err") != null);
}

// Darboğaz analizi bulgu #3 (bkz. benchmarks/RESULTS.md, 2026-07-22) —
// dominance-farkında CSE: `classify`'nin `i % 3`si (İKİ üst-düzey `if`
// koşulunda tekrar eden) hem KENDİ gövdesi İÇİNDE hem de `tally`nin
// `classify(i)`yi SATIR-İÇİ (inline) çağırdıktan SONRAKİ KENDİ `if i % 3
// == 0` kontrolünde YENİDEN KULLANILIR — TOPLAM 3 sözdizimsel oluşumun
// TEK bir hesaplamaya İNDİRGENDİĞİNİN kanıtı (bkz. AŞAĞIDAKİ IR-metni
// testi).


test "codegen: darboğaz #3 — `tally` IR'ında `i % 3` TEK bir `rem` talimatına İNDİRGENİR (3 DEĞİL)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/mod_cse_positive.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    // `$classify` (bağımsız/standalone sürüm, HER ZAMAN üretilir) KENDİ
    // TEK `rem`ini tutar — bu YÜZDEN modül GENELİNDE tam olarak 2 `rem`
    // BEKLENİR (1 standalone `$classify` + 1 `$tally`nin İÇİNDE, ÜÇ
    // sözdizimsel oluşumun TAMAMI İçin) — 3 DEĞİL (CSE OLMASAYDI `$tally`
    // İçinde 3 AYRI `rem` olurdu).
    const rem_count = std.mem.count(u8, ir, "=l rem ");
    try std.testing.expectEqual(@as(usize, 2), rem_count);
}

// KRİTİK güvenlik testi (bkz. `Codegen.mod_cache`nin belge notu, madde 3
// — GERÇEK bir hatayla YAKALANDI, bkz. break→red→fix ritüeli): `if`in
// KENDİ gövdesi `i`yi yeniden atıyorsa, if SONRASI `i % 3`ün ÖNCEKİ
// (if'ten ÖNCEKİ) önbellek girdisini YANLIŞLIKLA yeniden KULLANMAMASI
// gerekir — HANGİ dalın alındığı ÇALIŞMA ZAMANINDA belirlenir
// (`flag` parametresine bağlı), bu YÜZDEN doğru davranış YALNIZCA
// GERÇEKTEN ÇALIŞTIRILARAK doğrulanabilir.


// AYNI güvenlik sınıfı — `while` gövdesi İÇİNDE `i` yeniden atanıyor;
// gövdenin KENDİ İÇİNDEKİ (yeniden atamadan ÖNCEKİ/SONRAKİ) İKİ ayrı
// kullanım DOĞRU (taze) değerleri almalı, VE bu bayat bir ÖN-döngü
// değerine ASLA geri DÖNMEMELİDİR.


// AYNI güvenlik sınıfı — `for x in xs` döngü değişkeninin HER yinelemede
// (bir `.assign` AST düğümünü BAYPAS EDEN DOĞRUDAN QBE yayınıyla) aldığı
// YENİ değer, bir ÖNCEKİ yinelemenin (ya da döngüden ÖNCEKİ, varsa AYNI
// isimli bir değişkenin) önbelleklenmiş `x % 3`ünü ASLA yeniden KULLANMAZ.


// AYNI güvenlik sınıfı — bir `if`/`elif`/`else` zincirinin HER dalı `i`yi
// FARKLI bir biçimde yeniden atıyor; if SONRASI TEK `return i % 3`ün,
// dalların HERHANGİ BİRİNİN kendi İÇİNDE (branch-yerel olarak) hesapladığı
// bir değeri YANLIŞLIKLA yeniden KULLANMAMASI gerekir (hiçbiri if'TEN
// ÖNCE kurulmadığından, if SONRASI HİÇBİR önbellek girdisi OLMAMALIDIR).




test "codegen: lowlevel arenasından bir değeri bloktan return etmek reddedilir (Unsupported)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/rejected_lowlevel_escape.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    try std.testing.expectError(error.Unsupported, nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null));
}





// Bulundu (nyx framework — bkz. proje belleği "nyx'te farkedilen Nox
// eksiklikleri" görevi): `closures.zig`nin `buildClosureValue`ı, bir
// yakalanan (capture) DEĞERİN `func_sig`ini (`heap == .closure` OLAN
// yakalamalar İçİn ÇAĞRI imzası) KOPYALAMIYORDU — bu YÜZDEN bir iç içe
// `def`, ÇEVRELEYEN fonksiyonun FONKSIYON-TİPLİ (ör. `(int) -> int`) bir
// parametresini/yerel değişkenini YAKALAYIP ÇAĞIRMAYA çalıştığında
// (`handler(x)`) codegen "desteklenmeyen bir yapı" hatasıyla BAŞARISIZ
// oluyordu (list/dict/str/sınıf GİBİ VERİ tipi yakalamalar ETKİLENMİYORDU
// — yalnızca FONKSİYON tipi). Tek satırlık eksik alan ATAMASI (`.func_sig
// = src.func_sig`) İLE düzeltildi; iç içe SARMALAMA (bir closure'ın BAŞKA
// bir closure'ı yakalayıp SARMASI) DAHİL 500 yinelemede sızıntısız.
















test "codegen: Faz T.3 — debug_source_path VERİLMEDEN dbgfile/dbgloc HİÇ üretilmez (opt-in, sıfır davranış değişikliği)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/fibonacci.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dbgfile") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dbgloc") == null);
}

test "codegen: Faz T.3 — debug_source_path VERİLİRSE dbgfile + doğru satır numaralı dbgloc üretilir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/fibonacci.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, "fibonacci.nox", .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dbgfile \"fibonacci.nox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dbgloc") != null);
}











// GG.13 (bkz. nox-teknik-spesifikasyon.md §3.66): `Point == Point` (küçük,
// ≤8 alanlı, döngüsüz bir sınıf) ARTIK paylaşılan `$Point_eq`e bir
// `call`/dönüş YERİNE, karşılaştırıcı DOĞRUDAN kullanım sitesine SPLICE
// EDİLİR. Davranış (yukarıdaki AYNI fixture'da, milyonlarca yinelemede
// yığın taşması OLMADAN) ZATEN doğrulandı — burada YALNIZCA `call
// $Point_eq`in ÜRETİLEN IR'da GERÇEKTEN artık HİÇ görünmediği (yalnızca
// davranışın değişmediğinin DEĞİL) doğrudan kanıtlanır. `la == lb`
// (list[int], HER ZAMAN bir döngü gerektirir) BU optimizasyonun kapsamı
// DIŞINDA kalır — `call $List_priml_eq` HÂLÂ ÜRETİLMELİDİR.
test "codegen: GG.13 — küçük sınıf '=='inin ÜRETTİĞİ IR'da call \\$Point_eq GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/deep_equality_in_loop_no_stack_growth.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    try std.testing.expect(std.mem.indexOf(u8, ir, "call $Point_eq") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call $List_priml_eq") != null);
}

// GG.14 (bkz. nox-teknik-spesifikasyon.md §3.66): `forward(literal_str(i))`
// (`literal_str`in TÜM dalları DOĞRUDAN string literali döndürüyor) —
// `forward`in inline-splice edilmiş `s`si ARTIK retain/release
// GEREKTİRMEMELİDİR (`s` her zaman `PINNED_REFCOUNT`lı bir literal).
// AYNI fixture, POZİTİF durumun YANINDA bir NEGATİF durumu da (`forward
// (make_dynamic(i))` — `make_dynamic` bir string BİRLEŞTİRMESİ döndürür,
// ASLA pinned DEĞİL) KASITLI olarak İÇERİR: `exprAlwaysProducesPinnedString`
// bunu TANIMAMALI (aksi halde GERÇEK bir bellek sızıntısı/çift-serbest-
// bırakma olurdu). 2.000.000 yinelemelik `expectGolden` çalışması (ARC
// güvenlik ağının GERÇEKTEN çalıştığı Debug modu DAHİL, `zig build test`
// İLE) hem doğru sayıyı HEM DE sınırlı bellek kullanımını (dolaylı olarak,
// çökme/OOM OLMADAN tamamlanarak) doğrular.


// GG.14: `forward(literal_str(i))`in inline-splice edilmiş gövdesindeki
// `return s`in ÜRETTİĞİ IR'da retain'in GERÇEKTEN elendiğini DOĞRUDAN
// kanıtlar (yalnızca davranışın DEĞİŞMEDİĞİNİN değil) — `compute()`nin
// TAM gövdesi izole edilip İÇİNDEKİ `@retain`/`@predecrement` etiketli
// blok SAYISI TAM OLARAK BİR olmalıdır: `dynamic`in (`make_dynamic`
// literal DÖNDÜRMEDİĞİNDEN pinned OLARAK tanınmayan) `return s`si HÂLÂ
// GERÇEK bir retain YAPMALIDIR — `pinned`in retain'i ELENDİĞİ İçin
// TOPLAM SAYI iki DEĞİL, bir olmalıdır.
test "codegen: GG.14 — pinned passthrough'un ÜRETTİĞİ IR'da SADECE dinamik yol İçin BİR retain VAR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/pinned_string_passthrough.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const start_marker = "function l $compute(l %rt, l %p_n) {\n";
    const start = std.mem.indexOf(u8, ir, start_marker) orelse return error.MarkerNotFound;
    const body_start = start + start_marker.len;
    const end_rel = std.mem.indexOf(u8, ir[body_start..], "\nexport function") orelse return error.MarkerNotFound;
    const compute_ir = ir[body_start .. body_start + end_rel];

    // `emitInlineRetain` HER çağrıda `retain_skip` alt-dizesini TAM OLARAK
    // İKİ KEZ üretir (bir `jnz` HEDEFİ + KENDİ etiket TANIMI) — bu alt-dize
    // BAŞKA HİÇBİR YERDE geçmeyecek KADAR özgün, bu YÜZDEN toplam
    // geçiş SAYISI/2, GERÇEK `emitInlineRetain` ÇAĞRI SAYISINI verir.
    var occurrences: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOf(u8, compute_ir[pos..], "retain_skip")) |idx| {
        occurrences += 1;
        pos += idx + "retain_skip".len;
    }
    try std.testing.expectEqual(@as(usize, 2), occurrences); // TEK retain çağrısı (dinamik yol İçin) = 2 geçiş
}

// GG.15 (bkz. nox-teknik-spesifikasyon.md §3.66): `lowlevel:` bloğu
// İÇİNDEKİ sabit-boyutlu inşalar (bir sınıf kurucusu + basit-literal
// `list_lit`) ARTIK `nox_arena_alloc` YERİNE fonksiyon-girişinde ÖNCEDEN
// ayrılmış yığın slotlarını KULLANIR — `nox_arena_create`/`destroy` çifti
// (BU örnek İçin TÜM inşalar dönüştürülebildiğinden) TAMAMEN ELENİR.
// `expectGolden` (Debug ARC güvenlik ağı DAHİL) davranışın DEĞİŞMEDİĞİNİ
// doğrular; aşağıdaki AYRI IR-metni testi elenmenin GERÇEKTEN gerçekleştiğini
// kanıtlar.


test "codegen: GG.15 — lowlevel bloğunun ÜRETTİĞİ IR'da nox_arena_create/alloc GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/lowlevel_stack_construct.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_arena_create") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_arena_alloc") == null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_arena_destroy") == null);
}

// GG.15 NEGATİF durum: `nums: list[int] = [a, b, c]` (identifier ELEMANLI,
// basit-literal DEĞİL) `scanStackConstructSites`in "uniform" kontrolünü
// GEÇEMEZ — TÜM `lowlevel:` örneği GÜVENLİ tarafta kalıp MEVCUT arena
// davranışına DEĞİŞMEDEN düşmelidir (`Point` İçin BİLE, "ya HEPSİ ya
// HİÇBİRİ" ilkesi GEREĞİ). `expectGolden` davranış/bellek güvenliğini,
// aşağıdaki IR-metni testi `nox_arena_create`in HÂLÂ ÜRETİLDİĞİNİ kanıtlar.


test "codegen: GG.15 — karışık lowlevel bloğunun ÜRETTİĞİ IR'da nox_arena_create HÂLÂ VAR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/lowlevel_mixed_no_stack_construct.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_arena_create") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_arena_destroy") != null);
}

// GG.16 (bkz. nox-teknik-spesifikasyon.md §3.66): `sum_list(make_data())`
// gibi bir ÇAĞRI SINIRI ÖTESİNDE — `make_data()`nin GG.2 İLE inline edilmiş
// sabit-boyutlu liste literali, `sum_list`in KENDİ `xs` parametresinin
// GÖVDESİ İÇİNDE HİÇ kaçmadığı (`paramNeverEscapes`) KANITLANDIĞINDA —
// `nox_rc_alloc` YERİNE `compute`nin GİRİŞ bloğunda ÖNCEDEN ayrılmış TEK bir
// yığın slotu KULLANILIR (HER yinelemede YENİDEN kullanılır). `expectGolden`
// davranışın DEĞİŞMEDİĞİNİ, aşağıdaki AYRI IR-metni testi elenmenin GERÇEKTEN
// gerçekleştiğini kanıtlar.


test "codegen: GG.16 — compute() ÜRETTİĞİ IR'da nox_rc_alloc/nox_arena_alloc GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/cross_call_stack_slot.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const compute_start = std.mem.indexOf(u8, ir, "$compute(") orelse return error.ComputeNotFound;
    const compute_end = std.mem.indexOfPos(u8, ir, compute_start, "\n}\n") orelse ir.len;
    const compute_ir = ir[compute_start..compute_end];

    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_rc_alloc") == null);
    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_arena_alloc") == null);
}

// GG.16 NEGATİF durum: `forward(xs): return xs` parametresini DOĞRUDAN
// döndürür — `paramNeverEscapes`in TANIDIĞI ÜÇ güvenli şekilden (for-iterable/
// index-tabanı/`len()`) HİÇBİRİ DEĞİL, bu YÜZDEN `false` dönmeli VE
// `make_pair()`nin listesi normal `nox_rc_alloc`a DÜŞMELİDİR — yanlış bir
// `true` burada GERÇEK bir kullanım-sonrası-serbest-bırakmaya yol açardı
// (`forward`nin döndürdüğü, `compute`nin YIĞIN ÇERÇEVESİ silindikten SONRA
// da kullanılan bir işaretçi).


test "codegen: GG.16 — kaçan parametrenin ÜRETTİĞİ IR'da nox_rc_alloc HÂLÂ VAR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/cross_call_param_escapes.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    // GG.5'in AYNI IR-metni testindeki `resolveImports` notu: `forward(...)
    // [0]`nin sınır-dışı dalı `IndexError`ı (bir `nox.core` yerleşiği) İNŞA
    // EDER — `compileAndRun`in AYNI `resolveImports` çağrısı GEREKİR, aksi
    // halde `genIndex` `self.classes.get("IndexError")`ı BULAMAYIP
    // `error.Unsupported` döner.
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_rc_alloc") != null);
}

// GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): interprocedural
// escape kanıtının İLK POZİTİF sonucu — `read_only(xs): return len(xs)`
// SADECE `len()`in ZATEN GÜVENLİ saydığı şekilde `xs`i kullanıyor, bu
// YÜZDEN `computeParamEscapes` onu `escaping_params`E EKLEMEZ — `compute()`nin
// KENDİ yereli `xs` (fixed_stack adayı) BUNA argüman olarak GEÇTİĞİNDE
// ARTIK stack'e DÖNÜŞÜR (ÖNCEDEN, Tur 1/2/3'te, HER argüman-geçişi
// KOŞULSUZ kaçış SAYILDIĞINDAN `nox_rc_alloc`TA KALIRDI).


test "codegen: GG.20 — salt-okunur yönlendirmenin ÜRETTİĞİ IR'da compute() İçİnde nox_rc_alloc GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/gg20_local_forwarded_to_read_only_helper.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const compute_start = std.mem.indexOf(u8, ir, "$compute(") orelse return error.ComputeNotFound;
    const compute_end = std.mem.indexOfPos(u8, ir, compute_start, "\n}\n") orelse ir.len;
    const compute_ir = ir[compute_start..compute_end];

    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_rc_alloc") == null);
}

// GG.20 NEGATİF: `store_it(box, xs): box.xs = xs` — `xs`, KENDİ parametresi
// OLMAYAN BAŞKA bir nesnenin (`box`) alanına YAZILDIĞINDAN (bir container'a
// "yazma" — `computeParamEscapes`in tanıdığı KAÇIŞ şekillerinden biri)
// `store_it`in KENDİ parametresi `escaping_params`E EKLENİR VE `compute()`nin
// `xs`i (`store_it(b, xs)` İLE forward edildiğinden) HÂLÂ `nox_rc_alloc`TA
// KALIR — BAŞKA bir container'a yazma HER ZAMAN kaçış sayılır İlkesi
// GG.20 SONRASI da KORUNUR.


test "codegen: GG.20 — mutasyona uğratan yönlendirmenin ÜRETTİĞİ IR'da compute() İçİnde nox_rc_alloc HÂLÂ VAR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/gg20_local_forwarded_to_mutating_helper_stays_arc.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const compute_start = std.mem.indexOf(u8, ir, "$compute(") orelse return error.ComputeNotFound;
    const compute_end = std.mem.indexOfPos(u8, ir, compute_start, "\n}\n") orelse ir.len;
    const compute_ir = ir[compute_start..compute_end];

    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_rc_alloc") != null);
}

// GG.20 — İKİ SEVİYELİ TRANSİTİF kanıt: `a_forward(xs): return b_read(xs)`,
// `b_read(xs): return len(xs)` — worklist'in `{b_read,0}`nin GÜVENLİ
// OLDUĞUNU `{a_forward,0}`YE de YAYDIĞINI (ARBİTRER derinlikte, TEK-
// seviyeli bir kanıtla SINIRLI KALMADIĞINI) kanıtlar.


test "codegen: GG.20 — iki seviyeli TRANSİTİF kanıtın ÜRETTİĞİ IR'da compute() İçİnde nox_rc_alloc GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/gg20_two_level_safe_forwarding.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const compute_start = std.mem.indexOf(u8, ir, "$compute(") orelse return error.ComputeNotFound;
    const compute_end = std.mem.indexOfPos(u8, ir, compute_start, "\n}\n") orelse ir.len;
    const compute_ir = ir[compute_start..compute_end];

    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_rc_alloc") == null);
}

// GG.20 KIRMIZI-TAKIM/KRİTİK GÜVENLİK testi: `spawn`'a geçen bir yerelin,
// callee'nin KENDİ gövdesi "kaçmıyor" KANITLANSA BİLE HÂLÂ ARC'ta KALDIĞI —
// `async def worker(xs: list[int])` `.qbe` altında ÇÖZÜMLENEMEDİĞİNDEN
// (checker'ın `isSpawnParamSafeType`si list/dict/class parametreleri
// SADECE `--release`de İZİN VERİR), BU test `llvm_golden_test.zig`ye
// TAŞINDI (bkz. "GG.20 KIRMIZI-TAKIM" testi orada).

// GG.21 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 5"): interprocedural
// escape kanıtının METOD çağrılarına GENİŞLETİLMİŞ hali — `Helper.peek`
// override EDİLMEYEN (final) bir metod olduğundan VE receiver `h`
// `compute()`nin KENDİ (sibling) parametresi OLDUĞUNDAN, `compute()`nin
// yereli `xs` ARTIK stack'e dönüşür.


test "codegen: GG.21 — final metoda yönlendirmenin ÜRETTİĞİ IR'da compute() İçİnde nox_rc_alloc GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/gg21_local_forwarded_to_final_method_read_only.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const compute_start = std.mem.indexOf(u8, ir, "$compute(") orelse return error.ComputeNotFound;
    const compute_end = std.mem.indexOfPos(u8, ir, compute_start, "\n}\n") orelse ir.len;
    const compute_ir = ir[compute_start..compute_end];

    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_rc_alloc") == null);
}

// GG.21 NEGATİF: `Helper.store_it` (final) `xs`i BAŞKA bir container'a
// (modül-global `sink`) YAZIYOR — `computeParamEscapes`nin metod-gövdesi
// taraması BUNU tohum olarak İŞARETLER, `compute()`nin `xs`i HÂLÂ
// `nox_rc_alloc`ta KALIR (metod final OLMASI TEK BAŞINA yeterli DEĞİL —
// metodun KENDİ gövdesi de GERÇEKTEN güvenli OLMALI).


test "codegen: GG.21 — mutasyona uğratan final metodun ÜRETTİĞİ IR'da compute() İçİnde nox_rc_alloc HÂLÂ VAR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/gg21_local_forwarded_to_final_method_mutating_stays_arc.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const compute_start = std.mem.indexOf(u8, ir, "$compute(") orelse return error.ComputeNotFound;
    const compute_end = std.mem.indexOfPos(u8, ir, compute_start, "\n}\n") orelse ir.len;
    const compute_ir = ir[compute_start..compute_end];

    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_rc_alloc") != null);
}

// GG.21 KIRMIZI-TAKIM/KRİTİK GÜVENLİK testi: `Helper.peek` KENDİSİ salt-
// okunur AMA `SubHelper` ONU override EDİP `xs`i BAŞKA bir yere (`sink`)
// KAYDEDİYOR — `peek` bu YÜZDEN final DEĞİL (`methodIsFinal` `false`
// DÖNMELİ), `compute(h: Helper)`nin `h.peek(xs)` çağrısı (h BAZ-tipli
// olduğundan runtime'da HERHANGİ bir alt sınıf OLABİLİR) MUHAFAZAKÂR
// KALMALI — `xs` HÂLÂ `nox_rc_alloc`ta kalmalı. Yanlış bir "final" kanıtı
// burada GERÇEK bir kullanım-sonrası-serbest-bırakmaya yol AÇARDI.


test "codegen: GG.21 — KIRMIZI-TAKIM — override edilen metodun ÜRETTİĞİ IR'da nox_rc_alloc HÂLÂ VAR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/gg21_overridden_method_stays_conservative.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    const compute_start = std.mem.indexOf(u8, ir, "$compute(") orelse return error.ComputeNotFound;
    const compute_end = std.mem.indexOfPos(u8, ir, compute_start, "\n}\n") orelse ir.len;
    const compute_ir = ir[compute_start..compute_end];

    try std.testing.expect(std.mem.indexOf(u8, compute_ir, "nox_rc_alloc") != null);
}



test "codegen(çalıştır): ileri referanslı (henüz tanımlanmamış) sınıf tipli alan artık DESTEKLENİYOR" {
    // Stdlib fazı §L: `nox.json`nin `JsonValue`si (bkz. core.nox) KENDİ
    // KENDİNE başvuran bir `list[JsonValue]` alanı taşıdığından, codegen'in
    // `registerClass`ı artık TÜM sınıf adlarını (alan tipleri ÇÖZÜLMEDEN
    // ÖNCE) önceden kaydediyor (bkz. `generateModule`nin yeni ön-geçiş
    // döngüsü) — bu, ileri-referanslı (VE öz-referanslı) sınıf alanlarını
    // ARTIK DESTEKLER. Bu test ESKİDEN (bkz. git geçmişi) `error.Unsupported`
    // BEKLERDİ — şimdi TAM TERSİNİ, doğru çalışan bir uçtan uca golden test
    // olarak doğruluyor.
    try expectGolden(
        @embedFile("codegen_cases/class_field_forward_ref.nox"),
        @embedFile("codegen_cases/class_field_forward_ref.expected"),
    );
}



// GG.12 (bkz. nox-teknik-spesifikasyon.md §3.66): `Box.sum()`daki
// `local_items: list[int] = self.items` — `self`in bir alanının salt-
// okunur, TEK-kullanım (bir `for` döngüsünün iterable'ı) bir kopyası —
// ARTIK retain/release GEREKTİRMEMELİDİR (`self` metodun tüm aktivasyonu
// boyunca CANLI, alan hiç yeniden atanmıyor, kopya hiçbir yere aktarılmıyor).
// Davranış (doğru toplam) yukarıdaki ile AYNI fixture'da ZATEN doğrulandı
// (aliasing/passthrough DAHİL) — burada YALNIZCA `$Box_sum`in ÜRETTİĞİ
// IR'da retain/predecrement'in GERÇEKTEN elendiği (yalnızca davranışın
// DEĞİŞMEDİĞİNİN değil) doğrudan kanıtlanır.
test "codegen: GG.12 — self.<alan> salt-okunur kopyasının ÜRETTİĞİ IR'da retain/release GERÇEKTEN YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/list_class_field.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);

    // `$Box_sum`in KENDİ gövdesini (bir SONRAKİ "export function"a KADAR)
    // izole et — modülün BAŞKA yerlerinde (ör. `c: Box = b` takma adı,
    // `make_box()`nin dönüş değeri) GERÇEK retain'ler VARDIR, bu test
    // SADECE `Box_sum`in İÇİNİ kontrol eder.
    const start_marker = "function l $Box_sum(l %rt, l %p_self) {\n";
    const start = std.mem.indexOf(u8, ir, start_marker) orelse return error.MarkerNotFound;
    const body_start = start + start_marker.len;
    const end_rel = std.mem.indexOf(u8, ir[body_start..], "\nexport function") orelse return error.MarkerNotFound;
    const box_sum_ir = ir[body_start .. body_start + end_rel];

    // `emitInlineRetain`/`emitInlinePredecrement`in İKİSİ de `@retain*`/
    // `@predecrement*` ETİKETLİ bloklar üretir (bkz. `ownership.zig`) —
    // İKİSİNİN de YOKLUĞU, `local_items`in retain/release trafiğinin
    // TAMAMEN elendiğinin kanıtıdır.
    try std.testing.expect(std.mem.indexOf(u8, box_sum_ir, "retain") == null);
    try std.testing.expect(std.mem.indexOf(u8, box_sum_ir, "predecrement") == null);
}

// Faz P2.2 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi"): boş
// `[]` literalinin tipi DÖRT bağlamda ("var_decl" bildirilen tipi, bir
// atamanın hedefinin ZATEN bilinen tipi, çağrı argümanı/parametre tipi,
// `return`ün fonksiyon dönüş tipi) bağlamdan çıkarılır — checker.zig'in
// `checkExprExpected`i + codegen_qbe/expr.zig'in `genExprForTarget`
// içindeki YENİ `.list_lit` dalı (`genEmptyListLit`).






// Faz P2.1 (bkz. proje belleği "generic sınıflar" planı).




// `closure_raise_not_swallowed.nox`nin (bkz. yukarisi) AYNI "sessizce
// yutulmaz" doğrulaması — burada `expectGolden` DEĞİL `expectUncaughtException`
// kullanilir: bir generic sinifin `__init__`i icinde raise etmek (Nox'un
// GENEL, sinif-tipinden BAGIMSIZ, ONCEDEN VAR OLAN bir sinirlamasi geregi —
// kismi insa edilmis ornegin serbest birakilmamasi) BİLİNÇLİ olarak stderr'e
// bir bellek sizintisi uyarisi yazar; `expectGolden`in KATI "stderr bos
// olmali" kontrolu BU YUZDEN burada KULLANILAMAZ (plain, generic-olmayan bir
// sinifla da AYNI sizinti dogrulandi — P2.1'in KENDI kapsamina GİRMEYEN,
// ayri bir bilinen kisitlama).


// Faz 7 (tekli kalıtım, bkz. proje belleği "7 fazlı düzeltme planı"):
// `super().__init__(...)` ile kurucu zincirleme, override + alan mirası
// (taban+türetilen alanların TEK bir düz nesnede birleşmesi), sızıntı yok.


// Faz 7: taban-tipli bir DEĞİŞKEN/liste/fonksiyon parametresi üzerinden
// ÇALIŞMA ZAMANI polimorfik dispatch (vtable) — hem doğrudan `a.speak()`
// hem BAŞKA bir metod (`describe`) İÇİNDEN `self.speak()` hem de bir
// fonksiyon parametresi (`make_speak(a: Animal)`) ÜZERİNDEN AYNI şekilde
// çalışır; sızıntı yok.


// Faz 7: `except Base:` bir `Derived` örneğini de YAKALAR (hiyerarşik
// class_id eşleşmesi, OR-zinciri) — hem TABAN-tipli hem TAM-tipli
// `except` yan tümcesi AYNI `raise`i doğru şekilde yakalar; sızıntı yok.


// Faz 7: `super().metod(...)` (yalnızca `__init__` DEĞİL) — HER ZAMAN
// DOĞRUDAN (asla vtable ÜZERİNDEN) atanın KENDİ implementasyonuna gider,
// hem override EDEN sınıfın KENDİSİNDEN hem taban-tipli bir değişken
// ÜZERİNDEN (override'ın KENDİSİ dolaylı dispatch İLE çağrılsa BİLE
// override'ın İÇİNDEKİ `super()` çağrısı sonsuz özyinelemeye YOL AÇMAZ).








// Faz SC.1 (bkz. plan dosyası "spawn/await sınırında istisna yayılımı
// düzeltmesi"): `spawn` edilen bir `async def`nin gövdesinde YAKALANMAMIŞ
// bir istisna DÜZELTMEDEN ÖNCE sessizce KAYBOLUYORDU — `await` `try`/
// `except` HİÇBİR ZAMAN tetiklenmeden (çöp/varsayılan) bir değer
// döndürüyordu. Bu 4 test, DÜZELTMEYİ (`runtime/async_rt/scheduler.zig`nin
// `entryTrampoline`ı + `bridge.zig`nin `nox_async_await`ı + `compiler/
// codegen_qbe/async_thread.zig`nin `genAwaitExpr`ına eklenen
// `emitExceptionCheck()`) doğrular. "Mutlu yol" (istisna YOK) regresyonu
// İçİn AYRI bir fixture EKLENMEDİ — HEMEN YUKARIDAKİ `async_spawn_await`
// testi ZATEN bu yolu (spawn+await, istisnasız) egzersiz ediyor VE bu
// FAZIN `genAwaitExpr` değişikliğinin `continue_label` dalını (istisna
// YOKSA normal akış) DOĞRUDAN regresyon-test ediyor.








// Faz SC.2 (bkz. plan dosyası "Task[T].cancel() + CancelledError"):
// kooperatif görev iptali — `t.cancel()` bir bayrak İşaretler, GERÇEK
// iptal (CancelledError fırlatma) cancel edilen task'ın KENDİ kodu bir
// SONRAKİ `await` yaptığında devreye girer (v1 kooperatif/checkpoint
// sınırı — bkz. plan dosyasının "Kapsam DIŞI" notu, HİÇ await YAPMAYAN
// bir task ASLA kesilemez).










// Faz STD.1 (bkz. plan dosyası "nox.csv"): saf Nox'ta yazılmış RFC 4180
// uyumlu CSV ayrıştırma/yazma — kullanıcının 5 maddelik yol haritasının
// 3. maddesinin ("stdlib eksikleri") İLK alt-parçası.












// Faz STD.2 (bkz. plan dosyası "nox.gzip"): Zig'in `std.compress.flate`
// sini Nox'a dışa açan gzip sıkıştırma/açma — kullanıcının 5 maddelik
// yol haritasının 3. maddesinin ("stdlib eksikleri") 2. alt-parçası.
// Sıkıştırılmış veri `str`in NUL-sonlandırmalı temsiliyle GÜVENSİZ
// olduğundan (bkz. plan dosyasının kritik güvenlik bulgusu) `list[int]`
// olarak taşınır — bu ayrıca `extern def`in FFI-güvenli tip listesine
// `list[int]`in eklenmesini gerektirdi (`compiler/typecheck/checker.zig`
// `isFfiSafeListType`).










// Faz STD.3 (nox.toml) — kullanıcının 5 maddelik yol haritasının 3.
// maddesinin ("stdlib eksikleri") 3. alt-parçası. Saf Nox'ta yazıldı
// (csv.nox'un aynı deseni) — TEK gerçek keşif: Nox'ta `and`/`or` KISA-
// DEVRE YAPMAZ (her iki operand da her zaman değerlendirilir), bu
// yüzden toml.nox'un TÜM "pos[0] < n and text[pos[0]] == X" desenleri
// `_char_at_or_empty`/`_safe_substr` yardımcılarına taşındı.














// Faz STD.4 (nox.smtp) — kullanıcının 5 maddelik yol haritasının 3.
// maddesinin ("stdlib eksikleri") 4. alt-parçası. `nox.tls`/`nox.
// websocket`nin AYNI, ZATEN kanıtlanmış konvansiyonu: CI-otomatik test
// SADECE "bağlantı hatası temiz fırlatılır" yolunu kapsar — gerçek bir
// uzak SMTP sunucusuna karşı TAM EHLO/AUTH/MAIL FROM/RCPT TO/DATA/
// STARTTLS doğrulaması ELLE yapıldı (bkz. proje belleği), harici
// İnternet erişimine bağımlı olmaması İçin CI'da OTOMATİK DEĞİL.


// Faz STD.5 (nox.yaml) — kullanıcının 5 maddelik yol haritasının 3.
// maddesinin ("stdlib eksikleri") 5. (SONUNCU stdlib-gap) alt-parçası.
// `nox.toml`nin (Faz STD.3) AYNI "and/or kısa-devre yapmaz" + "fonksiyon-
// dönüşünde çıplak str-indeksleme ARC sızdırır" güvenlik dersleri BURADA
// da uygulandı. AYRICA BU turda YENİ, GERÇEK bir codegen hatası bulundu:
// `s[0] == X and <inlinable_fonksiyon_cagrisi>(...)` deseni bir QBE
// "predecessors not matched in phi" derleme hatasına yol açıyor (bkz.
// flaglenen takip görevi) — TÜM benzer siteler İç İçe `if`lerle atlatıldı.




















// v1.29.12 — GERÇEK, canlı bir SIGSEGV reprodüksiyonuyla bulunan bir hata
// İçİn eklendi: `Channel[T]` bir sahipten `spawn` İLE BAŞKA bir fiber'a
// GEÇİLİP sahip HENÜZ çocuk fiber ÇALIŞMADAN dönerse, ESKİDEN (Task[T]/
// Channel[T] ARC-yönetimli OLMADIĞINDAN, retain/refcount YOKKEN)
// `nox_channel_destroy` KOŞULSUZ serbest bırakırdı — çocuk DAHA SONRA
// `.recv()` çağırdığında `self.mutex.lock()` SERBEST BIRAKILMIŞ belleğe
// erişip GERÇEK bir SIGSEGV verirdi (`lldb` İLE DOĞRULANDI). `owner()`nin
// KENDİSİ `t`yi (`slow_consumer`nin Task'ını) HİÇ `await` ETMEDEN döner —
// `ch`nin (Channel) refcount'u sahibin `destroy()`u SIRASINDA HÂLÂ `2`
// (owner + spawn edilen closure) OLDUĞUNDAN struct HAYATTA KALIR,
// `slow_consumer` DAHA SONRA GÜVENLE `.recv()` çağırıp doğru veriyi alır.
































// Darboğaz analizi bulgu #4 (bkz. benchmarks/RESULTS.md, 2026-07-22):
// `genListEq`nin ürettiği döngü sayacı ESKİDEN bir `alloc8` yığın slotuna
// yazılıp OKUNUYORDU — ama üretilen ARM64 kodu okunduğunda (`_List_priml_eq`)
// QBE'nin KENDİ register ayırıcısının sayacı ZATEN tek bir yazmaçta tuttuğu,
// `str`in İSE (kimse OKUMASA bile) HER yinelemede GEREKSİZ yere çalıştığı
// GÖRÜLDÜ. Düzeltme: QBE'nin KENDİ `phi` talimatıyla sayaç TAMAMEN bellek
// KULLANMADAN ifade edilir. Bu test, `$List_priml_eq`nin gövdesinde ARTIK
// HİÇBİR `alloc8` OLMADIĞINI (dolayısıyla ilişkili `str`/`ldr` çiftinin de
// üretilmediğini) doğrudan IR metninden kanıtlar.
test "codegen: darboğaz #4 — `List_priml_eq`nin gövdesinde ARTIK `alloc8` (ölü yığın store'u) YOK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/deep_equality.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);
    switch (nox.checker.check(allocator, module)) {
        .ok => {},
        .err => return error.FixtureNotWellTyped,
    }
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, &.{}, .qbe, null);
    const fn_start = std.mem.indexOf(u8, ir, "export function w $List_priml_eq(") orelse return error.FunctionNotFound;
    const after_start = ir[fn_start..];
    const fn_end = std.mem.indexOf(u8, after_start, "\nexport function") orelse after_start.len;
    const fn_body = after_start[0..fn_end];
    try std.testing.expect(std.mem.indexOf(u8, fn_body, "alloc8") == null);
    try std.testing.expect(std.mem.indexOf(u8, fn_body, " phi ") != null);
}



























// Faz FF.3 (bkz. nox-teknik-spesifikasyon.md §3.62) — GERÇEK, ÖNCEDEN
// VAR OLAN bir bellek-güvenliği hatasını KANITLAR: `dict[K,V]` ARC-
// yönetimli DEĞİLDİ (`Task`/`Channel` İLE AYNI "tek sahiplilik, koşulsuz
// yıkım" modeli) — bir dict adlandırılmış bir yerele bağlanıp SONRA bir
// sınıf alanına GEÇİRİLİRSE, yerelin kapsam-sonu temizliği dict'i
// KOŞULSUZ yok ederdi, sınıf alanı SALLANAN bir işaretçi bırakırdı.
// `stdlib/nox/http.nox`nin `get`/`post`u BUNU "headers'ı ASLA bir yerele
// bağlama" disipliniyle ELLE AŞIYORDU — bu test, O disiplin OLMADAN
// (bilerek `d`yi adlandırılmış bir yerele bağlayarak) AYNI deseni
// sergiler. Düzeltmeden ÖNCE bu test KIRMIZI olmalı (GERÇEKTEN
// SIGSEGV/exit 139 İLE doğrulandı, manuel çalıştırmayla) — `dict`in
// `str`/`list`/`class` İLE AYNI ARC modeline taşınmasıyla YEŞİLE döner.


// Faz FF.3'ün POZİTİF kanıtı: AYNI `dict` KENDİ adlandırılmış yereli
// (`shared`) HÂLÂ kapsam İÇİNDEYKEN İKİ AYRI sınıf örneğine (`a.data`/
// `b.data`) PAYLAŞTIRILIYor — HER ÜÇ sahibin de (yerel + iki alan)
// BİRBİRİNDEN BAĞIMSIZ, doğru DEĞERİ okuyabildiğini VE (Zig testlerindeki
// DebugAllocator'ın hiçbir sızıntı/çift-serbest-bırakma raporlamadığı,
// bkz. `zig build test`) retain/release SAYACININ tam DENGEDE olduğunu
// kanıtlar — `dict`in ARTIK `str`/`list`/`class` İLE AYNI, PAYLAŞIM-
// GÜVENLİ ARC modelinde OLDUĞUNUN pozitif göstergesi.




// Güvenlik bulgusu H-2 (bkz. güvenlik raporu, 20 Temmuz 2026) — DÜZELTİLDİ:
// `d[key]` eksik bir anahtarda SESSİZCE null döndürüp sonraki HER kullanımda
// (`len()` gibi) null-pointer çökmesine (SIGSEGV) yol açıyordu; `dict[str,
// int]`de saklı bir `0` DEĞERİYLE "anahtar YOK" durumu da AYRICA ayırt
// edilemiyordu (bağımsız bir doğruluk hatası). `genDictGet` artık `nox_dict_
// contains` İLE ÖNCE varlığı kontrol edip yoksa `KeyError` raise ediyor.


// Güvenlik bulgusu H-1 (bkz. güvenlik raporu, 20 Temmuz 2026) — DÜZELTİLDİ:
// `hpy_call`ın `yol`/`uzantı_adı`/`fonksiyon_adı` argümanları ÖNCEDEN
// yalnızca TİPÇE `str` olmak zorundaydı, DEĞER olarak ÇALIŞMA ZAMANI
// hesaplı keyfi bir ifade OLABİLİYORDU — `runtime/hpy_bridge/loader.zig`nin
// doğrulamasız `std.DynLib.open`ı ile birleşince bu, SIRADAN Nox kodundan
// ulaşılabilen bir "keyfi native kütüphane yükle" ilkeliydi. Checker artık
// bu üçünün DERLEME-ZAMANI string LİTERALİ olmasını ZORUNLU kılıyor.
test "codegen: Güvenlik H-1 — hpy_call'ın yol argümanı çalışma-zamanı değişkeniyse REDDEDİLİR (yalnızca string literali)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/hpy_call_nonliteral_path_rejected.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => return error.ExpectedTypeErrorButGotOk,
        .err => |e| {
            try std.testing.expectEqual(error.TypeMismatch, e.code);
            try std.testing.expect(std.mem.indexOf(u8, e.message, "string LİTERALİ") != null);
        },
    }
}

// Faz 16 (bkz. plan dosyası "hpy_call'e kalıcı modül+context"): `hpy_call`nin
// AYNI Güvenlik bulgusu H-1 kısıtı `hpy_open`nin `yol` argümanı İçİn de
// GEÇERLİDİR.
test "codegen: Güvenlik H-1 — hpy_open'ın yol argümanı çalışma-zamanı değişkeniyse REDDEDİLİR (yalnızca string literali)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/hpy_open_nonliteral_path_rejected.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => return error.ExpectedTypeErrorButGotOk,
        .err => |e| {
            try std.testing.expectEqual(error.TypeMismatch, e.code);
            try std.testing.expect(std.mem.indexOf(u8, e.message, "string LİTERALİ") != null);
        },
    }
}

// Faz 16: `hpy_call_on`nin `fonksiyon_adı` argümanı da (`hpy_call`nin AYNI
// TUTARLILIK kararıyla) SADECE string LİTERALİ olabilir.
test "codegen: hpy_call_on'ın fonksiyon_adı argümanı çalışma-zamanı değişkeniyse REDDEDİLİR (yalnızca string literali)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/hpy_call_on_nonliteral_funcname_rejected.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => return error.ExpectedTypeErrorButGotOk,
        .err => |e| {
            try std.testing.expectEqual(error.TypeMismatch, e.code);
            try std.testing.expect(std.mem.indexOf(u8, e.message, "string LİTERALİ") != null);
        },
    }
}

// Faz 17 (bkz. plan dosyası "kalıcı tutamaçlı HPy çağrılarına çoklu-
// argüman + list/dict/class marshalling"): `list[list[int]]` (İÇ İÇE
// konteyner) `hpy_call_on`a DOĞRUDAN argüman olarak geçilirse REDDEDİLİR
// — v1 SADECE skaler elemanlı list/dict marshal eder.
test "codegen: hpy_call_on'a list[list[int]] (iç içe konteyner) argümanı REDDEDİLİR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/hpy_call_on_nested_list_arg_rejected.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => return error.ExpectedTypeErrorButGotOk,
        .err => |e| {
            try std.testing.expectEqual(error.TypeMismatch, e.code);
            try std.testing.expect(std.mem.indexOf(u8, e.message, "marshal EDİLEMEZ") != null);
        },
    }
}

// Faz 17: TÜM alanları skaler OLMAYAN (nested list/dict/class taşıyan)
// bir sınıf örneği de `hpy_call_on`a argüman olarak geçilirse REDDEDİLİR
// — class-as-dict "surrogate" marshalling'i SADECE skaler alanları
// destekler.
test "codegen: hpy_call_on'a nested-alanlı bir class argümanı REDDEDİLİR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = @embedFile("codegen_cases/hpy_call_on_class_with_nested_field_rejected.nox");

    const tokens = try nox.lexer.tokenize(allocator, source);
    const module = try nox.parser.parseModule(allocator, tokens);
    switch (nox.checker.check(allocator, module)) {
        .ok => return error.ExpectedTypeErrorButGotOk,
        .err => |e| {
            try std.testing.expectEqual(error.TypeMismatch, e.code);
            try std.testing.expect(std.mem.indexOf(u8, e.message, "marshal EDİLEMEZ") != null);
        },
    }
}

// Faz FF.4 (bkz. nox-teknik-spesifikasyon.md §3.63): çıplak `self`li bir
// metodun (`bump`) bir ALANI GERÇEKTEN okuyup/YAZDIĞI uçtan uca kanıt —
// codegen'in çıplak self İÇİN GERÇEKTEN sıfır değişiklik gerektirdiğinin
// (self'in tipi ZATEN `class_name`den BAĞIMSIZ türetiliyor) DOĞRULANMASI,
// yalnızca DERLENDİĞİNİN DEĞİL.


// Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): `class_point.nox` İLE
// YAPISAL OLARAK AYNI, alanları AÇIKÇA bildirilmiş — davranışın BİREBİR
// AYNI olduğunun kanıtı.


// Faz FF.5: `inferFieldType`nin BUGÜN HİÇ ele ALAMADIĞI bir alan — `value`
// yalnızca bir `if`/`else` DALI İÇİNDE atanıyor, `registerClass`ın
// `__init__`-tarama döngüsü YALNIZCA ÜST-DÜZEY deyimlere bakar (bkz.
// `registerClass`in belge notu). Bildirim OLMADAN bu alan codegen'de HİÇ
// KEŞFEDİLMEZDİ — codegen'in `resolveType` bypass'ının GERÇEKTEN
// çalıştığının, ÖZELLİĞİN ASIL DEĞER ÖNERİSİNİN kanıtı.




















// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): `list[int]`/`list[str]`/
// `list[float]`in HER ÜÇÜ İçin `nox_list_sort_int`/`_str`/`_float`
// dispatch'inin (`elem_qtype`/`elem_is_str`e göre) doğru fonksiyona
// yönlendirdiğini kanıtlar.


















// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): `exists`/`is_file`/
// `is_dir` HİÇBİR ZAMAN `raise` ETMEZ (`read_to_string`in AKSİNE) — var
// olan/olmayan bir dosya VE bir dizin ÜZERİNDE ÜÇÜNÜN de doğru sonuç
// döndürdüğünü kanıtlar.


// Faz EE.1: YENİ `nox.path` modülü — saf string manipülasyonu, hiçbir I/O
// yok, hiçbir fonksiyon raise etmez.
















// Güvenlik bulguları M-4/M-5/M-6 (bkz. güvenlik raporu, 20 Temmuz 2026) —
// DÜZELTİLDİ: `hmac_sha256`/`constant_time_eq`/`secure_random_hex` YENİ
// eklendi. RFC 4231/2202'nin bilinen "Jefe" test vektörüyle doğrulanır.


// Parola hash'leme (argon2id/bcrypt/scrypt) — hash'in KENDİSİ (rastgele
// tuz İçerdiğinden) deterministik DEĞİLDİR, bu YÜZDEN `crypto_hmac_and_
// secure_random`daki `t1 == t2` deseniyle AYNI: yalnızca doğrulama
// SONUÇLARI (bool) VE İKİ hash'in birbirinden FARKLI olduğu (`h1 == h1b`)
// karşılaştırılır, ham hash dizesi YAZDIRILMAZ.


// `nox.uuid.uuid4` — "eksik kütüphaneler" listesinin İLK maddesi, saf Nox
// (yeni bir runtime ilkeli GEREKMEDİ, bkz. `stdlib/nox/uuid.nox`nin belge
// notu). Hash'ler GİBİ rastgele OLDUĞUNDAN, `crypto_password_hashing`YLA
// AYNI desen: ham UUID METNİ YAZDIRILMAZ, yalnızca uzunluk/biçim/farklılık
// doğrulanır.
























// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi", Madde 2):
// MAX_JSON_NESTING_DEPTH (32) AŞAN bir girdi, `std.json.parseFromSlice`ye
// HİÇ GEÇİLMEDEN, ÇÖKMEDEN (`JsonError` İLE) reddedilir.




















// Faz JJ (bkz. nox-teknik-spesifikasyon.md §3.68'in devamı) — daha önce
// ÇÖZÜLEMEYEN, ~%100 tekrarlanabilir bir çift-serbest-bırakma/kullanım-
// sonrası-serbest-bırakma (SIGSEGV/"incorrect alignment" paniği): bir
// `list[str]` yerel değişkeni İÇEREN küçük bir fonksiyon (`hexd`), 2+
// yinelemeli bir döngü İÇİNDE AYNI ifadede İKİ KEZ inline edilerek
// çağrıldığında, İKİNCİ (ve sonraki) yinelemelerde ÇÖKÜYORDU — kök neden
// `releaseSlotIfSet`nin bir yerel değişkeni serbest bıraktıktan SONRA
// slotu SIFIRLAMAMASIYDI (inline edilmiş bir çağrı sitesinin slotu, GERÇEK
// bir fonksiyonun aksine, döngü yinelemeleri ARASI YENİDEN KULLANILIR).
// lldb İLE doğrulandı: düzeltmeden ÖNCE üçüncü `List_str_release` çağrısı
// BİRİNCİYLE AYNI (zaten serbest bırakılmış) adresi kullanıyor VE içeriği
// çöp veri (`len=0xaaaa` gibi) OLARAK okunuyordu.


// Faz NN — Faz JJ'nin "identifier ile taşınan" varyantı: `return xs` (çıplak
// identifier) İLE bir `list[str]`i döndüren küçük bir fonksiyon, bir `while`
// döngüsü İÇİNDE TEKRAR TEKRAR inline çağrılıp SONUCU bir `var_decl`e
// atandığında ÖNCEDEN "incorrect alignment" paniğiyle ÇÖKÜYORDU — kök neden
// `ownership.zig`nin `releaseNamedLocalsExcept`inin, değeri arayana "taşıyan"
// (yani `except_name` eşleşen) yerelin slotunu HİÇ sıfırlamamasıydı (Faz
// JJ'nin `releaseSlotIfSet`de düzelttiği AYNI kök nedenin bu değişkeni).
// `.ssa` çıktısı dump edilerek İKİNCİ yinelemede callee'nin KENDİ `xs:
// list[str] = [...]` var_decl'inin bir sonraki iterasyonda ÖNCEKİ (artık
// arayana taşınmış) işaretçiyi TEKRAR serbest bıraktığı KANITLANDI.


// Faz GG.3 (bkz. nox-teknik-spesifikasyon.md'nin yeni Faz bölümü) — Go-tarzı
// `defer` anahtar kelimesi. `expectGolden`in stderr-boş kontrolü (bkz. onun
// belge notu) bu testlerin HEPSİNİN de örtülü bir bellek-sızıntısı testi
// olmasını sağlar (yakalanan closure argümanlarının doğru retain/release
// edildiğinin KANITI).





// Asıl YENİ yetenek: bir döngü içinde `defer` — bekleyen çağrı SAYISI
// ÇALIŞMA ZAMANINDA değişir, bu yüzden `finally_stack` gibi TAMAMEN statik
// bir mekanizmayla KARŞILANAMAZ (bkz. `runtime/alloc/defer_stack.zig`nin
// belge notu) — bu test TAM OLARAK bunu doğrular.






// Faz 1 decorator (bkz. plan dosyası "Decorator sözdizimi + metadata-tabanlı
// metaprogramming"): uçtan uca — `@get`/`@post` İLE decore edilmiş İKİ
// üst-düzey fonksiyondan `nox.reflect.router_from_decorators()` GERÇEK bir
// `Router` inşa eder VE bir sahte isteği (GERÇEK soket YOK — `router.
// dispatch(req)` DOĞRUDAN çağrılır, bkz. `router_module_state_golden_test.
// zig`nin AYNI "modül-seviyesi Router" deseni) DOĞRU rotaya yönlendirir.
test "codegen(çalıştır): Faz 1 decorator — router_from_decorators() uçtan uca GET+POST dispatch'i" {
    try expectGolden(
        \\import nox.reflect
        \\from nox.router import Context, Router
        \\from nox.http import HttpResponse, HttpRequest
        \\
        \\@get("/users/:id")
        \\def show_user(ctx: Context) -> HttpResponse:
        \\    return HttpResponse(200, "hello " + ctx.param("id"), {})
        \\
        \\@post("/users")
        \\def create_user(ctx: Context) -> HttpResponse:
        \\    return HttpResponse(201, "created", {})
        \\
        \\@admin("only")
        \\def not_a_route() -> int:
        \\    return 1
        \\
        \\r: Router = nox.reflect.router_from_decorators()
        \\
        \\empty_headers: dict[str, str] = {}
        \\get_req: HttpRequest = HttpRequest("GET", "/users/42", "", empty_headers)
        \\get_resp: HttpResponse = r.dispatch(get_req)
        \\print(get_resp.status)
        \\print(get_resp.body)
        \\
        \\post_req: HttpRequest = HttpRequest("POST", "/users", "", empty_headers)
        \\post_resp: HttpResponse = r.dispatch(post_req)
        \\print(post_resp.status)
        \\print(post_resp.body)
        \\
    ,
        "200\nhello 42\n201\ncreated\n",
    );
}

// Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83): `TaskLocal[T]` —
// nyx'te farkedilen bir Nox eksikliği (task/fiber-local bağlam). İKİ
// AYRI fiber'ın (A/B) AYNI `TaskLocal[Ctx]` örneğine `set` ETTİĞİ
// DEĞERİN BİRBİRİNE SIZMADIĞINI (gerçek per-fiber izolasyon) kanıtlar —
// `Channel`ler ile İKİ fiber'ın da `set` ÇAĞIRDIKTAN SONRA (ama `get`
// ÇAĞIRMADAN ÖNCE) senkronize edilmesi, GERÇEK bir eşzamanlı-çakışma
// senaryosu OLUŞTURUR (sıralı çalıştırma İLE YETİNİLSEYDİ, tek-paylaşılan-
// yuva GİBİ bir hata BİLE fark edilmeyebilirdi). `clear()`in `get()`i
// `None`e DÖNDÜRDÜĞÜNÜ VE hiçbir sızıntı OLMADIĞINI (DebugAllocator)
// da doğrular.


// Faz OO.3 (bkz. nox-teknik-spesifikasyon.md §3.84): nyx'te farkedilen
// bir Nox eksikliği (zengin exception stack/source span) — `nox_raise`
// ARTIK `raise` deyiminin satırını taşır, `$nox_class_name_dispatch`
// (bkz. `layout.zig`nin `genClassNameDispatch`ı) ARTIK yakalanmamış
// istisnanın GERÇEK ÇALIŞMA-ZAMANI sınıf adını çözer — `nox_unhandled_
// exception` İKİSİNİ de tek satırlık ANLAMLI bir mesajda RAPORLAR (ÖNCEDEN
// tamamen sabit/jenerik bir mesajdı, ne tip ne satır bilgisi TAŞIRDI).
// Ayrıca `Exception` taban sınıfının (core.nox) VE `class X(Exception):
// pass` sözdiziminin (bkz. `parser.zig`nin sınıf gövdesindeki YENİ `pass`
// desteği) ÇALIŞTIĞINI da dolaylı olarak DOĞRULAR.


// Faz OO.4 (bkz. nox-teknik-spesifikasyon.md §3.85): nyx'te farkedilen
// bir Nox eksikliği (`dict[int, Record]` YOKTU, checker dict değer
// tipini int/float/bool/str'e KISITLIYORDU) — ARTIK `.class` DEĞER
// olarak KABUL EDİLİR (`nox_class_release_dispatch`in tag-tabanlı
// dispatch'i ÜZERİNDEN, Madde 1'in `TaskLocal[T]`siYLE AYNI mekanizma).
// İNŞA+OKUMA+ÜZERİNE-YAZMA (eski Record değerinin serbest bırakıldığını,
// SIZDIRILMADIĞINI kanıtlar — `expectGolden`nin boş-stderr kontrolü)
// +`.values()`i kapsar.


// GG.17 (bkz. nox-teknik-spesifikasyon.md §3.10X, plan dosyası "ASAP
// güçlendirmesi — Tur 1"): sıradan (ne `lowlevel:` bloğu İÇİNDE ne bir
// çağrı-argümanı olan) bir üst-düzey `var_decl`in sabit-boyutlu bir sınıf
// örneği/basit-literal liste OLDUĞU VE geri kalan gövdede HİÇ kaçmadığı
// KANITLANDIĞINDA `nox_rc_alloc` YERİNE bir `alloc8` yığın slotuna
// dönüştüğünü — HEM sınıf HEM liste İçin, İKİSİ AYNI fonksiyonda BİRLİKTE
// — kanıtlar (`expectGolden`nin boş-stderr kontrolü sızıntı YOK'u
// GARANTİ eder).


// GG.17: dönüştürülen stack slotunun fonksiyon GİRİŞİNDE TEK SEFER
// ayrılıp BÜYÜK bir döngü BOYUNCA (200.000 tur) TEKRAR TEKRAR GÜVENLE
// yeniden kullanıldığını (döngü İçİNDE taze bir `alloc8` YAPILSAYDI
// yığın taşardı — bkz. `ownership.zig`nin "döngü İçİnde taze alloc8"
// uyarısı) kanıtlar.


// GG.17 — NEGATİF (regresyon-yok) kanıtı: bir yerel `return` edilirse
// (kaçış) `nox_rc_alloc`ta KALIR, dönüştürülmez — davranış DEĞİŞMEZ.


// GG.17 — NEGATİF: bir yerel BAŞKA bir fonksiyona ARGÜMAN olarak geçerse
// `nox_rc_alloc`ta KALIR. GG.20 (bkz. plan dosyası "ASAP güçlendirmesi —
// Tur 4") SONRASI: BU ÖZEL fixture `read_box`'ın KENDİSİNİN bir METOD
// ÇAĞRISI (`b.get_n()`) kullanmasını SAĞLAR — metod çağrıları GG.20'nin
// interprocedural kanıtının KAPSAMI DIŞINDA (KOŞULSUZ kaçış SAYILMAYA
// devam eder), bu YÜZDEN BU senaryo HÂLÂ (v1.44.0'dan SONRA da)
// `nox_rc_alloc`ta KALIR — `.ssa` anlık görüntüsü DEĞİŞMEDEN geçerliliğini
// korur. Salt-okunur bir SERBEST fonksiyona (metod DEĞİL) yönlendirmenin
// ARTIK GÜVENLİ sayıldığı YENİ pozitif durum İçİn bkz. `gg20_*` fixture'ları.


// GG.17 — NEGATİF: bir yerel BAŞKA bir isme atanırsa (takma ad, `ys =
// xs`) HER İKİSİ de `nox_rc_alloc`ta KALIR — `ownership/analysis.zig`nin
// "İlke #8" muhafazakârlığıyla TUTARLI.


// GG.17 — NEGATİF: `MAX_STACK_ALLOC_SIZE`i (4096 bayt) AŞAN bir literal
// liste, gerisinde HİÇ kaçmasa BİLE stack `alloc8`'e DÖNÜŞMEZ (bir
// fiber'ın SABİT 256 KiB stack'ini korumak İçİn bilinçli boyut tavanı).
// GG.18 EKLENDİKTEN SONRA (bkz. plan dosyası "Tur 2"): elemanları
// SKALER OLDUĞUNDAN VE kaçmadığından `classifyVarDecl` BUNU ARTIK
// fonksiyon-kapsamlı bir arenaya (`nox_rc_alloc` DEĞİL) DÖNÜŞTÜRÜYOR —
// bu, Tur 1'in stack-boyutu tavanının BİLİNÇLİ, GÜVENLİ bir GENELLEMESİ
// (arena, fiber stack'i KULLANMADIĞINDAN AYNI boyut riski TAŞIMAZ).


// GG.17 hotfix (v1.42.0) + GG.19 (bkz. plan dosyası "ASAP güçlendirmesi
// — Tur 3"): bir GG.17-kalifiye YEREL İÇEREN VE AYRICA GG.2 inline-
// edilebilirlik şartlarını KARŞILAYAN bir fonksiyon (`helper`), GERÇEK
// bir çapraz-fonksiyon temp-adı çakışmasına (`stack_construct_sites`'in
// AST-düğüm-anahtarlı, hiç temizlenmeyen kaydı, `caller`e SPLICE
// edilince ESKİ bir temp adı BULUP KULLANIYORDU) yol açıyordu —
// GERÇEKTEN derlenip ÇALIŞTIRILARAK bulundu (SIGBUS riski). v1.42.0'ın
// KABA düzeltmesi `helper()`i inline-edilebilirlikten TAMAMEN
// dışlıyordu; GG.19 BUNU `registerInlineSite`in HER splice sitesi İçİn
// TAZE, çakışmayan bir tutamak ÜRETMESİYLE değiştirdi — `helper()` ARTIK
// GÜVENLE inline EDİLİYOR (`.ssa`da GERÇEK bir `call $helper` YOK,
// splice edilmiş bir gövde VAR), çıktı DEĞİŞMEDEN `13`.


// GG.18 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 2"): boş `[]`
// literalinden `.append()` İLE büyüyen, SADECE okunan (kaçmayan) bir
// `list[int]` yereli — `nox_rc_alloc`/`nox_rc_release` YERİNE fonksiyon-
// kapsamlı bir arena (`nox_arena_create`/`nox_arena_alloc`/`nox_arena_
// list_grow`/`nox_arena_destroy`) kullanır, sızıntı YOK.


// GG.18: BÜYÜK bir N (2000 tur × 50 `.append()`) İLE, arenanın Release-
// modu HAVUZLAMASININ (`lowlevel.zig`nin `arena_pool`ı) SIK create/destroy
// döngüsü ALTINDA da doğru/sızıntısız çalıştığını kanıtlar.


// GG.18 — NEGATİF: `return`le kaçan bir büyüyen-liste yereli ARC'ta KALIR.


// GG.18 — NEGATİF: başka bir fonksiyona argüman olarak geçen büyüyen bir
// liste arenaya dönüştürülmez (v1'de interprocedural kanıt YOK).


// GG.18 — NEGATİF: `.pop()` (v1'de SADECE `.append()` desteklenir,
// `.pop()`/`.sort()`/BAŞKA metodlar HÂLÂ kaçış sayılır) arenaya dönüştürülmez.


// GG.18 — NEGATİF: heap-yönetimli eleman tipi (`list[str]`, v1 SADECE
// skaler int/float/bool destekler) arenaya dönüştürülmez (Tur 1'in
// class-alan-release hatasının AYNISINI — elemanların HİÇ release
// edilmemesini — baştan eler).


// GG.19 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 3"): incelemenin
// KENDİ önerdiği `point_sum(x)` deseni — v1.42.0'da (v1.41.0'ın hotfix'i
// SAYESİNDE) GÜVENLİ ama inline-EDİLEMEZDİ; GG.19 SONRASI ARTIK HEM
// stack-promotion HEM inlining BİRLİKTE çalışıyor (`.ssa`da GERÇEK bir
// `call $point_sum` YOK).


// GG.19: AYNI GG.17-kalifiye `helper()` fonksiyonu AYNI `caller` İçİnde
// 3 KEZ çağrılıyor — HER splice'ın KENDİ TAZE, ÇAKIŞMAYAN tutamağını
// aldığını (`.ssa`da 3 AYRI `alloc8`) kanıtlar.


// GG.19: AYNI `helper()` HEM `caller_a` HEM `caller_b`DEN (HEM DE
// STANDALONE) çağrılıyor — HER splice VE `helper`'IN KENDİ standalone
// derlemesinin (üçü de AYNI AST düğümlerini kullanıyor) BİRBİRİNE
// ÇAKIŞMADIĞINI kanıtlar.


// GG.19: 10 ayrı, KENDİ BAŞINA `MAX_STACK_ALLOC_SIZE` (4096 bayt)
// İçİnde kalan (4008 bayt, 500 int alanlı) sınıf örneği — TOPLAMDA
// `MAX_PROMOTED_FRAME_SIZE`i (32 KiB) AŞIYOR. İLK 8'i (8×4008=32064 ≤
// 32768) stack'e, KALAN 2'si (9×4008=36072 > 32768) arenaya DÜŞMELİ.


// GG.22 (bkz. plan dosyası "checkCall gölgeleme-çözümleme düzeltmesi",
// Madde A): `checkCall`nin `.identifier` dalı ÖNCEDEN `ctx.scope.lookup`u
// (yerel değişken/parametre) `self.functions`den SONRA kontrol ediyordu
// — bir yerel func-tipli değişken GERÇEK bir global fonksiyonla AYNI adı
// AMA FARKLI bir imza TAŞIDIĞINDA (`mutate: (int) -> int = other`, global
// `mutate` 2 parametreli, `other` 1 parametreli), checker YANLIŞLIKLA
// global'in imzasına göre doğrulayıp GEÇERLİ bir programı `ArgumentCountMismatch`
// İLE reddediyordu (codegen'in `genCall`ı İSE HER ZAMAN yereli önceliklendirdiği
// İçİn GERÇEKTEN `other`yi ÇAĞIRIRDI — checker/codegen ANLAŞMAZLIĞI).
// Düzeltmeden ÖNCE bu fixture reddedilirdi; düzeltmeden SONRA doğru
// şekilde derlenip `other`yi çağırır (21 * 2 = 42).


// GG.24 (bkz. plan dosyası "genClassRelease'in özyineleme derinliği
// sertleştirmesi"): `MAX_DIRECT_RELEASE_DEPTH`i (200) AŞAN bir sınıf-
// zinciri ÖNCEDEN (worklist YOKKEN) ~7.300 düğümde çökerdi — ARTIK
// `arc.zig`nin derinlik-eşiği worklist'i sayesinde GÜVENLE tamamlanır.


// GG.24: eşiğin ÇOK ALTINDA bir zincir — davranış/çıktı ÖNCEKİYLE
// BİREBİR AYNI kalmalı (doğrudan-çağrı hızlı yolu, SIFIR ek yük).


// GG.24: `genListElemRelease`nin sınıf-dispatch dalı — `list[Node]`nin
// TEK bir elemanının KENDİ derin zinciri.


// GG.24: `nox_rc_release_enqueue_dynamic` yolu — polimorfik (`has_vtable`)
// bir sınıfın derin zinciri.


// GG.24: `exceptions.zig`nin bare-`except:` dispatch dalı — derin bir
// zincir taşıyan bir istisna nesnesi.


// GG.25.1: sıradan, KUYRUK-OLMAYAN bir KULLANICI özyinelemesi (bkz.
// fixture'ın KENDİ belge notu) — Python'un varsayılan özyineleme
// sınırıyla (1000) AYNI derinlikte, `spawn`/`await` İLE fiber'ın
// KENDİ (GÜVENLE 128 KiB'e küçültülüp SONRA 192 KiB'e AYARLANAN)
// yığınında çalıştırılır. STACK_SIZE GELECEKTE tekrar küçültülürse
// BU testin ÇÖKMESİ (SIGBUS/SIGSEGV) o değişikliğin GÜVENLİ olmadığının
// KANITIDIR — GG.24/GG.25'in İLK turunun ÖLÇMEDİĞİ, harici bir
// incelemenin işaret ettiği riski KALICI olarak kapatır.


// Bulundu: `[1, 2,]` gibi sondaki virgüllü bir liste literali (çok satırlı
// VEYA tek satırlı) `parser.zig`nin `.l_bracket` dalında `UnexpectedToken`
// hatasıyla çöküyordu — virgülden SONRA HER ZAMAN yeni bir `parseExpr()`
// bekleniyordu, `]`nin kendisi kontrol edilmiyordu.

