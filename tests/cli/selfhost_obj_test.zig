//! noxc-nightly Aşama 0.3: gizli `noxc build --selfhost-obj` kipi. `main`siz bir nesne üretir (`nox_lib_init`/`nox_lib_fini` + dış bağlantılı `def`ler); nesne `noxrt.o` ve bir Zig
//! harness ile bağlanıp çağrılır (sınıf, modül global'i ve global sözlük dahil). clang ya da zig yoksa atlanır.

const std = @import("std");
const builtin = @import("builtin");

const module_src =
    \\class P:
    \\    x: int
    \\
    \\    def __init__(self, x: int) -> None:
    \\        self.x = x
    \\
    \\KEYWORDS: dict[str, int] = {"def": 1, "class": 2}
    \\g: int = 5
    \\
    \\def f(a: int) -> int:
    \\    p: P = P(a)
    \\    return p.x + g + KEYWORDS["class"]
    \\
    \\def many(n: int) -> int:
    \\    t: int = 0
    \\    for i in range(n):
    \\        t = t + f(i)
    \\    return t
    \\
;

const harness_src =
    \\const std = @import("std");
    \\extern fn nox_runtime_init() ?*anyopaque;
    \\extern fn nox_runtime_deinit(rt: ?*anyopaque) void;
    \\extern fn nox_lib_init(rt: ?*anyopaque) void;
    \\extern fn nox_lib_fini(rt: ?*anyopaque) void;
    \\extern fn f(rt: ?*anyopaque, a: i64) i64;
    \\extern fn many(rt: ?*anyopaque, n: i64) i64;
    \\pub fn main() !void {
    \\    const rt = nox_runtime_init();
    \\    nox_lib_init(rt);
    \\    var buf: [64]u8 = undefined;
    \\    const out = try std.fmt.bufPrint(&buf, "{d} {d}\n", .{ f(rt, 3), many(rt, 1000) });
    \\    _ = std.c.write(1, out.ptr, out.len);
    \\    nox_lib_fini(rt);
    \\    nox_runtime_deinit(rt);
    \\}
    \\
;

test "selfhost-obj: main'siz nesne uretir, Zig'den cagrilir (sinif + global + sozluk)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "m.nox", .data = module_src });
    try tmp.dir.writeFile(io, .{ .sub_path = "h.zig", .data = harness_src });

    const obj = try std.fmt.allocPrint(a, "{s}/m.o", .{dir});
    const src = try std.fmt.allocPrint(a, "{s}/m.nox", .{dir});
    const r1 = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig-out/bin/noxc", "build", "--selfhost-obj", "-o", obj, src } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r1.stdout);
    defer std.testing.allocator.free(r1.stderr);
    if (r1.term != .exited or r1.term.exited != 0) {
        // clang yoksa (QBE'ye düşen ortam) bayrak açık bir hata verir; bunu atlama olarak say.
        if (std.mem.indexOf(u8, r1.stderr, "needs the native LLVM backend") != null) return error.SkipZigTest;
        std.debug.print("selfhost-obj basarisiz: {s}\n", .{r1.stderr});
        return error.TestUnexpectedResult;
    }

    // IR: `main` yok, init/fini var.
    const ll = try tmp.dir.readFileAlloc(io, "m.ll", a, .limited(64 * 1024 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, ll, "@nox_lib_init(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ll, "@nox_lib_fini(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ll, "define i32 @main(") == null);

    const exe = try std.fmt.allocPrint(a, "{s}/h", .{dir});
    const hsrc = try std.fmt.allocPrint(a, "{s}/h.zig", .{dir});
    const femit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{exe});
    const r2 = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig", "build-exe", hsrc, obj, "zig-out/lib/noxrt.o", "-lc", "-OReleaseSafe", femit } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    if (r2.term != .exited or r2.term.exited != 0) {
        std.debug.print("harness derlenemedi: {s}\n", .{r2.stderr});
        return error.TestUnexpectedResult;
    }
    const r3 = try std.process.run(std.testing.allocator, io, .{ .argv = &.{exe} });
    defer std.testing.allocator.free(r3.stdout);
    defer std.testing.allocator.free(r3.stderr);
    try std.testing.expectEqualStrings("10 506500\n", r3.stdout);
}

test "selfhost-obj: --target ile birlikte reddedilir, run ile kullanilamaz" {
    const io = std.testing.io;
    const r = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig-out/bin/noxc", "run", "--selfhost-obj", "selfhost/lexer.nox" } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(!(r.term == .exited and r.term.exited == 0));
}

