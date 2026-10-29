//! Faz 10 (WASM): `spawn`/`await`/`Task[T]`/`Channel[T]`in wasm32'deki uygulaması. WebAssembly'de yığın değiştirme (fiber) yoktur ve iş parçacığı yoktur,
//! bu yüzden görevler AYNI yığında, yuvalanmış çalıştırılır ("benzetim"):
//!
//!  - `spawn` görevi kuyruğa koyar (hemen çalıştırmaz; yerel M:1 zamanlayıcısındaki gibi çağıran bir yerde bekleyince çalışır).
//!  - Bir görev bekleten bir işlemde (`await`, boş kanaldan `recv`) kuyruktaki görevleri SIRAYLA, kendi yığınının üstünde, bitene kadar çalıştırır
//!    (`runOne`). Böylece üretici/tüketici, `await` zincirleri ve kanal tabanlı iş hatları çalışır.
//!  - Bir görev, kendisinin altındaki (yığında daha eski) bir görevi beklerse askıya alınamaz: bu bir kilitlenmedir ve net bir hata ile sonlanır.
//!    Bu yüzden yazan taraf bloklayamaz: kanal `send` dolu kuyrukta beklemez (kapasite aşılabilir; sınırsız kuyruk gibi davranır) — sonuç yalnızca
//!    çalıştırma SIRASINDAN etkilenir, değerlerden değil. Sonsuza dek `recv` döngüsünde bekleyen "işçi" görevler (ana görev ona istek gönderirken
//!    işçinin arada askıya alınması gereken kalıplar) desteklenmez: kilitlenme olarak bildirilir.
//!
//! Sözleşme `bridge_native.zig` ile aynıdır (aynı `export` sembolleri); derlenmiş kod fark etmez.

const std = @import("std");
const asap = @import("../alloc/asap.zig");
const fiber_mod = @import("fiber.zig");
const diag_sink = @import("diag_sink");
const abi_ptr = @import("../abi_ptr.zig");
const wasm_host = @import("../wasm_host.zig");

/// wasm32'de zamanlayıcı yoktur; çağıranlar `?*Scheduler` bekler ama her zaman `null` alır.
pub const Scheduler = opaque {};

pub fn currentFiberScheduler() ?*Scheduler {
    return null;
}

pub fn currentFiber() ?*fiber_mod.Fiber {
    return null;
}

const TaskLocalMap = std.AutoHashMapUnmanaged(*anyopaque, ?*anyopaque);

const TaskFn = *const fn (u64) callconv(.c) i64;

const State = enum { pending, running, done };

const Task = struct {
    func: TaskFn,
    arg: u64,
    state: State = .pending,
    result: i64 = 0,
    exc_obj: ?*anyopaque = null,
    exc_line: i64 = 0,
    refcount: u32 = 1,
    cancel_requested: bool = false,
    /// Sahip `destroy` etti ama görev bitmedi: bitince kendini serbest bırakır.
    detached: bool = false,
    task_locals: TaskLocalMap = .empty,
};

const Channel = struct {
    queue: std.ArrayListUnmanaged(i64) = .empty,
    head: usize = 0,
    capacity: usize,
    refcount: u32 = 1,

    fn len(self: *const Channel) usize {
        return self.queue.items.len - self.head;
    }
};

const Sched = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayListUnmanaged(*Task) = .empty,
    pending_head: usize = 0,
    current: ?*Task = null,
};

var g_sched: ?Sched = null;

extern fn nox_raise(rt: ?*anyopaque, obj: ?*anyopaque, line: i64) callconv(.c) void;
extern fn nox_exception_pending(rt: ?*anyopaque) callconv(.c) i32;
extern fn nox_exception_take(rt: ?*anyopaque) callconv(.c) ?*anyopaque;

fn allocatorFromRt(rt: ?*anyopaque) std.mem.Allocator {
    const state: *asap.RuntimeState = @ptrCast(@alignCast(rt.?));
    return state.allocator();
}

pub fn currentTaskLocals() ?*TaskLocalMap {
    const s = &(g_sched orelse return null);
    const t = s.current orelse return null;
    return &t.task_locals;
}

pub fn spawnPinnedForCurrentThread(func: *const fn (*anyopaque) callconv(.c) i64, arg: *anyopaque) ?*anyopaque {
    _ = func;
    _ = arg;
    return null;
}

pub export fn nox_async_init(rt: ?*anyopaque) void {
    g_sched = .{ .allocator = allocatorFromRt(rt) };
}

pub export fn nox_async_deinit(rt: ?*anyopaque) void {
    _ = rt;
    if (g_sched) |*s| s.pending.deinit(s.allocator);
    g_sched = null;
}

pub export fn nox_async_spawn(rt: ?*anyopaque, func: TaskFn, arg: ?*anyopaque) ?*anyopaque {
    const s = &g_sched.?;
    const t = allocatorFromRt(rt).create(Task) catch @panic("OOM: spawn");
    t.* = .{ .func = func, .arg = abi_ptr.arg(arg) };
    s.pending.append(s.allocator, t) catch @panic("OOM: spawn");
    return t;
}

fn freeTask(rt: ?*anyopaque, t: *Task) void {
    const a = allocatorFromRt(rt);
    t.task_locals.deinit(a);
    a.destroy(t);
}

