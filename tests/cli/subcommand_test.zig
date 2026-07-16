//! Faz O §P.2 golden testleri: `noxc`nin bir ALT SÜREÇ olarak test edildiği
//! İLK yer (mevcut golden testlerin AKSİNE, bkz. `tests/golden/
//! codegen_golden_test.zig`'in `nox.lexer`/`parser`/`checker`/`codegen`i
//! DOĞRUDAN Zig kütüphane çağrısıyla kullanması) — burada gerçekten kurulu
//! `zig-out/bin/noxc`yi çalıştırıp `build`/`run` alt komutlarını VE
//! geriye-dönük-uyumlu çıplak-dosya (legacy) formunu doğruluyoruz.
//!
//! Önkoşul: `zig build` (bu test adımının kendisi `install` adımına bağımlı
//! olduğundan `zig build test` çalıştırıldığında ZATEN garanti edilir).

const std = @import("std");

fn noxcPath(a: std.mem.Allocator) ![]const u8 {
    // `build.zig`nin `test_step`i `install_noxrt`e (dolayısıyla `noxc`nin
    // KENDİSİNİN de kurulmuş olmasına) bağımlı olduğundan bu her zaman var
    // olmalıdır (bkz. build.zig, `b.installArtifact(noxc)`).
    _ = a;
    return "zig-out/bin/noxc";
}

/// `noxcPath`in MUTLAK sürümü — `.cwd` İLE farklı bir çalışma dizininde
/// çalıştırılan alt süreçler İÇİN GEREKLİDİR: GÖRELİ bir argv[0]
/// (`"zig-out/bin/noxc"`), test SÜRECİNİN DEĞİL, `.cwd` İLE VERİLEN YENİ
/// çalışma dizinine göre çözülür (GERÇEK bir denemede `processSpawnPosix`
/// çökmesiyle KEŞFEDİLDİ — bkz. `package_resolution_test.zig`nin AYNI
/// belge notu).
fn noxcAbsPath(io: std.Io, a: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, try noxcPath(a) });
}

test "legacy cıplak-dosya formu: build ile birebir aynı davranış" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.nox", .data = "print(\"merhaba\")\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const noxc = try noxcPath(a);
    const src_path = try std.fmt.allocPrint(a, "{s}/hello.nox", .{dir_path});
    const bin_path = try std.fmt.allocPrint(a, "{s}/hello", .{dir_path});

    const legacy_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, src_path },
    });
    defer std.testing.allocator.free(legacy_result.stdout);
    defer std.testing.allocator.free(legacy_result.stderr);
    try std.testing.expect(legacy_result.term == .exited and legacy_result.term.exited == 0);
    // `main.zig`nin başarı/hata mesajları `std.debug.print` ile (Zig'in
    // KENDİSİNİN sabit davranışı gereği) HER ZAMAN stderr'e yazılır — bu
    // BU turdaki bir davranış DEĞİŞİKLİĞİ DEĞİL, önceki koddan MİRAS kalan
    // (ve BİLEREK korunan) bir özellik.
    const expected_msg = try std.fmt.allocPrint(a, "derlendi: {s}\n", .{bin_path});
    try std.testing.expectEqualStrings(expected_msg, legacy_result.stderr);

    const run_result = try std.process.run(std.testing.allocator, io, .{ .argv = &.{bin_path} });
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqualStrings("merhaba\n", run_result.stdout);

    // `build` alt komutu AYNI davranışı üretmeli (yalnızca farklı kullanım
    // mesajı, bkz. main.zig'in `cmdBuild`e geçirdiği `usage` parametresi).
    const build_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "build", src_path },
    });
    defer std.testing.allocator.free(build_result.stdout);
    defer std.testing.allocator.free(build_result.stderr);
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);
    try std.testing.expectEqualStrings(expected_msg, build_result.stderr);
}

test "build -o: cikti yolu ozellestirilebilir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.nox", .data = "print(\"merhaba\")\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const noxc = try noxcPath(a);
    const src_path = try std.fmt.allocPrint(a, "{s}/hello.nox", .{dir_path});
    const custom_bin = try std.fmt.allocPrint(a, "{s}/custom_out", .{dir_path});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "build", "-o", custom_bin, src_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);

    try tmp.dir.access(io, "custom_out", .{});
}

