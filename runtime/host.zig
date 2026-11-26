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
/// UR-012: sabitlenmiş arabellekte çakışan sabitleme (yazma/okuma) — `nox_host_handle_pin_buffer` reddedildi.
pub const ERR_BUSY: i32 = 10;
/// UR-015: sabit-genişlikli tamsayı taşması (kurtarılabilir; süreç ölmez, bağlam sağlıklı kalır).
pub const ERR_OVERFLOW: i32 = 11;

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
pub const Config = extern struct { size: u32, abi_version: u32, allocator: ?*const HostAllocator };

/// UR-013: host ayırıcısı (`include/nox_embed.h`daki `NoxHostAllocator` ile BİREBİR aynı düzen). `alloc`: en az `len` bayt, `alignment` hizalı; yetersizse NULL. `free`: aynı `len`/`alignment` ile bırakır. Her iki işlev iş parçacığı-güvenli
/// olmalı ve bağlam yok edilene kadar yaşamalıdır.
pub const HostAllocator = extern struct {
    size: u32,
    ctx: ?*anyopaque,
    alloc: ?*const fn (?*anyopaque, usize, usize) callconv(.c) ?*anyopaque,
    free: ?*const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) void,
};

/// UR-010 (addendum): bağlam kilidi YENİDEN-GİRİŞLİdir. Kilit sahibi iş parçacığı (`owner`) bir host geri çağrısı içindeyken aynı bağlama yeniden girebilir (`depth` artar); BAŞKA iş parçacıkları kilit
/// boşalana (`depth == 0`) dek bekler — geri çağrı sırasında askıdaki Nox çerçevelerine/ARC durumuna yabancı iş parçacığı giremez. `nox_host_context_destroy` çalışırken `depth > 0` ise yok etme ERTELENİR (son `unlock`ta yapılır).
const RLock = struct {
    spin: SpinLock = .{},
    owner: std.atomic.Value(usize) = .init(0),
    depth: u32 = 0,
    destroy_pending: bool = false,

    fn me() usize {
        return @intCast(thread_spawn.currentId());
    }

    fn lock(self: *RLock) void {
        const t = me();
        if (self.owner.load(.acquire) == t) {
            self.depth += 1;
            return;
        }
        self.spin.lock();
        self.owner.store(t, .release);
        self.depth = 1;
    }

    fn unlock(self: *RLock) void {
        self.depth -= 1;
        if (self.depth != 0) return;
        const pending = self.destroy_pending;
        self.owner.store(0, .release);
        self.spin.unlock();
        if (pending) {
            const ctx: *Context = @alignCast(@fieldParentPtr("lock", self));
            destroyNow(ctx);
        }
    }

    /// Bu iş parçacığının tuttuğu TÜM derinliği bırakır (zamanlayıcı reaktörde beklerken / `on_done` sırasında); derinlik `relock` ile geri verilir.
    fn unlockAll(self: *RLock) u32 {
        const d = self.depth;
        self.depth = 0;
        self.owner.store(0, .release);
        self.spin.unlock();
        return d;
    }

    fn relock(self: *RLock, d: u32) void {
        self.spin.lock();
        self.owner.store(me(), .release);
        self.depth = d;
    }
};

/// `lock`: bağlam BAŞINA kilit — `nox_host_enter`/`nox_host_leave` ile her çağrı seri çalışır; böylece bağlam HERHANGİ bir OS iş parçacığından (sırayla) kullanılabilir (UR-004).
/// Paralellik için her iş parçacığı KENDİ bağlamını oluşturur (bağlamlar tamamen bağımsızdır).
const Context = struct {
    magic: u32,
    rt: ?*anyopaque,
    lock: RLock = .{},
    /// UR-013: host ayırıcısının kopyası (null: sistem ayırıcısı); `rt` yönetilen heap'ini buradan besler.
    host_alloc: ?HostAllocator = null,
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
    /// Görev işçisinin iş parçacığı kimliği (0 = işçi yok).
    worker_id: std.atomic.Value(usize) = .init(0),
    hook_depth: u32 = 0,
    /// UR-012: sabitlenmiş arabellekler (`pin_id` = bağlam etiketi | nesil | indeks+1).
    pins: std.ArrayListUnmanaged(PinRec) = .empty,
    free_pins: std.ArrayListUnmanaged(u32) = .empty,
    /// İşçinin zamanlayıcısı (uyandırma için; yalnızca `worker_running` iken ve `tmu` altında geçerli).
    sched: ?*anyopaque = null,
    /// Çıkmaz (deadlock) sonrası zamanlayıcı bozulmuş sayılır: yeni görev başlatılamaz.
    async_dead: bool = false,
};

