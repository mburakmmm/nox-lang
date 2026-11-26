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
const builtin = @import("builtin");
/// UR-011: görev işçisi yalnızca iş parçacıklı yerel hedeflerde vardır (wasm/freestanding'de `nox_host_async_*` ERR_STATE döner).
const threaded = !(builtin.cpu.arch.isWasm() or builtin.os.tag == .freestanding or builtin.os.tag == .other);
const bridge = if (threaded) @import("async_rt/bridge_native.zig") else struct {};
const sched_mod = if (threaded) @import("async_rt/scheduler.zig") else struct {};
const thread_spawn = @import("async_rt/thread_spawn.zig");

/// v3 (UR-009..UR-014): v1/v2 ana makineleriyle geriye uyumlu EKLEMELER; `nox_host_context_create` 1..3 kabul eder (UR-014'te donduruldu).
pub const ABI_VERSION: u32 = 3;

pub const OK: i32 = 0;
pub const ERR_EXCEPTION: i32 = 1;
pub const ERR_NOMEM: i32 = 2;
pub const ERR_INVAL: i32 = 3;
pub const ERR_VERSION: i32 = 4;
pub const ERR_UTF8: i32 = 5;
pub const ERR_STATE: i32 = 6;
pub const ERR_INVALID_HANDLE: i32 = 7;
/// UR-010: bir host geri çağrısı (Python) istisna fırlattı; `nox_host_error_host_token` ile özgün istisna jetonu alınır.
pub const ERR_HOST_EXCEPTION: i32 = 8;
/// UR-011: asenkron görev iptal edildi (`CancelledError`).
pub const ERR_CANCELLED: i32 = 9;

const CTX_MAGIC: u32 = 0x4e58_4843; // "NXHC"
const ERR_MAGIC: u32 = 0x4e58_4845; // "NXHE"

/// UR-010: host geri çağrı tablosu (`NoxHostCallbackOps`; ABI donduruldu: alan sırası/boyutu değişmez).
pub const CallbackOps = extern struct {
    struct_size: u32,
    user_data: ?*anyopaque,
    invoke: ?*const fn (user_data: ?*anyopaque, ctx: ?*anyopaque, target: u64, args: u64, out_result: *u64, out_err_token: *u64, out_err_msg: *Buffer) callconv(.c) i32,
    retain: ?*const fn (user_data: ?*anyopaque, ref: u64) callconv(.c) void,
    release: ?*const fn (user_data: ?*anyopaque, ref: u64) callconv(.c) void,
};

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
    /// UR-008: bu bağlamın `NoxHostValue` tablosu (host-tarafı değer ağaçları; Nox nesnesi DEĞİLDİR).
    vals: std.ArrayListUnmanaged(VSlot) = .empty,
    free_vals: std.ArrayListUnmanaged(u32) = .empty,
    /// UR-010: host geri çağrıları (null = kurulmadı) ve son başarısız çağrının hata durumu (Nox tarafı hemen sonra okur).
    cb: ?CallbackOps = null,
    call_status: i32 = 0,
    call_err_token: u64 = 0,
    call_err_msg: []u8 = &.{},
    /// Yok edilirken geri çağrılar kilit AÇILMADAN yapılır (kilit tutulmuyor).
    closing: bool = false,
    /// UR-011: asenkron görevler. `tmu` yaprak kilittir (içinde başka kilit alınmaz; sıra: lock → tmu). `tasks` tablosu ve `queue` onunla korunur; `live` yalnızca işçi tarafından (lock altında) kullanılır.
    tmu: SpinLock = .{},
    tasks: std.ArrayListUnmanaged(TaskRec) = .empty,
    free_tasks: std.ArrayListUnmanaged(u32) = .empty,
    queue: std.ArrayListUnmanaged(u32) = .empty,
    live: std.ArrayListUnmanaged(u32) = .empty,
    worker_running: bool = false,
    worker: ?thread_spawn.Thread = null,
    shutdown: std.atomic.Value(bool) = .init(false),
    /// İşçinin zamanlayıcısı (uyandırma için; yalnızca `worker_running` iken ve `tmu` altında geçerli).
    sched: ?*anyopaque = null,
    /// Çıkmaz (deadlock) sonrası zamanlayıcı bozulmuş sayılır: yeni görev başlatılamaz.
    async_dead: bool = false,
};

pub const ThunkFn = *const fn (rt: ?*anyopaque, argv: ?[*]u64) callconv(.c) ?*anyopaque;
pub const TaskCallback = *const fn (user_data: ?*anyopaque, ctx: ?*anyopaque, task: u64, final_status: i32) callconv(.c) void;

const TaskState = enum(u8) { free, queued, running, done };

const TaskRec = struct {
    gen: u16 = 1,
    state: TaskState = .free,
    thunk: ?ThunkFn = null,
    argv: ?[*]u64 = null,
    on_done: ?TaskCallback = null,
    user_data: ?*anyopaque = null,
    /// Çalışan Nox `Task` işaretçisi (yalnızca `running` iken geçerli).
    task_ptr: ?*anyopaque = null,
    cancel_req: bool = false,
    released: bool = false,
    done_called: bool = false,
    taken: bool = false,
    status: i32 = OK,
    value: u64 = 0,
    err: ?*HostError = null,
};

const VSlot = struct { node: ?*Node, gen: u16 };

const Slot = struct { obj: ?*anyopaque, gen: u16 };

/// `NoxHostSpan`: BORÇLU bayt görünümü (çağıran sahibi). `NoxHostBuffer`: host'a AİT kopya (`nox_host_buffer_release` ile bırakılır).
pub const Span = extern struct { data: ?[*]const u8, len: usize };
pub const Buffer = extern struct { data: ?[*]u8, len: usize };

/// `ctx`: hatayı üreten bağlam — `nox_host_error_release` istisna nesnesini (ARC) bağlam kilidi ALTINDA bırakır; hata, bağlam yok edilmeden ÖNCE bırakılmalıdır (belgelenmiş).
const HostError = struct { magic: u32, ctx: *Context, rt: ?*anyopaque, exception: ?*anyopaque, line: i64, host_token: u64 = 0, synth_class: []const u8 = "", synth_msg: []const u8 = "" };

pub export fn nox_host_abi_version() u32 {
    return ABI_VERSION;
}

pub export fn nox_host_context_create(config: ?*const Config, out: ?*?*anyopaque) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = null;
    const cfg = config orelse return ERR_INVAL;
    if (cfg.size < @sizeOf(Config)) return ERR_VERSION;
    if (cfg.abi_version < 1 or cfg.abi_version > ABI_VERSION) return ERR_VERSION; // v2 başlığı v1 ana makinelerini de kabul eder (UR-008 eklemelidir)
    if (cfg.allocator != null) return ERR_INVAL; // v1: host ayırıcısı yok
    const ctx = std.heap.page_allocator.create(Context) catch return ERR_NOMEM;
    const rt = asap.nox_runtime_init() orelse {
        std.heap.page_allocator.destroy(ctx);
        return ERR_NOMEM;
    };
    ctx.* = .{ .magic = CTX_MAGIC, .rt = rt };
    rtState(rt).host_ctx = ctx; // UR-008: `nox_hv_*` ilkelleri bağlamı `rt`den bulur
    o.* = ctx;
    return OK;
}

