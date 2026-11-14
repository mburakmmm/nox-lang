//! Paylaşımlı WASM belleği ve `memory.atomic.wait/notify` park tablosu (TODO 4.6, tasarım: `project/wasm-threads-tasarimi-2026-11.md`, aşama 1).
//!
//! Bellek, `max_pages` kadar ADRES ALANI bir kez ayrılır ve HİÇ TAŞINMAZ (`page_allocator`: tembel işlenen sıfırlı sayfalar); `memory.grow` yalnızca `pages` sayacını atomik artırır. Her yürütme durumu
//! (`Instance`) belleğin `bytes[0 .. pages*65536]` görünümünü tutar ve sınır dışı erişimde yenilemeyi dener (başka bir iş parçacığı büyütmüş olabilir). Atomik komutlar gerçek donanım atomikleridir.
//! `wait`/`notify`: adres-anahtarlı bekleyen listesi (bir kilit altında "değer hâlâ beklenen mi?" denetimi + kayıt, `notify` ile yarış yok); bekleyen kısa uykularla yoklar (std 0.16'da
//! `Thread.Futex` yok, bu katmanın `Io` örneği de yok): uyandırma gecikmesi ≤ ~1 ms, CPU yakmaz.

const std = @import("std");
const builtin = @import("builtin");

pub const PAGE: usize = 65536;
pub const NOT_EQUAL: u32 = 1;
pub const WOKEN: u32 = 0;
pub const TIMED_OUT: u32 = 2;
pub const CANCELED: u32 = 3;

pub const SpinLock = struct {
    v: std.atomic.Value(u32) = .init(0),
    pub fn lock(self: *SpinLock) void {
        while (self.v.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinLock) void {
        self.v.store(0, .release);
    }
};

const Waiter = struct {
    addr: usize,
    next: ?*Waiter = null,
    woken: std.atomic.Value(bool) = .init(false),
};

const WinTime = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.c) void;
    extern "kernel32" fn QueryPerformanceCounter(c: *i64) callconv(.c) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(f: *i64) callconv(.c) c_int;
} else struct {};

