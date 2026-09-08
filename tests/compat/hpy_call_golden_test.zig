//! Faz 14: `hpy_call` yerleşiğinin GERÇEK bir .nox programından derlenmiş
//! bir native ikiliye, ve o ikilinin çalışma zamanında GERÇEK bir HPy
//! eklentisini (`tests/compat/hpy_ext/noxtest.so`) yükleyip çağırdığını
//! doğrular. `tests/golden/codegen_golden_test.zig`e (her zaman çalışan ana
//! takıma) KASITLI OLARAK eklenmedi — bu, `.hpy-venv` kurulu olmayanlarda
//! ana takımı kırardı (bkz. build.zig, Faz 12'nin "sessizce atlanır"
//! ilkesi). Bu dosya yalnızca `noxtest.so` derlendiğinde koşullu olarak
//! test takımına eklenir.
//!
//! `compileAndRun`/`expectGolden`, `tests/golden/codegen_golden_test.zig`
//! ile AYNI yapıdadır (kasıtlı bir kod tekrarı — bu dosyanın koşullu
//! olması, paylaşılan bir yardımcıyı build.zig'de ayrıca koşullu hale
//! getirmekten daha basit).

const std = @import("std");
const nox = @import("nox");

fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    // Faz 18 (bkz. plan dosyası "HPy köprüsünü Nox'un istisna mekanizmasına
    // entegre etme"): `emitHpyErrorCheckOrRaise` HER `hpy_*` çağrısından
    // SONRA `self.classes.get("HPyError")`ı (bir `nox.core` yerleşiği,
    // bkz. `stdlib/nox/core.nox`) ARAR — `codegen_golden_test.zig`nin
    // `str_index_loop_licm_positive` testindeki AYNI `IndexError` notuyla
    // TUTARLI: `resolveImports` ÇAĞRILMAZSA `self.classes` BOŞ kalır,
    // `error.Unsupported` fırlar (BU dosyanın 9 MEVCUT testi ÖNCEDEN
    // HİÇBİR core.nox sınıfına İHTİYAÇ DUYMADIĞINDAN bu adım HİÇ
    // GEREKMEMİŞTİ).
    const module = try nox.module_loader.resolveImports(allocator, std.testing.io, user_module);

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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, &.{}, &.{}, null, .empty, .empty, .empty, &.{}, .empty, checker_state.decorated_functions.items, .qbe, null);

    const io = std.testing.io;

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

    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{ "cc", "-rdynamic", "-o", bin_path, asm_path, "zig-out/lib/noxrt.o", "-lm" },
    });
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.CcFailed;
    }

    return std.process.run(allocator, io, .{ .argv = &.{bin_path} });
}

