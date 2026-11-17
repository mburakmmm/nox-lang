//! Faz 10 (WASM): wasm32'de `printf` biçimleyicisi (ADR-013/ADR-015) — `wasm_libc.zig` (freestanding, `nox_host.write`) ve `wasm_threads_libc.zig` (iş parçacıklı wasi) paylaşır.
//! Üretilen kod yalnızca tek yer tutuculu biçim dizeleriyle çağırır; alt küme: `%lld %llu %ld %lu %d %u %s %c %g %f %%`.

const std = @import("std");

/// `printf`in desteklediği alt küme: `%lld %llu %ld %lu %d %u %s %c %g %f %%`. Her yer tutucu bir `i64`/`u64`/`f64`/işaretçi değişken argümanıdır;
/// wasm32'de `long` 32-bit olduğundan Nox kodu daima `ll` ile çağırır, `%d`/`%ld` de 32-bit okunur.
pub fn printfImpl(comptime emit: fn ([]const u8) void, f: [*:0]const u8, ap: *std.builtin.VaList) usize {
    var out: [1024]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (f[i] != 0) : (i += 1) {
        const c = f[i];
        if (c != '%') {
            if (pos < out.len) {
                out[pos] = c;
                pos += 1;
            }
            continue;
        }
        i += 1;
        var long_count: usize = 0;
        while (f[i] == 'l') : (i += 1) long_count += 1;
        const conv = f[i];
        if (conv == 0) break;
        var tmp: [64]u8 = undefined;
        var piece: []const u8 = "";
        switch (conv) {
            'd', 'i' => piece = if (long_count >= 1) fmt64i(&tmp, @cVaArg(ap, i64)) else fmt64i(&tmp, @cVaArg(ap, i32)),
            'u' => piece = if (long_count >= 1) fmt64u(&tmp, @cVaArg(ap, u64)) else fmt64u(&tmp, @cVaArg(ap, u32)),
            'g', 'f' => piece = std.fmt.bufPrint(&tmp, "{d}", .{@cVaArg(ap, f64)}) catch "",
            'c' => {
                tmp[0] = @intCast(@cVaArg(ap, i32) & 0xff);
                piece = tmp[0..1];
            },
            's' => {
                const sp = @cVaArg(ap, ?[*:0]const u8);
                if (sp) |s| piece = std.mem.span(s);
            },
            '%' => piece = "%",
            else => {},
        }
        // Parça tamponun kalanından uzunsa (ör. 1 KiB'den uzun bir `%s`) KIRPILMAZ: önce biriken kısım, sonra parçanın tamamı tek `emit` ile yazılır
        // (2.3 madde 5.5: iş parçacıklı WASI'de 1 KiB'den uzun her `print` sessizce kesiliyordu).
        if (piece.len > out.len - pos) {
            if (pos > 0) {
                emit(out[0..pos]);
                pos = 0;
            }
            emit(piece);
            continue;
        }
        @memcpy(out[pos..][0..piece.len], piece);
        pos += piece.len;
        if (pos == out.len) {
            emit(out[0..pos]);
            pos = 0;
        }
    }
    if (pos > 0) emit(out[0..pos]);
    return pos;
}

fn fmt64i(buf: []u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
}

fn fmt64u(buf: []u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
}

test "printfImpl: tampondan uzun %s parçası kırpılmaz" {
    const Sink = struct {
        var buf: [8192]u8 = undefined;
        var len: usize = 0;
        fn emit(b: []const u8) void {
            @memcpy(buf[len..][0..b.len], b);
            len += b.len;
        }
    };
    Sink.len = 0;
    var big: [3000:0]u8 = undefined;
    @memset(&big, 'x');
    big[big.len] = 0;
    const T = struct {
        fn call(fmt: [*:0]const u8, ...) callconv(.c) usize {
            var ap = @cVaStart();
            defer @cVaEnd(&ap);
            return printfImpl(Sink.emit, fmt, &ap);
        }
    };
    _ = T.call("a%sb\n", @as(?[*:0]const u8, &big));
    try std.testing.expectEqual(@as(usize, 3000 + 3), Sink.len);
    try std.testing.expectEqual(@as(u8, 'a'), Sink.buf[0]);
    try std.testing.expectEqual(@as(u8, 'x'), Sink.buf[3000]);
    try std.testing.expectEqual(@as(u8, 'b'), Sink.buf[3001]);
    try std.testing.expectEqual(@as(u8, '\n'), Sink.buf[3002]);
}
