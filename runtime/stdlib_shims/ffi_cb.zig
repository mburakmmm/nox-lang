//! `nox.ffi.Callback` kabuğu (v2.1.101, TODO 3.4 F2): closure/lambda/bağlı metodun C'ye `@ffi.callback` olarak verilebilmesi için "kutu".
//!
//! Kutu, rt-bağımsız küçük bir ARC bloğudur: `[rt: *RuntimeState, closure: *Closure]`. C tarafı `userdata` olarak kutunun adresini saklar; derleyicinin
//! ürettiği closure-trampoline'ı (`$<extern>__clotramp`) kutudan `rt` ile closure'ı okuyup closure'ı çağırır. Kutu closure'ın KENDİ referansını (+1) tutar
//! (C hâlâ kullanıyorken ARC onu serbest bırakmasın); `nox_cb_box_free` hem o referansı hem kutuyu bırakır. Allocator her zaman `rt` üzerinden
//! (İlke 6: gizli global yok). Kutu YALNIZCA Nox'un başlattığı iş parçacığında kullanılmalıdır (ARC iş parçacığı sahipliği, bkz. `arc.zig` Faz X.3).

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const abi_ptr = @import("../abi_ptr.zig");
const str_mod = @import("../str.zig");
const builtin = @import("builtin");

const BOX_SIZE: usize = 2 * @sizeOf(usize);
/// `CLOSURE_RELEASE_FN_PTR_OFFSET` (bkz. `compiler/codegen_qbe/types.zig`): closure bloğunun ofset 8'indeki release işlevi.
const CLOSURE_RELEASE_OFFSET: usize = 8;

fn words(box: *anyopaque) [*]usize {
    return @ptrCast(@alignCast(box));
}

/// Kutuyu kurar; `closure`un +1 referansını tutar. Başarısızlıkta `null`.
pub export fn nox_cb_box_new(rt: ?*anyopaque, closure: ?*anyopaque) callconv(.c) ?*anyopaque {
    const c = closure orelse return null;
    const raw = arc.nox_rc_alloc(rt, BOX_SIZE) orelse return null;
    arc.nox_rc_retain(c);
    const w = words(raw);
    w[0] = @intFromPtr(rt);
    w[1] = @intFromPtr(c);
    return raw;
}

/// Kutudaki closure referansını ve kutuyu bırakır (kutu başına BİR kez çağrılmalıdır; `nox.ffi.Callback.release` tekrarı engeller).
pub export fn nox_cb_box_free(rt: ?*anyopaque, box: ?*anyopaque) callconv(.c) void {
    const raw = box orelse return;
    const w = words(raw);
    const c: ?*anyopaque = @ptrFromInt(w[1]);
    w[1] = 0;
    if (c) |closure| {
        const rel_slot: *const usize = @ptrFromInt(@intFromPtr(closure) + CLOSURE_RELEASE_OFFSET);
        const rel: *const fn (abi_ptr.Arg, abi_ptr.Arg) callconv(.c) void = @ptrFromInt(rel_slot.*);
        rel(abi_ptr.arg(rt), abi_ptr.arg(closure));
    }
    arc.nox_rc_release(rt, raw, BOX_SIZE);
}

/// NUL ile biten bir C dizesini (`char *`) YENİ bir Nox `str`e kopyalar; NULL -> "" (v2.1.107).
pub export fn nox_ffi_cstr_raw(rt: ?*anyopaque, p: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const raw: ?[*:0]const u8 = @ptrCast(p);
    const text: []const u8 = if (raw) |r| std.mem.span(r) else "";
    return str_mod.nox_str_from_bytes(rt, text);
}

/// `n` baytlık bir C bellek bölgesini (NUL gerekmez) YENİ bir `str`e kopyalar (v2.1.107).
pub export fn nox_ffi_cstr_n_raw(rt: ?*anyopaque, p: ?*anyopaque, n: i64) callconv(.c) ?[*:0]u8 {
    if (p == null or n <= 0) return str_mod.nox_str_from_bytes(rt, "");
    const bytes: [*]const u8 = @ptrCast(p.?);
    return str_mod.nox_str_from_bytes(rt, bytes[0..@intCast(n)]);
}