fn expectGolden(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    if (run_result.stderr.len != 0) {
        std.debug.print("program stderr'e beklenmeyen bir çıktı yazdı (olası bellek sızıntısı): {s}\n", .{run_result.stderr});
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings(expected, run_result.stdout);
}

/// Faz 19: `expectGolden`nin AYNISI, YALNIZCA `stderr`i KONTROL ETMEYEN
/// varyantı — `ctxTypeFromSpec` (context.zig) İNŞA ETTİĞİ `.type_` etiketli
/// `Obj`i (VE onun `type_name`sini) BİLİNÇLİ olarak KALICI/ÖLÜMSÜZ SAYAR
/// (GERÇEK Python'un KENDİ tip nesnelerinin de tipik olarak SÜRECİN
/// SONUNA kadar YAŞAMASIYLA TUTARLI) — `noxtest.c`nin `make_counter`ı
/// (Faz 19'un test C fonksiyonu) `Counter_type`i BİR KEZ hesaplayıp
/// KENDİ `static` C global'inde SONSUZA KADAR önbelleğe alır, `ctx_Close`ü
/// HİÇ ÇAĞIRMAZ — `tests/compat/hpy_tier0_test.zig`nin KENDİ, ZATEN kabul
/// ettiği "tip nesneleri BİLİNÇLİ olarak sızıyor" v1 ödünleşimiyle TUTARLI
/// (o dosya BUNU `page_allocator` İLE, leak-tespit eden allocator'ı
/// TAMAMEN ATLAYARAK gizler — BURADA GERÇEK bir derlenmiş ikili+GERÇEK
/// `RuntimeState` allocator'ı KULLANILDIĞINDAN AYNI atlama YAPILAMAZ,
/// bu YÜZDEN `stderr` KONTROLÜ BİLİNÇLİ olarak ATLANIR). Bu, HER `hpy_call_
/// obj_on`+`HPyType_FromSpec` çağrısı İçİn DEĞİL — SADECE TİP KAYDININ
/// KENDİSİ İçİn (ÖRNEK YARATMA/YIKMA DEĞİL) geçerli, BOUNDED (tip-sayısı
/// KADAR, ÇAĞRI-sayısı KADAR DEĞİL) bir sızıntı.
fn expectGoldenAllowTypeLeak(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const run_result = try compileAndRun(arena.allocator(), source);
    if (run_result.term != .exited or run_result.term.exited != 0) {
        std.debug.print("program basarisiz cikti (stderr): {s}\n", .{run_result.stderr});
        return error.ProgramFailed;
    }
    try std.testing.expectEqualStrings(expected, run_result.stdout);
}

test "hpy_call: gerçek bir .nox programından gerçek bir HPy eklentisi çağrılır" {
    try expectGolden(
        \\print(hpy_call("tests/compat/hpy_ext/noxtest.so", "noxtest", "add_one", 41))
        \\
    ,
        "42\n",
    );
}

// Faz 15 (bkz. nox-teknik-spesifikasyon.md §3.78): `hpy_call`in yalnızca-
// `str` kardeşi — `HPyFunc_KEYWORDS` imzalı (`ujson_hpy.dumps`/`loads` İLE
// AYNI imza sınıfı) bir metodu POZİSYONEL-TEK-ARGÜMAN olarak çağırır.
// `upper_str_via_c` (bkz. `tests/compat/hpy_ext/noxtest.c`) bu imzayla
// KAYITLI, tam olarak bu deseni doğrulamak İçin eklendi.
test "hpy_call_str: HPyFunc_KEYWORDS imzalı bir HPy metodu str argüman/dönüşle çağrılır" {
    try expectGolden(
        \\print(hpy_call_str("tests/compat/hpy_ext/noxtest.so", "noxtest", "upper_str_via_c", "merhaba dunya"))
        \\
    ,
        "MERHABA DUNYA\n",
    );
}

// Faz 16 (bkz. plan dosyası "hpy_call'e kalıcı modül+context"): `hpy_open`
// BİR KEZ açar, `hpy_call_on` AYNI tutamaçla ÜÇ KEZ çağrılır — `noxtest.c`nin
// `get_call_count`i HER çağrıda ARTAN bir `static` C global'i döndürdüğünden
// (bkz. onun modül üstü belge notu), `1`/`2`/`3` basılması `hpy_call_on`nin
// modülü/context'i YENİDEN YÜKLEMEDİĞİNİN (paylaşımlı kütüphane YENİDEN
// eşlenirse `static` global SIFIRLANIRDI) SOMUT kanıtıdır.
test "hpy_open/hpy_call_on: kalıcı tutamaç, ardışık çağrılar modül-seviyeli durumu KORUR" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\print(hpy_call_on(h, "get_call_count", 0))
        \\print(hpy_call_on(h, "get_call_count", 0))
        \\print(hpy_call_on(h, "get_call_count", 0))
        \\hpy_close(h)
        \\
    ,
        "1\n2\n3\n",
    );
}

