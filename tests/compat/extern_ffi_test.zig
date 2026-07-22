//! Planlanan Faz 20: Zig/C ABI FFI (`extern def`) uçtan uca uyumluluk testi
//! (bkz. nox-teknik-spesifikasyon.md §3.20).
//!
//! `tests/compat/c_ext/mathutil.c` (sistem `cc -c` ile) VE `tests/compat/
//! zig_ext/util.zig` (`zig build-obj` ile, `export fn ... callconv(.c)`)
//! AYRI AYRI gerçek nesne dosyalarına derlenir (bkz. build.zig), sonra GERÇEK
//! bir `.nox` kaynağından `extern def ... from "<yol>"` ile bağlanıp
//! ÇAĞRILIR — hem C hem Zig'in AYNI mekanizmayla (ve sistem kütüphanesi
//! `libm`in `sqrt`i de AYNI mekanizmayla, `from "m"`) çalıştığının somut
//! kanıtı. Bu, `tests/golden/codegen_golden_test.zig`nin `compileAndRun`ıyla
//! AYNI yapıdadır (kasıtlı bir kod tekrarı) — tek fark, `extern def`in
//! gerektirdiği EK bağlama argümanlarının (nesne dosyası yolları)
//! `noxc`nin kendi `appendExternLinkArgs`iyle AYNI mantıkla burada da
//! `cc` çağrısına eklenmesi.

const std = @import("std");
const nox = @import("nox");
const build_options = @import("build_options");

fn compileAndRun(allocator: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    const io = std.testing.io;

    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    // `codegen_golden_test.zig`nin AYNI çağrısı — `core.nox`u (ör.
    // `IndexError`/`ValueError`) BİRLEŞTİRİR. Faz S.2 SIRASINDA keşfedilen
    // GERÇEK, ÖNCEDEN VAR OLAN bir eksiklik: bu dosya DAHA ÖNCE bu çağrıyı
    // HİÇ yapmıyordu (yalnızca `list[str]` extern def testinin `[0]`
    // indekslemesi, YENİ liste sınır kontrolü İLE `IndexError`i KOŞULSUZ
    // gerektirene KADAR hiçbir testte bu eksiklik SESSİZCE gizli kalmıştı).
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

    const ir = try nox.codegen.generateModule(allocator, module, checker_state.instantiations.items, generic_names.items, null, .empty, .empty);

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

    // `extern def`in gerektirdiği ek bağlama argümanları — bkz. `compiler/
    // main.zig`nin `appendExternLinkArgs`ı (AYNI mantık, bu testte ayrıca
    // tekrarlanıyor çünkü main.zig'in kendisini değil, codegen+qbe+cc'yi
    // doğrudan çağırıyoruz).
    // Faz R.3: `-rdynamic` — `codegen_golden_test.zig`nin AYNI gerekçeli
    // notu (`nox.json`nin `dlsym` deseni GEREKTİRİYOR, bkz. `compiler/
    // main.zig`) — bu test `nox.json` KULLANMASA BİLE, AYNI `noxrt.o`ya
    // bağlandığından tutarlılık İÇİN eklendi.
    const cc_result = try std.process.run(allocator, io, .{
        .argv = &.{
            "cc",                      "-rdynamic",
            "-o",                      bin_path,
            asm_path,                  "zig-out/lib/noxrt.o",
            "-lm",                     build_options.mathutil_o_path,
            build_options.util_o_path, build_options.counter_o_path,
        },
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

test "extern def: gerçek bir C kütüphanesi + gerçek bir Zig dosyası + sistem libm, AYNI mekanizmayla çağrılır" {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator,
        \\extern def sqrt(x: float) -> float from "m"
        \\extern def add_two(a: int, b: int) -> int from "{s}"
        \\extern def triple(x: int) -> int from "{s}"
        \\
        \\print(sqrt(16.0))
        \\print(add_two(3, 4))
        \\print(triple(7))
        \\
    , .{ build_options.mathutil_o_path, build_options.util_o_path });
    defer allocator.free(source);

    try expectGolden(source, "4\n7\n21\n");
}

test "extern def: opak `ptr` tipi — gerçek bir handle-tabanlı C API (FILE*/sqlite3* deseni)" {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator,
        \\extern def counter_create(initial: int) -> ptr from "{s}"
        \\extern def counter_get(handle: ptr) -> int from "{s}"
        \\extern def counter_increment(handle: ptr) -> None from "{s}"
        \\extern def counter_destroy(handle: ptr) -> None from "{s}"
        \\
        \\h: ptr = counter_create(10)
        \\counter_increment(h)
        \\counter_increment(h)
        \\print(counter_get(h))
        \\counter_destroy(h)
        \\
    , .{
        build_options.counter_o_path,
        build_options.counter_o_path,
        build_options.counter_o_path,
        build_options.counter_o_path,
    });
    defer allocator.free(source);

    try expectGolden(source, "12\n");
}

test "extern def with_rt: RT_PARAM gizlice geçirilir, Zig tarafı rt üzerinden ARC-yönetimli bir str üretebilir" {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator,
        \\extern def nox_test_make_greeting(name: str) -> str from "{s}" with_rt
        \\
        \\print(nox_test_make_greeting("dunya"))
        \\
    , .{build_options.util_o_path});
    defer allocator.free(source);

    try expectGolden(source, "merhaba, dunya\n");
}

test "extern def: dict[str, str] argüman olarak geçirilebilir (FFI-güvenli), Zig tarafı içeriği doğru okur" {
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator,
        \\extern def nox_test_dict_lookup(d: dict[str, str], key: str) -> str from "{s}" with_rt
        \\
        \\h: dict[str, str] = {{"greeting": "merhaba nox"}}
        \\print(nox_test_dict_lookup(h, "greeting"))
        \\
    , .{build_options.util_o_path});
    defer allocator.free(source);

    try expectGolden(source, "merhaba nox\n");
}

test "extern def: list[str] dönüş tipi FFI-güvenli — indeksleme/ARC serbest bırakma doğru çalışır (sızıntı yok)" {
    // Not: `len(list[str])` DESTEKLENMİYOR (Alt-Faz B'nin bilinçli dar
    // kapsamı — `len` yalnızca `str` üzerinde çalışır, `list[T].len()`
    // AYRI bir faz), bu yüzden burada YALNIZCA indeksleme doğrulanıyor.
    // KASITLI OLARAK adlandırılmış/annotasyonlu bir yerele BAĞLANMADAN,
    // ÇAĞRININ SONUCU DOĞRUDAN indeksleniyor — bir yerele bağlansaydı
    // (`items: list[str] = ...`), o yerelin `VarInfo`si ZATEN annotasyondan
    // (`resolveType`) DOĞRU `elem_qtype`/`elem_heap_info`yi taşırdı ve bu,
    // `genCall`in extern dalının DÖNDÜRDÜĞÜ `Value`deki eksikliği (bkz.
    // yukarıdaki "keşfedilen ön koşullar" notu) MASKELERDİ — testi ANLAMSIZ
    // kılardı.
    const allocator = std.testing.allocator;
    const source = try std.fmt.allocPrint(allocator,
        \\extern def nox_test_make_list(n: int) -> list[str] from "{s}" with_rt
        \\
        \\print(nox_test_make_list(3)[0])
        \\print(nox_test_make_list(3)[1])
        \\print(nox_test_make_list(3)[2])
        \\
    , .{build_options.util_o_path});
    defer allocator.free(source);

    try expectGolden(source, "item_0\nitem_1\nitem_2\n");
}