test "run: programi calistirir, derlendi mesaji basmaz, stdout'u yansitir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.nox", .data = "print(\"koştu\")\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const noxc = try noxcPath(a);
    const src_path = try std.fmt.allocPrint(a, "{s}/hello.nox", .{dir_path});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "run", src_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expectEqualStrings("koştu\n", result.stdout);
    try std.testing.expect(!std.mem.startsWith(u8, result.stdout, "derlendi"));

    // `.nox/cache/bin/hello` altına derlenmiş olmalı (kaynağın YANINA değil).
    try tmp.dir.access(io, ".nox/cache/bin/hello", .{});
}

test "run: yakalanmamis istisna cikis kodunu sifirdan farkli yansitir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source =
        \\class Boom:
        \\    def __init__(self: Boom, message: str) -> None:
        \\        self.message = message
        \\
        \\raise Boom("patladi")
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "raiser.nox", .data = source });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const noxc = try noxcPath(a);
    const src_path = try std.fmt.allocPrint(a, "{s}/raiser.nox", .{dir_path});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "run", src_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
}

test "test: *_test.nox kesfi, karisik gecen/kalan, toplam ozet + cikis kodu" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "ok_test.nox",
        .data = "import nox.test\nnox.test.assert_eq_int(2 + 2, 4, \"toplama\")\n",
    });
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sub/broken_test.nox",
        .data = "import nox.test\nnox.test.assert_eq_int(2 + 2, 5, \"yanlis\")\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "helper.nox", .data = "print(\"yardimci\")\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const noxc = try noxcPath(a);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "test", dir_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "ok_test.nox") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "broken_test.nox") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "1 gecti, 1 basarisiz (2 toplam)") != null);
}

test "test: bos dizin -> 0 test dosyasi, cikis kodu 0" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const noxc = try noxcPath(a);
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "test", dir_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "0 test dosyasi bulundu") != null);
}

// Faz CC.2 (bkz. nox-teknik-spesifikasyon.md §3.54): `fetch`/`update`
// ARTIK GERÇEK bir implementasyona SAHİP (ÖNCEDEN "henuz uygulanmadi"
// basıp exit 1 dönen bir REZERVASYONDU) — buradaki test, HERHANGİ bir
// `nox.json` BULUNAMAYAN bir dizinden çalıştırıldıklarında net bir hata
// İLE (exit 1) BAŞARISIZ OLDUKLARINI doğrular. GERÇEK bir PROJE üzerinde
// getirme/güncelleme davranışı `tests/cli/package_resolution_test.zig`de
// (izole `$NOX_HOME` + yerel git fixture repo'larıyla) doğrulanır.
test "fetch/update: nox.json bulunamayan bir dizinden calistirilirsa net hatayla basarisiz olur" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noxc = try noxcAbsPath(io, a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    inline for (.{ "fetch", "update" }) |sub| {
        const result = try std.process.run(std.testing.allocator, io, .{
            .argv = &.{ noxc, sub },
            .cwd = .{ .path = dir_path },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 1);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "nox.json bulunamadi") != null);
    }
}