test "hpy_call_str_on: kalıcı tutamaçla HPyFunc_KEYWORDS imzalı bir metod str argüman/dönüşle çağrılır" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\print(hpy_call_str_on(h, "upper_str_via_c", "merhaba dunya"))
        \\hpy_close(h)
        \\
    ,
        "MERHABA DUNYA\n",
    );
}

// Faz 17 (bkz. plan dosyası "kalıcı tutamaçlı HPy çağrılarına çoklu-
// argüman + list/dict/class marshalling"): `hpy_call_on`/`hpy_call_str_on`
// ARTIK SIFIR VEYA DAHA FAZLA, HETEROJEN tipli (int/float/bool/str/
// list[T]/dict[K,V]/class) trailing argüman kabul eder.
test "hpy_call_on: iki int argümanla çoklu-argüman çağrısı" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\print(hpy_call_on(h, "sum_two_ints", 3, 4))
        \\hpy_close(h)
        \\
    ,
        "7\n",
    );
}

test "hpy_call_str_on: üç str argümanla çoklu-argüman çağrısı" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\print(hpy_call_str_on(h, "concat_three_strs", "a", "b", "c"))
        \\hpy_close(h)
        \\
    ,
        "abc\n",
    );
}

test "hpy_call_on: list[int] argüman marshalling'i" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\xs: list[int] = [1, 2, 3, 4]
        \\print(hpy_call_on(h, "sum_list_of_ints", xs))
        \\hpy_close(h)
        \\
    ,
        "10\n",
    );
}

test "hpy_call_on: dict[str,int] argüman marshalling'i" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\d: dict[str, int] = {"a": 1, "b": 2}
        \\print(hpy_call_on(h, "dict_value_sum", d))
        \\hpy_close(h)
        \\
    ,
        "3\n",
    );
}

test "hpy_call_on: class örneği alan-adı->değer HPy dict'i olarak (surrogate) marshal edilir" {
    try expectGolden(
        \\class Point:
        \\    def __init__(self: Point, x: int, y: int) -> None:
        \\        self.x = x
        \\        self.y = y
        \\
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\p: Point = Point(3, 4)
        \\print(hpy_call_on(h, "class_field_sum", p))
        \\hpy_close(h)
        \\
    ,
        "7\n",
    );
}

// Faz 18 (bkz. plan dosyası "HPy köprüsünü Nox'un istisna mekanizmasına
// entegre etme"): `hpy_*`nin TÜM hata durumları ARTIK GERÇEK bir `HPyError`
// (bkz. `stdlib/nox/core.nox`) raise eder — `try`/`except HPyError as e:`
// İLE yakalanabilir.
test "hpy_open: olmayan bir dosya yolu HPyError raise eder" {
    try expectGolden(
        \\try:
        \\    h: ptr = hpy_open("tests/compat/hpy_ext/olmayan_dosya.so", "noxtest")
        \\    print("hata yakalanmadi")
        \\except HPyError as e:
        \\    print("yakalandi")
        \\
    ,
        "yakalandi\n",
    );
}

test "hpy_call_on: olmayan bir fonksiyon adı HPyError raise eder" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\try:
        \\    print(hpy_call_on(h, "olmayan_fonksiyon", 1))
        \\except HPyError as e:
        \\    print("yakalandi")
        \\hpy_close(h)
        \\
    ,
        "yakalandi\n",
    );
}

test "hpy_call_on: çağrılan HPy C fonksiyonunun KENDİSİ bir istisna fırlattığında HPyError raise eder" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\try:
        \\    print(hpy_call_on(h, "raise_value_error", 5))
        \\except HPyError as e:
        \\    print("yakalandi")
        \\hpy_close(h)
        \\
    ,
        "yakalandi\n",
    );
}

