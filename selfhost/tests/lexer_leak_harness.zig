//! noxc-nightly kural (tam geçiş ⇒ bellek-uyumlu): Nox lexer'ı aynı kaynak üzerinde çok kez (düz + trivia, hata yolları dahil) çalıştırıp çalışma zamanını yıkar.
//! Debug `noxrt.o` ile (`zig build test`in bıraktığı) bir sızıntı/çifte serbest bırakma `DebugAllocator` tarafından stderr'e raporlanır; test stderr'in BOŞ olmasını bekler.
const std = @import("std");
extern fn nox_runtime_init() ?*anyopaque;
extern fn nox_runtime_deinit(rt: ?*anyopaque) void;
extern fn nox_lib_init(rt: ?*anyopaque) void;
extern fn nox_lib_fini(rt: ?*anyopaque) void;
extern fn nox_lex_run(rt: ?*anyopaque, base: i64, n: i64, want_trivia: i64) i64;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.NoPath;
    const src = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(src);
    const rt = nox_runtime_init();
    nox_lib_init(rt);
    var first: i64 = -1;
    var round: usize = 0;
    while (round < 60) : (round += 1) {
        const n = nox_lex_run(rt, @intCast(@intFromPtr(src.ptr)), @intCast(src.len), @intCast(round % 2));
        if (first < 0) first = n;
        if (n != first) return error.UnstableResult;
        // hata yolu: kaynağın ortasından kesilmiş (kapanmamış dize/girinti hataları üretebilir) ve bozuk girdiler
        const cut = src[0 .. src.len / 3 + round];
        _ = nox_lex_run(rt, @intCast(@intFromPtr(cut.ptr)), @intCast(cut.len), 1);
        const bad = "x = $\n";
        _ = nox_lex_run(rt, @intCast(@intFromPtr(bad.ptr)), @intCast(bad.len), 0);
        const unterminated = "s = \"abc\n";
        _ = nox_lex_run(rt, @intCast(@intFromPtr(unterminated.ptr)), @intCast(unterminated.len), 0);
    }
    nox_lib_fini(rt);
    nox_runtime_deinit(rt);
}