pub export fn nox_host_context_destroy(ctx_ptr: ?*anyopaque) void {
    const ctx = ctxFrom(ctx_ptr) orelse return;
    shutdownAsync(ctx); // UR-011: çalışan görevleri iptal et, işçiyi bekle (kilit tutulmaz)
    const rt = ctx.rt;
    ctx.closing = true;
    // Açık kalan handle'ların nesneleri çalışma zamanı kapanmadan ÖNCE bırakılır (sızıntı/sarkan başvuru yok).
    for (ctx.slots.items) |slot| releaseObject(rt, slot.obj);
    ctx.slots.deinit(std.heap.page_allocator);
    ctx.free_slots.deinit(std.heap.page_allocator);
    for (ctx.vals.items) |vs| nodeRelease(vs.node);
    ctx.vals.deinit(std.heap.page_allocator);
    ctx.free_vals.deinit(std.heap.page_allocator);
    if (ctx.call_err_msg.len != 0) std.heap.page_allocator.free(ctx.call_err_msg);
    rtState(rt).host_ctx = null;
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

fn rtState(rt: ?*anyopaque) *asap.RuntimeState {
    return @ptrCast(@alignCast(rt.?));
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
    const token = hostErrorToken(rt, exc);
    e.* = .{ .magic = ERR_MAGIC, .ctx = ctx, .rt = rt, .exception = exc, .line = line, .host_token = token };
    if (out_err) |o| {
        o.* = e;
    } else {
        releaseException(rt, exc);
        std.heap.page_allocator.destroy(e);
    }
    return if (token != 0) ERR_HOST_EXCEPTION else ERR_EXCEPTION;
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
    if (e.exception == null and e.synth_class.len != 0) { // UR-011: çalışma zamanının ürettiği hata (ör. çıkmaz)
        o.* = .{ .data = e.synth_class.ptr, .len = e.synth_class.len };
        return OK;
    }
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
    if (e.exception == null and e.synth_msg.len != 0) {
        o.* = .{ .data = e.synth_msg.ptr, .len = e.synth_msg.len };
        return OK;
    }
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

// ---- UR-008: `NoxHostValue` — host-tarafı OPAK değer ağaçları (`T | None`, `list[T]`, `dict[K, V]`, `tuple[...]` sınırı) ----
// Bir değer ağacı Nox nesnesi DEĞİLDİR: düğümler host/çalışma zamanı belleğindedir; `--host-abi` sarmalayıcıları (derleme öncesi SENTEZLENEN Nox adaptörleri, bkz. compiler/host_adapt.zig)
// `nox_hv_*` iç ilkelleriyle ağacı Nox'un KENDİ list/dict/Optional/tuple değerlerine çevirir ve geri çevirir; Nox'un iç bellek düzeni C'ye hiçbir zaman görünmez (İlke #4).
// Sahiplik kuralı: host'un elindeki HER `NoxHostValue` `nox_host_value_release` ile bırakılır; kapsayıcıya ekleme (`append`/`dict_set`) alt değeri KOPYALAMAZ ama başvuru sayar (+1),
// host kendi handle'ını yine bırakır. Okuyucular (`item`/`dict_entry`) yeni handle verir. Döngü (bir değeri kendi altına eklemek) `ERR_INVAL` ile reddedilir.

pub const VK_NONE: u8 = 0;
pub const VK_INT: u8 = 1;
pub const VK_FLOAT: u8 = 2;
pub const VK_BOOL: u8 = 3;
pub const VK_STR: u8 = 4;
pub const VK_BYTES: u8 = 5;
pub const VK_LIST: u8 = 6;
pub const VK_DICT: u8 = 7;
pub const VK_TUPLE: u8 = 8;
/// UR-009: Nox sınıf örneğine (ARC +1) tutulan değer düğümü — `Class | None` ve `list[Class]` gibi kapsayıcı içi sınıf örnekleri için (`NOX_HOST_VALUE_HANDLE`).
pub const VK_HANDLE: u8 = 9;
/// 10 = TYPED_ARRAY (UR-012 için ayrılmış).
/// UR-010: host'un yönettiği opak nesne belirteci (`NoxHostExternalRef`); düğüm bırakıldığında host `release` geri çağrısı alır.
pub const VK_EXTERNAL_REF: u8 = 11;

const Node = struct {
    rc: u32 = 1,
    kind: u8,
    i: i64 = 0,
    f: f64 = 0,
    data: []u8 = &.{},
    /// list/tuple: elemanlar; dict: [k0, v0, k1, v1, ...]
    items: std.ArrayListUnmanaged(*Node) = .empty,
    /// VK_HANDLE: tutulan Nox nesnesi (ARC +1; düğüm bırakılırken `rt` ile bırakılır).
    obj: ?*anyopaque = null,
    rt: ?*anyopaque = null,
    /// VK_EXTERNAL_REF: belirteç `i`de; bırakma geri çağrısı için sahip bağlam.
    ctx: ?*Context = null,
};

fn nodeNew(kind: u8) ?*Node {
    const n = std.heap.page_allocator.create(Node) catch return null;
    n.* = .{ .kind = kind };
    return n;
}

fn nodeRetain(n: *Node) void {
    n.rc += 1;
}

/// Yinelemesiz bırakma (derin ağaçlarda yığın taşmaz).
fn nodeRelease(root: ?*Node) void {
    const first = root orelse return;
    var stack: std.ArrayListUnmanaged(*Node) = .empty;
    defer stack.deinit(std.heap.page_allocator);
    stack.append(std.heap.page_allocator, first) catch return; // bellek yok: sızıntı, çökme değil
    while (stack.pop()) |n| {
        n.rc -= 1;
        if (n.rc != 0) continue;
        if (n.kind == VK_HANDLE) releaseObject(n.rt, n.obj);
        if (n.kind == VK_EXTERNAL_REF) if (n.ctx) |c| externalRelease(c, @bitCast(n.i));
        for (n.items.items) |c| stack.append(std.heap.page_allocator, c) catch {};
        n.items.deinit(std.heap.page_allocator);
        if (n.data.len != 0) std.heap.page_allocator.free(n.data);
        std.heap.page_allocator.destroy(n);
    }
}

fn valueTag(ctx: *Context) u64 {
    return ctxTag(ctx) ^ 0x5A5A;
}

fn vslotOf(ctx: *Context, h: u64) ?*VSlot {
    if (h == 0) return null;
    if ((h >> 48) != valueTag(ctx)) return null;
    const idx1: u32 = @truncate(h);
    if (idx1 == 0 or idx1 > ctx.vals.items.len) return null;
    const slot = &ctx.vals.items[idx1 - 1];
    if (slot.node == null or slot.gen != @as(u16, @truncate(h >> 32))) return null;
    return slot;
}

fn nodeOf(ctx: *Context, h: u64) ?*Node {
    return (vslotOf(ctx, h) orelse return null).node;
}

/// Düğümün sahipliğini (rc hesabı çağırana ait: yeni düğümde 1) devralan yeni handle; 0 = bellek yok (düğüm bırakılır).
fn valueNew(ctx: *Context, node: ?*Node) u64 {
    const n = node orelse return 0;
    if (ctx.free_vals.pop()) |idx| {
        const slot = &ctx.vals.items[idx];
        slot.node = n;
        return (valueTag(ctx) << 48) | (@as(u64, slot.gen) << 32) | (@as(u64, idx) + 1);
    }
    ctx.vals.append(std.heap.page_allocator, .{ .node = n, .gen = 1 }) catch {
        nodeRelease(n);
        return 0;
    };
    return (valueTag(ctx) << 48) | (@as(u64, 1) << 32) | @as(u64, ctx.vals.items.len);
}

fn valueRelease(ctx: *Context, h: u64) i32 {
    const slot = vslotOf(ctx, h) orelse return ERR_INVALID_HANDLE;
    const n = slot.node;
    slot.node = null;
    slot.gen +%= 1;
    if (slot.gen == 0) slot.gen = 1;
    const idx: u32 = @truncate((h & 0xFFFF_FFFF) - 1);
    ctx.free_vals.append(std.heap.page_allocator, idx) catch {};
    nodeRelease(n);
    return OK;
}

/// `needle`, `root`un altında (kendisi dahil) erişilebilir mi? (döngü denetimi; ziyaret kümesiyle yinelemesiz)
fn reaches(root: *Node, needle: *Node) bool {
    var seen: std.AutoHashMapUnmanaged(*Node, void) = .empty;
    defer seen.deinit(std.heap.page_allocator);
    var stack: std.ArrayListUnmanaged(*Node) = .empty;
    defer stack.deinit(std.heap.page_allocator);
    stack.append(std.heap.page_allocator, root) catch return true; // bellek yok: muhafazakâr (reddet)
    while (stack.pop()) |n| {
        if (n == needle) return true;
        const gop = seen.getOrPut(std.heap.page_allocator, n) catch return true;
        if (gop.found_existing) continue;
        for (n.items.items) |c| stack.append(std.heap.page_allocator, c) catch return true;
    }
    return false;
}

fn isScalarKind(k: u8) bool {
    return k <= VK_BYTES;
}

fn scalarEq(a: *const Node, b: *const Node) bool {
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        VK_NONE => true,
        VK_INT, VK_BOOL => a.i == b.i,
        VK_FLOAT => a.f == b.f,
        VK_STR, VK_BYTES => std.mem.eql(u8, a.data, b.data),
        else => false,
    };
}

// -- çekirdek işlemler (bağlam kilidi ELDE; hem herkese açık C işlevleri hem `nox_hv_*` bunları kullanır) --

fn coreScalar(ctx: *Context, kind: u8, i: i64, f: f64, data: ?[]const u8, out: *u64) i32 {
    out.* = 0;
    const n = nodeNew(kind) orelse return ERR_NOMEM;
    n.i = i;
    n.f = f;
    if (data) |d| if (d.len != 0) {
        n.data = std.heap.page_allocator.dupe(u8, d) catch {
            nodeRelease(n);
            return ERR_NOMEM;
        };
    };
    const h = valueNew(ctx, n);
    if (h == 0) return ERR_NOMEM;
    out.* = h;
    return OK;
}

fn coreAppend(ctx: *Context, c: u64, item: u64) i32 {
    const cn = nodeOf(ctx, c) orelse return ERR_INVALID_HANDLE;
    const it = nodeOf(ctx, item) orelse return ERR_INVALID_HANDLE;
    if (cn.kind != VK_LIST and cn.kind != VK_TUPLE) return ERR_INVAL;
    if (reaches(it, cn)) return ERR_INVAL;
    cn.items.append(std.heap.page_allocator, it) catch return ERR_NOMEM;
    nodeRetain(it);
    return OK;
}

fn coreDictSet(ctx: *Context, d: u64, k: u64, v: u64) i32 {
    const dn = nodeOf(ctx, d) orelse return ERR_INVALID_HANDLE;
    const kn = nodeOf(ctx, k) orelse return ERR_INVALID_HANDLE;
    const vn = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    if (dn.kind != VK_DICT or !isScalarKind(kn.kind) or kn.kind == VK_NONE) return ERR_INVAL;
    if (reaches(vn, dn)) return ERR_INVAL;
    var i: usize = 0;
    while (i < dn.items.items.len) : (i += 2) {
        if (scalarEq(dn.items.items[i], kn)) { // aynı anahtar: değeri değiştirir
            const old = dn.items.items[i + 1];
            dn.items.items[i + 1] = vn;
            nodeRetain(vn);
            nodeRelease(old);
            return OK;
        }
    }
    dn.items.ensureUnusedCapacity(std.heap.page_allocator, 2) catch return ERR_NOMEM;
    dn.items.appendAssumeCapacity(kn);
    dn.items.appendAssumeCapacity(vn);
    nodeRetain(kn);
    nodeRetain(vn);
    return OK;
}

fn coreChild(ctx: *Context, v: u64, index: usize, which: u8, out: *u64) i32 {
    out.* = 0;
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    const slot_idx: usize = switch (n.kind) {
        VK_LIST, VK_TUPLE => if (which == 0) index else return ERR_INVAL,
        VK_DICT => index * 2 + @as(usize, which -| 1), // which: 1 = anahtar, 2 = değer
        else => return ERR_INVAL,
    };
    if (n.kind == VK_DICT and which == 0) return ERR_INVAL;
    if (slot_idx >= n.items.items.len) return ERR_INVAL;
    const child = n.items.items[slot_idx];
    nodeRetain(child);
    const h = valueNew(ctx, child);
    if (h == 0) return ERR_NOMEM;
    out.* = h;
    return OK;
}

fn coreCount(n: *const Node) ?usize {
    return switch (n.kind) {
        VK_LIST, VK_TUPLE => n.items.items.len,
        VK_DICT => n.items.items.len / 2,
        else => null,
    };
}

// -- herkese açık C API (nox_host.h, ABI v2): her işlev bağlam kilidini kendisi alır --

fn lockedCtx(ctx_ptr: ?*anyopaque) ?*Context {
    const ctx = ctxFrom(ctx_ptr) orelse return null;
    ctx.lock.lock();
    // VK_HANDLE düğümleri ARC nesnesi tutar: değer işlemleri (`release`/`dict_set` değişimi vb.) nesneyi bırakabilir → ARC sahipliği çağıran iş parçacığına devredilir.
    if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
    return ctx;
}

pub export fn nox_host_value_none(ctx_ptr: ?*anyopaque, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreScalar(ctx, VK_NONE, 0, 0, null, o);
}

pub export fn nox_host_value_int(ctx_ptr: ?*anyopaque, v: i64, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreScalar(ctx, VK_INT, v, 0, null, o);
}

pub export fn nox_host_value_float(ctx_ptr: ?*anyopaque, v: f64, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreScalar(ctx, VK_FLOAT, 0, v, null, o);
}

pub export fn nox_host_value_bool(ctx_ptr: ?*anyopaque, v: u8, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreScalar(ctx, VK_BOOL, if (v != 0) 1 else 0, 0, null, o);
}

/// UTF-8 `str` (geçersizse ERR_UTF8) ya da ham `bytes` (`is_bytes != 0`; gömülü 0 korunur). Veri KOPYALANIR.
pub export fn nox_host_value_str(ctx_ptr: ?*anyopaque, data: ?[*]const u8, len: usize, is_bytes: i32, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    if (len != 0 and data == null) return ERR_INVAL;
    const slice: []const u8 = if (len == 0) "" else data.?[0..len];
    if (is_bytes == 0 and !std.unicode.utf8ValidateSlice(slice)) return ERR_UTF8;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreScalar(ctx, if (is_bytes != 0) VK_BYTES else VK_STR, 0, 0, slice, o);
}

/// `kind`: 6 = list, 7 = dict, 8 = tuple.
pub export fn nox_host_value_container(ctx_ptr: ?*anyopaque, kind: i32, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    if (kind != VK_LIST and kind != VK_DICT and kind != VK_TUPLE) return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreScalar(ctx, @intCast(kind), 0, 0, null, o);
}

pub export fn nox_host_value_append(ctx_ptr: ?*anyopaque, container: u64, item: u64) i32 {
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreAppend(ctx, container, item);
}

pub export fn nox_host_value_dict_set(ctx_ptr: ?*anyopaque, dict: u64, key: u64, value: u64) i32 {
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreDictSet(ctx, dict, key, value);
}

pub export fn nox_host_value_kind(ctx_ptr: ?*anyopaque, v: u64, out: ?*i32) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    o.* = n.kind;
    return OK;
}

