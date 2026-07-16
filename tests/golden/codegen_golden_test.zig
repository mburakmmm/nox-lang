//! Codegen golden testleri: kaynağı gerçekten `qbe` + sistem `cc`'siyle
//! native bir binary'ye derler, çalıştırır ve stdout'unu karşılaştırır.
//! AGENTS.md'nin izin verdiği "kaynak → beklenen davranış" golden test
//! biçimidir (yalnızca IR metni değil, gerçek çalışma zamanı davranışı).
//!
//! Önkoşul: `qbe` ve `cc` sistemde PATH üzerinde bulunmalıdır (bkz. AGENTS.md,
//! Faz 0 karar notları — `brew install qbe`).

const std = @import("std");
const nox = @import("nox");

/// Kaynağı derler, native bir binary üretir ve çalıştırır; ham `RunResult`'ı
/// döner (çıkış kodu/stderr üzerindeki iddialar çağırana bırakılır — normal
/// başarı senaryoları ile "yakalanmamış istisna" senaryosu farklı beklentiler
/// taşır, bkz. `expectGolden` / `expectUncaughtException`).
fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    // `import nox.xxx` deyimlerini çözer (bkz. compiler/module_loader.zig'in
    // belge notu) — golden testler `stdlib/` altındaki GERÇEK dosyaları
    // KULLANICI kodundakiyle AYNI şekilde okur (proje kökünden çalıştırılan
    // `zig build test` varsayımıyla TUTARLI, bkz. bu dosyanın alt satırlarında
    // ZATEN kullanılan `zig-out/lib/noxrt.o` göreli yolu).
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
    checker_state.checkModule(module) catch |e| {
        std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        return error.FixtureNotWellTyped;
    };
    // Faz T.2: kurtarılmış tanılamalar artık FIRLATILMAZ, `diagnostics`e
    // KAYDEDİLİR — bu fixture'ın hatasız derlenmesi BEKLENDİĞİNDEN, herhangi
    // biri VARSA testin (öncekiyle AYNI şekilde) başarısız olması gerekir.
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            std.debug.print("beklenmeyen tip hatasi ({t}): {s}\n", .{ d.code, d.message });
        }
        return error.FixtureNotWellTyped;
    }

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(allocator, k.*);

    // Faz U.4.3: bkz. compiler/main.zig'in AYNI dönüştürme notu.
    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try allocator.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(allocator, entry.key_ptr.*, names);
    }

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, null, closure_infos);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ssa_path = try std.fmt.allocPrint(allocator, "{s}/prog.ssa", .{dir_path});
    const asm_path = try std.fmt.allocPrint(allocator, "{s}/prog.s", .{dir_path});
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/prog", .{dir_path});

    try tmp.dir.writeFile(io, .{ .sub_path = "prog.ssa", .data = ir });

    const qbe_result = try std.process.run(allocator, io, .{
        .argv = &.{ "qbe", "-t", nox.qbe_target.name(), "-o", asm_path, ssa_path },
    });
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz: {s}\n", .{qbe_result.stderr});
        return error.QbeFailed;
    }

    // Faz R.3: `-rdynamic` ZORUNLUDUR — `runtime/stdlib_shims/json.zig`nin
    // `dlsym`i ana programın KENDİ (QBE'nin ürettiği) sembollerini bulmak
    // İÇİN dinamik sembol tablosuna EXPORT edilmelerini gerektirir (bkz.
    // `compiler/main.zig`nin AYNI satırındaki TAM belge notu — Linux'ta
    // BUNUN OLMADAN GERÇEK bir çökme/sızıntı yaşandı).
    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{ "cc", "-rdynamic", "-o", bin_path, asm_path, "zig-out/lib/noxrt.o", "-lm" },
    });
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.CcFailed;
    }

    return std.process.run(allocator, io, .{ .argv = &.{bin_path} });
}

fn expectGolden(comptime source: []const u8, comptime expected: []const u8) !void {
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
fn expectUncaughtException(comptime source: []const u8, comptime expected_stdout: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited == 0) {
        std.debug.print("program beklenenden farklı sonlandı (sıfırdan farklı bir çıkış kodu bekleniyordu)\n", .{});
        return error.ExpectedNonZeroExit;
    }
    try std.testing.expectEqualStrings(expected_stdout, run_result.stdout);
}

test "codegen(çalıştır): fibonacci (özyineleme + while + print)" {
    try expectGolden(
        @embedFile("codegen_cases/fibonacci.nox"),
        @embedFile("codegen_cases/fibonacci.expected"),
    );
}

test "codegen(çalıştır): tam bölme ve mod işaret düzeltmesi (negatif işlenenler)" {
    try expectGolden(
        @embedFile("codegen_cases/floordiv_mod_signs.nox"),
        @embedFile("codegen_cases/floordiv_mod_signs.expected"),
    );
}

test "codegen(çalıştır): üs alma (pow) ve karışık int/float aritmetik" {
    try expectGolden(
        @embedFile("codegen_cases/pow_and_float_mix.nox"),
        @embedFile("codegen_cases/pow_and_float_mix.expected"),
    );
}