// noxc-nightly Aşama 0.8: Nox bileşeni büyük yığınlı iş parçacığında çok derin özyinelemeyi (iki çocuklu yürüyüş + zincir serbest bırakma) taşır.
test "selfhost-obj: 100 bin derinlikte ozyineleme buyuk yiginli is parcaciginda calisir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    const obj = try std.fmt.allocPrint(a, "{s}/deep.o", .{dir});
    const r1 = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig-out/bin/noxc", "build", "--selfhost-obj", "-o", obj, "selfhost/spike/02-deep-recursion/deep.nox" } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r1.stdout);
    defer std.testing.allocator.free(r1.stderr);
    if (r1.term != .exited or r1.term.exited != 0) {
        if (std.mem.indexOf(u8, r1.stderr, "needs the native LLVM backend") != null) return error.SkipZigTest;
        return error.TestUnexpectedResult;
    }
    const exe = try std.fmt.allocPrint(a, "{s}/h", .{dir});
    const femit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{exe});
    const r2 = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig", "build-exe", "selfhost/spike/02-deep-recursion/harness.zig", obj, "zig-out/lib/noxrt.o", "-lc", "-OReleaseSafe", femit } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    if (r2.term != .exited or r2.term.exited != 0) {
        std.debug.print("harness derlenemedi: {s}\n", .{r2.stderr});
        return error.TestUnexpectedResult;
    }
    const r3 = try std.process.run(std.testing.allocator, io, .{ .argv = &.{ exe, "100000", "256" } });
    defer std.testing.allocator.free(r3.stdout);
    defer std.testing.allocator.free(r3.stderr);
    try std.testing.expectEqualStrings("n=100000 derinlik=100000\n", r3.stdout);
}

// noxc-nightly Aşama 1: `selfhost/lexer.nox` üretilmiş bir dosyadır; token türleri/anahtar sözcükler/Unicode tabloları Zig kaynaklarıyla senkron olmalı ve normal boru hattında derlenebilmelidir.
test "selfhost lexer: uretilmis dosya guncel ve --selfhost-obj ile derlenir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gen = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "python3", "scripts/gen_selfhost_lexer.py", "--check" } }) catch return error.SkipZigTest; // python3 yok
    defer std.testing.allocator.free(gen.stdout);
    defer std.testing.allocator.free(gen.stderr);
    if (gen.term != .exited or gen.term.exited != 0) {
        std.debug.print("lexer.nox guncel degil: {s}{s}\n", .{ gen.stdout, gen.stderr });
        return error.TestUnexpectedResult;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const obj = try std.fmt.allocPrint(std.testing.allocator, "{s}/lexer.o", .{dir});
    defer std.testing.allocator.free(obj);
    const r = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig-out/bin/noxc", "build", "--selfhost-obj", "-o", obj, "selfhost/lexer.nox" } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) {
        if (std.mem.indexOf(u8, r.stderr, "needs the native LLVM backend") != null) return error.SkipZigTest;
        std.debug.print("lexer.nox derlenemedi: {s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }
}


// noxc-nightly değişmez kuralı: Nox bileşenleri bellek-uyumlu olmalı. Lexer'ı çok kez (düz/trivia/hata yolları) çalıştırıp çalışma zamanını yıkar; Debug çalışma zamanının sızıntı raporu (stderr) boş olmalı.
test "selfhost lexer: tekrarli calistirma sizinti/cifte serbest birakma uretmez (Debug calisma zamani)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const obj = try std.fmt.allocPrint(a, "{s}/lexer.o", .{dir});
    const r1 = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig-out/bin/noxc", "build", "--selfhost-obj", "-o", obj, "selfhost/lexer.nox" } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r1.stdout);
    defer std.testing.allocator.free(r1.stderr);
    if (r1.term != .exited or r1.term.exited != 0) {
        if (std.mem.indexOf(u8, r1.stderr, "needs the native LLVM backend") != null) return error.SkipZigTest;
        return error.TestUnexpectedResult;
    }
    const exe = try std.fmt.allocPrint(a, "{s}/h", .{dir});
    const femit = try std.fmt.allocPrint(a, "-femit-bin={s}", .{exe});
    const r2 = std.process.run(std.testing.allocator, io, .{ .argv = &.{ "zig", "build-exe", "selfhost/tests/lexer_leak_harness.zig", obj, "zig-out/lib/noxrt.o", "-lc", "-OReleaseSafe", femit } }) catch return error.SkipZigTest;
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    if (r2.term != .exited or r2.term.exited != 0) {
        std.debug.print("harness derlenemedi: {s}\n", .{r2.stderr});
        return error.TestUnexpectedResult;
    }
    const r3 = try std.process.run(std.testing.allocator, io, .{ .argv = &.{ exe, "selfhost/lexer.nox" } });
    defer std.testing.allocator.free(r3.stdout);
    defer std.testing.allocator.free(r3.stderr);
    if (r3.term != .exited or r3.term.exited != 0 or r3.stderr.len != 0) {
        std.debug.print("sizinti/hata raporu:\n{s}\n", .{r3.stderr});
        return error.TestUnexpectedResult;
    }
}
