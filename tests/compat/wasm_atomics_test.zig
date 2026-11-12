//! WASM threads atomiklerinin (paylaşımlı bellek) V8'e karşı FARKSAL doğrulaması (v2.1.99, TODO 4.6).
//!
//! `tests/compat/wasm_atomics/atomics.wasm` her atomik komut için bir işlev içerir; `vectors.txt` her (işlev, uç-değer/hizasız/sınır-dışı adres) için V8'in
//! verdiği sonucu tutar (`scripts/wasm_gen_atomics_vectors.py` üretir). Bu test aynı vektörleri Nox yorumlayıcısında oynatır: sonuç bit-bit aynı olmalı,
//! `trap` beklenen yerde herhangi bir tuzak oluşmalıdır. Ardından tek iş parçacıklı `wait` davranışı ve paylaşımsız bellekte `wait` tuzağı ayrıca sınanır.

const std = @import("std");
const wasm = @import("wasm_bridge");

const atomics_wasm = @embedFile("wasm_atomics/atomics.wasm");
const vectors = @embedFile("wasm_atomics/vectors.txt");

fn parseHex(s: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, s, 16);
}

test "farksal: tüm atomik komutlar V8 ile bit-bit aynı sonucu verir" {
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, atomics_wasm);
    defer m.deinit();
    try std.testing.expect(m.mems[0].shared);
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
        var args: [4]u64 = undefined;
        var nargs: usize = 0;
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "=")) break;
            args[nargs] = try parseHex(tok);
            nargs += 1;
        }
        var want: [2]u64 = undefined;
        var nwant: usize = 0;
        var trap = false;
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "trap")) {
                trap = true;
            } else {
                want[nwant] = try parseHex(tok);
                nwant += 1;
            }
        }
        const idx = inst.findExport(name, .func) orelse return error.ExportNotFound;
        var res: [2]u64 = .{ 0, 0 };
        const nres = m.typeOf(idx).results.len;
        const outcome = inst.invoke(idx, args[0..nargs], res[0..nres]);
        var ok = true;
        if (trap) {
            ok = if (outcome) |_| false else |_| true;
        } else if (outcome) |_| {
            for (0..nwant) |i| if (res[i] != want[i]) {
                ok = false;
            };
        } else |_| ok = false;
        if (!ok) {
            failures += 1;
            if (failures <= 25) std.debug.print("FARK: {s}  (bulunan {any} / {x} {x})\n", .{ line, outcome, res[0], res[1] });
        }
    }
    try std.testing.expect(total > 4000);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "tek iş parçacığında wait: sonsuz bekleme kilitlenmek yerine tuzaktır; paylaşımsız bellekte wait tuzaktır" {
    const a = std.testing.allocator;
    var m = try wasm.module.parse(a, atomics_wasm);
    defer m.deinit();
    const inst = try wasm.interp.Instance.init(a, &m, &.{}, .{});
    defer inst.deinit();
    const idx = inst.findExport("memory.atomic.wait32", .func).?;
    var res: [2]u64 = undefined;
    // değer (desenin alt 32 biti) eşit, zaman aşımı sonsuz (-1): hiçbir iş parçacığı uyandıramaz
    try std.testing.expectError(error.WaitWouldBlock, inst.invoke(idx, &.{ 0, 0xB4A59687, 0xffff_ffff_ffff_ffff }, res[0..2]));

    // paylaşımsız bellekli modül: (memory 1) (func (export "w") (result i32) i32.const 0 i32.const 0 i64.const 0 memory.atomic.wait32)
    const unshared = [_]u8{ 0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 127, 3, 2, 1, 0, 5, 3, 1, 0, 1, 7, 5, 1, 1, 119, 0, 0, 10, 14, 1, 12, 0, 65, 0, 65, 0, 66, 0, 254, 1, 2, 0, 11 };
    var m2 = try wasm.module.parse(a, &unshared);
    defer m2.deinit();
    const inst2 = try wasm.interp.Instance.init(a, &m2, &.{}, .{});
    defer inst2.deinit();
    var r2: [1]u64 = undefined;
    try std.testing.expectError(error.ExpectedSharedMemory, inst2.invoke(inst2.findExport("w", .func).?, &.{}, &r2));
}
