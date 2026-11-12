//! `noxc bindgen` uçtan uca (v2.1.104, TODO 3.4/5.1 F4): gerçek bir C başlığı + kaynağı -> `cc` ile nesne -> `bindgen.runCli` ile Nox binding'i ve C kabuğu ->
//! binding'i kullanan bir Nox programı QBE ve LLVM ile derlenip çalıştırılır; çıktılar bire bir aynı olmalı.

const std = @import("std");
const nox = @import("nox");
const compile_helpers = @import("compile_helpers.zig");

const header =
    \\#ifndef MYLIB_H
    \\#define MYLIB_H
    \\#include <stdint.h>
    \\#include <stddef.h>
    \\#define MYLIB_VERSION 3
    \\#define MYLIB_NAME "mylib"
    \\typedef struct mylib_ctx mylib_ctx;
    \\typedef enum { MYLIB_OK = 0, MYLIB_ERR = 7 } mylib_status;
    \\static const uint32_t MYLIB_FLAG_FAST = 1 << 3;
    \\mylib_ctx *mylib_new(const char *name);
    \\void mylib_free(mylib_ctx *c);
    \\mylib_status mylib_run(mylib_ctx *c, int64_t x, uint32_t flags);
    \\int64_t mylib_total(const mylib_ctx *c);
    \\static inline int mylib_twice(int x) { return x * 2; }
    \\float mylib_half(float x);
    \\int mylib_sum3(int a, int b, int c, ...);
    \\#endif
    \\
;

const source =
    \\#include "mylib.h"
    \\#include <stdlib.h>
    \\struct mylib_ctx { int64_t acc; };
    \\mylib_ctx *mylib_new(const char *name) { (void)name; return calloc(1, sizeof(mylib_ctx)); }
    \\void mylib_free(mylib_ctx *c) { free(c); }
    \\mylib_status mylib_run(mylib_ctx *c, int64_t x, uint32_t flags) { c->acc += x; return (flags & MYLIB_FLAG_FAST) ? MYLIB_OK : MYLIB_ERR; }
    \\int64_t mylib_total(const mylib_ctx *c) { return c->acc; }
    \\float mylib_half(float x) { return x / 2; }
    \\int mylib_sum3(int a, int b, int c, ...) { return a + b + c; }
    \\
;

const program =
    \\c: ptr = mylib_new("demo")
    \\print(mylib_run(c, i64(5), MYLIB_FLAG_FAST) == MYLIB_OK)
    \\print(mylib_run(c, i64(7), u32(0)) == MYLIB_ERR)
    \\print(mylib_total(c))
    \\mylib_free(c)
    \\print(mylib_twice(i32(21)))
    \\print(mylib_half_(9.0))
    \\print(MYLIB_VERSION)
    \\print(MYLIB_NAME)
    \\
;

test "bindgen: üretilen binding gerçek bir C kütüphanesini iki backend'de aynı çağırır (struct işaretçisi, enum, sabitler, satır içi işlev, float kabuğu)" {
    // Windows CI'da `cc -E`/`cc -c` ortamı (MSVC/zig cc) bu sürümde hazır değil; Unix'te (macOS, Linux) çalışır.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.writeFile(io, .{ .sub_path = "mylib.h", .data = header });
    try tmp.dir.writeFile(io, .{ .sub_path = "mylib.c", .data = source });
    const h_path = try std.fmt.allocPrint(a, "{s}/mylib.h", .{dir});
    const c_path = try std.fmt.allocPrint(a, "{s}/mylib.c", .{dir});
    const o_path = try std.fmt.allocPrint(a, "{s}/mylib.o", .{dir});
    const out_path = try std.fmt.allocPrint(a, "{s}/mylib.nox", .{dir});
    const shim_o = try std.fmt.allocPrint(a, "{s}/mylib_shim.o", .{dir});

    const cc = try std.process.run(a, io, .{ .argv = &.{ "cc", "-c", "-fPIC", c_path, "-o", o_path, "-I", dir } });
    if (cc.term != .exited or cc.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc.stderr});
        return error.CcFailed;
    }
    const code = try nox.bindgen.runCli(std.testing.allocator, io, a, &.{ h_path, "--lib", o_path, "--prefix", "mylib", "-o", out_path });
    try std.testing.expectEqual(@as(u8, 0), code);

    const generated = try tmp.dir.readFileAlloc(io, "mylib.nox", a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, generated, "extern def mylib_run(c: ptr, x: i64, flags: u32) -> i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "mylib_sum3") == null); // değişken argümanlı: atlanır
    try std.testing.expect(std.mem.indexOf(u8, generated, "def mylib_half_(x: float) -> float:") != null);
    const full = try std.fmt.allocPrint(a, "{s}\n{s}", .{ generated, program });

    const objs = [_][]const u8{ o_path, shim_o };
    const qbe = try compile_helpers.compileAndRunWithObjs(a, full, &objs);
    const llvm = try compile_helpers.compileAndRunLlvmWithObjs(a, full, &objs);
    const expected = "True\nTrue\n12\n42\n4.5\n3\nmylib\n";
    for ([_]std.process.RunResult{ qbe, llvm }) |r| {
        if (r.term != .exited or r.term.exited != 0 or r.stderr.len != 0) {
            std.debug.print("program basarisiz: {s}\n", .{r.stderr});
            return error.ProgramFailed;
        }
        try std.testing.expectEqualStrings(expected, r.stdout);
    }
}