test "codegen(çalıştır): bool yazdırma ve mantıksal operatörler" {
    try expectGolden(
        @embedFile("codegen_cases/bool_logic.nox"),
        @embedFile("codegen_cases/bool_logic.expected"),
    );
}

test "codegen(çalıştır): for-range ve if/elif/else" {
    try expectGolden(
        @embedFile("codegen_cases/for_range_and_if.nox"),
        @embedFile("codegen_cases/for_range_and_if.expected"),
    );
}

test "codegen(çalıştır): str parametresi ve yazdırma" {
    try expectGolden(
        @embedFile("codegen_cases/str_param_and_print.nox"),
        @embedFile("codegen_cases/str_param_and_print.expected"),
    );
}

test "codegen(çalıştır): list[int] oluşturma, indeksleme, iterasyon" {
    try expectGolden(
        @embedFile("codegen_cases/list_build_index_iterate.nox"),
        @embedFile("codegen_cases/list_build_index_iterate.expected"),
    );
}

test "codegen(çalıştır): Faz S.2 — list[T] indeksleme sınır dışı erişimde IndexError raise eder" {
    try expectGolden(
        @embedFile("codegen_cases/list_index_out_of_bounds_raises.nox"),
        @embedFile("codegen_cases/list_index_out_of_bounds_raises.expected"),
    );
}

test "codegen(çalıştır): Faz U.1 — list[T].append() büyür VE kapasite yeterliyken alias'lar arasında paylaşılır" {
    try expectGolden(
        @embedFile("codegen_cases/list_append_grows_and_shares.nox"),
        @embedFile("codegen_cases/list_append_grows_and_shares.expected"),
    );
}

test "codegen(çalıştır): Faz U.1 — list[str].append() heap-yönetimli elemanlarla büyümede sızmaz" {
    try expectGolden(
        @embedFile("codegen_cases/list_append_str_elements.nox"),
        @embedFile("codegen_cases/list_append_str_elements.expected"),
    );
}

test "codegen(çalıştır): Faz U.1 — list[T] indeksli atama (xs[i] = v), sınır dışında IndexError raise eder" {
    try expectGolden(
        @embedFile("codegen_cases/list_index_assign_basic.nox"),
        @embedFile("codegen_cases/list_index_assign_basic.expected"),
    );
}

test "codegen(çalıştır): liste yeniden ataması eskisini serbest bırakır (çift serbest bırakma yok)" {
    try expectGolden(
        @embedFile("codegen_cases/list_reassignment_frees_old.nox"),
        @embedFile("codegen_cases/list_reassignment_frees_old.expected"),
    );
}

test "codegen(çalıştır): liste parametre/dönüş/takma ad (ARC ödünç alma + retain)" {
    try expectGolden(
        @embedFile("codegen_cases/list_param_return_alias.nox"),
        @embedFile("codegen_cases/list_param_return_alias.expected"),
    );
}

test "codegen(çalıştır): sınıf — kurucu, metod, alan okuma/yazma, takma ad" {
    try expectGolden(
        @embedFile("codegen_cases/class_point.nox"),
        @embedFile("codegen_cases/class_point.expected"),
    );
}

test "codegen(çalıştır): list[str] (açıkça anotasyonlu, iç içe heap OLMAYAN tip)" {
    try expectGolden(
        @embedFile("codegen_cases/list_str_elements.nox"),
        @embedFile("codegen_cases/list_str_elements.expected"),
    );
}

test "codegen(çalıştır): list[Sınıf] — heap-yönetimli elemanlar, özyinelemeli ARC release (Faz 21 ön-koşulu)" {
    try expectGolden(
        @embedFile("codegen_cases/list_class_elements.nox"),
        @embedFile("codegen_cases/list_class_elements.expected"),
    );
}

test "codegen(çalıştır): list[list[int]] — iç içe liste elemanları, özyinelemeli ARC release" {
    try expectGolden(
        @embedFile("codegen_cases/list_nested_list_elements.nox"),
        @embedFile("codegen_cases/list_nested_list_elements.expected"),
    );
}

test "codegen(çalıştır): raise/try/except/finally — eşleşen tip, eşleşmeyen tip, finally her zaman çalışır" {
    try expectGolden(
        @embedFile("codegen_cases/try_except_finally.nox"),
        @embedFile("codegen_cases/try_except_finally.expected"),
    );
}

test "codegen(çalıştır): yakalanmamış istisna programı sıfırdan farklı bir kodla sonlandırır" {
    try expectUncaughtException(
        @embedFile("codegen_cases/uncaught_exception.nox"),
        @embedFile("codegen_cases/uncaught_exception.expected"),
    );
}

test "codegen(çalıştır): performans fazı — 'raise etmez' analizi, dolaylı (transitif) raise yine de yakalanır" {
    try expectGolden(
        @embedFile("codegen_cases/indirect_raise_propagation.nox"),
        @embedFile("codegen_cases/indirect_raise_propagation.expected"),
    );
}

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
test "codegen(çalıştır): Faz M.8 — closure değişkeni üzerinden çağrılan raise, sessizce YUTULMAZ" {
    try expectGolden(
        @embedFile("codegen_cases/closure_raise_not_swallowed.nox"),
        @embedFile("codegen_cases/closure_raise_not_swallowed.expected"),
    );
}

