//! UR-002/UR-005/UR-006 (NoxPy, v2.2.78, DENEYSEL v1): `include/nox_host.h` çalışma zamanı tarafı — bir C/Python ana makinesinin Nox kütüphanesini ÇAĞIRABİLMESİ için
//! bağlam (`NoxHostContext`), istisna inceleme (`NoxHostError`) ve `str`/`bytes` span/tampon yardımcıları. Nox NESNELERİNİN iç bellek düzeni C'ye ASLA sızmaz (İlke #4):
//! yalnızca opak işaretçiler, `(veri, uzunluk)` span'leri ve host'a ait kopya tamponlar geçer. `--host-abi` ile üretilen `nox_host_export_<modül>_<ad>` sarmalayıcıları
//! (bkz. `compiler/codegen_qbe/host_abi.zig`) aşağıdaki `nox_host_*` ilkellerini çağırır.
//!
//! Sınırlar (DENEYSEL, belgelenmiş): bir bağlam TEK iş parçacığından kullanılır (UR-004: yabancı iş parçacığı bağlama sözleşmesi ayrıdır); bellek yetersizliği ve sabit-genişlikli
//! tamsayı taşma tuzağı süreci sonlandırır (`haltProcess`; kurtarılabilir hataya çevrilemez — Nox'un unwind tablosu yoktur, İlke #3); istisnalar `NOX_HOST_ERR_EXCEPTION` ile döner.

const std = @import("std");
const asap = @import("alloc/asap.zig");
const errors_handle = @import("errors/handle.zig");
const str_mod = @import("str.zig");
const dispatch_registry = @import("alloc/dispatch_registry.zig");
const abi_ptr = @import("abi_ptr.zig");
const abi_layout = @import("abi_layout");
const SpinLock = @import("async_rt/spinlock.zig").SpinLock;
const arc = @import("alloc/arc.zig");

pub const ABI_VERSION: u32 = 1;

pub const OK: i32 = 0;
pub const ERR_EXCEPTION: i32 = 1;
pub const ERR_NOMEM: i32 = 2;
pub const ERR_INVAL: i32 = 3;
pub const ERR_VERSION: i32 = 4;
pub const ERR_UTF8: i32 = 5;
pub const ERR_STATE: i32 = 6;
pub const ERR_INVALID_HANDLE: i32 = 7;

const CTX_MAGIC: u32 = 0x4e58_4843; // "NXHC"
const ERR_MAGIC: u32 = 0x4e58_4845; // "NXHE"

/// `nox_host_context_create` yapılandırması. `size`/`abi_version` zorunlu; `allocator` v1'de NULL OLMALIDIR (host ayırıcısı sonraki sürüm).
pub const Config = extern struct { size: u32, abi_version: u32, allocator: ?*const anyopaque };

/// `lock`: bağlam BAŞINA kilit — `nox_host_enter`/`nox_host_leave` ile her çağrı seri çalışır; böylece bağlam HERHANGİ bir OS iş parçacığından (sırayla) kullanılabilir (UR-004).
/// Paralellik için her iş parçacığı KENDİ bağlamını oluşturur (bağlamlar tamamen bağımsızdır).
const Context = struct {
    magic: u32,
    rt: ?*anyopaque,
    lock: SpinLock = .{},
    /// UR-006: bu bağlamın `NoxHostHandle` tablosu. Yuva = tutulan Nox nesnesi (ARC +1) + nesil sayacı; serbest yuvalar `free_slots`ta.
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    free_slots: std.ArrayListUnmanaged(u32) = .empty,
};

const Slot = struct { obj: ?*anyopaque, gen: u16 };

/// `NoxHostSpan`: BORÇLU bayt görünümü (çağıran sahibi). `NoxHostBuffer`: host'a AİT kopya (`nox_host_buffer_release` ile bırakılır).
pub const Span = extern struct { data: ?[*]const u8, len: usize };
pub const Buffer = extern struct { data: ?[*]u8, len: usize };

/// `ctx`: hatayı üreten bağlam — `nox_host_error_release` istisna nesnesini (ARC) bağlam kilidi ALTINDA bırakır; hata, bağlam yok edilmeden ÖNCE bırakılmalıdır (belgelenmiş).
const HostError = struct { magic: u32, ctx: *Context, rt: ?*anyopaque, exception: ?*anyopaque, line: i64 };

pub export fn nox_host_abi_version() u32 {
    return ABI_VERSION;
}

