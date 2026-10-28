//! Gömme ABI kabul korpusu (TODO 3.1-3.4, 3.6, 3.7): iOS simülatöründe çalışan bir C host, `include/nox_embed.h` üzerinden
//! primitive imzaları, str sınırını (Unicode, geçersiz UTF-8), istisna sınırını, yaşam döngüsü baskısını (10.000 create/destroy),
//! olay kuyruğunu, pump bütçesini, host ayırıcısını ve dosya sandbox'ını doğrular. Çalışma zamanı nesnesi kurulu değilse
//! (`zig build mobile-rt`) test atlanır; `.github/workflows/mobile.yml` bunu açıkça çalıştırır.

const std = @import("std");
const builtin = @import("builtin");

fn runtimeObjectReady(name: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "zig-out/lib/{s}.o", .{name}) catch return false;
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(gpa, io, .{ .argv = argv });
}

fn firstPhoneUdid(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "iPhone")) continue;
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, ')') orelse continue;
        const udid = trimmed[open + 1 .. close];
        if (udid.len < 32) continue;
        return udid;
    }
    return null;
}

const NoxSource =
    \\import nox.fs
    \\
    \\def add(a: int, b: int) -> int:
    \\    return a + b
    \\
    \\def half(x: float) -> float:
    \\    return x / 2.0
    \\
    \\def flip(b: bool) -> bool:
    \\    return not b
    \\
    \\def greet(name: str) -> str:
    \\    return "merhaba, " + name
    \\
    \\def count(s: str) -> int:
    \\    return len(s)
    \\
    \\def boom(n: int) -> int:
    \\    if n < 0:
    \\        raise ValueError("negative")
    \\    return n
    \\
    \\def can_see(path: str) -> bool:
    \\    return nox.fs.exists(path)
    \\
;