test "codegen(çalıştır): performans fazı — dolaylı (3 katmanlı) yakalanmamış istisna hâlâ net şekilde sonlanır" {
    try expectUncaughtException(
        @embedFile("codegen_cases/indirect_uncaught_exception.nox"),
        @embedFile("codegen_cases/indirect_uncaught_exception.expected"),
    );
}

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
test "codegen(çalıştır): Faz M.8 — metod-zinciri (self. VE yerel değişken) üzerinden dolaylı raise yine de yakalanır" {
    try expectGolden(
        @embedFile("codegen_cases/method_indirect_raise_propagation.nox"),
        @embedFile("codegen_cases/method_indirect_raise_propagation.expected"),
    );
}

test "codegen(çalıştır): Faz M.8 — metod-zinciri üzerinden dolaylı yakalanmamış istisna hâlâ net şekilde sonlanır" {
    try expectUncaughtException(
        @embedFile("codegen_cases/method_indirect_uncaught_exception.nox"),
        @embedFile("codegen_cases/method_indirect_uncaught_exception.expected"),
    );
}

// Güvenlik testi: `obj` önce `A` sonra (yalnızca `if` dalında) `B` olarak
// YENİDEN bildiriliyor — `checker.zig`nin `Scope.declare`si bunu YASAKLAMAZ
// (bkz. `declareVarType`in belge notu). Bu, `obj`in `var_types`den
// ÇIKARILIP `poisoned`e EKLENMESİNİ tetiklemeli, `obj.get()` çağrısı
// MUHAFAZAKÂR (`direct_unsafe`) kalmalı — davranış (doğru sınıfın `get`i
// çağrılması) BUNDAN HİÇ ETKİLENMEMELİDİR, yalnızca kontrol FAZLADAN kalır.
test "codegen(çalıştır): Faz M.8 — aynı isim farklı sınıflarla yeniden bildirilirse (zehirlenme) davranış doğru kalır" {
    try expectGolden(
        @embedFile("codegen_cases/method_redeclared_var_poisoning.nox"),
        @embedFile("codegen_cases/method_redeclared_var_poisoning.expected"),
    );
}

// Pozitif (GERÇEKTEN elenen) durum: `Adder`in HİÇBİR metodu raise ETMEZ —
// hem `self.inc(x)` (metod içinden) hem `a.double_inc(x)` (yerel değişken
// üzerinden, `use_local` serbest fonksiyonu içinde) çağrıları DOĞRU
// çalışmaya devam eder (davranış değişmedi). IR-metni düzeyinde GERÇEKTEN
// elenmenin gerçekleştiğinin doğrulanması için bkz. aşağıdaki AYRI
// "IR'da nox_exception_pending YOK" testi (aynı fixture'ı KULLANIR).
test "codegen(çalıştır): Faz M.8 — provably-safe metod zinciri (self. VE yerel değişken), davranış değişmedi" {
    try expectGolden(
        @embedFile("codegen_cases/method_call_elision_positive.nox"),
        @embedFile("codegen_cases/method_call_elision_positive.expected"),
    );
}

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
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, null, .empty);
    // `Adder`in ne `__init__`i ne `inc`i ne `double_inc`i HİÇBİR ZAMAN raise
    // ETMEZ (kod içinde tek bir `raise` bile YOK) — bu yüzden bu programın
    // ÜRETTİĞİ IR'da `nox_exception_pending`e TEK bir çağrı bile
    // OLMAMALIDIR (elenmenin GERÇEKTEN gerçekleştiğinin doğrudan kanıtı,
    // yalnızca davranışın değişmediğinin DEĞİL).
    try std.testing.expect(std.mem.indexOf(u8, ir, "nox_exception_pending") == null);
}

test "codegen(çalıştır): lowlevel — arena üzerinden sınıf + liste, alan okuma, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/lowlevel_basic.nox"),
        @embedFile("codegen_cases/lowlevel_basic.expected"),
    );
}

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
    try std.testing.expectError(error.Unsupported, nox.codegen.generateModule(allocator, module, &.{}, &.{}, null, .empty));
}

test "codegen(çalıştır): Faz U.4.3 — iç içe def bir int'i yakalar (capture), inşa+release döngüsü sızıntısız" {
    try expectGolden(
        @embedFile("codegen_cases/nested_def_capture_primitive.nox"),
        @embedFile("codegen_cases/nested_def_capture_primitive.expected"),
    );
}

test "codegen(çalıştır): Faz U.4.3 — iç içe def bir str'i (heap-yönetimli) yakalar, döngü içinde tekrar tekrar inşa+release sızıntısız" {
    try expectGolden(
        @embedFile("codegen_cases/nested_def_capture_heap.nox"),
        @embedFile("codegen_cases/nested_def_capture_heap.expected"),
    );
}

test "codegen(çalıştır): Faz U.4.4 — döndürülen bir closure func-tipli değişkene atanır, DOLAYLI çağrılır (birden çok kez, birden çok somut closure)" {
    try expectGolden(
        @embedFile("codegen_cases/closure_returned_and_called_indirectly.nox"),
        @embedFile("codegen_cases/closure_returned_and_called_indirectly.expected"),
    );
}