// Faz 19 (bkz. plan dosyası "opak HPy nesne tutamaçları"): `hpy_call_obj_on`
// `HPyType_FromSpec` İLE tanımlanmış bir C eklenti tipinin (`Counter`,
// bkz. `noxtest.c`) ÖRNEĞİNE OPAK bir tutamaç döner — bu tutamaç BAŞKA
// bir `hpy_call_on` çağrısına (C eklentisinin KENDİ "getter" fonksiyonu,
// `get_counter_x`) argüman olarak GERİ geçirilebilir (round-trip KANITI).
test "hpy_call_obj_on: opak Counter tutamacı round-trip (make_counter -> get_counter_x)" {
    try expectGoldenAllowTypeLeak(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\c: ptr = hpy_call_obj_on(h, "make_counter", 5)
        \\print(hpy_call_on(h, "get_counter_x", c))
        \\hpy_close_obj(h, c)
        \\hpy_close(h)
        \\
    ,
        "5\n",
    );
}

// Faz 19: `hpy_close_obj`nin GERÇEKTEN C eklentisinin KENDİ `tp_destroy`
// slot'unu tetiklediğinin kanıtı (`get_destroy_count`, `Counter_destroy`nin
// artırdığı `static` sayacı döner — TAZE bir modül yüklemesinde 0'dan
// başlar).
test "hpy_close_obj: Counter_destroy (tp_destroy) GERÇEKTEN tetiklenir" {
    try expectGoldenAllowTypeLeak(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\c: ptr = hpy_call_obj_on(h, "make_counter", 1)
        \\hpy_close_obj(h, c)
        \\print(hpy_call_on(h, "get_destroy_count", 0))
        \\hpy_close(h)
        \\
    ,
        "1\n",
    );
}

// Faz 20 (bkz. plan dosyası "HPy modül nesnesi + HPy_mod_exec desteği"):
// GERÇEK Cython-üretimi kod (aHPy `hpy-universal` arka ucu), import
// anındaki `HPy_mod_exec` slot'unu, derleme-zamanı sabitlerini `self`
// (modülün KENDİ nesnesi) üzerinde `HPy_SetAttr_s` İLE yazmak İçİn
// kullanır — `module_exec_marker`/`get_faz20_marker` (bkz. `noxtest.c`)
// TAM OLARAK bu deseni taklit eder. HEM kalıcı-tutamaç yolu (`hpy_open`+
// `hpy_call_on`) HEM ESKİ tek-seferlik yol (`hpy_call`) İçİn AYRI testler
// — `nox_hpy_open`/`nox_hpy_call`/`nox_hpy_call_str`nin ÜÇÜ de ARTIK
// `setupModuleObject`i çağırıp `HPy_mod_exec`i ÇALIŞTIRIR.
test "hpy_call_on: kalıcı tutamaç yoluyla HPy_mod_exec'in yazdığı modül attribute'u okunur" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\print(hpy_call_on(h, "get_faz20_marker"))
        \\hpy_close(h)
        \\
    ,
        "99\n",
    );
}

test "hpy_call: eski tek-seferlik yoluyla HPy_mod_exec'in yazdığı modül attribute'u okunur" {
    try expectGolden(
        \\print(hpy_call("tests/compat/hpy_ext/noxtest.so", "noxtest", "get_faz20_marker", 0))
        \\
    ,
        "99\n",
    );
}

// Faz 21 (bkz. plan dosyası "modül-seviyesi tip inşası + GETSET + NOARGS
// tip metodları"): `Boxed` (bkz. `noxtest.c`) — aHPy'nin GERÇEK `Box`
// sınıfının KÜÇÜLTÜLMÜŞ bir kopyası: `HPy_tp_new` KAYITLI DEĞİL (jenerik
// `constructInstance` düşüşünü egzersiz eder), `HPyDef_GETSET` (`"n"`)
// VE `HPyFunc_NOARGS` bir tip metodu (`double_n`) taşır. `Boxed`, GERÇEK
// aHPy'nin `Box`ından FARKLI olarak, KENDİ tipini HER `hpy_open` çağrısında
// TAZE inşa edip modülün instance_dict'ine KAYDEDER (Counter/Widget'ın
// AKSİNE, `hpy_close` SONRASI tip nesnesi de DÜZGÜNCE serbest bırakılır —
// BU YÜZDEN aşağıdaki testler `expectGoldenAllowTypeLeak` DEĞİL, KATI
// `expectGolden` KULLANIR).
test "hpy_new_on: jenerik tp_new düşüşü + tp_init + GETSET getter round-trip" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\boxed: ptr = hpy_new_on(h, "Boxed", 5)
        \\print(hpy_getattr_int_on(h, boxed, "n"))
        \\hpy_close_obj(h, boxed)
        \\hpy_close(h)
        \\
    ,
        "5\n",
    );
}

