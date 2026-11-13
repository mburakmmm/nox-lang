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

const yyjson_program =
    \\def build_json(n: int) -> str:
    \\    out: str = "["
    \\    i: int = 0
    \\    while i < n:
    \\        if i > 0:
    \\            out = out + ","
    \\        out = out + "{\"id\":" + str(i) + ",\"name\":\"item\",\"active\":true,\"tags\":[1,2]}"
    \\        i = i + 1
    \\    return out + "]"
    \\
    \\extern def malloc(n: int) -> ptr from "c"
    \\extern def free(p: ptr) -> None from "c"
    \\
    \\text: str = build_json(200)
    \\doc: ptr = yyjson_read(text, usize(len(text)), YYJSON_READ_NOFLAG)
    \\root: ptr = yyjson_doc_get_root(doc)
    \\print(yyjson_is_arr(root))
    \\print(yyjson_arr_size(root))
    \\it: ptr = malloc(64)
    \\yyjson_arr_iter_init(root, it)
    \\total: int = 0
    \\active: int = 0
    \\while yyjson_arr_iter_has_next(it):
    \\    item: ptr = yyjson_arr_iter_next(it)
    \\    total = total + int(yyjson_get_sint(yyjson_obj_get(item, "id")))
    \\    if yyjson_get_bool(yyjson_obj_get(item, "active")):
    \\        active = active + 1
    \\free(it)
    \\print(total * 1000 + active)
    \\lenp: ptr = malloc(8)
    \\out: ptr = yyjson_write(doc, YYJSON_WRITE_NOFLAG, lenp)
    \\n: int = 0
    \\lowlevel:
    \\    n = ptr_read_int(lenp)
    \\print(n == len(text))
    \\free(out)
    \\free(lenp)
    \\yyjson_doc_free(doc)
    \\print(YYJSON_VERSION_STRING)
    \\
;

test "bindgen: yyjson.h (gerçek, ~9000 satırlık satır içi ağırlıklı başlık) -> binding; JSON okuma/gezinme/yazma iki backend'de aynı" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const src_dir = "benchmarks/yyjson";
    const o_path = try std.fmt.allocPrint(a, "{s}/yyjson.o", .{dir});
    const out_path = try std.fmt.allocPrint(a, "{s}/yyjson.nox", .{dir});
    const shim_c = try std.fmt.allocPrint(a, "{s}/yyjson_shim.c", .{dir});
    const shim_o = try std.fmt.allocPrint(a, "{s}/yyjson_shim.o", .{dir});
    const cc = std.process.run(a, io, .{ .argv = &.{ "cc", "-O1", "-fPIC", "-c", src_dir ++ "/yyjson.c", "-o", o_path } }) catch return error.SkipZigTest;
    if (cc.term != .exited or cc.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc.stderr});
        return error.CcFailed;
    }
    const code = try nox.bindgen.runCli(std.testing.allocator, io, a, &.{ src_dir ++ "/yyjson.h", "--lib", o_path, "--prefix", "yyjson", "-o", out_path, "--shim", shim_c, "--shim-lib", shim_o });
    try std.testing.expectEqual(@as(u8, 0), code);

    const generated = try tmp.dir.readFileAlloc(io, "yyjson.nox", a, .limited(8 << 20));
    try std.testing.expect(std.mem.indexOf(u8, generated, "def yyjson_doc_get_root(doc: ptr) -> ptr:") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "extern def yyjson_read_opts(") != null);
    const full = try std.fmt.allocPrint(a, "{s}\n{s}", .{ generated, yyjson_program });

    const objs = [_][]const u8{ o_path, shim_o };
    const qbe = try compile_helpers.compileAndRunWithObjs(a, full, &objs);
    const llvm = try compile_helpers.compileAndRunLlvmWithObjs(a, full, &objs);
    const expected = "True\n200\n19900200\nTrue\n0.13.0\n";
    for ([_]std.process.RunResult{ qbe, llvm }) |r| {
        if (r.term != .exited or r.term.exited != 0 or r.stderr.len != 0) {
            std.debug.print("program basarisiz: {s}\n", .{r.stderr});
            return error.ProgramFailed;
        }
        try std.testing.expectEqualStrings(expected, r.stdout);
    }
}