pub const ThunkFn = *const fn (rt: ?*anyopaque, argv: ?[*]u64) callconv(.c) ?*anyopaque;
pub const TaskCallback = *const fn (user_data: ?*anyopaque, ctx: ?*anyopaque, task: u64, final_status: i32) callconv(.c) void;

const PinRec = struct { gen: u16 = 1, obj: ?*anyopaque = null, writable: bool = false };

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
const HostError = struct { magic: u32, ctx: *Context, rt: ?*anyopaque, exception: ?*anyopaque, line: i64, host_token: u64 = 0, synth_class: []const u8 = "", synth_msg: []const u8 = "", owned_msg: bool = false };

pub export fn nox_host_abi_version() u32 {
    return ABI_VERSION;
}

pub export fn nox_host_context_create(config: ?*const Config, out: ?*?*anyopaque) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = null;
    const cfg = config orelse return ERR_INVAL;
    if (cfg.size < @sizeOf(Config)) return ERR_VERSION;
    if (cfg.abi_version < 1 or cfg.abi_version > ABI_VERSION) return ERR_VERSION; // v2/v3 başlıkları v1/v2 ana makinelerini de kabul eder (eklemeli)
    // UR-013: `allocator` yalnızca ABI v3 ana makineleri içindir (v1/v2'de alan "NULL OLMALI" idi).
    if (cfg.allocator != null and cfg.abi_version < 3) return ERR_INVAL;
    if (cfg.allocator) |ha| {
        if (ha.size < @sizeOf(HostAllocator)) return ERR_VERSION;
        if (ha.alloc == null or ha.free == null) return ERR_INVAL;
    }
    const ctx = std.heap.page_allocator.create(Context) catch return ERR_NOMEM;
    ctx.* = .{ .magic = CTX_MAGIC, .rt = null };
    if (cfg.allocator) |ha| ctx.host_alloc = ha.*;
    const rt = (if (ctx.host_alloc != null)
        asap.nox_runtime_init_with_allocator(.{ .ptr = ctx, .vtable = &host_alloc_vtable })
    else
        asap.nox_runtime_init()) orelse {
        std.heap.page_allocator.destroy(ctx);
        return ERR_NOMEM;
    };
    ctx.rt = rt;
    rtState(rt).host_ctx = ctx; // UR-008: `nox_hv_*` ilkelleri bağlamı `rt`den bulur
    o.* = ctx;
    return OK;
}

const host_alloc_vtable: std.mem.Allocator.VTable = .{
    .alloc = hostAlloc,
    .resize = hostResize,
    .remap = hostRemap,
    .free = hostFree,
};

fn hostAlloc(p: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const ctx: *Context = @ptrCast(@alignCast(p));
    const h = ctx.host_alloc orelse return null;
    const f = h.alloc orelse return null;
    return @ptrCast(f(h.ctx, len, alignment.toByteUnits()));
}

fn hostResize(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = .{ p, memory, alignment, new_len, ret_addr };
    return false;
}

fn hostRemap(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = .{ p, memory, alignment, new_len, ret_addr };
    return null;
}

fn hostFree(p: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const ctx: *Context = @ptrCast(@alignCast(p));
    const h = ctx.host_alloc orelse return;
    const f = h.free orelse return;
    f(h.ctx, memory.ptr, memory.len, alignment.toByteUnits());
}

