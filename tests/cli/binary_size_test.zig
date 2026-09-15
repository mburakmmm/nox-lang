//! Faz FFI.3 (bkz. nox-teknik-spesifikasyon.md §3.148): `-rdynamic`
//! (blanket) → dar, 5-sembol dinamik export + linker dead-stripping
//! değişikliğinin uçtan-uca kanıtı — GERÇEK `noxc` alt süreci ile
//! (`tests/cli/help_screen_test.zig`/`explain_test.zig`nin AYNI deseni).
//!
//! Üç kanıt:
//! 1. Negatif kanıt: `nox.smtp`/`nox.postgres` KULLANMAYAN basit bir
//!    program derlenip `nm` çıktısında bu modüllere AİT sembollerin HİÇ
//!    BULUNMADIĞI (dead-stripping'in GERÇEKTEN çalıştığı) doğrulanır.
//! 2. Boyut kanıtı: aynı ikilinin boyutu, düzeltme ÖNCESİ (yaklaşık 7+ MB)
//!    durumdan AÇIKÇA küçük (makul bir üst sınır).
//! 3. Fonksiyonel kanıt (KRİTİK — 5-sembol listesinin DOĞRU olduğunun asıl
//!    kanıtı): `nox.json.decode` + bir sınıf örneği + cycle-collector'ı
//!    tetikleyen (>700 örnek) bir program doğru çalışır.
//!
//! `nm`/dead-stripping Windows'ta (PE/MinGW, blanket `--export-all-symbols`,
//! bilinçli olarak DEĞİŞTİRİLMEDİ) anlamlı değil — bu testler SADECE macOS/
//! Linux'ta çalışır.

const std = @import("std");
const builtin = @import("builtin");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn writeTempSource(gpa: std.mem.Allocator, io: std.Io, source: []const u8, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    return std.fmt.allocPrint(gpa, "{s}/prog.nox", .{path_buf[0..len]});
}

test "noxc build: smtp/postgres kullanmayan basit bir program dead-stripping ile küçük kalır" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    // v1.80.5 (bkz. CHANGELOG.md/nox-teknik-spesifikasyon.md §3.155): GERÇEK
    // bir Linux (x86-64) CI koşusuyla bulunup, bir Docker/Ubuntu 24.04
    // konteynerinde HEM Debug HEM ReleaseFast build'leri karşılaştırılarak
    // KANITLANDI — Zig'in ELF hedeflerinde `link_function_sections`i
    // SADECE LLVM backend'i (Release* modları) ONURLANDIRIYOR; `-Doptimize`
    // BAYRAKSIZ (Debug, ci.yml'nin İLK, öntanımlı `zig build test` çağrısı)
    // derlenen `noxrt.o` (native/self-hosted x86_64 backend'i KULLANIR)
    // SIFIR `.text.*` bölümü ÜRETİYOR (readelf İLE doğrulandı) — bu YÜZDEN
    // `--gc-sections`/`--export-dynamic-symbol`in GRANÜLERLİĞİ YOK, HİÇBİR
    // stdlib shim sembolü (nox_smtp_connect_raw DAHİL) elenmez. Bu test
    // modülü `build.zig`nin `optimize`iyle AYNI paylaşılan değeri (`.
    // optimize = optimize`) KULLANDIĞINDAN, `builtin.mode` BURADA ambient
    // noxrt.o'nun KENDİ modunu GÜVENİLİR biçimde YANSITIR — Debug'da BU
    // testin dead-stripping'e ÖZGÜ iddiaları ATLANIR (`zig build test
    // -Doptimize=ReleaseFast`nin AYNI test'i GERÇEKTEN doğrulamaya DEVAM
    // ETTİĞİNDEN kapsam KAYBI YOK — ci.yml HER İKİ modu da SIRAYLA çalıştırır).
    if (builtin.mode == .Debug) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src_path = try writeTempSource(gpa, io, "print(\"hi\")\n", &tmp);
    defer gpa.free(src_path);

    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_len = try tmp.dir.realPath(io, &out_path_buf);
    const tmp_dir_path = out_path_buf[0..tmp_dir_len];
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/prog_out", .{tmp_dir_path});
    defer gpa.free(bin_path);

    const build_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", src_path, "-o", bin_path } });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    // Negatif kanıt: nox.smtp/nox.postgres'e ait, KESİNLİKLE İLGİSİZ
    // sembollerin ikilinin sembol tablosunda HİÇ bulunmaması — dead-code-
    // stripping GERÇEKTEN çalışıyorsa bu fonksiyonların KODU (ve sembol
    // girdisi) ikiliden TAMAMEN elenir (stripped-out kod, `nm`de HİÇ
    // görünmez — local/`t` sembol olarak bile kalmaz).
    const nm_result = try std.process.run(gpa, io, .{ .argv = &.{ "nm", bin_path } });
    defer gpa.free(nm_result.stdout);
    defer gpa.free(nm_result.stderr);
    try std.testing.expect(nm_result.term == .exited and nm_result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, nm_result.stdout, "nox_smtp_connect_raw") == null);
    try std.testing.expect(std.mem.indexOf(u8, nm_result.stdout, "nox_pg_exec_params_raw") == null);

    // Boyut kanıtı: düzeltme ÖNCESİ durumdan (macOS ~7.68 MB, Linux/ELF'te
    // `link_function_sections` OLMADAN ~12+ MB) AÇIKÇA küçük. Platformlar
    // ARASI DWARF/debug-info boyut farkı GERÇEK VE ÖNEMLİ (GERÇEK bir Linux
    // aarch64 CI koşusunda ÖLÇÜLDÜ: Debug noxrt.o macOS'un ~4 katı) — bu
    // YÜZDEN sınır CÖMERT tutulur (asıl, KESİN kanıt YUKARIDAKİ negatif-
    // sembol kontrolüdür, BU sınır SADECE "aşırı şişkinliğe" karşı bir
    // savunma-derinliği regresyon bekçisidir).
    const stat = try tmp.dir.statFile(io, "prog_out", .{});
    try std.testing.expect(stat.size < 10 * 1024 * 1024);
}