/// C tarafına verilecek ham, sıfırlanmış bellek (libc `calloc`; C kodunun `free`siyle uyumludur).
pub export fn nox_ffi_alloc_raw(n: i64) callconv(.c) ?*anyopaque {
    if (n <= 0) return null;
    return std.c.calloc(1, @intCast(n));
}

pub export fn nox_ffi_release_raw(p: ?*anyopaque) callconv(.c) void {
    if (p) |q| std.c.free(q);
}

test "kutu closure referansını tutar ve bırakır" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    // sahte closure: [fn_ptr, release_fn, ...] — release_fn çağrısını sayar
    const S = struct {
        var released: usize = 0;
        fn rel(_: abi_ptr.Arg, _: abi_ptr.Arg) callconv(.c) void {
            released += 1;
        }
    };
    const fake = arc.nox_rc_alloc(rt, 32) orelse return error.AllocFailed;
    const fw: [*]usize = @ptrCast(@alignCast(fake));
    fw[0] = 0;
    fw[1] = @intFromPtr(&S.rel);
    const box = nox_cb_box_new(rt, fake) orelse return error.AllocFailed;
    const bw = words(box);
    try std.testing.expectEqual(@intFromPtr(rt), bw[0]);
    try std.testing.expectEqual(@intFromPtr(fake), bw[1]);
    nox_cb_box_free(rt, box);
    try std.testing.expectEqual(@as(usize, 1), S.released);
    // sahte release işlevi sayım dışında bir şey yapmadığından kutunun +1'i ile kendi +1'imizi elle bırakırız
    arc.nox_rc_release(rt, fake, 32);
    arc.nox_rc_release(rt, fake, 32);
}

extern "c" fn strerror(errnum: c_int) ?[*:0]const u8;

fn currentErrno() c_int {
    if (builtin.os.tag == .windows or builtin.os.tag == .freestanding or builtin.os.tag == .wasi) return 0;
    return std.c._errno().*;
}

/// `@ffi.errors(errno=True)` yardımcısı: o anki `errno` değeri.
pub export fn nox_ffi_errno_raw() callconv(.c) i64 {
    return currentErrno();
}

/// `errno`nun `strerror` metni (`errno == 0` ya da desteklenmeyen platformda "errno 0"). Nox `str` döndürür (ARC, `rt` allocator'ı).
pub export fn nox_ffi_errno_text_raw(rt: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    const e = currentErrno();
    if (e != 0 and builtin.os.tag != .windows and builtin.os.tag != .freestanding and builtin.os.tag != .wasi) {
        if (strerror(e)) |msg| return str_mod.nox_str_from_bytes(rt, std.mem.span(msg));
    }
    var buf: [32]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "errno {d}", .{e}) catch "errno";
    return str_mod.nox_str_from_bytes(rt, t);
}

test "errno metni strerror'dan gelir; errno 0 ise sayısal metin" {
    if (builtin.os.tag == .windows or builtin.os.tag == .freestanding or builtin.os.tag == .wasi) return error.SkipZigTest;
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    std.c._errno().* = 2; // ENOENT
    try std.testing.expectEqual(@as(i64, 2), nox_ffi_errno_raw());
    const t = nox_ffi_errno_text_raw(rt) orelse return error.AllocFailed;
    const text = std.mem.span(t);
    try std.testing.expect(std.mem.indexOf(u8, text, "No such file") != null);
    str_mod.nox_str_release(rt, t);
}

test "cstr: NUL'lu dizi kopyalanır, NULL boş, cstr_n uzunluğu sayar" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    var buf = [_]u8{ 'h', 'i', 0, 'x' };
    const s1 = nox_ffi_cstr_raw(rt, &buf) orelse return error.AllocFailed;
    try std.testing.expectEqualStrings("hi", std.mem.span(s1));
    str_mod.nox_str_release(rt, s1);
    const s2 = nox_ffi_cstr_raw(rt, null) orelse return error.AllocFailed;
    try std.testing.expectEqualStrings("", std.mem.span(s2));
    str_mod.nox_str_release(rt, s2);
    const s3 = nox_ffi_cstr_n_raw(rt, &buf, 4) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(usize, 2), std.mem.span(s3).len); // C dizesi NUL'da biter; baytlar kopyalandı
    str_mod.nox_str_release(rt, s3);
}