pub export fn nox_host_value_get_int(ctx_ptr: ?*anyopaque, v: u64, out: ?*i64) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    if (n.kind != VK_INT and n.kind != VK_BOOL) return ERR_INVAL;
    o.* = n.i;
    return OK;
}

pub export fn nox_host_value_get_float(ctx_ptr: ?*anyopaque, v: u64, out: ?*f64) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    if (n.kind != VK_FLOAT) return ERR_INVAL;
    o.* = n.f;
    return OK;
}

/// `str`/`bytes` içeriği: BORÇLU görünüm, değer bırakılana kadar geçerlidir.
pub export fn nox_host_value_get_span(ctx_ptr: ?*anyopaque, v: u64, out: ?*Span) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    if (n.kind != VK_STR and n.kind != VK_BYTES) return ERR_INVAL;
    o.* = .{ .data = if (n.data.len == 0) null else n.data.ptr, .len = n.data.len };
    return OK;
}

/// list/tuple için eleman sayısı, dict için çift sayısı.
pub export fn nox_host_value_len(ctx_ptr: ?*anyopaque, v: u64, out: ?*usize) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    o.* = coreCount(n) orelse return ERR_INVAL;
    return OK;
}

/// list/tuple elemanı `index` için YENİ handle (host bırakır).
pub export fn nox_host_value_item(ctx_ptr: ?*anyopaque, v: u64, index: usize, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreChild(ctx, v, index, 0, o);
}

/// dict `index`inci çiftin anahtarı/değeri için YENİ handle'lar (host ikisini de bırakır). Eklenme sırası korunur.
pub export fn nox_host_value_dict_entry(ctx_ptr: ?*anyopaque, v: u64, index: usize, key_out: ?*u64, value_out: ?*u64) i32 {
    const ko = key_out orelse return ERR_INVAL;
    const vo = value_out orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    var kh: u64 = 0;
    var vh: u64 = 0;
    var st = coreChild(ctx, v, index, 1, &kh);
    if (st == OK) st = coreChild(ctx, v, index, 2, &vh);
    if (st != OK) {
        if (kh != 0) _ = valueRelease(ctx, kh);
        ko.* = 0;
        vo.* = 0;
        return st;
    }
    ko.* = kh;
    vo.* = vh;
    return OK;
}

pub export fn nox_host_value_release(ctx_ptr: ?*anyopaque, v: u64) i32 {
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return valueRelease(ctx, v);
}

pub export fn nox_host_value_is_valid(ctx_ptr: ?*anyopaque, v: u64) i32 {
    const ctx = lockedCtx(ctx_ptr) orelse return 0;
    defer ctx.lock.unlock();
    return if (vslotOf(ctx, v) != null) 1 else 0;
}

// ---- UR-010 (ABI v3): host nesne belirteçleri (`NoxHostExternalRef`) ve yeniden-girişli geri çağrılar ----
// Kural: host geri çağrıları (`invoke`/`retain`/`release`) bağlam kilidi AÇIKKEN çağrılır; böylece geri çağrı içinden host → Nox çağrıları (aynı bağlam) kilitlenmeden çalışır. Çağrıdan sonra
// kilit yeniden alınır ve ARC sahipliği bu iş parçacığına devredilir. Kilidin elde olduğu varsayılır (Nox kodu `nox_host_enter` içinde çalışır); bağlam yok edilirken kilit tutulmaz (`closing`).

fn cbUnlock(ctx: *Context) void {
    if (!ctx.closing) ctx.lock.unlock();
}

fn cbRelock(ctx: *Context) void {
    if (ctx.closing) return;
    ctx.lock.lock();
    if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
}

