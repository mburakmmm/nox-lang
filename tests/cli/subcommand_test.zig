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

test "fmt/fetch/update: henuz uygulanmadi mesaji, cikis kodu 1" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noxc = try noxcPath(a);

    inline for (.{ "fmt", "fetch", "update" }) |sub| {
        const result = try std.process.run(std.testing.allocator, io, .{
            .argv = &.{ noxc, sub },
        });
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 1);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "henuz uygulanmadi") != null);
    }
}
