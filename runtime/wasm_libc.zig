//! Faz 10 (WASM): `wasm32-freestanding` çalışma zamanının libc yerine verdiği küçük küme (ADR-013). Üretilen kod yalnızca `printf` (`print()` yerleşiği,
//! her biçim dizesi en çok BİR yer tutucu içerir), `strcmp` (str eşitliği) ve `memcpy`/`memset` ailesini çağırır; son ikisi derleyici-rt'den gelir.
//! Çıktı `nox_host.write`a gider. `_start`, `main`i çağırıp çıkış kodunu host'a iletir.

const std = @import("std");
const host = @import("wasm_host.zig");
const entry = @import("wasm_entry.zig");
const wasm_printf = @import("wasm_printf.zig");

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

fn hostEmit(bytes: []const u8) void {
    _ = host.write(1, bytes.ptr, bytes.len);
}

export fn printf(fmt: ?[*:0]const u8, ...) callconv(.c) c_int {
    const f = fmt orelse return 0;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    return @intCast(wasm_printf.printfImpl(hostEmit, f, &ap));
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
var g_argv0 = [_]?[*:0]const u8{ "nox", null };

export fn _start() callconv(.c) void {
    host.exit(entry.run(1, @intFromPtr(&g_argv0)));
}

export fn nox_host_abi_version() callconv(.c) u32 {
    return host.ABI_VERSION;
}