fn externalRetain(ctx: *Context, ref: u64) void {
    const ops = ctx.cb orelse return;
    const f = ops.retain orelse return;
    cbUnlock(ctx);
    f(ops.user_data, ref);
    cbRelock(ctx);
}

fn externalRelease(ctx: *Context, ref: u64) void {
    const ops = ctx.cb orelse return;
    const f = ops.release orelse return;
    cbUnlock(ctx);
    f(ops.user_data, ref);
    cbRelock(ctx);
}

/// Geri çağrı tablosunu kurar (`ops == NULL` temizler). `struct_size` en az `sizeof(NoxHostCallbackOps)` olmalı ve `invoke` dolu olmalıdır. Tablo kopyalanır.
/// Yaşayan `HostObject`/belirteç varken temizlemek host tarafı `release`lerini kaçırır: önce nesneleri bırakın.
pub export fn nox_host_context_set_callbacks(ctx_ptr: ?*anyopaque, ops: ?*const CallbackOps) i32 {
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const o = ops orelse {
        ctx.cb = null;
        return OK;
    };
    if (o.struct_size < @sizeOf(CallbackOps)) return ERR_VERSION;
    if (o.invoke == null) return ERR_INVAL;
    ctx.cb = o.*;
    return OK;
}

/// Hatanın host istisna jetonu (`NOX_HOST_ERR_HOST_EXCEPTION`ta geri çağrının verdiği belirteç; Nox kaynaklı istisnada 0). Jeton `nox_host_error_release`e kadar geçerlidir.
pub export fn nox_host_error_host_token(err_ptr: ?*anyopaque) u64 {
    const e = errFrom(err_ptr) orelse return 0;
    return e.host_token;
}

/// `nox.host.HostError`ın jeton alanı: `Exception` alanlarından (`message`, `line`, `cause`) SONRA gelen ilk alan (bkz. stdlib/nox/host.nox; `host_error_layout` testi düzeni korur).
fn hostErrorToken(rt: ?*anyopaque, obj: ?*anyopaque) u64 {
    const p = obj orelse return 0;
    const name = classNameOf(rt, p) orelse return 0;
    if (!std.mem.eql(u8, name, host_error_class)) return 0;
    const base: [*]const u8 = @ptrCast(p);
    const slot: *align(1) const u64 = @ptrCast(base + abi_layout.TAG_SIZE + abi_layout.VTABLE_PTR_SIZE + 3 * 8);
    return slot.*;
}

const host_error_class = "nox_host_HostError";

pub export fn nox_host_value_external_ref(ctx_ptr: ?*anyopaque, ref: u64, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = 0;
    if (ref == 0) return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    return coreExternalValue(ctx, ref, o);
}

/// Belirteci tutan düğüm (host `retain` alır; düğüm bırakılırken `release`).
fn coreExternalValue(ctx: *Context, ref: u64, out: *u64) i32 {
    if (ctx.cb == null) return ERR_STATE;
    const n = nodeNew(VK_EXTERNAL_REF) orelse return ERR_NOMEM;
    n.i = @bitCast(ref);
    n.ctx = ctx;
    externalRetain(ctx, ref);
    const h = valueNew(ctx, n);
    if (h == 0) return ERR_NOMEM; // `valueNew` düğümü bıraktı (`release` geri çağrısı dahil)
    out.* = h;
    return OK;
}

/// Değerin belirteci (BORÇLU: host kendi başvuru sayımını tutuyorsa `retain` etmelidir).
pub export fn nox_host_value_get_external_ref(ctx_ptr: ?*anyopaque, v: u64, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = 0;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    if (n.kind != VK_EXTERNAL_REF) return ERR_INVAL;
    o.* = @bitCast(n.i);
    return OK;
}

fn clearCallError(ctx: *Context) void {
    ctx.call_status = 0;
    ctx.call_err_token = 0;
    if (ctx.call_err_msg.len != 0) std.heap.page_allocator.free(ctx.call_err_msg);
    ctx.call_err_msg = &.{};
}

/// `nox.host.HostObject` ilkeli: belirtece `retain`.
pub export fn nox_host_ref_retain(rt: ?*anyopaque, ref: i64) void {
    const ctx = curCtx(rt) orelse return;
    externalRetain(ctx, @bitCast(ref));
}

pub export fn nox_host_ref_release(rt: ?*anyopaque, ref: i64) void {
    const ctx = curCtx(rt) orelse return;
    externalRelease(ctx, @bitCast(ref));
}

/// `nox.host.HostObject.call` ilkeli: `target` host nesnesini `args` (tuple değer handle'ı) ile çağırır. Dönüş: sonuç değer handle'ı (>0; `None` sonucu `none` düğümüdür) ya da 0 = hata
/// (`nox_host_call_status`/`_err_token`/`_err_message` ile okunur). Kilit geri çağrı boyunca AÇIKTIR; sonuç handle'ı Nox tarafına geçer (`nox_hv_release` ile bırakılır).
pub export fn nox_host_call_external(rt: ?*anyopaque, target: i64, args: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    clearCallError(ctx);
    const ops = ctx.cb orelse {
        ctx.call_status = ERR_STATE;
        return 0;
    };
    const f = ops.invoke orelse {
        ctx.call_status = ERR_STATE;
        return 0;
    };
    var result: u64 = 0;
    var token: u64 = 0;
    var msg: Buffer = .{ .data = null, .len = 0 };
    cbUnlock(ctx);
    const st = f(ops.user_data, ctx, @bitCast(target), @bitCast(args), &result, &token, &msg);
    cbRelock(ctx);
    if (st == OK) {
        if (result == 0) {
            var none: u64 = 0;
            if (coreScalar(ctx, VK_NONE, 0, 0, null, &none) != OK) {
                ctx.call_status = ERR_NOMEM;
                return 0;
            }
            return @bitCast(none);
        }
        if (nodeOf(ctx, result) == null) {
            ctx.call_status = ERR_INVALID_HANDLE;
            return 0;
        }
        return @bitCast(result);
    }
    if (result != 0) _ = valueRelease(ctx, result);
    ctx.call_status = st;
    ctx.call_err_token = token;
    if (msg.data) |d| if (msg.len != 0) {
        ctx.call_err_msg = std.heap.page_allocator.dupe(u8, d[0..msg.len]) catch &.{}; // geri çağrı belleği ÖDÜNÇTÜR (invoke dönünce geçersiz sayılır)
    };
    return 0;
}

pub export fn nox_host_call_status(rt: ?*anyopaque) i64 {
    const ctx = curCtx(rt) orelse return ERR_STATE;
    return ctx.call_status;
}

pub export fn nox_host_call_err_token(rt: ?*anyopaque) i64 {
    const ctx = curCtx(rt) orelse return 0;
    const t = ctx.call_err_token;
    ctx.call_err_token = 0; // jetonun sahipliği Nox'taki HostError'a geçer
    return @bitCast(t);
}

pub export fn nox_host_call_err_message(rt: ?*anyopaque) ?[*:0]u8 {
    const ctx = curCtx(rt) orelse return str_mod.nox_str_from_bytes(rt, "");
    return str_mod.nox_str_from_bytes(rt, ctx.call_err_msg);
}

/// `nox.host` değer-ağacı ilkelleri (`nox_hv_*` ile aynı iş; ayrı sembol adları, çünkü `--host-abi` önsözü `nox_hv_*` extern'lerini kendi kaynağında bildirir ve aynı ad iki kez bildirilemez).
pub export fn nox_hx_kind(rt: ?*anyopaque, h: i64) i64 {
    return nox_hv_kind(rt, h);
}
pub export fn nox_hx_int(rt: ?*anyopaque, h: i64) i64 {
    return nox_hv_int(rt, h);
}
pub export fn nox_hx_float(rt: ?*anyopaque, h: i64) f64 {
    return nox_hv_float(rt, h);
}
pub export fn nox_hx_str(rt: ?*anyopaque, h: i64) ?[*:0]u8 {
    return nox_hv_str(rt, h);
}
pub export fn nox_hx_len(rt: ?*anyopaque, h: i64) i64 {
    return nox_hv_len(rt, h);
}
pub export fn nox_hx_item(rt: ?*anyopaque, h: i64, i: i64) i64 {
    return nox_hv_item(rt, h, i);
}
pub export fn nox_hx_release(rt: ?*anyopaque, h: i64) void {
    nox_hv_release(rt, h);
}
pub export fn nox_hx_new(rt: ?*anyopaque, kind: i64) i64 {
    return nox_hv_new(rt, kind);
}
pub export fn nox_hx_new_int(rt: ?*anyopaque, v: i64) i64 {
    return nox_hv_new_int(rt, v);
}
pub export fn nox_hx_new_float(rt: ?*anyopaque, v: f64) i64 {
    return nox_hv_new_float(rt, v);
}
pub export fn nox_hx_new_bool(rt: ?*anyopaque, v: i64) i64 {
    return nox_hv_new_bool(rt, v);
}
pub export fn nox_hx_new_str(rt: ?*anyopaque, s: ?[*:0]const u8) i64 {
    return nox_hv_new_str(rt, s);
}
pub export fn nox_hx_new_bytes(rt: ?*anyopaque, s: ?[*:0]const u8) i64 {
    return nox_hv_new_bytes(rt, s);
}
pub export fn nox_hx_append(rt: ?*anyopaque, c: i64, item: i64) i64 {
    return nox_hv_append(rt, c, item);
}
pub export fn nox_hv_ref(rt: ?*anyopaque, h: i64) i64 {
    return nox_hx_ref(rt, h);
}
pub export fn nox_hv_new_ref(rt: ?*anyopaque, ref: i64) i64 {
    return nox_hx_new_ref(rt, ref);
}
/// `VK_EXTERNAL_REF` düğümünün belirteci / belirteç için yeni düğüm (0 = geri çağrı yok/bellek yok).
pub export fn nox_hx_ref(rt: ?*anyopaque, h: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    const n = nodeOf(ctx, @bitCast(h)) orelse return 0;
    return if (n.kind == VK_EXTERNAL_REF) n.i else 0;
}
pub export fn nox_hx_new_ref(rt: ?*anyopaque, ref: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    var out: u64 = 0;
    if (coreExternalValue(ctx, @bitCast(ref), &out) != OK) return 0;
    return @bitCast(out);
}

