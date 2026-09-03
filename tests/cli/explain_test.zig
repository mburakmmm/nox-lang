//! HH.3 (bkz. plan dosyası "`noxc explain`"): `noxc explain <dosya.nox>`nin
//! (`compiler/main.zig`nin `cmdExplain`ı, `compiler/codegen_qbe/local_escape.zig`nin
//! `explainVarDecl`ı) uçtan-uca davranışını, GERÇEK `noxc` alt süreciyle
//! (`tests/cli/help_screen_test.zig`nin AYNI deseni) doğrular — HER
//! senaryo BİR (verdict, gerekçe metni) çiftini KANITLAR.

const std = @import("std");

fn noxcPath() []const u8 {
    return "zig-out/bin/noxc";
}

fn writeTempSource(gpa: std.mem.Allocator, io: std.Io, source: []const u8, tmp: *std.testing.TmpDir) ![]const u8 {
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.nox", .data = source });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    return std.fmt.allocPrint(gpa, "{s}/prog.nox", .{path_buf[0..len]});
}

fn runExplain(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = &.{ noxcPath(), "explain", path } });
}

test "noxc explain: sabit-boyutlu, kaçmayan bir sınıf örneği stack'e (doğru gerekçeyle) tahsis edilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\class Point:
        \\    def __init__(self: Point, x: int, y: int) -> None:
        \\        self.x = x
        \\        self.y = y
        \\
        \\def compute() -> int:
        \\    p: Point = Point(3, 4)
        \\    return p.x + p.y
        \\
        \\print(compute())
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try runExplain(gpa, io, path);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tahsis: stack") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "kaçmıyor") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "çerçeve bütçesi") != null);
}

test "noxc explain: heap-yönetimli bir alan içeren sınıf örneği ARC'a tahsis edilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\class Bag:
        \\    def __init__(self: Bag, label: str) -> None:
        \\        self.label = label
        \\
        \\def compute() -> str:
        \\    b: Bag = Bag("x")
        \\    return b.label
        \\
        \\print(compute())
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try runExplain(gpa, io, path);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tahsis: ARC") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "heap-yönetimli") != null);
}

test "noxc explain: bir sonraki deyimde döndürülen (kaçan) bir yerel ARC'ta kalır" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\class Point:
        \\    def __init__(self: Point, x: int, y: int) -> None:
        \\        self.x = x
        \\        self.y = y
        \\
        \\def make() -> Point:
        \\    p: Point = Point(1, 2)
        \\    return p
        \\
        \\print(make().x)
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try runExplain(gpa, io, path);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tahsis: ARC") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "kaçıyor") != null);
}

test "noxc explain: .append() ile büyüyen, kaçmayan bir liste büyüyebilir-arena'ya tahsis edilir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\def compute(n: int) -> int:
        \\    xs: list[int] = []
        \\    i: int = 0
        \\    while i < n:
        \\        xs.append(i)
        \\        i = i + 1
        \\    return len(xs)
        \\
        \\print(compute(5))
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try runExplain(gpa, io, path);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tahsis: arena") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "büyüyebilir-arena adayı") != null);
}

// HH.3'ün "regresyon-yok" kanıtı: core.nox/stdlib'in BİRLEŞTİRİLEN
// deyimlerinin KULLANICININ kendi dosyasına AİTMİŞ GİBİ (yanlış satır
// numarasıyla) raporLANMADIĞINI doğrular (bkz. `codegen.ExplainOptions`nin
// belge notu — `module_loader.resolveImports`in `core.nox`u module.body'nin
// BAŞINA EKLEMESİ YÜZÜNDEN bulunan GERÇEK bir hata, DÜZELTİLDİ).
test "noxc explain: yalnızca kullanıcının kendi dosyasındaki yerelleri raporlar (core.nox/stdlib sızmaz)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeTempSource(gpa, io,
        \\xs: list[int] = [1, 2, 3]
        \\print(xs)
        \\
    , &tmp);
    defer gpa.free(path);

    const result = try runExplain(gpa, io, path);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    // TEK bir kayıt beklenir (`xs`) — HER satırın TAM OLARAK `path`İLE
    // başladığını (core.nox'un KENDİ, TAMAMEN FARKLI bir yoldan gelen
    // satırlarının SIZMADIĞINI) doğrular.
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var record_header_count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "  xs") == 0 or std.mem.startsWith(u8, line, path)) {
            if (std.mem.startsWith(u8, line, path)) record_header_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), record_header_count);
}