test "codegen(çalıştır): Faz U.4.4 — closure func-tipli bir PARAMETRE olarak geçirilir, çağrılanın İÇİNDE dolaylı çağrılır" {
    try expectGolden(
        @embedFile("codegen_cases/closure_passed_as_param_called_indirectly.nox"),
        @embedFile("codegen_cases/closure_passed_as_param_called_indirectly.expected"),
    );
}

test "codegen(çalıştır): Faz U.5 — 'with EXPR as NAME:' temel __enter__/__exit__ akışı" {
    try expectGolden(
        @embedFile("codegen_cases/with_basic_enter_exit.nox"),
        @embedFile("codegen_cases/with_basic_enter_exit.expected"),
    );
}

test "codegen(çalıştır): Faz U.5 — 'with' gövdesi içindeki 'return', __exit__'i BEKLEYİP SONRA dönüş yapar" {
    try expectGolden(
        @embedFile("codegen_cases/with_return_inside_runs_exit.nox"),
        @embedFile("codegen_cases/with_return_inside_runs_exit.expected"),
    );
}

test "codegen(çalıştır): Faz U.5 — 'with' içinde raise edilen istisna DIŞ bir try/except tarafından yakalanır, __exit__ ARADA çalışır" {
    try expectGolden(
        @embedFile("codegen_cases/with_exception_caught_by_outer_try_runs_exit.nox"),
        @embedFile("codegen_cases/with_exception_caught_by_outer_try_runs_exit.expected"),
    );
}

test "codegen(çalıştır): Faz U.5 — heap-yönetimli bir bağlam değeri döngü içinde tekrar tekrar with'lenir, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/with_heap_capture_loop_no_leak.nox"),
        @embedFile("codegen_cases/with_heap_capture_loop_no_leak.expected"),
    );
}

test "codegen(çalıştır): Faz U.5 — 'as NAME' OLMADAN 'with EXPR:' (yalnızca yan etki İÇİN)" {
    try expectGolden(
        @embedFile("codegen_cases/with_no_binding.nox"),
        @embedFile("codegen_cases/with_no_binding.expected"),
    );
}

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
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, null, .empty);
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
    const ir = try nox.codegen.generateModule(allocator, module, &.{}, &.{}, "fibonacci.nox", .empty);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dbgfile \"fibonacci.nox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "dbgloc") != null);
}

test "codegen(çalıştır): except X as e bir döngü içinde yeniden kullanılır — eski istisna sızmaz" {
    try expectGolden(
        @embedFile("codegen_cases/except_bind_reused_in_loop.nox"),
        @embedFile("codegen_cases/except_bind_reused_in_loop.expected"),
    );
}

test "codegen(çalıştır): iç içe sınıf tipli alanlar — inşa, zincirleme okuma, yeniden atama, passthrough, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/nested_class_fields.nox"),
        @embedFile("codegen_cases/nested_class_fields.expected"),
    );
}

test "codegen(çalıştır): bir döngü içindeki '%' yığın taşmasına yol açmaz (milyonlarca yineleme)" {
    try expectGolden(
        @embedFile("codegen_cases/mod_in_loop_no_stack_growth.nox"),
        @embedFile("codegen_cases/mod_in_loop_no_stack_growth.expected"),
    );
}

test "codegen(çalıştır): bir döngü içine gömülü 'for ... in list' yığın taşmasına yol açmaz" {
    try expectGolden(
        @embedFile("codegen_cases/nested_forlist_no_stack_growth.nox"),
        @embedFile("codegen_cases/nested_forlist_no_stack_growth.expected"),
    );
}

test "codegen(çalıştır): bir döngü içindeki list[T]/sınıf '==' yığın taşmasına yol açmaz (milyonlarca yineleme)" {
    try expectGolden(
        @embedFile("codegen_cases/deep_equality_in_loop_no_stack_growth.nox"),
        @embedFile("codegen_cases/deep_equality_in_loop_no_stack_growth.expected"),
    );
}

test "codegen(çalıştır): zincirlenmiş alan okuması bir çağrı sonucu üzerinde — ara nesne sızmaz" {
    try expectGolden(
        @embedFile("codegen_cases/chained_attr_temporary_release.nox"),
        @embedFile("codegen_cases/chained_attr_temporary_release.expected"),
    );
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

test "codegen(çalıştır): list[T] tipli bir sınıf alanı — inşa, takma ad, passthrough, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/list_class_field.nox"),
        @embedFile("codegen_cases/list_class_field.expected"),
    );
}

test "codegen(çalıştır): TAZE olmayan bir tabandan alan/indeks okuması yeni bir yerele atanınca retain edilir" {
    try expectGolden(
        @embedFile("codegen_cases/attr_index_read_into_local_retain.nox"),
        @embedFile("codegen_cases/attr_index_read_into_local_retain.expected"),
    );
}

test "codegen(çalıştır): generic fonksiyonlar — birden çok somut tip, list[T], sınıf argümanı, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/generic_functions.nox"),
        @embedFile("codegen_cases/generic_functions.expected"),
    );
}

test "codegen(çalıştır): yapısal protokol — iki farklı sınıf, monomorphize edilmiş dispatch, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/protocol_dispatch.nox"),
        @embedFile("codegen_cases/protocol_dispatch.expected"),
    );
}