pub export fn nox_host_context_create(config: ?*const Config, out: ?*?*anyopaque) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = null;
    const cfg = config orelse return ERR_INVAL;
    if (cfg.size < @sizeOf(Config)) return ERR_VERSION;
    if (cfg.abi_version != ABI_VERSION) return ERR_VERSION;
    if (cfg.allocator != null) return ERR_INVAL; // v1: host ayırıcısı yok
    const ctx = std.heap.page_allocator.create(Context) catch return ERR_NOMEM;
    const rt = asap.nox_runtime_init() orelse {
        std.heap.page_allocator.destroy(ctx);
        return ERR_NOMEM;
    };
    ctx.* = .{ .magic = CTX_MAGIC, .rt = rt };
    o.* = ctx;
    return OK;
}

pub export fn nox_host_context_destroy(ctx_ptr: ?*anyopaque) void {
    const ctx = ctxFrom(ctx_ptr) orelse return;
    const rt = ctx.rt;
    // Açık kalan handle'ların nesneleri çalışma zamanı kapanmadan ÖNCE bırakılır (sızıntı/sarkan başvuru yok).
    for (ctx.slots.items) |slot| releaseObject(rt, slot.obj);
    ctx.slots.deinit(std.heap.page_allocator);
    ctx.free_slots.deinit(std.heap.page_allocator);
    ctx.magic = 0;
    ctx.rt = null;
    asap.nox_runtime_deinit(rt);
    std.heap.page_allocator.destroy(ctx);
}

fn ctxFrom(p: ?*anyopaque) ?*Context {
    const c: *Context = @ptrCast(@alignCast(p orelse return null));
    if (c.magic != CTX_MAGIC) return null;
    return c;
}

/// Üretilen sarmalayıcıların kullandığı İÇ ilkel: bağlam kilidini ALIR ve `RuntimeState`i verir (geçersiz/yok edilmiş bağlam → null, kilit alınmaz; ham `rt` hiçbir zaman C'ye geçmez).
/// Her başarılı `nox_host_enter` tam bir `nox_host_leave` ile eşleşmelidir. Girişte ARC sahipliği çağıran iş parçacığına devredilir (Debug iş parçacığı denetimi).
pub export fn nox_host_enter(ctx_ptr: ?*anyopaque) ?*anyopaque {
    const ctx = ctxFrom(ctx_ptr) orelse return null;
    ctx.lock.lock();
    if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
    return ctx.rt;
}

pub export fn nox_host_leave(ctx_ptr: ?*anyopaque) void {
    const ctx = ctxFrom(ctx_ptr) orelse return;
    ctx.lock.unlock();
}

pub export fn nox_host_utf8_ok(data: ?[*]const u8, len: usize) i32 {
    if (len == 0) return 1;
    const d = data orelse return 0;
    return if (std.unicode.utf8ValidateSlice(d[0..len])) 1 else 0;
}

/// Host baytlarından yeni bir Nox `str`/`bytes` değeri (sahipliği çağıranın sarmalayıcısındadır; işi bitince `nox_str_release`). UTF-8 doğrulaması `nox_host_utf8_ok` ile ayrıca yapılır.
pub export fn nox_host_str_new(rt: ?*anyopaque, data: ?[*]const u8, len: usize) ?[*:0]u8 {
    if (len == 0) return str_mod.nox_str_from_bytes(rt, "");
    const d = data orelse return null;
    return str_mod.nox_str_from_bytes(rt, d[0..len]);
}

/// Nox `str`/`bytes` içeriğini host'a ait bir tampona KOPYALAR (`out.data` null değilse üzerine yazılmaz: çağıran sıfırlamalıdır). Dönüş: OK / ERR_NOMEM.
pub export fn nox_host_str_out(s: ?[*:0]const u8, out: ?*Buffer) i32 {
    const o = out orelse return ERR_INVAL;
    const bytes: []const u8 = if (s) |p| str_mod.nox_str_slice(p) else "";
    // `malloc` yerine page_allocator: uzunluk `nox_host_buffer_release`te yeniden bilinir.
    if (bytes.len == 0) {
        o.* = .{ .data = null, .len = 0 };
        return OK;
    }
    const mem = std.heap.page_allocator.alloc(u8, bytes.len) catch return ERR_NOMEM;
    @memcpy(mem, bytes);
    o.* = .{ .data = mem.ptr, .len = bytes.len };
    return OK;
}

pub export fn nox_host_buffer_release(buf: ?*Buffer) void {
    const b = buf orelse return;
    if (b.data) |d| std.heap.page_allocator.free(d[0..b.len]);
    b.* = .{ .data = null, .len = 0 };
}

