//! Faz 10 (WASM): `wasm32-freestanding` çalışma zamanının libc yerine verdiği küçük küme (ADR-013). Üretilen kod yalnızca `printf` (`print()` yerleşiği,
//! her biçim dizesi en çok BİR yer tutucu içerir), `strcmp` (str eşitliği) ve `memcpy`/`memset` ailesini çağırır; son ikisi derleyici-rt'den gelir.
//! Çıktı `nox_host.write`a gider. `_start`, `main`i çağırıp çıkış kodunu host'a iletir.

const std = @import("std");
const host = @import("wasm_host.zig");

export fn strcmp(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) c_int {
    const pa = a orelse return 0;
    const pb = b orelse return 0;
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = pa[i];
        const cb = pb[i];
        if (ca != cb) return @as(c_int, ca) - @as(c_int, cb);
        if (ca == 0) return 0;
    }
}

/// `printf`in desteklediği alt küme: `%lld %llu %ld %lu %d %u %s %c %g %f %%`. Her yer tutucu bir `i64`/`u64`/`f64`/işaretçi değişken argümanıdır;
/// wasm32'de `long` 32-bit olduğundan Nox kodu daima `ll` ile çağırır, `%d`/`%ld` de 32-bit okunur.
fn printfImpl(f: [*:0]const u8, ap: *std.builtin.VaList) usize {
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
        const n = @min(piece.len, out.len - pos);
        @memcpy(out[pos..][0..n], piece[0..n]);
        pos += n;
        if (pos == out.len) {
            _ = host.write(1, &out, pos);
            pos = 0;
        }
    }
    if (pos > 0) _ = host.write(1, &out, pos);
    return pos;
}

fn fmt64i(buf: []u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
}

fn fmt64u(buf: []u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "";
}

export fn printf(fmt: ?[*:0]const u8, ...) callconv(.c) c_int {
    const f = fmt orelse return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return @intCast(printfImpl(f, &ap));
}

/// libm: `nox.math`in `extern def ... from "m"` sembolleri. Zig'in compiler-rt'si `sin/cos/exp/log/pow/floor/ceil/sqrt/fmod`i zayıf sembol olarak verir;
/// eksik olan(lar) burada tanımlanır. (Sonuçlar platform libm'den son basamakta ayrılabilir.)
fn exportWeak(comptime name: []const u8, comptime f: anytype) void {
    @export(f, .{ .name = name, .linkage = .weak });
}

fn atan2Impl(y: f64, x: f64) callconv(.c) f64 {
    return std.math.atan2(y, x);
}

fn tanImpl(x: f64) callconv(.c) f64 {
    return @tan(x);
}

comptime {
    exportWeak("atan2", &atan2Impl);
    exportWeak("tan", &tanImpl);
}

/// Derlenmiş Nox programının girişi (`main(argc, argv)`; argv işaretçisi Nox'ta 64-bit). `_start` host'un çağırdığı TEK giriştir; çıkış kodu `nox_host.exit` ile gider.
/// `argv[0]` program adıdır ("nox"); host argüman geçirmez (ADR-013).
extern fn main(argc: i32, argv: u64) callconv(.c) i32;

var g_argv0 = [_]?[*:0]const u8{ "nox", null };

export fn _start() callconv(.c) void {
    host.exit(main(1, @intFromPtr(&g_argv0)));
}

export fn nox_host_abi_version() callconv(.c) u32 {
    return host.ABI_VERSION;
}