test "codegen(çalıştır): wasm_call — gerçek bir .nox programından gerçek bir WASM modülü çağrılır" {
    try expectGolden(
        @embedFile("codegen_cases/wasm_call_builtin.nox"),
        @embedFile("codegen_cases/wasm_call_builtin.expected"),
    );
}

test "codegen(çalıştır): async — spawn + await, i64 payload, sızıntı yok (Faz 21 aşama 4)" {
    try expectGolden(
        @embedFile("codegen_cases/async_spawn_await.nox"),
        @embedFile("codegen_cases/async_spawn_await.expected"),
    );
}

test "codegen(çalıştır): async — Channel[T] (rendezvous) iki görev arasında, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/async_channel.nox"),
        @embedFile("codegen_cases/async_channel.expected"),
    );
}

test "codegen(çalıştır): Faz BB.4 — nox.thread.start/ThreadHandle[int]/.join(), gerçek OS iş parçacığı, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/thread_spawn_join_int.nox"),
        @embedFile("codegen_cases/thread_spawn_join_int.expected"),
    );
}

test "codegen(çalıştır): Faz BB.4 — nox.thread.start/ThreadHandle[str]/.join(), çapraz-iş-parçacığı str transferi, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/thread_spawn_join_str.nox"),
        @embedFile("codegen_cases/thread_spawn_join_str.expected"),
    );
}

test "codegen(çalıştır): Faz BB.4 — ThreadHandle.join() fiber-farkında askıya alır, ebeveynin DİĞER fiber'ı ilerlemeye devam eder" {
    try expectGolden(
        @embedFile("codegen_cases/thread_spawn_ordering.nox"),
        @embedFile("codegen_cases/thread_spawn_ordering.expected"),
    );
}

test "codegen(çalıştır): Faz BB.4 — join edilmeden scope'tan çıkan ThreadHandle (fire-and-forget), sızıntı/UAF yok" {
    try expectGolden(
        @embedFile("codegen_cases/thread_spawn_detached_leak.nox"),
        @embedFile("codegen_cases/thread_spawn_detached_leak.expected"),
    );
}

test "codegen(çalıştır): Faz BB.6 — ThreadChannel[int], iki gerçek OS iş parçacığı arasında, tamponlu (kapasite 2)" {
    try expectGolden(
        @embedFile("codegen_cases/thread_channel_int.nox"),
        @embedFile("codegen_cases/thread_channel_int.expected"),
    );
}

test "codegen(çalıştır): Faz BB.6 — ThreadChannel[str], çapraz-iş-parçacığı str transferi, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/thread_channel_str.nox"),
        @embedFile("codegen_cases/thread_channel_str.expected"),
    );
}

test "codegen(çalıştır): Faz BB.6 — ThreadChannel[int] geri basınç (kapasite 1, 20 değer), tam boru hattından, sıra/kayıp yok" {
    try expectGolden(
        @embedFile("codegen_cases/thread_channel_backpressure.nox"),
        @embedFile("codegen_cases/thread_channel_backpressure.expected"),
    );
}

test "codegen(çalıştır): Faz S.1 — Task[T] yeniden ataması, ilk görev await edilmeden önce, sızıntı/UAF yok" {
    try expectGolden(
        @embedFile("codegen_cases/task_reassignment_frees_old.nox"),
        @embedFile("codegen_cases/task_reassignment_frees_old.expected"),
    );
}

test "codegen(çalıştır): Faz S.1 — Channel[T] yeniden ataması, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/channel_reassignment_frees_old.nox"),
        @embedFile("codegen_cases/channel_reassignment_frees_old.expected"),
    );
}

test "codegen(çalıştır): async — kasıtlı deadlock, net hatayla sonlanır (asılı KALMAZ)" {
    try expectUncaughtException(
        @embedFile("codegen_cases/async_deadlock.nox"),
        @embedFile("codegen_cases/async_deadlock.expected"),
    );
}

test "codegen(çalıştır): __init__ içermeyen sınıf (alansız, yalnızca metod)" {
    try expectGolden(
        @embedFile("codegen_cases/class_no_init.nox"),
        @embedFile("codegen_cases/class_no_init.expected"),
    );
}

test "codegen(çalıştır): Faz S.3 — gerçek A<->B sınıf referans döngüsü, Katman 3 sızmadan toplar" {
    try expectGolden(
        @embedFile("codegen_cases/class_reference_cycle_collected.nox"),
        @embedFile("codegen_cases/class_reference_cycle_collected.expected"),
    );
}

test "codegen(çalıştır): 'obj.attr = değer' ataması self dışından — değer tipli VE sınıf tipli alan, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/attr_assign_external.nox"),
        @embedFile("codegen_cases/attr_assign_external.expected"),
    );
}

test "codegen(çalıştır): str == str / != — gerçek içerik karşılaştırması (strcmp), işaretçi karşılaştırması DEĞİL" {
    try expectGolden(
        @embedFile("codegen_cases/str_equality.nox"),
        @embedFile("codegen_cases/str_equality.expected"),
    );
}