/// Bekleyen Nox istisnasını alır, bir `NoxHostError` tutamacına çevirir (`out_err` null ise yalnızca temizler). İstisna yoksa OK döner ve `out_err` null kalır.
/// Bağlam kilidi ELDE iken (sarmalayıcıdan) çağrılır. Dönüş: ERR_EXCEPTION (tutamaç `nox_host_error_release` ile bırakılır) / ERR_NOMEM.
pub export fn nox_host_capture(ctx_ptr: ?*anyopaque, out_err: ?*?*anyopaque) i32 {
    if (out_err) |o| o.* = null;
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    const rt = ctx.rt;
    if (errors_handle.nox_exception_pending(rt) == 0) return OK;
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return ERR_INVAL));
    const line = errors_handle.pendingLine(state);
    const exc = errors_handle.nox_exception_take(rt);
    const e = std.heap.page_allocator.create(HostError) catch {
        releaseException(rt, exc);
        return ERR_NOMEM;
    };
    e.* = .{ .magic = ERR_MAGIC, .ctx = ctx, .rt = rt, .exception = exc, .line = line };
    if (out_err) |o| {
        o.* = e;
    } else {
        releaseException(rt, exc);
        std.heap.page_allocator.destroy(e);
    }
    return ERR_EXCEPTION;
}

fn releaseException(rt: ?*anyopaque, exc: ?*anyopaque) void {
    releaseObject(rt, exc);
}

fn releaseObject(rt: ?*anyopaque, o: ?*anyopaque) void {
    const obj = o orelse return;
    const f = dispatch_registry.classReleaseFn() orelse return;
    const tag: *const i64 = @ptrCast(@alignCast(obj));
    f(abi_ptr.arg(rt), tag.*, abi_ptr.arg(obj));
}

fn errFrom(p: ?*anyopaque) ?*HostError {
    const e: *HostError = @ptrCast(@alignCast(p orelse return null));
    if (e.magic != ERR_MAGIC) return null;
    return e;
}

pub export fn nox_host_error_release(err_ptr: ?*anyopaque) void {
    const e = errFrom(err_ptr) orelse return;
    e.magic = 0;
    const ctx = e.ctx;
    ctx.lock.lock();
    if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
    releaseException(e.rt, e.exception);
    ctx.lock.unlock();
    std.heap.page_allocator.destroy(e);
}

/// `raise` satırı (bilinmiyorsa 0).
pub export fn nox_host_error_line(err_ptr: ?*anyopaque) i64 {
    const e = errFrom(err_ptr) orelse return 0;
    return e.line;
}

/// Sınıf adı (`"ValueError"` ...): BORÇLU görünüm, `nox_host_error_release`e kadar geçerli (ham sınıf nesnesi/düzeni görünmez).
pub export fn nox_host_error_class_name(err_ptr: ?*anyopaque, out: ?*Span) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = .{ .data = null, .len = 0 };
    const e = errFrom(err_ptr) orelse return ERR_INVAL;
    const obj = e.exception orelse return ERR_STATE;
    const tag: *const i64 = @ptrCast(@alignCast(obj));
    const f = dispatch_registry.classNameFn() orelse return ERR_STATE;
    const name = std.mem.span(abi_ptr.cstr(f(abi_ptr.arg(e.rt), tag.*, abi_ptr.arg(obj))));
    o.* = .{ .data = name.ptr, .len = name.len };
    return OK;
}

/// İleti (`Exception.message`, taban sınıfın İLK alanı — `stdlib/nox/core.nox`): BORÇLU UTF-8 görünümü, `nox_host_error_release`e kadar geçerli.
pub export fn nox_host_error_message(err_ptr: ?*anyopaque, out: ?*Span) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = .{ .data = null, .len = 0 };
    const e = errFrom(err_ptr) orelse return ERR_INVAL;
    const obj = e.exception orelse return ERR_STATE;
    const base: [*]const u8 = @ptrCast(obj);
    // `Exception` kalıtıma katılır (ValueError vb. türer): etiketten sonra 8 baytlık vtable yuvası, `message` ilk alan (bkz. `abi_layout.VTABLE_PTR_SIZE`).
    const slot: *align(1) const i64 = @ptrCast(base + abi_layout.TAG_SIZE + abi_layout.VTABLE_PTR_SIZE);
    const sp: usize = @intCast(@as(u64, @bitCast(slot.*)));
    if (sp == 0) return OK;
    const s: [*:0]const u8 = @ptrFromInt(sp);
    const bytes = str_mod.nox_str_slice(s);
    o.* = .{ .data = bytes.ptr, .len = bytes.len };
    return OK;
}