const HostSource =
    \\#include <errno.h>
    \\#include <stdint.h>
    \\#include <stdio.h>
    \\#include <stdlib.h>
    \\#include <string.h>
    \\#include <sys/stat.h>
    \\#include <unistd.h>
    \\#include "nox_embed.h"
    \\
    \\int64_t add(void *rt, int64_t a, int64_t b);
    \\double half(void *rt, double x);
    \\int32_t flip(void *rt, int32_t b);
    \\char *greet(void *rt, char *name);
    \\int64_t count(void *rt, char *s);
    \\int64_t boom(void *rt, int64_t n);
    \\int32_t can_see(void *rt, char *path);
    \\
    \\static long live = 0, total = 0;
    \\static void *h_alloc(void *ctx, size_t len, size_t alignment) {
    \\    void *p = 0;
    \\    (void)ctx;
    \\    if (alignment < sizeof(void *)) alignment = sizeof(void *);
    \\    if (posix_memalign(&p, alignment, len ? len : 1) != 0) return 0;
    \\    live++; total++;
    \\    return p;
    \\}
    \\static void h_free(void *ctx, void *ptr, size_t len, size_t alignment) {
    \\    (void)ctx; (void)len; (void)alignment;
    \\    free(ptr); live--;
    \\}
    \\
    \\static int events = 0;
    \\static void on_event(void *rt, int32_t kind, const char *bytes, uint32_t len) {
    \\    (void)rt; (void)kind; (void)bytes; (void)len;
    \\    events++;
    \\}
    \\
    \\static void fill(NoxHostConfig *cfg, NoxEmbedSlot *slot, const char *dir, const NoxHostAllocator *alloc) {
    \\    memset(cfg, 0, sizeof(*cfg));
    \\    cfg->size = sizeof(*cfg);
    \\    cfg->abi_version = NOX_EMBED_ABI;
    \\    cfg->slot = slot;
    \\    cfg->documents = dir; cfg->support = dir; cfg->cache = dir; cfg->temp_dir = dir;
    \\    cfg->allocator = alloc;
    \\}
    \\
    \\int main(void) {
    \\    const char *dir = "/tmp/nox-embed-corpus";
    \\    char path[256];
    \\    FILE *f;
    \\    NoxEmbedSlot slot = {NOX_EMBED_ABI, 0};
    \\    NoxHostConfig cfg;
    \\    NoxHostAllocator host = {sizeof(NoxHostAllocator), 0, h_alloc, h_free};
    \\    void *app = 0, *rt = 0;
    \\    char *s, *name;
    \\    void *exc;
    \\    int i;
    \\    mkdir(dir, 0700);
    \\    snprintf(path, sizeof(path), "%s/f.txt", dir);
    \\    f = fopen(path, "w"); if (!f) return 1; fputs("x", f); fclose(f);
    \\
    \\    /* 3.1 primitive + 3.2 str + 3.3 istisna + 1.3 host ayırıcısı + 3.7 sandbox, tek uygulama */
    \\    fill(&cfg, &slot, dir, &host);
    \\    if (nox_app_create(&cfg, &app) != NOX_EMBED_OK) return 10;
    \\    nox_embed_bind(app);
    \\    nox_app_set_event_fn(app, on_event);
    \\    if (nox_app_start(app) != NOX_EMBED_OK) return 11;
    \\    rt = nox_app_runtime(app);
    \\    if (!rt) return 12;
    \\    if (total == 0) return 13; /* çalışma zamanı host ayırıcısını kullandı */
    \\    if (add(rt, 20, 22) != 42) return 20;
    \\    if (add(rt, -5, 3) != -2) return 21;
    \\    if (half(rt, 5.0) != 2.5) return 22;
    \\    if (flip(rt, 0) == 0) return 23;
    \\    if (flip(rt, 1) != 0) return 24;
    \\    name = nox_str_from_cstr(rt, "d\xc3\xbcnya \xf0\x9f\x8c\x8d");
    \\    s = greet(rt, name);
    \\    if (strcmp(s, "merhaba, d\xc3\xbcnya \xf0\x9f\x8c\x8d") != 0) return 30;
    \\    if (count(rt, name) != 7) return 31; /* codepoint sayısı: d ü n y a boşluk 🌍 */
    \\    nox_str_release(rt, s); nox_str_release(rt, name);
    \\    name = nox_str_from_cstr(rt, "\xff\xfe");
    \\    if (!name) return 32;
    \\    if (count(rt, name) != 2) return 33; /* geçersiz UTF-8: bayt semantiği */
    \\    nox_str_release(rt, name);
    \\    name = nox_str_from_cstr(rt, "");
    \\    if (count(rt, name) != 0) return 34;
    \\    nox_str_release(rt, name);
    \\    if (boom(rt, 7) != 7 || nox_exception_pending(rt) != 0) return 40;
    \\    boom(rt, -1);
    \\    if (nox_exception_pending(rt) != 1) return 41;
    \\    exc = nox_exception_take(rt);
    \\    if (!exc) return 42;
    \\    nox_exception_release(rt, exc);
    \\    if (nox_exception_pending(rt) != 0) return 43;
    \\    name = nox_str_from_cstr(rt, path);
    \\    if (!can_see(rt, name)) return 50;
    \\    nox_str_release(rt, name);
    \\    name = nox_str_from_cstr(rt, "/etc/passwd");
    \\    if (can_see(rt, name)) return 51;
    \\    nox_str_release(rt, name);
    \\    snprintf(path, sizeof(path), "%s/../hosts", dir);
    \\    name = nox_str_from_cstr(rt, path);
    \\    if (can_see(rt, name)) return 52;
    \\    nox_str_release(rt, name);
    \\
    \\    /* 3.6 olay kuyruğu + pump bütçesi */
    \\    for (i = 0; i < 64; i++) if (nox_app_post_event(app, 1, "e", 1) != NOX_EMBED_OK) return 60;
    \\    if (nox_app_post_event(app, 1, "e", 1) != NOX_EMBED_ERR_FULL) return 61;
    \\    if (nox_app_post_event(app, 1, "\xff", 1) != NOX_EMBED_ERR_UTF8 && nox_app_post_event(app, 1, "\xff", 1) != NOX_EMBED_ERR_FULL) return 62;
    \\    if (nox_app_pump(app, 1) != 0 || events != 0) return 63; /* bütçe geçmiş: hiçbiri teslim edilmez */
    \\    if (nox_app_pump(app, 0) != 64 || events != 64) return 64;
    \\    if (nox_app_pump(app, 0) != 0) return 65;
    \\    if (nox_app_request_stop(app) != NOX_EMBED_OK) return 66;
    \\    if (nox_app_post_event(app, 1, "e", 1) != NOX_EMBED_ERR_STATE) return 67;
    \\    if (nox_app_destroy(slot.app) != NOX_EMBED_OK) return 68;
    \\    if (nox_app_destroy(slot.app) != NOX_EMBED_OK) return 69; /* ikinci destroy güvenli */
    \\    if (live != 0) return 14; /* host ayırıcısına sızıntı yok */
    \\
    \\    /* 3.4 yaşam döngüsü baskısı: 10.000 create/start/destroy, sistem ayırıcısı */
    \\    for (i = 0; i < 10000; i++) {
    \\        slot.app = 0;
    \\        fill(&cfg, &slot, dir, 0);
    \\        if (nox_app_create(&cfg, &app) != NOX_EMBED_OK) return 70;
    \\        nox_embed_bind(app);
    \\        if (nox_app_start(app) != NOX_EMBED_OK) return 71;
    \\        if (add(nox_app_runtime(app), i, 1) != i + 1) return 72;
    \\        if (nox_app_destroy(slot.app) != NOX_EMBED_OK) return 73;
    \\    }
    \\
    \\    /* yanlış ABI sürümü ve yanlış boyut */
    \\    slot.app = 0;
    \\    fill(&cfg, &slot, dir, 0);
    \\    cfg.abi_version = 99;
    \\    if (nox_app_create(&cfg, &app) != NOX_EMBED_ERR_VERSION) return 80;
    \\    fill(&cfg, &slot, dir, 0);
    \\    cfg.size = 3;
    \\    if (nox_app_create(&cfg, &app) != NOX_EMBED_ERR_VERSION) return 81;
    \\    return 0;
    \\}