test "hpy_setattr_int_on: GETSET setter GERÇEKTEN çağrılır" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\boxed: ptr = hpy_new_on(h, "Boxed", 5)
        \\hpy_setattr_int_on(h, boxed, "n", 42)
        \\print(hpy_getattr_int_on(h, boxed, "n"))
        \\hpy_close_obj(h, boxed)
        \\hpy_close(h)
        \\
    ,
        "42\n",
    );
}

test "hpy_call_attr_on: HPyFunc_NOARGS tip metodu + bound-method dispatch" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\boxed: ptr = hpy_new_on(h, "Boxed", 5)
        \\hpy_setattr_int_on(h, boxed, "n", 42)
        \\print(hpy_call_attr_on(h, boxed, "double_n"))
        \\hpy_close_obj(h, boxed)
        \\hpy_close(h)
        \\
    ,
        "84\n",
    );
}

test "hpy_close_obj: Boxed_destroy (tp_destroy) GERÇEKTEN tetiklenir" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\boxed: ptr = hpy_new_on(h, "Boxed", 1)
        \\hpy_close_obj(h, boxed)
        \\print(hpy_call_on(h, "get_boxed_destroy_count"))
        \\hpy_close(h)
        \\
    ,
        "1\n",
    );
}

// Faz 22 (bkz. plan dosyası "bare attribute-nesnesi + gerçek slice tipi
// + numpy-tarzı skaler-broadcast slice ataması"): aHPy'nin GERÇEK
// `external_nogil_targets`ının (ÖNCEDEN "hibrit attribute+subscript
// nesnesi gerektiriyor" SANILAN, AMA GERÇEKTE İKİ AYRI BASİT nesne —
// bir attribute-nesnesi + bir sıralı nesne — yeterli OLAN) küçültülmüş
// bir kopyası, `attr_and_seq_roundtrip` (bkz. `noxtest.c`), GERÇEKTEN
// ÇALIŞTIRILIP DOĞRULANIR: `hpy_new_object_on` (bare attribute-nesnesi)
// + `hpy_setattr_int_on` + `h_SliceType`in GERÇEKTEN çağrılabilir olması
// + `.list_`nin SLICE GET/SET'i (SKALER broadcast DAHİL) HEPSİ BİRLİKTE.
test "hpy_new_object_on + h_SliceType + list slice broadcast: aHPy'nin external_nogil_targets deseni" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\obj: ptr = hpy_new_object_on(h)
        \\hpy_setattr_int_on(h, obj, "amount", 5)
        \\mapping: list[int] = [10, 20, 30, 40]
        \\print(hpy_call_on(h, "attr_and_seq_roundtrip", obj, mapping))
        \\hpy_close_obj(h, obj)
        \\hpy_close(h)
        \\
    ,
        "219\n",
    );
}