/// UR-013: çalışma zamanının desteklediği özellik bitleri (host, kullanmadan önce yoklar). Bit numaraları DONDURULMUŞTUR; yeni özellikler yeni bit alır.
pub const CAP_VALUE_TREE: u64 = 1 << 0;
pub const CAP_CLASSES: u64 = 1 << 1;
pub const CAP_CALLBACKS: u64 = 1 << 2;
pub const CAP_ASYNC_TASKS: u64 = 1 << 3;
pub const CAP_PINNED_BUFFERS: u64 = 1 << 4;
pub const CAP_TYPED_ARRAYS: u64 = 1 << 5;
pub const CAP_CUSTOM_ALLOCATOR: u64 = 1 << 6;
pub const CAP_SUBINTERPRETERS: u64 = 1 << 7;
pub const CAP_RECOVERABLE_TRAPS: u64 = 1 << 8;

pub export fn nox_host_capabilities() u64 {
    var caps: u64 = CAP_VALUE_TREE | CAP_CLASSES | CAP_CALLBACKS | CAP_PINNED_BUFFERS | CAP_TYPED_ARRAYS | CAP_CUSTOM_ALLOCATOR | CAP_SUBINTERPRETERS | CAP_RECOVERABLE_TRAPS;
    if (threaded) caps |= CAP_ASYNC_TASKS;
    return caps;
}

/// Bağlamı yok eder. Bağlam başka bir iş parçacığında kullanılıyorsa (derinlik > 0) o iş bitene dek BEKLER; çağıran bir host geri çağrısının içindeyse (kilit bu iş parçacığında tutuluyor) yok etme, en dıştaki çağrı
/// bitince YAPILIR (ertelenir). Görev işçisinin KENDİ iş parçacığından (görev/`on_done` geri çağrısı içinden) yok etme desteklenmez: yalnızca iptal istenir (host bunu başka iş parçacığından tamamlamalıdır).
pub export fn nox_host_context_destroy(ctx_ptr: ?*anyopaque) void {
    const ctx = ctxFrom(ctx_ptr) orelse return;
    ctx.shutdown.store(true, .release); // çalışan görevleri bir an önce iptale zorlar
    ctx.tmu.lock();
    wakeWorkerLocked(ctx);
    ctx.tmu.unlock();
    const my = RLock.me();
    if (ctx.worker_id.load(.acquire) == my) return;
    if (ctx.lock.owner.load(.acquire) == my) { // geri çağrı içindeyiz: erteler
        ctx.lock.destroy_pending = true;
        return;
    }
    ctx.lock.lock(); // başka bir iş parçacığı içerdeyse bekler
    _ = ctx.lock.unlockAll();
    destroyNow(ctx);
}

fn destroyNow(ctx: *Context) void {
    shutdownAsync(ctx); // UR-011: çalışan görevleri iptal et, işçiyi bekle (kilit tutulmaz)
    const rt = ctx.rt;
    ctx.closing = true;
    // Açık kalan handle'ların nesneleri çalışma zamanı kapanmadan ÖNCE bırakılır (sızıntı/sarkan başvuru yok).
    for (ctx.pins.items) |pr| if (pr.obj != null) releaseObject(rt, pr.obj);
    ctx.pins.deinit(std.heap.page_allocator);
    ctx.free_pins.deinit(std.heap.page_allocator);
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
    // UR-015: taşma tuzağı — Nox sınıfı olmayan özel nesne; kurtarılabilir `ERR_OVERFLOW`.
    if (exc) |eo| {
        const w: [*]const i64 = @ptrCast(@alignCast(eo));
        if (w[0] == errors_handle.TRAP_TAG_OVERFLOW) {
            const tname: []const u8 = if (w[1] != 0) std.mem.span(@as([*:0]const u8, @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(w[1]))))))) else "?";
            arc.nox_rc_free_payload(rt, eo, 16);
            const owned: ?[]u8 = std.fmt.allocPrint(std.heap.page_allocator, "integer overflow in type '{s}'", .{tname}) catch null;
            const er = newSynthError(ctx, "OverflowError", owned orelse "integer overflow") orelse {
                if (owned) |m| std.heap.page_allocator.free(m);
                return ERR_NOMEM;
            };
            er.owned_msg = owned != null;
            if (out_err) |o| o.* = er else errDrop(er);
            return ERR_OVERFLOW;
        }
    }
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
    if (e.owned_msg) std.heap.page_allocator.free(@constCast(e.synth_msg));
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
/// UR-012: bitişik, tek dtype'lı sayısal dizi değeri (`i` = dtype, `data` = ham bayt kopyası).
pub const VK_TYPED_ARRAY: u8 = 10;
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
        VK_TYPED_ARRAY => n.data.len / dtypeSize(@intCast(n.i)),
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
// Kural (addendum): host geri çağrıları (`invoke`/`retain`/`release`) bağlam kilidi TUTULURKEN çağrılır. Kilit YENİDEN-GİRİŞLİdir (`RLock`): geri çağrıyı yapan iş parçacığı aynı bağlamda host → Nox çağrıları yapabilir;
// başka iş parçacıkları kilit boşalana dek bekler (askıdaki Nox çerçevelerine/ARC durumuna yabancı iş parçacığı girmez).