// ---- UR-011 (ABI v3): `@export async def` görevleri — başlat / iptal / sonuç al / bırak ----
// Tasarım (kararlar, docs/apis/host-abi.md "Async tasks"): bağlam başına TEK bir işçi OS iş parçacığı (ilk `start`ta açılır, görev kalmayınca kapanır) KENDİ Nox zamanlayıcısını (`nox_async_init`, iş parçacığı-yerel) sürer.
// İşçi bağlam kilidini yalnızca Nox kodu çalışırken tutar; zamanlayıcı reaktörde (G/Ç/zamanlayıcı) beklerken, `on_done` geri çağrısı ve host geri çağrıları sırasında AÇIKTIR. `cancel`/`take_result`/`release`
// bağlam kilidini beklemez (yaprak kilit `tmu`). `on_done`, görev başına en fazla ve (görev `release` edilmedikçe) en az bir kez çağrılır. İptal kooperatiftir: görev bir sonraki `await`inde `CancelledError` alır.

fn taskTag(ctx: *Context) u64 {
    return ctxTag(ctx) ^ 0x3C3C;
}

fn taskHandle(ctx: *Context, idx: u32, gen: u16) u64 {
    return (taskTag(ctx) << 48) | (@as(u64, gen) << 32) | (@as(u64, idx) + 1);
}

/// `tmu` ELDE iken çağrılır.
fn taskRecOf(ctx: *Context, h: u64) ?*TaskRec {
    if (h == 0 or (h >> 48) != taskTag(ctx)) return null;
    const idx1: u32 = @truncate(h);
    if (idx1 == 0 or idx1 > ctx.tasks.items.len) return null;
    const rec = &ctx.tasks.items[idx1 - 1];
    if (rec.state == .free or rec.gen != @as(u16, @truncate(h >> 32))) return null;
    return rec;
}

fn taskIndexOf(ctx: *Context, rec: *TaskRec) u32 {
    return @intCast((@intFromPtr(rec) - @intFromPtr(ctx.tasks.items.ptr)) / @sizeOf(TaskRec));
}

/// `tmu` ELDE: kaydı serbest bırakır (nesil artar; eski handle bir daha geçerli olmaz).
fn taskRecFree(ctx: *Context, rec: *TaskRec) void {
    const idx = taskIndexOf(ctx, rec);
    const gen = rec.gen +% 1;
    rec.* = .{ .gen = if (gen == 0) 1 else gen };
    ctx.free_tasks.append(std.heap.page_allocator, idx) catch {};
}

/// Kilitsiz hata bırakma (kilit ELDE ya da bağlam yok ediliyor).
fn errDrop(e: *HostError) void {
    e.magic = 0;
    releaseException(e.rt, e.exception);
    std.heap.page_allocator.destroy(e);
}

fn newSynthError(ctx: *Context, class: []const u8, msg: []const u8) ?*HostError {
    const e = std.heap.page_allocator.create(HostError) catch return null;
    e.* = .{ .magic = ERR_MAGIC, .ctx = ctx, .rt = ctx.rt, .exception = null, .line = 0, .synth_class = class, .synth_msg = msg };
    return e;
}

/// `--host-abi` başlatma sarmalayıcısı (kilit ELDE): argüman bloğu (`n` sözcük; `argv[-1]` = n) ayırır.
pub export fn nox_host_async_args(ctx_ptr: ?*anyopaque, n: i64) ?[*]u64 {
    _ = ctx_ptr;
    const count: usize = @intCast(n);
    const mem = std.heap.page_allocator.alloc(u64, count + 1) catch return null;
    mem[0] = count;
    return mem.ptr + 1;
}

pub export fn nox_host_async_free_args(argv: ?[*]u64) void {
    const p = argv orelse return;
    const base = p - 1;
    std.heap.page_allocator.free(base[0 .. base[0] + 1]);
}

/// Değer handle'ı geçerli mi (kilit ELDE)? 1/0.
pub export fn nox_host_value_check(ctx_ptr: ?*anyopaque, h: u64) i32 {
    const ctx = ctxFrom(ctx_ptr) orelse return 0;
    return if (nodeOf(ctx, h) != null) 1 else 0;
}

/// Aynı düğüme YENİ bir handle (görevin kendi sahipliği; kilit ELDE). 0 = geçersiz/bellek yok.
pub export fn nox_host_value_dup(ctx_ptr: ?*anyopaque, h: u64) u64 {
    const ctx = ctxFrom(ctx_ptr) orelse return 0;
    const n = nodeOf(ctx, h) orelse return 0;
    nodeRetain(n);
    return valueNew(ctx, n);
}

pub export fn nox_host_value_drop(ctx_ptr: ?*anyopaque, h: u64) void {
    const ctx = ctxFrom(ctx_ptr) orelse return;
    _ = valueRelease(ctx, h);
}

pub export fn nox_host_obj_retain(obj: ?*anyopaque) void {
    arc.nox_rc_retain(obj);
}

pub export fn nox_host_obj_release(rt: ?*anyopaque, obj: ?*anyopaque) void {
    releaseObject(rt, obj);
}

pub export fn nox_host_clear_err(err: ?*?*anyopaque) void {
    if (err) |e| e.* = null;
}

/// Başlatma isteğini kuyruğa alır (bağlam kilidi ELDE: sarmalayıcıdan). Başarıda `*out_task` doludur ve `thunk`/`argv` sahipliği işçiye geçer; hatada çağıran temizler.
pub export fn nox_host_async_submit(ctx_ptr: ?*anyopaque, thunk: ?ThunkFn, argv: ?[*]u64, argc: i64, on_done: ?TaskCallback, user_data: ?*anyopaque, out_task: ?*u64) i32 {
    _ = argc;
    if (comptime !threaded) return ERR_STATE;
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    const o = out_task orelse return ERR_INVAL;
    o.* = 0;
    if (thunk == null or on_done == null) return ERR_INVAL;
    if (ctx.async_dead or ctx.shutdown.load(.acquire)) return ERR_STATE;
    ctx.tmu.lock();
    var idx: u32 = undefined;
    if (ctx.free_tasks.pop()) |i| {
        idx = i;
    } else {
        ctx.tasks.append(std.heap.page_allocator, .{}) catch {
            ctx.tmu.unlock();
            return ERR_NOMEM;
        };
        idx = @intCast(ctx.tasks.items.len - 1);
    }
    const rec = &ctx.tasks.items[idx];
    const gen = rec.gen;
    rec.* = .{ .gen = gen, .state = .queued, .thunk = thunk, .argv = argv, .on_done = on_done, .user_data = user_data };
    ctx.queue.append(std.heap.page_allocator, idx) catch {
        taskRecFree(ctx, rec);
        ctx.tmu.unlock();
        return ERR_NOMEM;
    };
    const need_worker = !ctx.worker_running;
    if (need_worker) ctx.worker_running = true;
    if (!need_worker) wakeWorkerLocked(ctx);
    ctx.tmu.unlock();
    if (need_worker) {
        if (ctx.worker) |t| t.join(); // önceki işçi çıkış yolunda (kilidimiz yüzünden zaten bitti)
        ctx.worker = thread_spawn.spawn(workerMain, .{ctx}) catch {
            ctx.tmu.lock();
            ctx.worker = null;
            ctx.worker_running = false;
            _ = ctx.queue.pop();
            taskRecFree(ctx, &ctx.tasks.items[idx]);
            ctx.tmu.unlock();
            return ERR_NOMEM;
        };
    }
    o.* = taskHandle(ctx, idx, gen);
    return OK;
}