// Faz T.4b: `noxc fmt` artık GERÇEK bir formatlayıcıdır (bkz.
// `compiler/fmt/formatter.zig`) — `fetch`/`update`in AKSİNE "henüz
// uygulanmadı" DEMEZ, dosyayı YERİNDE (in-place) yeniden yazar.
test "fmt: gercek formatlayici dosyayi yerinde yeniden yazar, IDEMPOTENTTIR" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "messy.nox", .data = "x:int=1+2\nprint(x)\n" });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const noxc = try noxcPath(a);
    const src_path = try std.fmt.allocPrint(a, "{s}/messy.nox", .{dir_path});

    const fmt_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "fmt", src_path },
    });
    defer std.testing.allocator.free(fmt_result.stdout);
    defer std.testing.allocator.free(fmt_result.stderr);
    try std.testing.expect(fmt_result.term == .exited and fmt_result.term.exited == 0);

    const once = try tmp.dir.readFileAlloc(io, "messy.nox", a, .limited(4096));
    try std.testing.expectEqualStrings("x: int = 1 + 2\nprint(x)\n", once);

    // İkinci kez formatlamak (İDEMPOTENT olmalı) dosyayı DEĞİŞTİRMEMELİ.
    const fmt_again = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "fmt", src_path },
    });
    defer std.testing.allocator.free(fmt_again.stdout);
    defer std.testing.allocator.free(fmt_again.stderr);
    try std.testing.expect(fmt_again.term == .exited and fmt_again.term.exited == 0);
    const twice = try tmp.dir.readFileAlloc(io, "messy.nox", a, .limited(4096));
    try std.testing.expectEqualStrings(once, twice);
}

// Kurulum betiğinin (`install.sh`) doğrulama adımının GÜVENDİĞİ komut —
// `noxc version`/`--version`/`-V` ÜÇÜ de `noxc <build.zig.zon'daki
// version>\n`i basar (bkz. build.zig'in `build_options.version`ı, `main.
// zig`nin `cmdVersion` dalı) — `std.debug.print` KULLANDIĞINDAN (bu
// dosyanın İLK testindeki AYNI not gibi) stderr'e yazılır, stdout'a DEĞİL.
// `-v` (küçük harf) `build`in AYRINTILI-döküm bayrağıyla ÇAKIŞTIĞINDAN
// BİLEREK `-V` (büyük harf) kullanılır.
test "version: version/--version/-V ÜÇÜ de AYNI 'noxc <surum>' satırını basar" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noxc = try noxcPath(a);

    inline for (.{ "version", "--version", "-V" }) |flag| {
        const result = try std.process.run(std.testing.allocator, io, .{
            .argv = &.{ noxc, flag },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
        try std.testing.expect(std.mem.startsWith(u8, result.stderr, "noxc "));
        try std.testing.expect(result.stderr.len > "noxc \n".len);
    }
}

// Faz CC.2.2 (bkz. nox-teknik-spesifikasyon.md §3.56): `noxc init`
// (argümansız) CWD'nin KENDİSİNDE bir `nox.json`/`main.nox`/`.gitignore`
// oluşturur — üretilen proje GERÇEKTEN `noxc build` + çalıştırılabilir
// olmalı (yalnızca dosyaların VAR OLMASI değil, İÇERİKLERİNİN de GEÇERLİ
// olduğu kanıtlanır). İKİNCİ bir `init` ÇAĞRISI (var olan bir projeyi
// YANLIŞLIKLA silmemek İçin) net bir hatayla (exit 1) BAŞARISIZ OLMALI.
test "init: argumansiz CWD'de proje iskeleti olusturur, uretilen proje GERCEKTEN calisir, ikinci init reddeder" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noxc = try noxcAbsPath(io, a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const init1 = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "init" },
        .cwd = .{ .path = dir_path },
    });
    defer std.testing.allocator.free(init1.stdout);
    defer std.testing.allocator.free(init1.stderr);
    if (init1.term != .exited or init1.term.exited != 0) {
        std.debug.print("init basarisiz, stderr: {s}\n", .{init1.stderr});
    }
    try std.testing.expect(init1.term == .exited and init1.term.exited == 0);
    try tmp.dir.access(io, "nox.json", .{});
    try tmp.dir.access(io, "main.nox", .{});
    try tmp.dir.access(io, ".gitignore", .{});

    // Uretilen main.nox GERCEKTEN derlenip calisir olmali.
    const main_path = try std.fmt.allocPrint(a, "{s}/main.nox", .{dir_path});
    const bin_path = try std.fmt.allocPrint(a, "{s}/main", .{dir_path});
    const build_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "build", main_path },
    });
    defer std.testing.allocator.free(build_result.stdout);
    defer std.testing.allocator.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.debug.print("build basarisiz, stderr: {s}\n", .{build_result.stderr});
    }
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    const run_result = try std.process.run(std.testing.allocator, io, .{ .argv = &.{bin_path} });
    defer std.testing.allocator.free(run_result.stdout);
    defer std.testing.allocator.free(run_result.stderr);
    try std.testing.expectEqualStrings("merhaba, nox!\n", run_result.stdout);

    // Ikinci init AYNI dizinde -- var olan projeyi SILMEMELI, net hatayla basarisiz olmali.
    const init2 = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "init" },
        .cwd = .{ .path = dir_path },
    });
    defer std.testing.allocator.free(init2.stdout);
    defer std.testing.allocator.free(init2.stderr);
    try std.testing.expect(init2.term == .exited and init2.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, init2.stderr, "zaten var") != null);
}