fn externalRetain(ctx: *Context, ref: u64) void {
    const ops = ctx.cb orelse return;
    const f = ops.retain orelse return;
    f(ops.user_data, ref); // kilit TUTULUR: geri çağrı aynı iş parçacığından yeniden girebilir, yabancılar bekler
}

fn externalRelease(ctx: *Context, ref: u64) void {
    const ops = ctx.cb orelse return;
    const f = ops.release orelse return;
    f(ops.user_data, ref);
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
    const st = f(ops.user_data, ctx, @bitCast(target), @bitCast(args), &result, &token, &msg);
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
    if (e.owned_msg) std.heap.page_allocator.free(@constCast(e.synth_msg));
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

/// Sınıf denetimi: `obj`nin sınıf adı `spec` (`"A|B|C"`) içindeki adlardan biri mi? 1/0 (`--host-abi` sarmalayıcıları; tutamaç parametrelerinin türü doğrulanır).
pub export fn nox_host_obj_is_type(rt: ?*anyopaque, obj: ?*anyopaque, spec: ?[*:0]const u8) i32 {
    const name = classNameOf(rt, obj) orelse return 1; // sınıf adı çözülemiyorsa (dağıtım tablosu yok) denetim atlanır
    const sp = std.mem.span(spec orelse return 1);
    var it = std.mem.splitScalar(u8, sp, '|');
    while (it.next()) |c| if (std.mem.eql(u8, c, name)) return 1;
    return 0;
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
    ctx.worker_id.store(RLock.me(), .release);
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
            // Bayrak, görevler bitirilmeden (on_done host'u uyandırmadan) ÖNCE kurulur: aksi halde host
            // on_done'dan hemen sonra yeni görev başlatabilir ve ERR_STATE yerine OK alır (aarch64 yarışı).
            ctx.tmu.lock();
            ctx.async_dead = true;
            ctx.tmu.unlock();
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
    ctx.worker_id.store(0, .release);
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
        1 => ctx.hook_depth = ctx.lock.unlockAll(),
        else => {
            ctx.lock.relock(ctx.hook_depth);
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
        const d = ctx.lock.unlockAll();
        cb.?(ud, ctx, taskHandle(ctx, idx, gen), status);
        ctx.lock.relock(d);
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

// ---- UR-012 (ABI v3): bitişik sayısal diziler (`NOX_HOST_VALUE_TYPED_ARRAY`) ve sıfır kopya sabitlenmiş arabellekler ----

pub const DT_U8: i32 = 1;
pub const DT_F64: i32 = 10;
pub const DT_BOOL: i32 = 11;

fn dtypeSize(dt: i32) usize {
    return switch (dt) {
        1, 2, 11 => 1,
        3, 4 => 2,
        5, 6, 9 => 4,
        else => 8, // 7, 8, 10
    };
}

fn dtypeValid(dt: i32) bool {
    return dt >= 1 and dt <= 11;
}

/// `count` elemanlı `dtype` dizisini (TEK bellek kopyası) taşıyan değer. Host verisi kopyalanır.
pub export fn nox_host_value_typed_array(ctx_ptr: ?*anyopaque, dtype: i32, data: ?*const anyopaque, count: usize, out: ?*u64) i32 {
    const o = out orelse return ERR_INVAL;
    o.* = 0;
    if (!dtypeValid(dtype)) return ERR_INVAL;
    if (count != 0 and data == null) return ERR_INVAL;
    const sz = dtypeSize(dtype);
    const bytes = std.math.mul(usize, count, sz) catch return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const src: []const u8 = if (bytes == 0) "" else @as([*]const u8, @ptrCast(data.?))[0..bytes];
    return coreScalarKind(ctx, VK_TYPED_ARRAY, dtype, src, o);
}

fn coreScalarKind(ctx: *Context, kind: u8, i: i64, data: []const u8, out: *u64) i32 {
    out.* = 0;
    const n = nodeNew(kind) orelse return ERR_NOMEM;
    n.i = i;
    if (data.len != 0) {
        n.data = std.heap.page_allocator.dupe(u8, data) catch {
            nodeRelease(n);
            return ERR_NOMEM;
        };
    }
    const h = valueNew(ctx, n);
    if (h == 0) return ERR_NOMEM;
    out.* = h;
    return OK;
}

/// Dizinin dtype'ı, verisi (BORÇLU: değer bırakılana kadar geçerli) ve eleman sayısı.
pub export fn nox_host_value_get_typed_array(ctx_ptr: ?*anyopaque, v: u64, out_dtype: ?*i32, out_data: ?*?*const anyopaque, out_count: ?*usize) i32 {
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const n = nodeOf(ctx, v) orelse return ERR_INVALID_HANDLE;
    if (n.kind != VK_TYPED_ARRAY) return ERR_INVAL;
    if (out_dtype) |p| p.* = @intCast(n.i);
    if (out_data) |p| p.* = if (n.data.len == 0) null else n.data.ptr;
    if (out_count) |p| p.* = n.data.len / dtypeSize(@intCast(n.i));
    return OK;
}

/// Adaptör ilkelleri: dizinin `idx`inci elemanı (tamsayı/bool dtype'ları → int; F32/F64 → float). Aralık/tür dışı 0.
pub export fn nox_hv_ta_int(rt: ?*anyopaque, h: i64, idx: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    const n = nodeOf(ctx, @bitCast(h)) orelse return 0;
    if (n.kind != VK_TYPED_ARRAY or idx < 0) return 0;
    const dt: i32 = @intCast(n.i);
    const sz = dtypeSize(dt);
    const off = @as(usize, @intCast(idx)) * sz;
    if (off + sz > n.data.len) return 0;
    const p = n.data.ptr + off;
    return switch (dt) {
        1, 11 => p[0],
        2 => @as(i8, @bitCast(p[0])),
        3 => std.mem.readInt(u16, p[0..2], .little),
        4 => std.mem.readInt(i16, p[0..2], .little),
        5 => std.mem.readInt(u32, p[0..4], .little),
        6 => std.mem.readInt(i32, p[0..4], .little),
        7 => @bitCast(std.mem.readInt(u64, p[0..8], .little)),
        8 => std.mem.readInt(i64, p[0..8], .little),
        else => 0,
    };
}

pub export fn nox_hv_ta_float(rt: ?*anyopaque, h: i64, idx: i64) f64 {
    const ctx = curCtx(rt) orelse return 0;
    const n = nodeOf(ctx, @bitCast(h)) orelse return 0;
    if (n.kind != VK_TYPED_ARRAY or idx < 0) return 0;
    const dt: i32 = @intCast(n.i);
    const sz = dtypeSize(dt);
    const off = @as(usize, @intCast(idx)) * sz;
    if (off + sz > n.data.len) return 0;
    const p = n.data.ptr + off;
    return switch (dt) {
        9 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, p[0..4], .little)))),
        10 => @bitCast(std.mem.readInt(u64, p[0..8], .little)),
        else => @floatFromInt(nox_hv_ta_int(rt, h, idx)),
    };
}