fn nowNs() i64 {
    if (comptime builtin.os.tag == .windows) {
        var f: i64 = 0;
        var c: i64 = 0;
        _ = WinTime.QueryPerformanceFrequency(&f);
        _ = WinTime.QueryPerformanceCounter(&c);
        return @divTrunc(c, f) * std.time.ns_per_s + @divTrunc(@mod(c, f) * std.time.ns_per_s, f);
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn sleepNs(ns: u64) void {
    if (comptime builtin.os.tag == .windows) {
        WinTime.Sleep(@intCast(@max(1, ns / std.time.ns_per_ms)));
        return;
    }
    const ts: std.c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = std.c.nanosleep(&ts, null);
}

/// Hizalı bir adresten `w` baytlık (1/2/4/8) atomik yükleme (seq_cst).
pub fn atomicLoad(base: [*]u8, e: usize, w: u8) u64 {
    return switch (w) {
        1 => @atomicLoad(u8, @as(*const u8, @ptrCast(base + e)), .seq_cst),
        2 => @atomicLoad(u16, @as(*const u16, @ptrCast(@alignCast(base + e))), .seq_cst),
        4 => @atomicLoad(u32, @as(*const u32, @ptrCast(@alignCast(base + e))), .seq_cst),
        else => @atomicLoad(u64, @as(*const u64, @ptrCast(@alignCast(base + e))), .seq_cst),
    };
}

pub const SharedMemory = struct {
    bytes: []u8,
    pages: std.atomic.Value(u32),
    max_pages: u32,
    refs: std.atomic.Value(u32) = .init(1),
    /// Bu belleğe bağlı yürütme durumu (iş parçacığı) sayısı; tek başına çalışan örnekte `wait` bloklamaz (eski tek iş parçacıklı davranış korunur).
    attached: std.atomic.Value(u32) = .init(0),
    lock: SpinLock = .{},
    head: ?*Waiter = null,
    tail: ?*Waiter = null,

    pub fn create(gpa: std.mem.Allocator, min_pages: u32, max_pages: u32) !*SharedMemory {
        const self = try gpa.create(SharedMemory);
        errdefer gpa.destroy(self);
        const bytes = try std.heap.page_allocator.alloc(u8, @as(usize, max_pages) * PAGE);
        @memset(bytes[0 .. @as(usize, min_pages) * PAGE], 0);
        self.* = .{ .bytes = bytes, .pages = .init(min_pages), .max_pages = max_pages };
        return self;
    }

    /// `gpa`: `create`te verilenle aynı ayırıcı.
    pub fn release(self: *SharedMemory, gpa: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            std.heap.page_allocator.free(self.bytes);
            gpa.destroy(self);
        }
    }

    pub fn retain(self: *SharedMemory) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Şu anki görünüm: `bytes[0 .. pages*65536]`.
    pub fn view(self: *SharedMemory) []u8 {
        return self.bytes[0 .. @as(usize, self.pages.load(.acquire)) * PAGE];
    }

    /// `memory.grow`: eski sayfa sayısı; sığmazsa 0xffffffff. Sayfalar zaten sıfırlıdır (hiç yazılmadılar: erişim `pages` ile sınırlıydı).
    pub fn grow(self: *SharedMemory, delta: u32) u32 {
        var cur = self.pages.load(.acquire);
        while (true) {
            const new = @as(u64, cur) + delta;
            if (new > self.max_pages) return 0xffff_ffff;
            if (delta == 0) return cur;
            if (self.pages.cmpxchgWeak(cur, @intCast(new), .acq_rel, .acquire)) |actual| {
                cur = actual;
                continue;
            }
            return cur;
        }
    }

    /// `memory.atomic.wait32/64`: 0 uyandırıldı, 1 değer farklı, 2 zaman aşımı. `timeout_ns < 0`: sonsuz. `e`: doğal hizalı bayt adresi.
    pub fn wait(self: *SharedMemory, e: usize, w: u8, expected: u64, timeout_ns: i64, cancel: ?*const std.atomic.Value(bool)) u32 {
        var me: Waiter = .{ .addr = e };
        const mask: u64 = if (w == 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(w * 8)) - 1;
        self.lock.lock();
        if (atomicLoad(self.bytes.ptr, e, w) != (expected & mask)) {
            self.lock.unlock();
            return NOT_EQUAL;
        }
        if (self.tail) |t| t.next = &me else self.head = &me;
        self.tail = &me;
        self.lock.unlock();

        const deadline: i64 = if (timeout_ns >= 0) nowNs() +| timeout_ns else std.math.maxInt(i64);
        var spins: u32 = 0;
        var nap: u64 = 20_000;
        while (true) {
            if (me.woken.load(.acquire)) return WOKEN;
            const canceled = if (cancel) |c| c.load(.acquire) else false;
            if (canceled or (timeout_ns >= 0 and nowNs() >= deadline)) {
                self.lock.lock();
                if (me.woken.load(.acquire)) {
                    self.lock.unlock();
                    return WOKEN;
                }
                self.unlinkLocked(&me);
                self.lock.unlock();
                return if (canceled) CANCELED else TIMED_OUT;
            }
            if (spins < 64) {
                spins += 1;
                std.atomic.spinLoopHint();
            } else {
                sleepNs(nap);
                nap = @min(nap * 2, 1_000_000);
            }
        }
    }

    fn unlinkLocked(self: *SharedMemory, me: *Waiter) void {
        var prev: ?*Waiter = null;
        var cur = self.head;
        while (cur) |c| : (cur = c.next) {
            if (c == me) {
                if (prev) |p| p.next = c.next else self.head = c.next;
                if (self.tail == c) self.tail = prev;
                return;
            }
            prev = c;
        }
    }

    /// `memory.atomic.notify`: `e` adresini bekleyen en çok `count` (FIFO) bekleyeni uyandırır; uyandırılan sayıyı döner.
    pub fn notify(self: *SharedMemory, e: usize, count: u32) u32 {
        var woken: u32 = 0;
        self.lock.lock();
        defer self.lock.unlock();
        var prev: ?*Waiter = null;
        var cur = self.head;
        while (cur) |c| {
            const nxt = c.next;
            if (c.addr == e and woken < count) {
                if (prev) |p| p.next = nxt else self.head = nxt;
                if (self.tail == c) self.tail = prev;
                c.woken.store(true, .release);
                woken += 1;
            } else {
                prev = c;
            }
            cur = nxt;
        }
        return woken;
    }
};

test "paylaşımlı bellek: büyütme yerinde, sınır ve sayfa sayacı; notify/wait çift iş parçacığı" {
    const gpa = std.testing.allocator;
    const sm = try SharedMemory.create(gpa, 1, 4);
    defer sm.release(gpa);
    try std.testing.expectEqual(@as(usize, PAGE), sm.view().len);
    const base = sm.bytes.ptr;
    try std.testing.expectEqual(@as(u32, 1), sm.grow(2));
    try std.testing.expectEqual(@as(usize, 3 * PAGE), sm.view().len);
    try std.testing.expect(sm.bytes.ptr == base); // taşınmadı
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), sm.grow(2)); // 5 > 4
    try std.testing.expectEqual(@as(u32, 3), sm.grow(0));

    // değer farklı
    sm.bytes[16] = 7;
    try std.testing.expectEqual(NOT_EQUAL, sm.wait(16, 4, 0, -1, null));
    // zaman aşımı (kimse uyandırmıyor)
    try std.testing.expectEqual(TIMED_OUT, sm.wait(32, 4, 0, 5 * std.time.ns_per_ms, null));
    // gerçek uyandırma: ikinci iş parçacığı notify eder
    const T = struct {
        fn run(m: *SharedMemory) void {
            sleepNs(20 * std.time.ns_per_ms);
            while (m.notify(48, 1) == 0) sleepNs(1 * std.time.ns_per_ms);
        }
    };
    const th = try std.Thread.spawn(.{}, T.run, .{sm});
    try std.testing.expectEqual(WOKEN, sm.wait(48, 4, 0, 5 * std.time.ns_per_s, null));
    th.join();
    try std.testing.expectEqual(@as(u32, 0), sm.notify(48, 10)); // bekleyen kalmadı
}
