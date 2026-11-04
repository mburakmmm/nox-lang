//! `wasm32-freestanding` çalışma zamanında SQLite'ın (`third_party/sqlite/sqlite3.c`, bkz. spec §3.348) ihtiyaç duyduğu libc parçaları: bellek yönetimi
//! (`malloc`/`free`/`realloc`), `mem*`/`str*` işlevleri ve `third_party/sqlite/nox_sqlite_os_free.c` VFS'inin kullandığı iki host köprüsü.
//!
//! Bu semboller yalnızca sqlite nesnesi gerçekten bağlandığında (bir program `nox.sqlite` kullandığında) canlı kalır; wasm-ld kullanılmayan işlevleri atar. Hepsi zayıf
//! (`.weak`) dışa aktarılır: Zig'in compiler-rt'si `memchr`/`memcmp` gibi bazılarını zaten sağlıyorsa çakışma olmaz, o sürüm kazanır.
//!
//! `malloc` ailesi `std.heap.page_allocator` üzerindedir (wasm32'de `WasmAllocator`; `--threads` kipinde kök `os.heap.page_allocator` geçersiz kılması, yani kilitli
//! ayırıcı). Her blok 16 baytlık bir başlık taşır (toplam boyut), böylece `free`/`realloc` boyutu bilir; SQLite kendi blok boyutlarını ayrıca tutar.

const std = @import("std");
const host = @import("wasm_host.zig");

const header_size: usize = 16;

fn exportWeak(comptime name: []const u8, comptime f: anytype) void {
    @export(f, .{ .name = name, .linkage = .weak });
}

fn mallocImpl(size: usize) callconv(.c) ?*anyopaque {
    const total = size + header_size;
    const block = std.heap.page_allocator.alignedAlloc(u8, .@"16", total) catch return null;
    const hdr: *usize = @ptrCast(@alignCast(block.ptr));
    hdr.* = total;
    return block.ptr + header_size;
}

fn freeImpl(ptr: ?*anyopaque) callconv(.c) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    const base = p - header_size;
    const hdr: *usize = @ptrCast(@alignCast(base));
    const total = hdr.*;
    std.heap.page_allocator.free(@as([]align(16) u8, @alignCast(base[0..total])));
}

fn reallocImpl(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const old: [*]u8 = @ptrCast(ptr orelse return mallocImpl(size));
    if (size == 0) {
        freeImpl(ptr);
        return null;
    }
    const base = old - header_size;
    const old_total = @as(*usize, @ptrCast(@alignCast(base))).*;
    const old_size = old_total - header_size;
    const fresh = mallocImpl(size) orelse return null;
    const copy_len = @min(old_size, size);
    @memcpy(@as([*]u8, @ptrCast(fresh))[0..copy_len], old[0..copy_len]);
    freeImpl(ptr);
    return fresh;
}

fn memchrImpl(s: ?*const anyopaque, c: c_int, n: usize) callconv(.c) ?*anyopaque {
    const p: [*]const u8 = @ptrCast(s orelse return null);
    const want: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var i: usize = 0;
    while (i < n) : (i += 1) if (p[i] == want) return @ptrCast(@constCast(p + i));
    return null;
}

fn memcmpImpl(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) callconv(.c) c_int {
    const pa: [*]const u8 = @ptrCast(a orelse return 0);
    const pb: [*]const u8 = @ptrCast(b orelse return 0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (pa[i] != pb[i]) return @as(c_int, pa[i]) - @as(c_int, pb[i]);
    }
    return 0;
}

fn strlenImpl(s: ?[*:0]const u8) callconv(.c) usize {
    const p = s orelse return 0;
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return n;
}

fn strncmpImpl(a: ?[*:0]const u8, b: ?[*:0]const u8, n: usize) callconv(.c) c_int {
    const pa = a orelse return 0;
    const pb = b orelse return 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (pa[i] != pb[i]) return @as(c_int, pa[i]) - @as(c_int, pb[i]);
        if (pa[i] == 0) return 0;
    }
    return 0;
}

fn strrchrImpl(s: ?[*:0]const u8, c: c_int) callconv(.c) ?[*:0]u8 {
    const p = s orelse return null;
    const want: u8 = @truncate(@as(c_uint, @bitCast(c)));
    var last: ?[*:0]u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (p[i] == want) last = @ptrCast(@constCast(p + i));
        if (p[i] == 0) break;
    }
    return last;
}

fn inSet(set: [*:0]const u8, ch: u8) bool {
    var i: usize = 0;
    while (set[i] != 0) : (i += 1) if (set[i] == ch) return true;
    return false;
}

fn strspnImpl(s: ?[*:0]const u8, accept: ?[*:0]const u8) callconv(.c) usize {
    const p = s orelse return 0;
    const set = accept orelse return 0;
    var n: usize = 0;
    while (p[n] != 0 and inSet(set, p[n])) n += 1;
    return n;
}

fn strcspnImpl(s: ?[*:0]const u8, reject: ?[*:0]const u8) callconv(.c) usize {
    const p = s orelse return 0;
    const set = reject orelse return strlenImpl(s);
    var n: usize = 0;
    while (p[n] != 0 and !inSet(set, p[n])) n += 1;
    return n;
}

comptime {
    exportWeak("malloc", &mallocImpl);
    exportWeak("free", &freeImpl);
    exportWeak("realloc", &reallocImpl);
    exportWeak("memchr", &memchrImpl);
    exportWeak("memcmp", &memcmpImpl);
    exportWeak("strlen", &strlenImpl);
    exportWeak("strncmp", &strncmpImpl);
    exportWeak("strrchr", &strrchrImpl);
    exportWeak("strspn", &strspnImpl);
    exportWeak("strcspn", &strcspnImpl);
}

// ---- `nox_sqlite_os_free.c` VFS'inin kullandığı host köprüleri ----------------------------------------------------------------------------------------------

/// `n` bayt rastgelelik (SQLite'ın PRNG tohumu ve geçici adlar için).
export fn nox_sqlite_rt_random(buf: [*]u8, n: c_int) callconv(.c) c_int {
    if (n <= 0) return 0;
    host.random_fill(buf, @intCast(n));
    return n;
}

/// Duvar saati, Unix milisaniye cinsinden (`nox_host.clock_ms(0)`).
export fn nox_sqlite_rt_now_ms() callconv(.c) i64 {
    return host.clock_ms(0);
}