test "init: isimli cagri YENI bir alt dizin olusturup icinde baslatir" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noxc = try noxcAbsPath(io, a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "init", "myproj" },
        .cwd = .{ .path = dir_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);

    const manifest = try tmp.dir.readFileAlloc(io, "myproj/nox.json", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"myproj\"") != null);
}

// Faz CC.2.2: `noxc check`, `build`in AKSİNE codegen/`qbe`/`cc`
// TETİKLEMEMELİ — GEÇERLİ bir dosyada exit 0 + "tip hatasi yok" basmalı,
// HİÇBİR `.ssa`/`.s`/ikili ARTIFACT ÜRETMEMELİ; tip hatalı bir dosyada
// exit 1 + "tip hatasi" içeren bir mesaj basmalı.
test "check: gecerli dosyada codegen'e HIC girmeden basarili, hatali dosyada net tip hatasi" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noxc = try noxcAbsPath(io, a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.nox", .data = "print(\"merhaba\")\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.nox", .data = "x: int = \"yanlis tip\"\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ok_path = try std.fmt.allocPrint(a, "{s}/ok.nox", .{dir_path});
    const ok_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "check", ok_path },
    });
    defer std.testing.allocator.free(ok_result.stdout);
    defer std.testing.allocator.free(ok_result.stderr);
    if (ok_result.term != .exited or ok_result.term.exited != 0) {
        std.debug.print("check basarisiz, stderr: {s}\n", .{ok_result.stderr});
    }
    try std.testing.expect(ok_result.term == .exited and ok_result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, ok_result.stderr, "tip hatasi yok") != null);
    // `check` codegen/`qbe`/`cc`e HIC GIRMEMELI -- hicbir artifact YOK.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "ok.ssa", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "ok", .{}));

    const bad_path = try std.fmt.allocPrint(a, "{s}/bad.nox", .{dir_path});
    const bad_result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "check", bad_path },
    });
    defer std.testing.allocator.free(bad_result.stdout);
    defer std.testing.allocator.free(bad_result.stderr);
    try std.testing.expect(bad_result.term == .exited and bad_result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, bad_result.stderr, "tip hatasi") != null);
}

// Faz CC.2.3 (bkz. nox-teknik-spesifikasyon.md §3.58): `noxc` çıktısı
// artık `printErr`/`printOk` İLE (TTY VE `NO_COLOR` tespitine göre) ANSI
// renk kodlarıyla SARILABİLİR — AMA `std.process.run`ın YAKALADIĞI stdout/
// stderr HER ZAMAN bir BORU HATTIDIR (GERÇEK bir TTY DEĞİL), bu yüzden
// GÜVENLİ VARSAYILAN davranış (renklendirme OTOMATİK devre dışı kalır,
// script/CI TÜKETİCİLERİ ham metni GÖRÜR) BURADA AÇIKÇA doğrulanır —
// HİÇBİR `\x1b` (ESC) baytı stderr'e SIZMAMALI.
test "renklendirme: TTY olmayan (boru hatti) ciktida HICBIR ANSI kacis dizisi sizmaz" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noxc = try noxcPath(a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.nox", .data = "x: int = \"yanlis tip\"\n" });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];
    const bad_path = try std.fmt.allocPrint(a, "{s}/bad.nox", .{dir_path});

    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{ noxc, "check", bad_path },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "tip hatasi") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result.stderr, 0x1b) == null);
}
