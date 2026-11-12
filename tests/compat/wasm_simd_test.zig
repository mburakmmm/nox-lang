//! WASM SIMD (v128) yorumlayıcısının V8 `WebAssembly` motoruna karşı FARKSAL doğrulaması (v2.1.98, TODO 4.6).
//!
//! `tests/compat/wasm_simd/simd.wasm` her SIMD komutu için bir işlev içerir (v128 operandlar `i64 lo, i64 hi` çiftleriyle kurulur); `vectors.txt` her
//! (işlev, uç-değer argümanları) için V8'in verdiği sonucu tutar (`scripts/wasm_gen_simd_vectors.py` üretir). Bu test aynı vektörleri Nox yorumlayıcısında
//! oynatır: sonuç bit-bit aynı olmalı; `~f32`/`~f64` işaretli satırlarda NaN lane'ler yalnızca "NaN mı" olarak karşılaştırılır; `trap` beklenen yerde herhangi
//! bir tuzak oluşmalıdır.

const std = @import("std");
const wasm = @import("wasm_bridge");

const simd_wasm = @embedFile("wasm_simd/simd.wasm");
const vectors = @embedFile("wasm_simd/vectors.txt");

fn parseHex(s: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, s, 16);
}

fn lanesEqual(comptime F: type, got: [2]u64, want: [2]u64) bool {
    const B = std.meta.Int(.unsigned, @bitSizeOf(F));
    const n = 16 / @sizeOf(F);
    const g: [n]F = @bitCast(got);
    const w: [n]F = @bitCast(want);
    for (g, w) |x, y| {
        if (std.math.isNan(x) and std.math.isNan(y)) continue;
        if (@as(B, @bitCast(x)) != @as(B, @bitCast(y))) return false;
    }
    return true;
}

test "farksal: tüm SIMD komutları V8 ile bit-bit aynı sonucu verir" {
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, simd_wasm);
    defer m.deinit();
    const inst = try wasm.interp.Instance.init(a, &m, &.{}, .{});
    defer inst.deinit();

    var total: usize = 0;
    var failures: usize = 0;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        total += 1;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const name = it.next().?;
        var args: [8]u64 = undefined;
        var nargs: usize = 0;
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "=")) break;
            args[nargs] = try parseHex(tok);
            nargs += 1;
        }
        var want: [4]u64 = undefined;
        var nwant: usize = 0;
        var trap = false;
        var flag: []const u8 = "";
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "trap")) {
                trap = true;
            } else if (tok[0] == '~') {
                flag = tok;
            } else {
                want[nwant] = try parseHex(tok);
                nwant += 1;
            }
        }
        const idx = inst.findExport(name, .func) orelse return error.ExportNotFound;
        var res: [4]u64 = .{ 0, 0, 0, 0 };
        const nres = m.typeOf(idx).results.len;
        const outcome = inst.invoke(idx, args[0..nargs], res[0..nres]);
        var ok = true;
        if (trap) {
            ok = if (outcome) |_| false else |_| true;
        } else if (outcome) |_| {
            if (std.mem.eql(u8, flag, "~f32")) {
                ok = lanesEqual(f32, .{ res[0], res[1] }, .{ want[0], want[1] });
            } else if (std.mem.eql(u8, flag, "~f64")) {
                ok = lanesEqual(f64, .{ res[0], res[1] }, .{ want[0], want[1] });
            } else {
                for (0..nwant) |i| {
                    const got = if (m.typeOf(idx).results[i] == .i32) res[i] & 0xffff_ffff else res[i];
                    if (got != want[i]) ok = false;
                }
            }
        } else |_| ok = false;
        if (!ok) {
            failures += 1;
            if (failures <= 25) std.debug.print("FARK: {s}  (bulunan {any} / {x} {x})\n", .{ line, outcome, res[0], res[1] });
        }
    }
    try std.testing.expect(total > 8000);
    try std.testing.expectEqual(@as(usize, 0), failures);
}
