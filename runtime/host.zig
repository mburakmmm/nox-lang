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

pub const ABI_VERSION: u32 = 2;

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
    /// UR-008: bu bağlamın `NoxHostValue` tablosu (host-tarafı değer ağaçları; Nox nesnesi DEĞİLDİR).
    vals: std.ArrayListUnmanaged(VSlot) = .empty,
    free_vals: std.ArrayListUnmanaged(u32) = .empty,
};

const VSlot = struct { node: ?*Node, gen: u16 };

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
    const rt = ctx.rt;
    // Açık kalan handle'ların nesneleri çalışma zamanı kapanmadan ÖNCE bırakılır (sızıntı/sarkan başvuru yok).
    for (ctx.slots.items) |slot| releaseObject(rt, slot.obj);
    ctx.slots.deinit(std.heap.page_allocator);
    ctx.free_slots.deinit(std.heap.page_allocator);
    for (ctx.vals.items) |vs| nodeRelease(vs.node);
    ctx.vals.deinit(std.heap.page_allocator);
    ctx.free_vals.deinit(std.heap.page_allocator);
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

const Node = struct {
    rc: u32 = 1,
    kind: u8,
    i: i64 = 0,
    f: f64 = 0,
    data: []u8 = &.{},
    /// list/tuple: elemanlar; dict: [k0, v0, k1, v1, ...]
    items: std.ArrayListUnmanaged(*Node) = .empty,
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
