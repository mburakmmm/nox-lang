//! noxc-nightly kural (tam geçiş ⇒ bellek-uyumlu): Nox parser'ı aynı kaynak üzerinde çok kez (başarı + hata yolları + dökümler) çalıştırıp çalışma zamanını yıkar.
//! Debug `noxrt.o` ile (`zig build test`in bıraktığı) bir sızıntı/çifte serbest bırakma `DebugAllocator` tarafından stderr'e raporlanır; test stderr'in BOŞ olmasını bekler.
const std = @import("std");
extern fn nox_runtime_init() ?*anyopaque;
extern fn nox_runtime_deinit(rt: ?*anyopaque) void;
extern fn nox_lib_init(rt: ?*anyopaque) void;
extern fn nox_lib_fini(rt: ?*anyopaque) void;
extern fn parser_nox_parse_run(rt: ?*anyopaque, base: i64, n: i64) i64;
extern fn parser_nox_parse_dump(rt: ?*anyopaque) i64;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.NoPath;
    const src = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(64 * 1024 * 1024));
    defer init.gpa.free(src);
    const rt = nox_runtime_init();
    nox_lib_init(rt);
    var round: usize = 0;
    while (round < 30) : (round += 1) {
        const code = parser_nox_parse_run(rt, @intCast(@intFromPtr(src.ptr)), @intCast(src.len));
        if (code != 0) return error.ParseFailed;
        if (round % 5 == 0) _ = parser_nox_parse_dump(rt);
        // hata yolları: kesilmiş kaynak (sözdizimi/girinti hatası) ve bozuk girdiler
        const cut = src[0 .. src.len / 3 + round];
        _ = parser_nox_parse_run(rt, @intCast(@intFromPtr(cut.ptr)), @intCast(cut.len));
        const bad = [_][]const u8{ "x = = 1\n", "def f(:\n    pass\n", "s = \"abc\n", "print(1 2)\n", "x: int = 99999999999999999999\n", "match k:\n    case 1:\n        pass\n", "if x:\n" };
        for (bad) |b| _ = parser_nox_parse_run(rt, @intCast(@intFromPtr(b.ptr)), @intCast(b.len));
    }
    nox_lib_fini(rt);
    nox_runtime_deinit(rt);
}