/// `tmu` ELDE: reaktörde bekleyen işçiyi uyandırır.
fn wakeWorkerLocked(ctx: *Context) void {
    if (comptime !threaded) return;
    if (ctx.sched) |p| {
        const sch: *sched_mod.Scheduler = @ptrCast(@alignCast(p));
        sch.wakeFromForeign();
    }
}

fn workerMain(ctx: *Context) void {
    if (comptime !threaded) return;
    ctx.lock.lock();
    if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
    bridge.nox_async_init(ctx.rt);
    const sch = bridge.hostScheduler().?;
    sch.host_hook = hostHook;
    sch.host_hook_ctx = ctx;
    sch.enableWake() catch {}; // Windows: uyandırma borusu yok; yeni görev/iptal reaktörden çıkışta fark edilir
    ctx.tmu.lock();
    ctx.sched = sch;
    ctx.tmu.unlock();
    var dead = false;
    while (true) {
        drainQueue(ctx);
        finalizeDone(ctx);
        if (ctx.live.items.len == 0) {
            ctx.tmu.lock();
            if (ctx.queue.items.len == 0 or ctx.shutdown.load(.acquire)) {
                ctx.worker_running = false;
                ctx.sched = null;
                ctx.tmu.unlock();
                break;
            }
            ctx.tmu.unlock();
            continue;
        }
        sch.run() catch {
            failAllDeadlocked(ctx);
            dead = true;
        };
        if (dead) {
            ctx.tmu.lock();
            ctx.async_dead = true;
            ctx.worker_running = false;
            ctx.sched = null;
            ctx.tmu.unlock();
            break;
        }
    }
    sch.host_hook = null;
    bridge.nox_async_deinit(ctx.rt);
    ctx.lock.unlock();
}

fn hostHook(p: ?*anyopaque, what: u8) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(p.?));
    switch (what) {
        0 => {
            if (ctx.shutdown.load(.acquire)) cancelAllLive(ctx);
            drainQueue(ctx);
            finalizeDone(ctx);
        },
        1 => ctx.lock.unlock(),
        else => {
            ctx.lock.lock();
            if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
        },
    }
}

fn cancelAllLive(ctx: *Context) void {
    if (comptime !threaded) return;
    for (ctx.live.items) |idx| {
        const rec = &ctx.tasks.items[idx];
        if (rec.task_ptr) |t| bridge.nox_task_cancel(t);
    }
}

/// İşçi (kilit ELDE): kuyruktaki görevleri zamanlayıcıya verir.
fn drainQueue(ctx: *Context) void {
    if (comptime !threaded) return;
    while (true) {
        if (ctx.shutdown.load(.acquire)) return;
        ctx.tmu.lock();
        if (ctx.queue.items.len == 0) {
            ctx.tmu.unlock();
            return;
        }
        const idx = ctx.queue.orderedRemove(0);
        const rec = &ctx.tasks.items[idx];
        const thunk = rec.thunk.?;
        const argv = rec.argv;
        ctx.tmu.unlock();
        const task = thunk(ctx.rt, argv);
        // thunk argüman bloğunu serbest bıraktı.
        ctx.tmu.lock();
        const r2 = &ctx.tasks.items[idx];
        r2.argv = null;
        r2.thunk = null;
        if (errors_handle.nox_exception_pending(ctx.rt) != 0 or task == null) {
            ctx.tmu.unlock();
            completeWithPending(ctx, idx, ERR_EXCEPTION);
            continue;
        }
        r2.task_ptr = task;
        r2.state = .running;
        const cancel = r2.cancel_req or r2.released;
        ctx.tmu.unlock();
        ctx.live.append(std.heap.page_allocator, idx) catch {};
        if (cancel) bridge.nox_task_cancel(task);
    }
}

/// Bekleyen Nox istisnasından (varsa) kaydı tamamlar; yoksa `fallback` durumu ve sentetik hata.
fn completeWithPending(ctx: *Context, idx: u32, fallback: i32) void {
    var errp: ?*anyopaque = null;
    var st = nox_host_capture(ctx, &errp);
    var err: ?*HostError = if (errp) |p| @ptrCast(@alignCast(p)) else null;
    if (st == OK) {
        st = fallback;
        err = newSynthError(ctx, "RuntimeError", "async task could not be started");
    }
    if (err) |e| if (e.exception != null) if (classNameOf(e.rt, e.exception)) |nm| if (std.mem.eql(u8, nm, "CancelledError")) {
        errDrop(e);
        err = null;
        st = ERR_CANCELLED;
    };
    finishRec(ctx, idx, st, 0, err);
}

/// İşçi (kilit ELDE): kaydı `done` yapar; sahibi `release` ettiyse kaynakları bırakır; değilse `on_done` çağrılır (kilit AÇIK).
fn finishRec(ctx: *Context, idx: u32, status: i32, value: u64, err: ?*HostError) void {
    ctx.tmu.lock();
    const rec = &ctx.tasks.items[idx];
    rec.state = .done;
    rec.task_ptr = null;
    rec.status = status;
    rec.value = value;
    rec.err = err;
    const gen = rec.gen;
    const released = rec.released;
    const cb = rec.on_done;
    const ud = rec.user_data;
    var call = !released and !rec.done_called and cb != null and !ctx.shutdown.load(.acquire);
    if (call) rec.done_called = true;
    if (released) {
        const v = rec.value;
        const e = rec.err;
        taskRecFree(ctx, rec);
        ctx.tmu.unlock();
        if (v != 0) _ = valueRelease(ctx, v);
        if (e) |x| errDrop(x);
        call = false;
    } else ctx.tmu.unlock();
    if (call) {
        ctx.lock.unlock();
        cb.?(ud, ctx, taskHandle(ctx, idx, gen), status);
        ctx.lock.lock();
        if (ctx.rt) |rt| asap.handOverArcOwner(@ptrCast(@alignCast(rt)));
    }
}

/// İşçi (kilit ELDE): bitmiş görevlerin sonucunu/istisnasını toplar.
fn finalizeDone(ctx: *Context) void {
    if (comptime !threaded) return;
    var i: usize = 0;
    while (i < ctx.live.items.len) {
        const idx = ctx.live.items[i];
        ctx.tmu.lock();
        const task = ctx.tasks.items[idx].task_ptr;
        ctx.tmu.unlock();
        if (task == null or bridge.nox_task_is_done(task) == 0) {
            i += 1;
            continue;
        }
        _ = ctx.live.swapRemove(i);
        ctx.tmu.lock();
        ctx.tasks.items[idx].task_ptr = null; // iptal artık Nox Task'ına dokunmaz
        ctx.tmu.unlock();
        const payload = bridge.nox_async_await(ctx.rt, task);
        if (errors_handle.nox_exception_pending(ctx.rt) != 0) {
            bridge.nox_async_destroy_task(ctx.rt, task);
            completeWithPending(ctx, idx, ERR_EXCEPTION);
        } else {
            bridge.nox_async_destroy_task(ctx.rt, task);
            finishRec(ctx, idx, OK, @bitCast(payload), null);
        }
    }
}

/// `run()` çıkmaz bildirdi: çalışan tüm görevler RuntimeError("deadlock in async task") ile biter (süreç ölmez).
fn failAllDeadlocked(ctx: *Context) void {
    while (ctx.live.items.len > 0) {
        const idx = ctx.live.swapRemove(ctx.live.items.len - 1);
        ctx.tmu.lock();
        ctx.tasks.items[idx].task_ptr = null;
        ctx.tmu.unlock();
        finishRec(ctx, idx, ERR_STATE, 0, newSynthError(ctx, "RuntimeError", "deadlock in async task"));
    }
}

/// Görev iptali: kooperatif (görevin bir sonraki `await`inde `CancelledError`). Başlamamış görev başlar başlamaz iptal edilir. Bitmiş görevde etkisizdir (OK).
pub export fn nox_host_task_cancel(ctx_ptr: ?*anyopaque, task: u64) i32 {
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    ctx.tmu.lock();
    defer ctx.tmu.unlock();
    const rec = taskRecOf(ctx, task) orelse return ERR_INVALID_HANDLE;
    switch (rec.state) {
        .queued => rec.cancel_req = true,
        .running => {
            rec.cancel_req = true;
            if (comptime threaded) {
                if (rec.task_ptr) |t| bridge.nox_task_cancel(t);
                wakeWorkerLocked(ctx);
            }
        },
        else => {},
    }
    return OK;
}