// ---- UR-006: `NoxHostHandle` — Nox sınıf örneklerine nesil-denetimli, sahip-doğrulamalı opak tutamaçlar ----
// Handle (u64) = bağlam etiketi (16 bit; bağlam adresinden türer) | nesil (16 bit) | indeks+1 (32 bit). 0 her zaman geçersizdir. Bırakılmış, sahte ya da BAŞKA bağlamın handle'ı deterministik
// olarak `ERR_INVALID_HANDLE` ile reddedilir; ham işaretçi/ARC başlığı host'a hiçbir zaman görünmez. Tablo bağlam kilidi altında kullanılır.

fn ctxTag(ctx: *Context) u64 {
    return (@intFromPtr(ctx) >> 4) & 0xFFFF;
}

fn encodeHandle(ctx: *Context, index: u32, gen: u16) u64 {
    return (ctxTag(ctx) << 48) | (@as(u64, gen) << 32) | (@as(u64, index) + 1);
}

fn slotOf(ctx: *Context, h: u64) ?*Slot {
    if (h == 0) return null;
    if ((h >> 48) != ctxTag(ctx)) return null;
    const idx1: u32 = @truncate(h);
    if (idx1 == 0 or idx1 > ctx.slots.items.len) return null;
    const slot = &ctx.slots.items[idx1 - 1];
    if (slot.obj == null or slot.gen != @as(u16, @truncate(h >> 32))) return null;
    return slot;
}

/// İÇ ilkel (sarmalayıcılar; bağlam kilidi ELDE): `obj`nin sahipliğini (ARC +1) devralan yeni handle. Başarısızlıkta 0 (bellek).
pub export fn nox_host_handle_new(ctx_ptr: ?*anyopaque, obj: ?*anyopaque) u64 {
    const ctx = ctxFrom(ctx_ptr) orelse return 0;
    if (obj == null) return 0;
    if (ctx.free_slots.pop()) |idx| {
        const slot = &ctx.slots.items[idx];
        slot.obj = obj;
        return encodeHandle(ctx, idx, slot.gen);
    }
    ctx.slots.append(std.heap.page_allocator, .{ .obj = obj, .gen = 1 }) catch return 0;
    return encodeHandle(ctx, @intCast(ctx.slots.items.len - 1), 1);
}

/// İÇ ilkel (sarmalayıcılar; kilit ELDE): handle'ın nesnesi (BORÇLU) ya da geçersizse null.
pub export fn nox_host_handle_obj(ctx_ptr: ?*anyopaque, h: u64) ?*anyopaque {
    const ctx = ctxFrom(ctx_ptr) orelse return null;
    const slot = slotOf(ctx, h) orelse return null;
    return slot.obj;
}

pub export fn nox_host_handle_is_valid(ctx_ptr: ?*anyopaque, h: u64) i32 {
    const ctx = ctxFrom(ctx_ptr) orelse return 0;
    ctx.lock.lock();
    defer ctx.lock.unlock();
    return if (slotOf(ctx, h) != null) 1 else 0;
}

/// Handle'ı bırakır (nesne ARC -1; başka handle/başvuru tutmuyorsa serbest kalır); nesil artar, böylece eski değer bir daha geçerli olmaz.
pub export fn nox_host_handle_release(ctx_ptr: ?*anyopaque, h: u64) i32 {
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    ctx.lock.lock();
    defer ctx.lock.unlock();
    const slot = slotOf(ctx, h) orelse return ERR_INVALID_HANDLE;
    if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
    const obj = slot.obj;
    slot.obj = null;
    slot.gen +%= 1;
    if (slot.gen == 0) slot.gen = 1;
    const idx: u32 = @truncate((h & 0xFFFF_FFFF) - 1);
    ctx.free_slots.append(std.heap.page_allocator, idx) catch {}; // OOM'da yuva yeniden kullanılmaz (sızıntı değil: nesne yine de bırakılır)
    releaseObject(ctx.rt, obj);
    return OK;
}

/// Aynı nesneye İKİNCİ bir handle üretir (ARC +1). `out_h` boşsa ERR_INVAL.
pub export fn nox_host_handle_retain(ctx_ptr: ?*anyopaque, h: u64, out_h: ?*u64) i32 {
    const o = out_h orelse return ERR_INVAL;
    o.* = 0;
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    ctx.lock.lock();
    defer ctx.lock.unlock();
    const slot = slotOf(ctx, h) orelse return ERR_INVALID_HANDLE;
    arc.nox_rc_retain(slot.obj);
    const nh = nox_host_handle_new(ctx_ptr, slot.obj);
    if (nh == 0) {
        releaseObject(ctx.rt, slot.obj);
        return ERR_NOMEM;
    }
    o.* = nh;
    return OK;
}