test "codegen(çalıştır): list[T]/sınıf için derin yapısal == / != — int/str/iç içe liste/sınıf/list[sınıf], sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/deep_equality.nox"),
        @embedFile("codegen_cases/deep_equality.expected"),
    );
}

test "codegen(çalıştır): print(list)/print(sınıf) — Python benzeri görüntüleme, iç içe, sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/print_list_class.nox"),
        @embedFile("codegen_cases/print_list_class.expected"),
    );
}

test "codegen(çalıştır): import nox.testmod — nitelikli fonksiyon/sınıf çağrıları, iç modül içi çapraz-başvurular" {
    try expectGolden(
        @embedFile("codegen_cases/import_basic.nox"),
        @embedFile("codegen_cases/import_basic.expected"),
    );
}

test "codegen(çalıştır): import nox.testmod — kullanıcının aynı adlı KENDİ fonksiyonuyla ÇAKIŞMAZ" {
    try expectGolden(
        @embedFile("codegen_cases/import_name_collision.nox"),
        @embedFile("codegen_cases/import_name_collision.expected"),
    );
}

test "codegen(çalıştır): Faz U.3 — import nox.testmod as tm (takma ad üzerinden nitelikli çağrı)" {
    try expectGolden(
        @embedFile("codegen_cases/import_as_alias.nox"),
        @embedFile("codegen_cases/import_as_alias.expected"),
    );
}

test "codegen(çalıştır): Faz U.3 — from nox.testmod import double/quadruple as quad (çıplak çağrı)" {
    try expectGolden(
        @embedFile("codegen_cases/from_import_basic.nox"),
        @embedFile("codegen_cases/from_import_basic.expected"),
    );
}

test "codegen(çalıştır): Faz U.3 — from import ile gelen isim, KULLANICININ yerel tanımıyla GÖLGELENİR" {
    try expectGolden(
        @embedFile("codegen_cases/from_import_shadowed_by_local.nox"),
        @embedFile("codegen_cases/from_import_shadowed_by_local.expected"),
    );
}

test "codegen(çalıştır): str + str birleştirme (zincirleme) + len(), sızıntı yok" {
    try expectGolden(
        @embedFile("codegen_cases/str_concat_basic.nox"),
        @embedFile("codegen_cases/str_concat_basic.expected"),
    );
}

test "codegen(çalıştır): str yeniden ataması eskisini serbest bırakır (çift serbest bırakma yok)" {
    try expectGolden(
        @embedFile("codegen_cases/str_concat_reassignment_frees_old.nox"),
        @embedFile("codegen_cases/str_concat_reassignment_frees_old.expected"),
    );
}

test "codegen(çalıştır): len(str) — literal ve değişken üzerinde" {
    try expectGolden(
        @embedFile("codegen_cases/str_len.nox"),
        @embedFile("codegen_cases/str_len.expected"),
    );
}

test "codegen(çalıştır): dict[int, int] — literal, indeksleme, contains/len, üzerine yazma" {
    try expectGolden(
        @embedFile("codegen_cases/dict_int_key_basic.nox"),
        @embedFile("codegen_cases/dict_int_key_basic.expected"),
    );
}

test "codegen(çalıştır): dict[str, int] — anahtar İÇERİK eşitliğiyle bulunur (pointer eşitliği DEĞİL)" {
    try expectGolden(
        @embedFile("codegen_cases/dict_str_key_basic.nox"),
        @embedFile("codegen_cases/dict_str_key_basic.expected"),
    );
}

test "codegen(çalıştır): dict[str, str] — str anahtar/değer ARC doğruluğu (üzerine yazma eskiyi serbest bırakır, sızıntı yok)" {
    try expectGolden(
        @embedFile("codegen_cases/dict_str_key_str_value_arc.nox"),
        @embedFile("codegen_cases/dict_str_key_str_value_arc.expected"),
    );
}