test "noxc build: nox.json.decode + sınıf + cycle-collector (5-sembol dlsym listesi) doğru çalışır" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const src_path = try writeTempSource(gpa, io,
        \\import nox.json
        \\
        \\class Node:
        \\    def __init__(self: Node, value: int) -> None:
        \\        self.value = value
        \\        self.other = self
        \\
        \\data: str = "{\"a\": 1, \"b\": [1, 2, 3]}"
        \\v: JsonValue = nox.json.decode(data)
        \\print(nox.json.object_key(v, 0))
        \\print(nox.json.as_number(nox.json.object_value(v, 0)))
        \\
        \\count: int = 0
        \\i: int = 0
        \\while i < 800:
        \\    n: Node = Node(i)
        \\    n.other = n
        \\    count = count + 1
        \\    i = i + 1
        \\print(count)
        \\
    , &tmp);
    defer gpa.free(src_path);

    var out_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_dir_len = try tmp.dir.realPath(io, &out_path_buf);
    const tmp_dir_path = out_path_buf[0..tmp_dir_len];
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/prog_out", .{tmp_dir_path});
    defer gpa.free(bin_path);

    const build_result = try std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "build", src_path, "-o", bin_path } });
    defer gpa.free(build_result.stdout);
    defer gpa.free(build_result.stderr);
    try std.testing.expect(build_result.term == .exited and build_result.term.exited == 0);

    const run_result = try std.process.run(gpa, io, .{ .argv = &.{bin_path} });
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    try std.testing.expect(run_result.term == .exited and run_result.term.exited == 0);
    try std.testing.expectEqualStrings("a\n1\n800\n", run_result.stdout);
    // DebugAllocator'ın sızıntı/UAF kontrolü BOŞ stderr İLE kanıtlanır —
    // 5-sembol dlsym listesinin EKSİK/YANLIŞ olması (bkz. plan dosyası,
    // `nox_trace_dispatch` çıkarılınca kanıtlanan break→red→fix) cycle-
    // collector'ın SESSİZCE sızıntı vermesine yol açardı.
    try std.testing.expectEqualStrings("", run_result.stderr);
}
