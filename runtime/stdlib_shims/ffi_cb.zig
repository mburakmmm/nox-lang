//! `nox.ffi.Callback` kabuğu (v2.1.101, TODO 3.4 F2): closure/lambda/bağlı metodun C'ye `@ffi.callback` olarak verilebilmesi için "kutu".
//!
//! Kutu, rt-bağımsız küçük bir ARC bloğudur: `[rt: *RuntimeState, closure: *Closure]`. C tarafı `userdata` olarak kutunun adresini saklar; derleyicinin
//! ürettiği closure-trampoline'ı (`$<extern>__clotramp`) kutudan `rt` ile closure'ı okuyup closure'ı çağırır. Kutu closure'ın KENDİ referansını (+1) tutar
//! (C hâlâ kullanıyorken ARC onu serbest bırakmasın); `nox_cb_box_free` hem o referansı hem kutuyu bırakır. Allocator her zaman `rt` üzerinden
//! (İlke 6: gizli global yok). Kutu YALNIZCA Nox'un başlattığı iş parçacığında kullanılmalıdır (ARC iş parçacığı sahipliği, bkz. `arc.zig` Faz X.3).

const std = @import("std");
const arc = @import("../alloc/arc.zig");
const abi_ptr = @import("../abi_ptr.zig");

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