/// Dizi, `want` (0 = int, 1 = float, 2 = bool) kullanımına uygun mu? 1/0 (int: tamsayı+bool dtype'ları, float: tüm sayısal dtype'lar, bool: yalnız BOOL).
pub export fn nox_hv_ta_ok(rt: ?*anyopaque, h: i64, want: i64) i64 {
    const ctx = curCtx(rt) orelse return 0;
    const n = nodeOf(ctx, @bitCast(h)) orelse return 0;
    if (n.kind != VK_TYPED_ARRAY) return 0;
    const dt: i32 = @intCast(n.i);
    const is_float = dt == 9 or dt == 10;
    return switch (want) {
        0 => if (!is_float) 1 else 0,
        1 => 1,
        else => if (dt == DT_BOOL) 1 else 0,
    };
}

pub const BufferView = extern struct {
    struct_size: u32,
    dtype: i32,
    data: ?*anyopaque,
    byte_len: usize,
    itemsize: usize,
    ndim: i32,
    flags: u32,
    shape: [8]i64,
    strides: [8]i64,
    pin_id: u64,
};

const BUF_WRITABLE: u32 = 1;
const BUF_CONTIGUOUS_C: u32 = 2;

const BufClass = struct { name: []const u8, dtype: i32 };
const buf_classes = [_]BufClass{
    .{ .name = "nox_host_F64Buffer", .dtype = 10 },
    .{ .name = "nox_host_I64Buffer", .dtype = 8 },
    .{ .name = "nox_host_I32Buffer", .dtype = 6 },
    .{ .name = "nox_host_U8Buffer", .dtype = 1 },
};

