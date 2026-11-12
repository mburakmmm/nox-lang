//! `@ffi.callback` uçtan uca (iki backend): SAKLANAN üst-düzey callback (v2.1.100) ve `nox.ffi.Callback` closure tutamacı (v2.1.101, TODO 3.4 F2).
//! C tarafı `tests/compat/zig_ext/util.zig`nin `nox_test_cb_store`/`nox_test_cb_fire`ı: callback + userdata'yı saklar, sonraki çağrıda tetikler.
//! Her program QBE ve LLVM ile ayrı ayrı derlenip çalıştırılır; stdout beklenenle bire bir, stderr boş (sızıntı/çökme yok) olmalıdır.

const std = @import("std");
const build_options = @import("build_options");
const compile_helpers = @import("compile_helpers.zig");

fn expectBoth(comptime template: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try std.fmt.allocPrint(a, template, .{ build_options.util_o_path, build_options.util_o_path });
    const objs = [_][]const u8{build_options.util_o_path};
    const qbe = try compile_helpers.compileAndRunWithObjs(a, source, &objs);
    try expectRun(qbe, expected, "qbe");
    const llvm = try compile_helpers.compileAndRunLlvmWithObjs(a, source, &objs);
    try expectRun(llvm, expected, "llvm");
}

fn expectRun(r: std.process.RunResult, expected: []const u8, which: []const u8) !void {
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("[{s}] program basarisiz (stderr): {s}\n", .{ which, r.stderr });
        return error.ProgramFailed;
    }
    if (r.stderr.len != 0) {
        std.debug.print("[{s}] beklenmeyen stderr: {s}\n", .{ which, r.stderr });
        return error.UnexpectedStderrOutput;
    }
    try std.testing.expectEqualStrings(expected, r.stdout);
}

test "v2.1.100 SAKLANAN üst-düzey callback: C kaydeder, Nox başka çağrılarda/işlevlerde sonradan tetikler (iki backend)" {
    try expectBoth(
        \\def on_event(x: int) -> int:
        \\    return x * 2 + 1
        \\
        \\def on_other(x: int) -> int:
        \\    return x - 100
        \\
        \\@ffi.callback("cb", "userdata")
        \\extern def nox_test_cb_store(cb: (int, ptr) -> int, userdata: ptr) -> None from "{s}"
        \\extern def nox_test_cb_fire(x: int) -> int from "{s}"
        \\
        \\def fire_twice(x: int) -> int:
        \\    return nox_test_cb_fire(x) + nox_test_cb_fire(x + 1)
        \\
        \\nox_test_cb_store(on_event)
        \\print(nox_test_cb_fire(20))
        \\print(fire_twice(5))
        \\nox_test_cb_store(on_other)
        \\print(nox_test_cb_fire(150))
        \\
    , "41\n24\n50\n");
}

test "v2.1.101 nox.ffi.Callback: closure/lambda callback'i — C saklar, Nox sonra tetikler; close() sonrası kullanım yok (iki backend)" {
    try expectBoth(
        \\import nox.ffi
        \\from nox.ffi import Callback
        \\
        \\@ffi.callback("cb", "userdata")
        \\extern def nox_test_cb_store(cb: (int, ptr) -> int, userdata: ptr) -> None from "{s}"
        \\extern def nox_test_cb_fire(x: int) -> int from "{s}"
        \\
        \\def make(k: int) -> Callback[(int) -> int]:
        \\    return Callback[(int) -> int](lambda x: x * k + 1)
        \\
        \\a: Callback[(int) -> int] = Callback[(int) -> int](lambda x: x + 100)
        \\nox_test_cb_store(a)
        \\print(nox_test_cb_fire(5))
        \\
        \\b: Callback[(int) -> int] = make(3)
        \\nox_test_cb_store(b)
        \\print(nox_test_cb_fire(10))
        \\a.close()
        \\print(nox_test_cb_fire(2))
        \\b.close()
        \\b.close()
        \\c0: Callback[(int) -> int] = Callback[(int) -> int](lambda x: x - 1)
        \\with c0 as c:
        \\    nox_test_cb_store(c)
        \\    print(nox_test_cb_fire(50))
        \\
    , "105\n31\n7\n49\n");
}