test "codegen(çalıştır): Faz S.1 — dict[K,V] DEĞİŞKENİNİN yeniden ataması eskisini serbest bırakır (sızıntı yok)" {
    try expectGolden(
        @embedFile("codegen_cases/dict_reassignment_frees_old.nox"),
        @embedFile("codegen_cases/dict_reassignment_frees_old.expected"),
    );
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
test "codegen(çalıştır): Faz FF.3 — dict[K,V] sınıf alanı, kaynak yerelden UZUN YAŞAR (sallanan işaretçi YOK)" {
    try expectGolden(
        @embedFile("codegen_cases/dict_field_outlives_local_no_dangling.nox"),
        @embedFile("codegen_cases/dict_field_outlives_local_no_dangling.expected"),
    );
}

// Faz FF.3'ün POZİTİF kanıtı: AYNI `dict` KENDİ adlandırılmış yereli
// (`shared`) HÂLÂ kapsam İÇİNDEYKEN İKİ AYRI sınıf örneğine (`a.data`/
// `b.data`) PAYLAŞTIRILIYor — HER ÜÇ sahibin de (yerel + iki alan)
// BİRBİRİNDEN BAĞIMSIZ, doğru DEĞERİ okuyabildiğini VE (Zig testlerindeki
// DebugAllocator'ın hiçbir sızıntı/çift-serbest-bırakma raporlamadığı,
// bkz. `zig build test`) retain/release SAYACININ tam DENGEDE olduğunu
// kanıtlar — `dict`in ARTIK `str`/`list`/`class` İLE AYNI, PAYLAŞIM-
// GÜVENLİ ARC modelinde OLDUĞUNUN pozitif göstergesi.
test "codegen(çalıştır): Faz FF.3 — dict[K,V] İKİ AYRI sınıf örneğine + kaynak yerele PAYLAŞILIR (retain/release dengede)" {
    try expectGolden(
        @embedFile("codegen_cases/dict_shared_across_two_class_instances.nox"),
        @embedFile("codegen_cases/dict_shared_across_two_class_instances.expected"),
    );
}

// Faz FF.4 (bkz. nox-teknik-spesifikasyon.md §3.63): çıplak `self`li bir
// metodun (`bump`) bir ALANI GERÇEKTEN okuyup/YAZDIĞI uçtan uca kanıt —
// codegen'in çıplak self İÇİN GERÇEKTEN sıfır değişiklik gerektirdiğinin
// (self'in tipi ZATEN `class_name`den BAĞIMSIZ türetiliyor) DOĞRULANMASI,
// yalnızca DERLENDİĞİNİN DEĞİL.
test "codegen(çalıştır): Faz FF.4 — çıplak self'li metod bir alanı GERÇEKTEN okur/yazar" {
    try expectGolden(
        @embedFile("codegen_cases/bare_self_method_field_mutation.nox"),
        @embedFile("codegen_cases/bare_self_method_field_mutation.expected"),
    );
}

test "codegen(çalıştır): str(int)/int(str) roundtrip" {
    try expectGolden(
        @embedFile("codegen_cases/str_int_roundtrip.nox"),
        @embedFile("codegen_cases/str_int_roundtrip.expected"),
    );
}

test "codegen(çalıştır): str(float)/float(str) roundtrip" {
    try expectGolden(
        @embedFile("codegen_cases/str_float_roundtrip.nox"),
        @embedFile("codegen_cases/str_float_roundtrip.expected"),
    );
}

test "codegen(çalıştır): int(s)/float(s) geçersiz girdide ValueError raise eder, try/except yakalar" {
    try expectGolden(
        @embedFile("codegen_cases/int_parse_error_raises.nox"),
        @embedFile("codegen_cases/int_parse_error_raises.expected"),
    );
}

test "codegen(çalıştır): str indeksleme s[i] — adlandırılmış/temporary taban, yeniden atama (sızıntı yok)" {
    try expectGolden(
        @embedFile("codegen_cases/str_index_basic.nox"),
        @embedFile("codegen_cases/str_index_basic.expected"),
    );
}

test "codegen(çalıştır): str indeksleme sınır dışı erişimde IndexError raise eder" {
    try expectGolden(
        @embedFile("codegen_cases/str_index_out_of_bounds_raises.nox"),
        @embedFile("codegen_cases/str_index_out_of_bounds_raises.expected"),
    );
}

test "codegen(çalıştır): nox.strings.split/join" {
    try expectGolden(
        @embedFile("codegen_cases/strings_split_join.nox"),
        @embedFile("codegen_cases/strings_split_join.expected"),
    );
}

test "codegen(çalıştır): nox.strings.trim/upper/lower/replace" {
    try expectGolden(
        @embedFile("codegen_cases/strings_case_trim_replace.nox"),
        @embedFile("codegen_cases/strings_case_trim_replace.expected"),
    );
}

test "codegen(çalıştır): nox.strings.starts_with/ends_with/contains/index_of (str[i] karşılaştırma sızıntısı yok)" {
    try expectGolden(
        @embedFile("codegen_cases/strings_search.nox"),
        @embedFile("codegen_cases/strings_search.expected"),
    );
}

// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): `list[int]`/`list[str]`/
// `list[float]`in HER ÜÇÜ İçin `nox_list_sort_int`/`_str`/`_float`
// dispatch'inin (`elem_qtype`/`elem_is_str`e göre) doğru fonksiyona
// yönlendirdiğini kanıtlar.
test "codegen(çalıştır): list[T].sort() — int/str/float elemanlar" {
    try expectGolden(
        @embedFile("codegen_cases/list_sort.nox"),
        @embedFile("codegen_cases/list_sort.expected"),
    );
}

test "codegen(çalıştır): nox.math — sqrt/pow/floor/ceil (çıplak) + min/max/abs (nitelikli)" {
    try expectGolden(
        @embedFile("codegen_cases/math_basic.nox"),
        @embedFile("codegen_cases/math_basic.expected"),
    );
}

test "codegen(çalıştır): nox.os.arg_count/arg (argc/argv $main'e taşınmış)" {
    try expectGolden(
        @embedFile("codegen_cases/os_args_basic.nox"),
        @embedFile("codegen_cases/os_args_basic.expected"),
    );
}

test "codegen(çalıştır): nox.os.getenv eksik değişken OsError raise eder" {
    try expectGolden(
        @embedFile("codegen_cases/os_getenv_missing_raises.nox"),
        @embedFile("codegen_cases/os_getenv_missing_raises.expected"),
    );
}

test "codegen(çalıştır): nox.fs.write_string/read_to_string round-trip" {
    try expectGolden(
        @embedFile("codegen_cases/fs_read_write_roundtrip.nox"),
        @embedFile("codegen_cases/fs_read_write_roundtrip.expected"),
    );
}

test "codegen(çalıştır): nox.fs.read_to_string eksik dosya FsError raise eder" {
    try expectGolden(
        @embedFile("codegen_cases/fs_read_missing_raises.nox"),
        @embedFile("codegen_cases/fs_read_missing_raises.expected"),
    );
}

// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61): `exists`/`is_file`/
// `is_dir` HİÇBİR ZAMAN `raise` ETMEZ (`read_to_string`in AKSİNE) — var
// olan/olmayan bir dosya VE bir dizin ÜZERİNDE ÜÇÜNÜN de doğru sonuç
// döndürdüğünü kanıtlar.
test "codegen(çalıştır): nox.fs.exists/is_file/is_dir — raise ETMEDEN sorgu" {
    try expectGolden(
        @embedFile("codegen_cases/fs_exists_queries.nox"),
        @embedFile("codegen_cases/fs_exists_queries.expected"),
    );
}

// Faz EE.1: YENİ `nox.path` modülü — saf string manipülasyonu, hiçbir I/O
// yok, hiçbir fonksiyon raise etmez.
test "codegen(çalıştır): nox.path.join/basename/dirname/extension/is_absolute" {
    try expectGolden(
        @embedFile("codegen_cases/path_manipulation.nox"),
        @embedFile("codegen_cases/path_manipulation.expected"),
    );
}

test "codegen(çalıştır): nox.time.now_ms/sleep_ms (monoton artış)" {
    try expectGolden(
        @embedFile("codegen_cases/time_now_monotonic_increases.nox"),
        @embedFile("codegen_cases/time_now_monotonic_increases.expected"),
    );
}

test "codegen(çalıştır): nox.log.format — seviye etiketi + zaman damgası + mesaj yapısı (nox.strings ile deterministik doğrulama)" {
    try expectGolden(
        @embedFile("codegen_cases/log_format_structure.nox"),
        @embedFile("codegen_cases/log_format_structure.expected"),
    );
}

test "codegen(çalıştır): nox.random.seed/randint/random — aralık sınırları + aynı tohumla deterministik tekrar" {
    try expectGolden(
        @embedFile("codegen_cases/random_seeded_reproducible.nox"),
        @embedFile("codegen_cases/random_seeded_reproducible.expected"),
    );
}

test "codegen(çalıştır): nox.crypto.sha256 — bilinen test vektörleri (\"\"/\"abc\")" {
    try expectGolden(
        @embedFile("codegen_cases/crypto_sha256_known_vectors.nox"),
        @embedFile("codegen_cases/crypto_sha256_known_vectors.expected"),
    );
}

test "codegen(çalıştır): nox.time.DateTime — bilinen epoch-ms'in doğru takvim bileşenlerine ayrıştırılması" {
    try expectGolden(
        @embedFile("codegen_cases/time_datetime_from_epoch_ms.nox"),
        @embedFile("codegen_cases/time_datetime_from_epoch_ms.expected"),
    );
}

test "codegen(çalıştır): nox.test.TestSuite — check_* HİÇ raise ETMEZ (setup/teardown HER ZAMAN çalışır) + JUnit XML raporu" {
    try expectGolden(
        @embedFile("codegen_cases/test_suite_setup_teardown_junit.nox"),
        @embedFile("codegen_cases/test_suite_setup_teardown_junit.expected"),
    );
}

test "codegen(çalıştır): nox.regex.is_match/find — temel alt küme (karakter sınıfları, */+/?, ^/$)" {
    try expectGolden(
        @embedFile("codegen_cases/regex_basic_patterns.nox"),
        @embedFile("codegen_cases/regex_basic_patterns.expected"),
    );
}

test "codegen(çalıştır): nox.test.assert_eq_*/assert_true (başarılı yol)" {
    try expectGolden(
        @embedFile("codegen_cases/test_assert_eq_pass.nox"),
        @embedFile("codegen_cases/test_assert_eq_pass.expected"),
    );
}

test "codegen(çalıştır): nox.test.assert_eq_int başarısız olursa AssertionError raise eder" {
    try expectGolden(
        @embedFile("codegen_cases/test_assert_eq_fail_raises.nox"),
        @embedFile("codegen_cases/test_assert_eq_fail_raises.expected"),
    );
}

test "codegen(çalıştır): nox.json.decode — iç içe dizi/obje, sayı/string/bool/null karışık" {
    try expectGolden(
        @embedFile("codegen_cases/json_decode_nested.nox"),
        @embedFile("codegen_cases/json_decode_nested.expected"),
    );
}

test "codegen(çalıştır): nox.json — decode/encode round-trip" {
    try expectGolden(
        @embedFile("codegen_cases/json_encode_roundtrip.nox"),
        @embedFile("codegen_cases/json_encode_roundtrip.expected"),
    );
}

test "codegen(çalıştır): nox.json.decode bozuk JSON JsonError raise eder" {
    try expectGolden(
        @embedFile("codegen_cases/json_decode_malformed_raises.nox"),
        @embedFile("codegen_cases/json_decode_malformed_raises.expected"),
    );
}