fn pinTag(ctx: *Context) u64 {
    return ctxTag(ctx) ^ 0x7777;
}

/// `nox.host.F64Buffer` / `I64Buffer` / `I32Buffer` / `U8Buffer` örneğini sabitler: ham veriye SIFIR KOPYA görünüm (`out_view`). Birden çok okuma sabitlemesi olabilir; en çok bir ÖZEL yazma sabitlemesi
/// (okuma varken ya da tersi `NOX_HOST_ERR_BUSY`). Sabitleme nesneyi canlı tutar (ARC) ve `nox_host_buffer_unpin`e kadar Nox tarafında `resize` RuntimeError verir. Tamponun veri adresi sabitken değişmez.
pub export fn nox_host_handle_pin_buffer(ctx_ptr: ?*anyopaque, h: u64, req_flags: u32, out_view: ?*BufferView, out_err: ?*?*anyopaque) i32 {
    if (out_err) |e| e.* = null;
    const o = out_view orelse return ERR_INVAL;
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    const slot = slotOf(ctx, h) orelse return ERR_INVALID_HANDLE;
    const obj = slot.obj orelse return ERR_INVALID_HANDLE;
    const name = classNameOf(ctx.rt, obj) orelse return ERR_STATE;
    var dtype: i32 = 0;
    for (buf_classes) |bc| if (std.mem.eql(u8, bc.name, name)) {
        dtype = bc.dtype;
    };
    if (dtype == 0) return ERR_INVAL; // sabitlenebilir bir arabellek sınıfı değil
    const base: [*]u8 = @ptrCast(obj);
    const f: [*]align(1) i64 = @ptrCast(base + abi_layout.TAG_SIZE);
    if (f[0] != dtype) return ERR_STATE; // alan düzeni beklenenden farklı
    const writable = (req_flags & BUF_WRITABLE) != 0;
    if (writable) {
        if (f[1] > 0 or f[2] != 0) return ERR_BUSY;
    } else if (f[2] != 0) return ERR_BUSY;
    const list_addr: usize = @intCast(@as(u64, @bitCast(f[3])));
    if (list_addr == 0) return ERR_STATE;
    const lp: [*]const u8 = @ptrFromInt(list_addr);
    const len: usize = @intCast(@as(*align(1) const i64, @ptrCast(lp + abi_layout.LIST_LEN_OFF)).*);
    const data_addr: usize = @intCast(@as(*align(1) const u64, @ptrCast(lp + abi_layout.LIST_DATA_OFF)).*);
    var idx: u32 = undefined;
    if (ctx.free_pins.pop()) |i| {
        idx = i;
    } else {
        ctx.pins.append(std.heap.page_allocator, .{}) catch return ERR_NOMEM;
        idx = @intCast(ctx.pins.items.len - 1);
    }
    const rec = &ctx.pins.items[idx];
    arc.nox_rc_retain(obj);
    rec.obj = obj;
    rec.writable = writable;
    if (writable) f[2] = 1 else f[1] += 1;
    const itemsize = dtypeSize(dtype);
    o.* = .{
        .struct_size = @sizeOf(BufferView),
        .dtype = dtype,
        .data = @ptrFromInt(data_addr),
        .byte_len = len * itemsize,
        .itemsize = itemsize,
        .ndim = 1,
        .flags = BUF_CONTIGUOUS_C | (if (writable) BUF_WRITABLE else 0),
        .shape = [_]i64{0} ** 8,
        .strides = [_]i64{0} ** 8,
        .pin_id = (pinTag(ctx) << 48) | (@as(u64, rec.gen) << 32) | (@as(u64, idx) + 1),
    };
    o.shape[0] = @intCast(len);
    o.strides[0] = @intCast(itemsize);
    return OK;
}

