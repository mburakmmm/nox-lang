//! Dogfood D2.3 (selfhost Aşama 2): farklı modüllerde AYNI adlı modül-düzeyi değişkenler ayrı yuvalardır (önceden `a.G` ↔ `b.G` tek yuvayı paylaşıyor, sessiz yanlış sonuç veriyordu).
const std = @import("std");

fn absPath(io: std.Io, dir: std.Io.Dir, buf: []u8) ![]const u8 {
    const len = try dir.realPath(io, buf);
    return buf[0..len];
}

fn runWith(a: std.mem.Allocator, io: std.Io, backend: []const u8) !void {
    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absPath(io, proj.dir, &buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}" });
    try proj.dir.writeFile(io, .{ .sub_path = "ga.nox", .data = "G: list[int] = [1]\nCOUNT: int = 5\n\ndef bump() -> int:\n    global G\n    G = [11, 12]\n    return len(G) + COUNT\n" });
    try proj.dir.writeFile(io, .{ .sub_path = "gb.nox", .data = "G: list[int] = [7, 8, 9]\nCOUNT: int = 6\n\ndef size() -> int:\n    return len(G) * 100 + COUNT\n" });
    try proj.dir.writeFile(io, .{ .sub_path = "main.nox", .data = "import ga\nimport gb\nfrom gb import COUNT as GB_COUNT\n\nprint(ga.bump(), gb.size())\nG: int = 99\nprint(G)\nprint(GB_COUNT)\n" });
    const main_path = try std.fmt.allocPrint(a, "{s}/main.nox", .{root});
    const r = try std.process.run(a, io, .{ .argv = &.{ "zig-out/bin/noxc", "run", "--backend", backend, main_path } });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
    // ga.bump(): len([11,12]) + 5 = 7; gb.size(): 3 * 100 + 6 = 306; kullanıcı dosyasının kendi G'si 99; `from gb import COUNT as GB_COUNT` modül değişkenini yerel adla getirir (6)
    try std.testing.expectEqualStrings("7 306\n99\n6\n", r.stdout);
}

test "modul-duzeyi degiskenler modul basina ayridir (llvm)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runWith(arena.allocator(), std.testing.io, "llvm");
}

test "modul-duzeyi degiskenler modul basina ayridir (qbe)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runWith(arena.allocator(), std.testing.io, "qbe");
}

// R1-P0.1 kalan (v2.2.48): aynı adlı tür takma adı (`type Id`) ve modül değişkeni (`G`) iki modülde farklı tiplerle; iç içe def (closure) kendi modülünün `G`sini okur — modüller birbirinin tipini/yuvasını ezmez.
fn runAliasClosure(a: std.mem.Allocator, io: std.Io, backend: []const u8) !void {
    var proj = std.testing.tmpDir(.{});
    defer proj.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absPath(io, proj.dir, &buf);
    try proj.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\":\"proj\",\"entry\":\"main.nox\"}" });
    try proj.dir.writeFile(io, .{ .sub_path = "ta.nox", .data = "type Id = int\nG: Id = 1\n\ndef get() -> Id:\n    def inner() -> Id:\n        return G + 10\n    return inner()\n" });
    try proj.dir.writeFile(io, .{ .sub_path = "tb.nox", .data = "type Id = str\nG: Id = \"x\"\n\ndef get() -> Id:\n    def inner() -> Id:\n        return G + \"y\"\n    return inner()\n" });
    try proj.dir.writeFile(io, .{ .sub_path = "main.nox", .data = "import ta\nimport tb\n\nprint(ta.get())\nprint(tb.get())\n" });
    const main_path = try std.fmt.allocPrint(a, "{s}/main.nox", .{root});
    const r = try std.process.run(a, io, .{ .argv = &.{ "zig-out/bin/noxc", "run", "--backend", backend, main_path } });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
    try std.testing.expectEqualStrings("11\nxy\n", r.stdout);
}

test "tur takma adi + closure modul izolasyonu (llvm)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runAliasClosure(arena.allocator(), std.testing.io, "llvm");
}

test "tur takma adi + closure modul izolasyonu (qbe)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runAliasClosure(arena.allocator(), std.testing.io, "qbe");
}