// Faz 24 (bkz. plan dosyası "bellek-içi file-like writer/reader
// nesneleri"): `hpy-ujson`nin `dump()`unun (GERÇEK bir "file-like"
// nesne — çağrılabilir `.write(str) -> int` attribute'u OLAN bir nesne —
// bekleyen HPy fonksiyonlarının HEPSİNİN) İhtiyaç duyduğu TAM protokolü
// `call_write_method` (bkz. `noxtest.c`) İLE doğrular.
test "hpy_new_string_writer_on: write() çağrılabilir, sonucu (yazılan bayt sayısı) + biriken içerik doğru" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\w: ptr = hpy_new_string_writer_on(h)
        \\print(hpy_call_on(h, "call_write_method", w, "merhaba"))
        \\print(hpy_writer_get_str_on(h, w))
        \\hpy_close_obj(h, w)
        \\hpy_close(h)
        \\
    ,
        "7\nmerhaba\n",
    );
}

test "hpy_new_string_writer_on: BİRDEN FAZLA write() çağrısı biriktirir" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\w: ptr = hpy_new_string_writer_on(h)
        \\print(hpy_call_on(h, "call_write_method", w, "abc"))
        \\print(hpy_call_on(h, "call_write_method", w, "def"))
        \\print(hpy_writer_get_str_on(h, w))
        \\hpy_close_obj(h, w)
        \\hpy_close(h)
        \\
    ,
        "3\n3\nabcdef\n",
    );
}

test "hpy_new_string_reader_on: read() çağrılabilir, TÜM içeriği döner, İKİNCİ çağrıda boş (EOF)" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\r: ptr = hpy_new_string_reader_on(h, "dunya")
        \\print(hpy_call_str_on(h, "call_read_method", r))
        \\print(hpy_call_str_on(h, "call_read_method", r))
        \\hpy_close_obj(h, r)
        \\hpy_close(h)
        \\
    ,
        "dunya\n\n",
    );
}

test "hpy_new_string_writer_on: write()e str-DIŞI bir argüman geçilirse HPyError raise edilir" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\w: ptr = hpy_new_string_writer_on(h)
        \\try:
        \\    print(hpy_call_on(h, "call_write_method", w, 42))
        \\except HPyError as e:
        \\    print("yakalandi")
        \\hpy_close_obj(h, w)
        \\hpy_close(h)
        \\
    ,
        "yakalandi\n",
    );
}

// Faz 24 (bkz. plan dosyası "bellek-içi file-like writer/reader
// nesneleri", "Kritik dosyalar" bölümündeki `foreign_bridge.zig`
// notu): GERÇEK `hpy-ujson`nin `dump()`u ELLE test EDİLİRKEN bulunan,
// writer/reader özelliğiyle İLİŞKİSİZ AYRI bir hata — `nox_hpy_call_int_
// finish`/vb. ÖNCEDEN unmarshal (`ctx_Long_AsInt64_t`) BAŞARISIZ
// olduğunda (`None` DÖNEN bir fonksiyon YANLIŞLIKLA `hpy_call_on` İLE —
// int bekleyerek — çağrıldığında) `ctx`nin İÇ hata durumunu ASLA kontrol/
// TEMİZLEMİYORDU — bu SESSİZCE "başarılı" (garbage `0`) dönerdi VE `ctx`nin
// İÇ hata durumu KİRLİ KALIP AYNI `h` üzerindeki BAŞKA, TAMAMEN İLİŞKİSİZ
// bir SONRAKİ çağrıyı GİZEMLİ şekilde BOZARDI (`HPyArg_ParseKeywords`nin
// KENDİSİ BİLE bir PENDING hatayla karşılaştığında BAŞARISIZ olabiliyordu).
test "nox_hpy_call_int_finish: yanlış dönüş tipi (None) HPyError raise eder VE ctx'in iç hata durumunu KİRLETMEZ" {
    try expectGolden(
        \\h: ptr = hpy_open("tests/compat/hpy_ext/noxtest.so", "noxtest")
        \\try:
        \\    print(hpy_call_on(h, "returns_none_via_o", 1))
        \\except HPyError as e:
        \\    print("yakalandi")
        \\print(hpy_call_on(h, "sum_two_ints", 3, 4))
        \\hpy_close(h)
        \\
    ,
        "yakalandi\n7\n",
    );
}