;

test "simulator embed abi corpus" {
    if (builtin.os.tag != .macos) return;
    if (!runtimeObjectReady("noxrt-ios-simulator-arm64")) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.nox", .data = NoxSource });
    try tmp.dir.writeFile(io, .{ .sub_path = "host.c", .data = HostSource });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..len];
    const src = try std.fmt.allocPrint(gpa, "{s}/lib.nox", .{dir});
    defer gpa.free(src);
    const archive = try std.fmt.allocPrint(gpa, "{s}/libnoxlib.a", .{dir});
    defer gpa.free(archive);
    const built = try run(gpa, io, &.{ "zig-out/bin/noxc", "build", "--target", "ios-simulator-arm64", "--emit-static-lib", "-o", archive, src });
    defer gpa.free(built.stdout);
    defer gpa.free(built.stderr);
    if (built.term != .exited or built.term.exited != 0) {
        std.debug.print("{s}\n", .{built.stderr});
        return error.BuildFailed;
    }
    const sdk = try run(gpa, io, &.{ "xcrun", "--sdk", "iphonesimulator", "--show-sdk-path" });
    defer gpa.free(sdk.stdout);
    defer gpa.free(sdk.stderr);
    try std.testing.expect(sdk.term == .exited and sdk.term.exited == 0);
    const sdk_path = std.mem.trim(u8, sdk.stdout, " \t\r\n");
    const host_c = try std.fmt.allocPrint(gpa, "{s}/host.c", .{dir});
    defer gpa.free(host_c);
    const host_bin = try std.fmt.allocPrint(gpa, "{s}/host", .{dir});
    defer gpa.free(host_bin);
    const linked = try run(gpa, io, &.{ "xcrun", "clang", "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk_path, "-I", "include", "-o", host_bin, host_c, archive });
    defer gpa.free(linked.stdout);
    defer gpa.free(linked.stderr);
    if (linked.term != .exited or linked.term.exited != 0) {
        std.debug.print("{s}\n", .{linked.stderr});
        return error.LinkFailed;
    }
    const listed = try run(gpa, io, &.{ "xcrun", "simctl", "list", "devices", "available" });
    defer gpa.free(listed.stdout);
    defer gpa.free(listed.stderr);
    const udid = firstPhoneUdid(listed.stdout) orelse return error.NoSimulator;
    const booted = try run(gpa, io, &.{ "xcrun", "simctl", "bootstatus", udid, "-b" });
    defer gpa.free(booted.stdout);
    defer gpa.free(booted.stderr);
    const ran = try run(gpa, io, &.{ "xcrun", "simctl", "spawn", udid, host_bin });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (ran.term != .exited or ran.term.exited != 0) {
        const code: u8 = if (ran.term == .exited) ran.term.exited else 255;
        std.debug.print("embed corpus host failed with code {d}: {s}\n", .{ code, ran.stderr });
        return error.CorpusFailed;
    }
}