/// Bitmiş görevin sonucunu devreder: dönüş = nihai durum (OK / ERR_EXCEPTION / ERR_HOST_EXCEPTION / ERR_CANCELLED / ERR_STATE: çıkmaz). `*out_val` sonuç değeri (None/`None` dönüş için 0; host `nox_host_value_release` ile bırakır),
/// `*out_err` istisna ayrıntısıdır (`nox_host_error_release`). Görev bitmediyse ya da sonuç zaten alındıysa NOX_HOST_ERR_STATE (bu iki durum nihai durumdan `nox_host_task_status` ile ayrılabilir değildir; `on_done` sonrası çağırın).
pub export fn nox_host_task_take_result(ctx_ptr: ?*anyopaque, task: u64, out_val: ?*u64, out_err: ?*?*anyopaque) i32 {
    if (out_val) |o| o.* = 0;
    if (out_err) |o| o.* = null;
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    ctx.tmu.lock();
    const rec = taskRecOf(ctx, task) orelse {
        ctx.tmu.unlock();
        return ERR_INVALID_HANDLE;
    };
    if (rec.state != .done or rec.taken) {
        ctx.tmu.unlock();
        return ERR_STATE;
    }
    rec.taken = true;
    const st = rec.status;
    const v = rec.value;
    const e = rec.err;
    rec.value = 0;
    rec.err = null;
    ctx.tmu.unlock();
    if (out_val) |o| o.* = v else if (v != 0) {
        ctx.lock.lock();
        _ = valueRelease(ctx, v);
        ctx.lock.unlock();
    }
    if (e) |x| {
        if (out_err) |o| {
            o.* = x;
        } else {
            ctx.lock.lock();
            errDrop(x);
            ctx.lock.unlock();
        }
    }
    return st;
}

/// Görev kaydını bırakır. Çalışan görev iptal edilir ve artık `on_done` ÇAĞRILMAZ (host ilgilenmiyor); sonuç/hata alınmadıysa bırakılır.
pub export fn nox_host_task_release(ctx_ptr: ?*anyopaque, task: u64) i32 {
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    ctx.tmu.lock();
    const rec = taskRecOf(ctx, task) orelse {
        ctx.tmu.unlock();
        return ERR_INVALID_HANDLE;
    };
    if (rec.state == .done) {
        const v = rec.value;
        const e = rec.err;
        taskRecFree(ctx, rec);
        ctx.tmu.unlock();
        if (v != 0 or e != null) {
            ctx.lock.lock();
            if (v != 0) _ = valueRelease(ctx, v);
            if (e) |x| errDrop(x);
            ctx.lock.unlock();
        }
        return OK;
    }
    rec.released = true;
    rec.cancel_req = true;
    if (comptime threaded) {
        if (rec.state == .running) if (rec.task_ptr) |t| bridge.nox_task_cancel(t);
        wakeWorkerLocked(ctx);
    }
    ctx.tmu.unlock();
    return OK;
}

/// Bağlam yok edilirken: çalışan görevleri iptal eder, işçiyi bekler (görevler bir sonraki `await`lerinde biter), kayıtların kaynaklarını bırakır.
fn shutdownAsync(ctx: *Context) void {
    if (comptime !threaded) return;
    ctx.shutdown.store(true, .release);
    ctx.tmu.lock();
    wakeWorkerLocked(ctx);
    const t = ctx.worker;
    ctx.worker = null;
    ctx.tmu.unlock();
    if (t) |th| th.join();
    for (ctx.tasks.items) |*rec| {
        if (rec.state == .free) continue;
        if (rec.argv) |a| nox_host_async_free_args(a);
        if (rec.err) |e| errDrop(e);
    }
    ctx.tasks.deinit(std.heap.page_allocator);
    ctx.free_tasks.deinit(std.heap.page_allocator);
    ctx.queue.deinit(std.heap.page_allocator);
    ctx.live.deinit(std.heap.page_allocator);
}

// ---- UR-009 (ABI v3): sınıf örneği tutamaçları + kapsayıcı içi sınıf değerleri ----

/// `h` tutamacının Nox sınıf adı (`"Counter"`): BORÇLU UTF-8 görünümü (sınıf adı derleyicinin ürettiği değişmez veridir; yine de yalnızca `h` geçerliyken kullanılmalıdır).
/// Host, farklı modüllerden gelen tutamaçların beklenen sınıfa ait olduğunu bununla doğrular (sınıf düzeni/etiketi görünmez).
pub export fn nox_host_handle_type_name(ctx_ptr: ?*anyopaque, h: u64, out: ?*Span) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = .{ .data = null, .len = 0 };
    const ctx = ctxFrom(ctx_ptr) orelse return ERR_INVAL;
    ctx.lock.lock();
    defer ctx.lock.unlock();
    const slot = slotOf(ctx, h) orelse return ERR_INVALID_HANDLE;
    const name = classNameOf(ctx.rt, slot.obj) orelse return ERR_STATE;
    o.* = .{ .data = name.ptr, .len = name.len };
    return OK;
}

fn classNameOf(rt: ?*anyopaque, obj: ?*anyopaque) ?[]const u8 {
    const p = obj orelse return null;
    const f = dispatch_registry.classNameFn() orelse return null;
    const tag: *const i64 = @ptrCast(@alignCast(p));
    return std.mem.span(abi_ptr.cstr(f(abi_ptr.arg(rt), tag.*, abi_ptr.arg(p))));
}

/// `h` tutamacının nesnesini tutan (ARC +1) `NOX_HOST_VALUE_HANDLE` değeri; host kendi tutamacını yine bırakır.
pub export fn nox_host_value_handle(ctx_ptr: ?*anyopaque, h: u64, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = 0;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const slot = slotOf(ctx, h) orelse return ERR_INVALID_HANDLE;
    return coreHandleValue(ctx, slot.obj, o);
}

/// Nesneyi (ARC +1 alınır) tutan yeni `VK_HANDLE` düğümü; `obj == null` → `VK_NONE` düğümü (Nox `Class | None`in `None`ı).
fn coreHandleValue(ctx: *Context, obj: ?*anyopaque, out: *u64) i32 {
    if (obj == null) return coreScalar(ctx, VK_NONE, 0, 0, null, out);
    const n = nodeNew(VK_HANDLE) orelse return ERR_NOMEM;
    n.obj = obj;
    n.rt = ctx.rt;
    arc.nox_rc_retain(obj);
    const h = valueNew(ctx, n);
    if (h == 0) return ERR_NOMEM; // `valueNew` düğümü bıraktı (nesne ARC'si de `nodeRelease` ile geri verildi)
    out.* = h;
    return OK;
}

/// `NOX_HOST_VALUE_HANDLE` değerinin nesnesine YENİ bir `NoxHostHandle` (host `nox_host_handle_release` ile bırakır).
pub export fn nox_host_value_get_handle(ctx_ptr: ?*anyopaque, v: u64, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = 0;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    if (n.kind != VK_HANDLE) return ERR_INVAL;
    arc.nox_rc_retain(n.obj);
    const nh = nox_host_handle_new(ctx_ptr, n.obj);
    if (nh == 0) {
        releaseObject(ctx.rt, n.obj);
        return ERR_NOMEM;
    }
    o.* = nh;
    return OK;
}

// -- İÇ ilkeller: sentezlenen Nox adaptörleri `extern def ... with_rt` ile çağırır (bağlam kilidi ZATEN elde; bağlam `rt.host_ctx`ten) --
// Hata kodlaması Nox tarafında kolaydır: handle'lar 0 = başarısız/geçersiz, durum işlevleri 0 = OK.

/// `with_rt` ile gelen `rt`nin sahibi bağlam (kilit bu iş parçacığında ZATEN elde: adaptör `nox_host_enter` ile girilmiş bir çağrının içinde çalışır).
fn curCtx(rt: ?*anyopaque) ?*Context {
    const r: *asap.RuntimeState = @ptrCast(@alignCast(rt orelse return null));
    const p = r.host_ctx orelse return null;
    return @ptrCast(@alignCast(p));
}

pub export fn nox_hv_kind(rt: ?*anyopaque, h: i64) i64 {
    const ctx = curCtx(rt) orelse return -1;
    const n = nodeOf(ctx, @bitCast(h)) orelse return -1;
    return n.kind;
}

pub export fn nox_hv_int(rt: ?*anyopaque, h: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    return (nodeOf(ctx, @bitCast(h)) orelse return 0).i;
}

pub export fn nox_hv_float(rt: ?*anyopaque, h: i64) f64 {
    const ctx = curCtx(rt) orelse return 0;
    return (nodeOf(ctx, @bitCast(h)) orelse return 0).f;
}

pub export fn nox_hv_str(rt: ?*anyopaque, h: i64) ?[*:0]u8 {
    const ctx = curCtx(rt) orelse return str_mod.nox_str_from_bytes(rt, "");
    const n = nodeOf(ctx, @bitCast(h)) orelse return str_mod.nox_str_from_bytes(rt, "");
    return str_mod.nox_str_from_bytes(rt, n.data);
}

