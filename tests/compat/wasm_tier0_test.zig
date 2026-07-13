//! Nox WASM köprüsü — uçtan uca uyumluluk testi (AGENTS.md §11). GERÇEK,
//! `zig`in kendisiyle `wasm32-freestanding` hedefine derlenmiş bir `.wasm`
//! ikilisini (bkz. `tests/compat/wasm_ext/addone.zig`, `build.zig`) diskten
//! okuyup Nox'un kendi ayrıştırıcısı/yorumlayıcısıyla (`runtime/wasm_bridge`)
//! çalıştırır — sahte/simüle edilmiş bir modül değil, gerçek bir derleyici
//! çıktısı.

const std = @import("std");
const wasm = @import("wasm_bridge");
const hpy = @import("hpy_bridge");

fn readWasmFile(allocator: std.mem.Allocator) ![]u8 {
    const path = @import("build_options").addone_wasm_path;
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
}

test "gerçek WASM modülü: add_one(41) == 42 (doğrudan i32 API)" {
    const allocator = std.testing.allocator;
    const bytes = try readWasmFile(allocator);
    defer allocator.free(bytes);

    var mod = try wasm.module.parse(allocator, bytes);
    defer mod.deinit();

    const idx = mod.findExportedFunc("add_one") orelse return error.ExportNotFound;
    const result = try wasm.interp.callFunc(allocator, &mod, idx, &.{41});
    try std.testing.expectEqual(@as(i32, 42), result.?);
}

test "gerçek WASM modülü: add_two(a, b) — fonksiyonlar arası `call` talimatı" {
    const allocator = std.testing.allocator;
    const bytes = try readWasmFile(allocator);
    defer allocator.free(bytes);

    var mod = try wasm.module.parse(allocator, bytes);
    defer mod.deinit();

    const idx = mod.findExportedFunc("add_two") orelse return error.ExportNotFound;
    // add_two(10, 20) = add_one(10) + add_one(20) = 11 + 21 = 32
    const result = try wasm.interp.callFunc(allocator, &mod, idx, &.{ 10, 20 });
    try std.testing.expectEqual(@as(i32, 32), result.?);
}

test "gerçek WASM modülü: HPy ile AYNI handle sistemi üzerinden çağrı" {
    const allocator = std.testing.allocator;
    const bytes = try readWasmFile(allocator);
    defer allocator.free(bytes);

    var mod = try wasm.module.parse(allocator, bytes);
    defer mod.deinit();

    const ctx = try hpy.context.createContext(allocator);
    defer hpy.context.destroyContext(allocator, ctx);

    const arg = ctx.ctx_Long_FromInt64_t.?(ctx, 41);
    defer ctx.ctx_Close.?(ctx, arg);

    const result = try wasm.interp.callExport(allocator, ctx, &mod, "add_one", &.{arg});
    defer ctx.ctx_Close.?(ctx, result);

    try std.testing.expectEqual(@as(i64, 42), ctx.ctx_Long_AsInt64_t.?(ctx, result));
}
