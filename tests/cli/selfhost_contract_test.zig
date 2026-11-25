//! R1-P1.7/P1.8/P1.11/P1.14 (v2.2.48): Zig↔Nox selfhost sınırı sözleşmesi. `noxc-nightly` / `zig-out/nightly/selfhost.o` yoksa nightly'e bağlı testler atlanır
//! (opt-in: `zig build nightly`); ayrıca `zig build frontend-diff-test` `noxc-nightly selfhost-contract` süreç-içi sözleşmesini çalıştırır.

const std = @import("std");
const builtin = @import("builtin");

fn have(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn run(argv: []const []const u8) !std.process.RunResult {
    return std.process.run(std.testing.allocator, std.testing.io, .{ .argv = argv });
}

// P1.11: başarısız `noxc fmt` kaynak dosyayı DEĞİŞTİRMEZ (kararlı noxc ve nightly --frontend nox).
test "fmt: bozuk kaynakta cikis 1 ve dosya bayt-bayt degismez" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const bins = [_][]const []const u8{
        &.{"zig-out/bin/noxc"},
        &.{ "zig-out/bin/noxc-nightly", "--frontend", "nox" },
    };
    for (bins) |bin| {
        if (!have(io, bin[0])) continue;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const bad = "def f(x: int) -> int:\n    return (x +\n";
        try tmp.dir.writeFile(io, .{ .sub_path = "bad.nox", .data = bad });
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir = buf[0..try tmp.dir.realPath(io, &buf)];
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bad.nox", .{dir});
        defer std.testing.allocator.free(path);
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(std.testing.allocator);
        try argv.appendSlice(std.testing.allocator, bin);
        try argv.appendSlice(std.testing.allocator, &.{ "fmt", path });
        const r = try run(argv.items);
        defer std.testing.allocator.free(r.stdout);
        defer std.testing.allocator.free(r.stderr);
        try std.testing.expect(!(r.term == .exited and r.term.exited == 0));
        const after = try tmp.dir.readFileAlloc(io, "bad.nox", std.testing.allocator, .limited(4096));
        defer std.testing.allocator.free(after);
        try std.testing.expectEqualStrings(bad, after);
    }
}

// P1.14: bench kapısı — boş girdi / 0 tekrar anlamsız sonuçtur, kip başlığı basılır, çıkış kodu 1.
test "bench kapisi: bos girdi reddedilir, baslik kip/commit icerir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    if (!have(io, "zig-out/bin/noxc-nightly")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.nox", .data = "" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/empty.nox", .{dir});
    defer std.testing.allocator.free(path);
    for ([_][]const u8{ "parse-bench", "fmt-bench" }) |kind| {
        const r = try run(&.{ "zig-out/bin/noxc-nightly", kind, path, "1", "--allow-debug" });
        defer std.testing.allocator.free(r.stdout);
        defer std.testing.allocator.free(r.stderr);
        try std.testing.expect(r.term == .exited and r.term.exited == 1);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "kip: derleyici=") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "commit=") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "bos girdi") != null);
    }
}

// P1.8: birleşik selfhost nesnesinin sembol sözleşmesi — `selfhost_glue.zig`in her `extern fn`i nesnede TANIMLI; `nox_lib_init`/`nox_lib_fini` tam bir kez; tekrar eden global tanım yok (çift bağlama koruması).
test "selfhost.o sembol sozlesmesi: glue extern'leri tanimli, init/fini tekil, cift tanim yok" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const obj = "zig-out/nightly/selfhost.o";
    if (!have(io, obj)) return error.SkipZigTest;
    const nm = run(&.{ "nm", "-g", obj }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(nm.stdout);
    defer std.testing.allocator.free(nm.stderr);
    if (!(nm.term == .exited and nm.term.exited == 0)) return error.SkipZigTest;

    var defined = std.StringHashMap(u32).init(std.testing.allocator);
    defer defined.deinit();
    var it = std.mem.tokenizeScalar(u8, nm.stdout, '\n');
    while (it.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next() orelse continue; // adres
        const kind = f.next() orelse continue;
        var name = f.next() orelse continue;
        if (kind.len != 1 or std.mem.indexOfScalar(u8, "TDBS", kind[0]) == null) continue;
        if (name[0] == '_') name = name[1..]; // macOS alt çizgi öneki
        const gop = try defined.getOrPut(name);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    var dup = defined.iterator();
    while (dup.next()) |e| {
        if (e.value_ptr.* != 1) std.debug.print("cift tanimli sembol: {s} x{d}\n", .{ e.key_ptr.*, e.value_ptr.* });
        try std.testing.expectEqual(@as(u32, 1), e.value_ptr.*);
    }
    try std.testing.expect(defined.contains("nox_lib_init"));
    try std.testing.expect(defined.contains("nox_lib_fini"));

    const glue = try std.Io.Dir.cwd().readFileAlloc(io, "compiler/selfhost_glue.zig", std.testing.allocator, .limited(1 << 22));
    defer std.testing.allocator.free(glue);
    var lines = std.mem.tokenizeScalar(u8, glue, '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        const pre = "extern fn ";
        if (!std.mem.startsWith(u8, line, pre)) continue;
        const rest = line[pre.len..];
        const end = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const sym = rest[0..end];
        // çalışma zamanı simgeleri (`nox_runtime_*`, `nox_mem_stat`) noxrt.o'dan gelir; geri kalanı selfhost.o tanımlamalıdır
        if (std.mem.startsWith(u8, sym, "nox_runtime_") or std.mem.eql(u8, sym, "nox_mem_stat")) continue;
        if (!defined.contains(sym)) std.debug.print("glue extern tanimsiz: {s}\n", .{sym});
        try std.testing.expect(defined.contains(sym));
        checked += 1;
    }
    try std.testing.expect(checked >= 20);
}

// Aşama 3.1: Zig `typecheck/types.zig` ↔ Nox `selfhost/types.nox` farksal denetimi (format/mangle/eql⇔TypeId/assignable/FixedIntKind/invariantlar). Nightly yoksa atlanır.
test "types-diff: Zig tip temsili ile Nox tip tablosu farksiz (3 tohum)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    if (!have(io, "zig-out/bin/noxc-nightly")) return error.SkipZigTest;
    for ([_][]const u8{ "1", "7", "99" }) |seed| {
        const r = try run(&.{ "zig-out/bin/noxc-nightly", "types-diff", "1500", seed });
        defer std.testing.allocator.free(r.stdout);
        defer std.testing.allocator.free(r.stderr);
        try std.testing.expect(r.term == .exited and r.term.exited == 0);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "types-diff: OK") != null);
    }
}