pub export fn nox_hv_len(rt: ?*anyopaque, h: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    const n = nodeOf(ctx, @bitCast(h)) orelse return 0;
    return @intCast(coreCount(n) orelse 0);
}

pub export fn nox_hv_item(rt: ?*anyopaque, h: i64, index: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    if (index < 0) return 0;
    var out: u64 = 0;
    if (coreChild(ctx, @bitCast(h), @intCast(index), 0, &out) != OK) return 0;
    return @bitCast(out);
}

pub export fn nox_hv_key(rt: ?*anyopaque, h: i64, index: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    if (index < 0) return 0;
    var out: u64 = 0;
    if (coreChild(ctx, @bitCast(h), @intCast(index), 1, &out) != OK) return 0;
    return @bitCast(out);
}

pub export fn nox_hv_val(rt: ?*anyopaque, h: i64, index: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    if (index < 0) return 0;
    var out: u64 = 0;
    if (coreChild(ctx, @bitCast(h), @intCast(index), 2, &out) != OK) return 0;
    return @bitCast(out);
}

pub export fn nox_hv_release(rt: ?*anyopaque, h: i64) void {
    const ctx = curCtx(rt) orelse return;
    _ = valueRelease(ctx, @bitCast(h));
}

/// `kind`: 0 none, 6 list, 7 dict, 8 tuple.
pub export fn nox_hv_new(rt: ?*anyopaque, kind: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    if (kind != VK_NONE and kind != VK_LIST and kind != VK_DICT and kind != VK_TUPLE) return 0;
    var out: u64 = 0;
    if (coreScalar(ctx, @intCast(kind), 0, 0, null, &out) != OK) return 0;
    return @bitCast(out);
}

pub export fn nox_hv_new_int(rt: ?*anyopaque, v: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    var out: u64 = 0;
    if (coreScalar(ctx, VK_INT, v, 0, null, &out) != OK) return 0;
    return @bitCast(out);
}

pub export fn nox_hv_new_float(rt: ?*anyopaque, v: f64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    var out: u64 = 0;
    if (coreScalar(ctx, VK_FLOAT, 0, v, null, &out) != OK) return 0;
    return @bitCast(out);
}

pub export fn nox_hv_new_bool(rt: ?*anyopaque, v: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    var out: u64 = 0;
    if (coreScalar(ctx, VK_BOOL, if (v != 0) 1 else 0, 0, null, &out) != OK) return 0;
    return @bitCast(out);
}

fn newStrLike(rt: ?*anyopaque, kind: u8, s: ?[*:0]const u8) i64 {
    const ctx = curCtx(rt) orelse return 0;
    const bytes: []const u8 = if (s) |p| str_mod.nox_str_slice(p) else "";
    var out: u64 = 0;
    if (coreScalar(ctx, kind, 0, 0, bytes, &out) != OK) return 0;
    return @bitCast(out);
}

/// `s` bir Nox `str` (BORÇLU; kopyalanır).
pub export fn nox_hv_new_str(rt: ?*anyopaque, s: ?[*:0]const u8) i64 {
    return newStrLike(rt, VK_STR, s);
}

/// `s` bir Nox `bytes` (BORÇLU; kopyalanır; gömülü 0 korunur).
pub export fn nox_hv_new_bytes(rt: ?*anyopaque, s: ?[*:0]const u8) i64 {
    return newStrLike(rt, VK_BYTES, s);
}

/// `bytes` içeriği için YENİ bir Nox `bytes` (`str` ile aynı ABI).
pub export fn nox_hv_bytes(rt: ?*anyopaque, h: i64) ?[*:0]u8 {
    return nox_hv_str(rt, h);
}

/// UR-009: `h` bir `NOX_HOST_VALUE_HANDLE` düğümü ve nesnesinin sınıf adı TAM olarak `name` ise 1 (alt sınıf örnekleri kapsayıcı içinde REDDEDİLİR; belgelenmiş sınır), değilse 0.
pub export fn nox_hv_class_is(rt: ?*anyopaque, h: i64, name: ?[*:0]const u8) i64 {
    const ctx = curCtx(rt) orelse return 0;
    const n = nodeOf(ctx, @bitCast(h)) orelse return 0;
    if (n.kind != VK_HANDLE) return 0;
    const want = std.mem.span(name orelse return 0);
    const got = classNameOf(rt, n.obj) orelse return 0;
    return if (std.mem.eql(u8, got, want)) 1 else 0;
}

/// UR-009: `VK_HANDLE` düğümünün nesnesi (ARC +1: çağıran sahip olur; `with_rt` sınıf-dönüşlü extern fabrikası sözleşmesi). Tür denetimi `nox_hv_class_is` ile ÖNCEDEN yapılır.
pub export fn nox_hv_obj_take(rt: ?*anyopaque, h: i64) ?*anyopaque {
    const ctx = curCtx(rt) orelse return null;
    const n = nodeOf(ctx, @bitCast(h)) orelse return null;
    if (n.kind != VK_HANDLE) return null;
    arc.nox_rc_retain(n.obj);
    return n.obj;
}

/// UR-009: Nox nesnesi (BORÇLU; düğüm kendi +1'ini alır) için `VK_HANDLE` düğümü (YENİ handle; 0 = bellek yok).
pub export fn nox_hv_new_obj(rt: ?*anyopaque, obj: ?*anyopaque) i64 {
    const ctx = curCtx(rt) orelse return 0;
    var out: u64 = 0;
    if (coreHandleValue(ctx, obj, &out) != OK) return 0;
    return @bitCast(out);
}

pub export fn nox_hv_append(rt: ?*anyopaque, c: i64, item: i64) i64 {
    const ctx = curCtx(rt) orelse return ERR_INVAL;
    return coreAppend(ctx, @bitCast(c), @bitCast(item));
}

pub export fn nox_hv_dict_set(rt: ?*anyopaque, d: i64, k: i64, v: i64) i64 {
    const ctx = curCtx(rt) orelse return ERR_INVAL;
    return coreDictSet(ctx, @bitCast(d), @bitCast(k), @bitCast(v));
}

test "UR-008: değer ağacı kurulur, okunur, döngü reddedilir, bırakılır (sızıntısız)" {
    var cfg = Config{ .size = @sizeOf(Config), .abi_version = ABI_VERSION, .allocator = null };
    var ctx_ptr: ?*anyopaque = null;
    try std.testing.expectEqual(OK, nox_host_context_create(&cfg, &ctx_ptr));
    defer nox_host_context_destroy(ctx_ptr);

    var l: u64 = 0;
    try std.testing.expectEqual(OK, nox_host_value_container(ctx_ptr, VK_LIST, &l));
    var a: u64 = 0;
    var b: u64 = 0;
    try std.testing.expectEqual(OK, nox_host_value_int(ctx_ptr, 41, &a));
    try std.testing.expectEqual(OK, nox_host_value_str(ctx_ptr, "hi", 2, 0, &b));
    try std.testing.expectEqual(OK, nox_host_value_append(ctx_ptr, l, a));
    try std.testing.expectEqual(OK, nox_host_value_append(ctx_ptr, l, b));
    try std.testing.expectEqual(ERR_INVAL, nox_host_value_append(ctx_ptr, l, l)); // döngü
    try std.testing.expectEqual(OK, nox_host_value_release(ctx_ptr, a));
    try std.testing.expectEqual(ERR_INVALID_HANDLE, nox_host_value_release(ctx_ptr, a)); // nesil denetimi

    var n: usize = 0;
    try std.testing.expectEqual(OK, nox_host_value_len(ctx_ptr, l, &n));
    try std.testing.expectEqual(@as(usize, 2), n);
    var it: u64 = 0;
    try std.testing.expectEqual(OK, nox_host_value_item(ctx_ptr, l, 0, &it));
    var iv: i64 = 0;
    try std.testing.expectEqual(OK, nox_host_value_get_int(ctx_ptr, it, &iv));
    try std.testing.expectEqual(@as(i64, 41), iv);
    try std.testing.expectEqual(ERR_INVAL, nox_host_value_item(ctx_ptr, l, 5, &it)); // aralık dışı

    var d: u64 = 0;
    try std.testing.expectEqual(OK, nox_host_value_container(ctx_ptr, VK_DICT, &d));
    var k: u64 = 0;
    try std.testing.expectEqual(OK, nox_host_value_str(ctx_ptr, "k", 1, 0, &k));
    try std.testing.expectEqual(OK, nox_host_value_dict_set(ctx_ptr, d, k, l));
    try std.testing.expectEqual(OK, nox_host_value_dict_set(ctx_ptr, d, k, b)); // aynı anahtar: değer değişir
    try std.testing.expectEqual(OK, nox_host_value_len(ctx_ptr, d, &n));
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(ERR_INVAL, nox_host_value_dict_set(ctx_ptr, l, k, b)); // dict değil
    // kalan handle'lar (b, l, it, d, k) bağlam yok edilirken bırakılır
}