const shapes_header =
    \\#ifndef SHAPES_H
    \\#define SHAPES_H
    \\typedef struct { double x, y; } vec2;
    \\typedef struct node { int id; const char *name; double w[3]; struct node *next; unsigned flag : 3; const int fixed; } node;
    \\vec2 vec2_add(vec2 a, vec2 b);
    \\double vec2_len2(vec2 v);
    \\node *node_make(int id, const char *name);
    \\extern int shapes_counter;
    \\extern const char *const shapes_version;
    \\float shapes_scale(float x);
    \\#endif
    \\
;

const shapes_source =
    \\#include "shapes.h"
    \\#include <stdlib.h>
    \\#include <string.h>
    \\int shapes_counter = 40;
    \\const char *const shapes_version = "1.2";
    \\vec2 vec2_add(vec2 a, vec2 b) { vec2 r = { a.x + b.x, a.y + b.y }; return r; }
    \\double vec2_len2(vec2 v) { return v.x * v.x + v.y * v.y; }
    \\node *node_make(int id, const char *name) { node *n = calloc(1, sizeof(node)); n->id = id; n->name = strdup(name); return n; }
    \\float shapes_scale(float x) { return x * 2; }
    \\
;

const shapes_program =
    \\a: ptr = vec2_new()
    \\vec2_set_x(a, 1.5)
    \\vec2_set_y(a, 2.0)
    \\b: ptr = vec2_new()
    \\vec2_set_x(b, 2.0)
    \\vec2_set_y(b, 3.5)
    \\c: ptr = vec2_add_(a, b)
    \\print(vec2_get_x(c))
    \\print(vec2_get_y(c))
    \\print(vec2_len2_(c))
    \\vec2_free(a)
    \\vec2_free(b)
    \\vec2_free(c)
    \\n: ptr = node_make(7, "alpha")
    \\print(node_get_id(n))
    \\print(nox.ffi.cstr(node_get_name(n)))
    \\node_set_flag(n, u32(5))
    \\print(node_get_flag(n))
    \\node_set_w(n, usize(1), 2.5)
    \\print(node_get_w(n, usize(1)))
    \\print(node_w_LEN)
    \\print(nox.ffi.is_null(node_get_next(n)))
    \\node_free(n)
    \\print(shapes_counter_get())
    \\shapes_counter_set(42)
    \\print(shapes_counter_get())
    \\print(nox.ffi.cstr(shapes_version_get()))
    \\print(shapes_scale_(3.0))
    \\
;

test "bindgen: struct alanları, değerle struct, dizi/bit alanı, global değişken, float kabuğu ve nox.ffi.cstr iki backend'de aynı" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.writeFile(io, .{ .sub_path = "shapes.h", .data = shapes_header });
    try tmp.dir.writeFile(io, .{ .sub_path = "shapes.c", .data = shapes_source });
    const h_path = try std.fmt.allocPrint(a, "{s}/shapes.h", .{dir});
    const c_path = try std.fmt.allocPrint(a, "{s}/shapes.c", .{dir});
    const o_path = try std.fmt.allocPrint(a, "{s}/shapes.o", .{dir});
    const out_path = try std.fmt.allocPrint(a, "{s}/shapes.nox", .{dir});
    const shim_o = try std.fmt.allocPrint(a, "{s}/shapes_shim.o", .{dir});
    const cc = try std.process.run(a, io, .{ .argv = &.{ "cc", "-c", "-fPIC", c_path, "-o", o_path, "-I", dir } });
    if (cc.term != .exited or cc.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc.stderr});
        return error.CcFailed;
    }
    const code = try nox.bindgen.runCli(std.testing.allocator, io, a, &.{ h_path, "--lib", o_path, "--prefix", "shapes_,vec2,node", "-o", out_path });
    try std.testing.expectEqual(@as(u8, 0), code);
    const generated = try tmp.dir.readFileAlloc(io, "shapes.nox", a, .limited(1 << 20));
    const full = try std.fmt.allocPrint(a, "import nox.ffi\n{s}\n{s}", .{ generated, shapes_program });

    const objs = [_][]const u8{ o_path, shim_o };
    const qbe = try compile_helpers.compileAndRunWithObjs(a, full, &objs);
    const llvm = try compile_helpers.compileAndRunLlvmWithObjs(a, full, &objs);
    const expected = "3.5\n5.5\n42.5\n7\nalpha\n5\n2.5\n3\nTrue\n40\n42\n1.2\n6.0\n";
    for ([_]std.process.RunResult{ qbe, llvm }) |r| {
        if (r.term != .exited or r.term.exited != 0 or r.stderr.len != 0) {
            std.debug.print("program basarisiz: {s}\n", .{r.stderr});
            return error.ProgramFailed;
        }
        try std.testing.expectEqualStrings(expected, r.stdout);
    }
}

