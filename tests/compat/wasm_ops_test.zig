//! WASM yorumlayıcısı — sayısal komutların Node/V8 `WebAssembly` motoruna karşı FARKSAL doğrulaması (v2.1.65, TODO 4.2).
//!
//! `tests/compat/wasm_ops/ops.wasm` her sayısal komut için bir işlev içerir; `vectors.txt` her (komut, uç-değer argümanları) için V8'in verdiği
//! sonucu tutar (`scripts/wasm_gen_vectors.py` üretir; `--check` ile CI'de Node'a karşı yeniden doğrulanır). Bu test aynı vektörleri Nox yorumlayıcısında
//! oynatır: sonuç bit-bit aynı olmalı (NaN için yalnızca "NaN mı" karşılaştırılır), `trap` beklenen yerde herhangi bir tuzak oluşmalıdır.

const std = @import("std");
const wasm = @import("wasm_bridge");

const ops_wasm = @embedFile("wasm_ops/ops.wasm");
const vectors = @embedFile("wasm_ops/vectors.txt");

fn parseHex(s: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, s, 16);
}

test "farksal: tüm sayısal komutlar V8 ile bit-bit aynı sonucu verir" {
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, ops_wasm);
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
        var args: [2]u64 = undefined;
        var nargs: usize = 0;
        var expected: []const u8 = "";
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "=")) {
                expected = it.next().?;
                break;
            }
            args[nargs] = try parseHex(tok);
            nargs += 1;
        }
        const idx = inst.findExport(name, .func) orelse return error.ExportNotFound;
        const ft = m.typeOf(idx);
        var res: [1]u64 = .{0};
        const outcome = inst.invoke(idx, args[0..nargs], &res);
        var ok = true;
        if (std.mem.eql(u8, expected, "trap")) {
            ok = if (outcome) |_| false else |_| true;
        } else if (outcome) |_| {
            const rt = ft.results[0];
            if (std.mem.eql(u8, expected, "nan")) {
                ok = switch (rt) {
                    .f32 => std.math.isNan(@as(f32, @bitCast(@as(u32, @truncate(res[0]))))),
                    .f64 => std.math.isNan(@as(f64, @bitCast(res[0]))),
                    else => false,
                };
            } else {
                const want = try parseHex(expected);
                const got = if (rt == .i32 or rt == .f32) res[0] & 0xffff_ffff else res[0];
                ok = got == want;
            }
        } else |_| ok = false;
        if (!ok) {
            failures += 1;
            if (failures <= 25) std.debug.print("FARK: {s}  (beklenen {s}, bulunan {any} / {x})\n", .{ line, expected, outcome, res[0] });
        }
    }
    try std.testing.expect(total > 30000);
    try std.testing.expectEqual(@as(usize, 0), failures);
}
