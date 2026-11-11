//! WASM yorumlayıcısı — gerçek derleyici çıktısı (zig cc -> wasm32, `tests/compat/wasm_programs/prog.c`) üzerinde Node/V8 ile farksal doğrulama
//! (v2.1.65, TODO 4.2). Beklenen sonuçlar `scripts/wasm_gen_programs.py` ile V8'den alınır; burada aynı çağrılar yorumlayıcıda oynatılır.

const std = @import("std");
const wasm = @import("wasm_bridge");

const prog_wasm = @embedFile("wasm_programs/prog.wasm");
const expected = @embedFile("wasm_programs/prog.expected");

test "derleyici çıktısı: tüm program çağrıları V8 ile bit-bit aynı" {
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, prog_wasm);
    defer m.deinit();
    const inst = try wasm.interp.Instance.init(a, &m, &.{}, .{ .fuel = 4_000_000_000 });
    defer inst.deinit();

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const head = it.next().?;
        const colon = std.mem.indexOfScalar(u8, head, ':').?;
        const name = head[0..colon];
        const idx = inst.findExport(name, .func) orelse return error.ExportNotFound;
        const ft = m.typeOf(idx);
        var args: [4]u64 = undefined;
        var n: usize = 0;
        var want: []const u8 = "";
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "=")) {
                want = it.next().?;
                break;
            }
            const pt = ft.params[n];
            args[n] = switch (pt) {
                .i32 => @as(u32, @truncate(@as(u64, @bitCast(try std.fmt.parseInt(i64, tok, 10))))),
                .i64 => @bitCast(try std.fmt.parseInt(i64, tok, 10)),
                .f32 => @as(u32, @bitCast(try std.fmt.parseFloat(f32, tok))),
                .f64 => @bitCast(try std.fmt.parseFloat(f64, tok)),
                else => unreachable,
            };
            n += 1;
        }
        try std.testing.expectEqual(ft.params.len, n);
        var res: [1]u64 = .{0};
        const outcome = inst.invoke(idx, args[0..n], &res);
        if (std.mem.eql(u8, want, "trap")) {
            try std.testing.expect(std.meta.isError(outcome));
            continue;
        }
        outcome catch |e| {
            std.debug.print("{s} -> {s}\n", .{ line, @errorName(e) });
            return e;
        };
        const rt = ft.results[0];
        const got = if (rt == .i32 or rt == .f32) res[0] & 0xffff_ffff else res[0];
        if (std.mem.eql(u8, want, "nan")) {
            try std.testing.expect(std.math.isNan(@as(f64, @bitCast(res[0]))) or rt == .f32);
            continue;
        }
        const w = try std.fmt.parseUnsigned(u64, want, 16);
        if (got != w) {
            std.debug.print("FARK: {s}  bulunan {x}\n", .{ line, got });
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expect(count >= 50);
}