/// Görevi bitene kadar çalıştırır; yakalanmamış istisnayı göreve taşır.
fn runTask(rt: ?*anyopaque, t: *Task) void {
    const s = &g_sched.?;
    t.state = .running;
    const prev = s.current;
    s.current = t;
    t.result = t.func(t.arg);
    s.current = prev;
    if (nox_exception_pending(rt) != 0) {
        t.exc_obj = nox_exception_take(rt);
        t.exc_line = 0;
    }
    t.state = .done;
    if (t.detached) freeTask(rt, t);
}

/// Kuyruktaki ilk bekleyen görevi çalıştırır; çalıştıracak görev yoksa `false`.
fn runOne(rt: ?*anyopaque) bool {
    const s = &g_sched.?;
    while (s.pending_head < s.pending.items.len) {
        const t = s.pending.items[s.pending_head];
        s.pending_head += 1;
        if (s.pending_head == s.pending.items.len) {
            s.pending.clearRetainingCapacity();
            s.pending_head = 0;
        }
        if (t.state != .pending) continue; // başka bir bekleyen tarafından zaten çalıştırıldı
        runTask(rt, t);
        return true;
    }
    return false;
}

fn deadlock(rt: ?*anyopaque, what: []const u8) noreturn {
    diag_sink.report(rt, "nox: deadlock detected ({s}) — on wasm, tasks run nested on one stack and cannot be suspended; the awaited result can only come from a task that is blocked below this one\n", .{what});
    wasm_host.exitProcess(1);
}

pub export fn nox_async_await(rt: ?*anyopaque, task: ?*anyopaque) i64 {
    const t: *Task = @ptrCast(@alignCast(task.?));
    while (t.state != .done) {
        if (!runOne(rt)) deadlock(rt, "await");
    }
    if (t.exc_obj) |exc| {
        t.exc_obj = null;
        nox_raise(rt, exc, t.exc_line);
    }
    return t.result;
}

pub export fn nox_task_retain(task: ?*anyopaque) void {
    const t: *Task = @ptrCast(@alignCast(task orelse return));
    t.refcount += 1;
}

pub export fn nox_task_cancel(task: ?*anyopaque) void {
    const t: *Task = @ptrCast(@alignCast(task orelse return));
    t.cancel_requested = true;
}

pub export fn nox_task_check_cancelled(rt: ?*anyopaque) i32 {
    _ = rt;
    const s = &(g_sched orelse return 0);
    const t = s.current orelse return 0;
    return if (t.cancel_requested) 1 else 0;
}

pub export fn nox_async_destroy_task(rt: ?*anyopaque, task: ?*anyopaque) void {
    const t: *Task = @ptrCast(@alignCast(task orelse return));
    t.refcount -= 1;
    if (t.refcount != 0) return;
    if (t.state == .done) {
        freeTask(rt, t);
        return;
    }
    // Bitmemiş görev: çalıştığında (ya da `run_to_completion`da) kendini serbest bırakır.
    t.detached = true;
}

pub export fn nox_async_run_to_completion(rt: ?*anyopaque) i32 {
    while (runOne(rt)) {}
    return 0;
}

pub export fn nox_async_deadlock_abort(rt: ?*anyopaque) noreturn {
    diag_sink.report(rt, "nox: deadlock detected — all tasks are blocked, none can make progress\n", .{});
    wasm_host.exitProcess(1);
}

export fn nox_channel_new(rt: ?*anyopaque, capacity: i64) ?*anyopaque {
    const ch = allocatorFromRt(rt).create(Channel) catch @panic("OOM: channel");
    ch.* = .{ .capacity = @intCast(@max(capacity, 0)) };
    return ch;
}

export fn nox_channel_retain(ch: ?*anyopaque) void {
    const c: *Channel = @ptrCast(@alignCast(ch orelse return));
    c.refcount += 1;
}

export fn nox_channel_destroy(rt: ?*anyopaque, ch: ?*anyopaque) void {
    const c: *Channel = @ptrCast(@alignCast(ch orelse return));
    c.refcount -= 1;
    if (c.refcount != 0) return;
    const a = allocatorFromRt(rt);
    c.queue.deinit(a);
    a.destroy(c);
}

/// `send` bekleyemez (bkz. modül notu): değer kuyruğa konur; kapasite aşıldıysa kuyruktaki görevler (alıcılar) çalıştırılmayı denenir, olmazsa kuyruk
/// kapasitenin ötesine büyür.
export fn nox_channel_send(rt: ?*anyopaque, ch: ?*anyopaque, value: i64) void {
    const c: *Channel = @ptrCast(@alignCast(ch.?));
    c.queue.append(allocatorFromRt(rt), value) catch @panic("OOM: channel send");
    // Dengesiz (rendezvous) kanal: alıcıya devredilmesi için bekleyen görevlere bir şans ver.
    while (c.len() > c.capacity) {
        if (!runOne(rt)) break;
    }
}

export fn nox_channel_recv(rt: ?*anyopaque, ch: ?*anyopaque) i64 {
    const c: *Channel = @ptrCast(@alignCast(ch.?));
    while (c.len() == 0) {
        if (!runOne(rt)) deadlock(rt, "channel recv");
    }
    const v = c.queue.items[c.head];
    c.head += 1;
    if (c.head == c.queue.items.len) {
        c.queue.clearRetainingCapacity();
        c.head = 0;
    }
    return v;
}