pub export fn nox_host_buffer_unpin(ctx_ptr: ?*anyopaque, pin_id: u64) i32 {
    const ctx = lockedCtx(ctx_ptr) orelse return ERR_INVAL;
    defer ctx.lock.unlock();
    if (pin_id == 0 or (pin_id >> 48) != pinTag(ctx)) return ERR_INVALID_HANDLE;
    const idx1: u32 = @truncate(pin_id);
    if (idx1 == 0 or idx1 > ctx.pins.items.len) return ERR_INVALID_HANDLE;
    const rec = &ctx.pins.items[idx1 - 1];
    if (rec.obj == null or rec.gen != @as(u16, @truncate(pin_id >> 32))) return ERR_INVALID_HANDLE;
    const obj = rec.obj;
    const base: [*]u8 = @ptrCast(obj.?);
    const f: [*]align(1) i64 = @ptrCast(base + abi_layout.TAG_SIZE);
    if (rec.writable) f[2] = 0 else if (f[1] > 0) f[1] -= 1;
    rec.obj = null;
    rec.gen +%= 1;
    if (rec.gen == 0) rec.gen = 1;
    ctx.free_pins.append(std.heap.page_allocator, idx1 - 1) catch {};
    releaseObject(ctx.rt, obj);
    return OK;
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

// UR-014: Zig tarafı düzenleri `include/nox_host.h` (tests/compat/host_abi/abi_layout.c) ile AYNI olmalıdır; sapma derleme hatasıdır. (64-bit hedefler.)
comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Config) == 16 and @offsetOf(Config, "abi_version") == 4 and @offsetOf(Config, "allocator") == 8);
        std.debug.assert(@sizeOf(Span) == 16 and @offsetOf(Span, "len") == 8);
        std.debug.assert(@sizeOf(Buffer) == 16 and @offsetOf(Buffer, "len") == 8);
        std.debug.assert(@sizeOf(HostAllocator) == 32 and @offsetOf(HostAllocator, "ctx") == 8 and @offsetOf(HostAllocator, "alloc") == 16 and @offsetOf(HostAllocator, "free") == 24);
        std.debug.assert(@sizeOf(CallbackOps) == 40 and @offsetOf(CallbackOps, "user_data") == 8 and @offsetOf(CallbackOps, "invoke") == 16 and @offsetOf(CallbackOps, "retain") == 24 and @offsetOf(CallbackOps, "release") == 32);
        std.debug.assert(@sizeOf(BufferView) == 176 and @offsetOf(BufferView, "shape") == 40 and @offsetOf(BufferView, "strides") == 104 and @offsetOf(BufferView, "pin_id") == 168);
    }
}