const cbs_header =
    \\#ifndef CBS_H
    \\#define CBS_H
    \\typedef int (*visit_fn)(void *ud, int key, const char *val);
    \\int walk_items(int n, visit_fn cb, void *ud);
    \\int sum_with(void *ud, int (*step)(int, void *), int n);
    \\#endif
    \\
;

const cbs_source =
    \\#include "cbs.h"
    \\int walk_items(int n, visit_fn cb, void *ud) { if (!cb) return -1; int total = 0; for (int i = 0; i < n; i++) total += cb(ud, i, "v"); return total; }
    \\int sum_with(void *ud, int (*step)(int, void *), int n) { int total = 0; for (int i = 0; i < n; i++) total += step(i, ud); return total; }
    \\
;

const cbs_program =
    \\def visitor(key: i32, val: ptr) -> i32:
    \\    return key * i32(10) + i32(len(nox.ffi.cstr(val)))
    \\
    \\def stepper(i: i32) -> i32:
    \\    return i * i
    \\
    \\print(walk_items(i32(3), visitor))
    \\print(sum_with(stepper, i32(4)))
    \\base: i32 = i32(100)
    \\h: Callback[(i32, ptr) -> i32] = Callback[(i32, ptr) -> i32](lambda k, v: k + base)
    \\print(walk_items(i32(3), h))
    \\h.close()
    \\print(walk_items(i32(3), None))
    \\
;

test "bindgen: callback + userdata kalıbı (userdata ilk ya da son) @ffi.callback üretir; üst-düzey def ve Callback tutamacı iki backend'de" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    try tmp.dir.writeFile(io, .{ .sub_path = "cbs.h", .data = cbs_header });
    try tmp.dir.writeFile(io, .{ .sub_path = "cbs.c", .data = cbs_source });
    const h_path = try std.fmt.allocPrint(a, "{s}/cbs.h", .{dir});
    const c_path = try std.fmt.allocPrint(a, "{s}/cbs.c", .{dir});
    const o_path = try std.fmt.allocPrint(a, "{s}/cbs.o", .{dir});
    const out_path = try std.fmt.allocPrint(a, "{s}/cbs.nox", .{dir});
    const cc = try std.process.run(a, io, .{ .argv = &.{ "cc", "-c", "-fPIC", c_path, "-o", o_path, "-I", dir } });
    if (cc.term != .exited or cc.term.exited != 0) {
        std.debug.print("cc basarisiz: {s}\n", .{cc.stderr});
        return error.CcFailed;
    }
    const code = try nox.bindgen.runCli(std.testing.allocator, io, a, &.{ h_path, "--lib", o_path, "--prefix", "walk,sum", "-o", out_path });
    try std.testing.expectEqual(@as(u8, 0), code);
    const generated = try tmp.dir.readFileAlloc(io, "cbs.nox", a, .limited(1 << 20));
    try std.testing.expect(std.mem.indexOf(u8, generated, "@ffi.callback(\"cb\", \"ud\", ud_index=0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "@ffi.callback(\"step\", \"ud\")") != null);
    const full = try std.fmt.allocPrint(a, "import nox.ffi\nfrom nox.ffi import Callback\n{s}\n{s}", .{ generated, cbs_program });

    const objs = [_][]const u8{o_path};
    const qbe = try compile_helpers.compileAndRunWithObjs(a, full, &objs);
    const llvm = try compile_helpers.compileAndRunLlvmWithObjs(a, full, &objs);
    const expected = "33\n14\n303\n-1\n";
    for ([_]std.process.RunResult{ qbe, llvm }) |r| {
        if (r.term != .exited or r.term.exited != 0 or r.stderr.len != 0) {
            std.debug.print("program basarisiz: {s}\n", .{r.stderr});
            return error.ProgramFailed;
        }
        try std.testing.expectEqualStrings(expected, r.stdout);
    }
}
