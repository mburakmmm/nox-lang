//! Nox async runtime — yığınlı (stackful) fiber ilkeli (bkz. nox-teknik-
//! spesifikasyon.md §3.21, "Eşzamanlılık modeli"). Go'nun goroutine'leri
//! gibi: her `Fiber` kendi SABİT boyutlu yığınını alır; bağlam değişimi
//! `swap_aarch64.s`teki elle yazılmış montaj rutinüyle yapılır (Zig'in
//! kendisi 0.11'den beri dilde async/await İÇERMEDİĞİNDEN).
//!
//! **Kapsam (v0.1, yalnızca aarch64):** bu katman TEK BAŞINA "eşzamanlı
//! çalıştırma" sağlamaz — yalnızca "iki bağlam arasında elle geçiş"
//! ilkelini sağlar. Zamanlanma (hangi fiber'ın ne zaman çalışacağı),
//! `Task`/`Channel` semantiği ve deadlock tespiti `scheduler.zig`dedir.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .aarch64) {
        @compileError("runtime/async_rt şu an yalnızca aarch64 için uygulandı (bkz. nox-teknik-spesifikasyon.md §3.21, v0.1 sınırlaması)");
    }
}

/// `swap_aarch64.s`teki alan ofsetleriyle BİRE BİR eşleşmelidir — sıra
/// ya da alan eklemek/çıkarmak montaj dosyasını da güncellemeyi gerektirir.
pub const Context = extern struct {
    x19: usize = 0,
    x20: usize = 0,
    x21: usize = 0,
    x22: usize = 0,
    x23: usize = 0,
    x24: usize = 0,
    x25: usize = 0,
    x26: usize = 0,
    x27: usize = 0,
    x28: usize = 0,
    fp: usize = 0,
    lr: usize = 0,
    sp: usize = 0,
    d8: u64 = 0,
    d9: u64 = 0,
    d10: u64 = 0,
    d11: u64 = 0,
    d12: u64 = 0,
    d13: u64 = 0,
    d14: u64 = 0,
    d15: u64 = 0,
};

extern fn nox_swap_context(old: *Context, new: *Context) void;

pub const STACK_SIZE: usize = 256 * 1024;
pub const STACK_ALIGN: usize = 16;

pub const FiberFn = *const fn (*anyopaque) void;

pub const Fiber = struct {
    ctx: Context = .{},
    /// Bu fiber'ı `resume_` eden tarafın bağlamı — `yield`/bitişte buraya
    /// geri döneriz. Her `resume_` çağrısında güncellenir (bir fiber farklı
    /// zamanlarda farklı çağıranlar tarafından resume edilebilir — bkz.
    /// zamanlayıcı).
    return_ctx: ?*Context = null,
    stack: []align(STACK_ALIGN) u8,
    entry: FiberFn,
    arg: *anyopaque,
    finished: bool = false,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, entry: FiberFn, arg: *anyopaque) !*Fiber {
        const stack = try allocator.alignedAlloc(u8, .fromByteUnits(STACK_ALIGN), STACK_SIZE);
        errdefer allocator.free(stack);
        return createWithStack(allocator, entry, arg, stack);
    }

    /// `create` ile AYNI, ama yığını KENDİSİ tahsis etmez — ÖNCEDEN elde
    /// edilmiş (bkz. `scheduler.zig`, `Scheduler.acquireStack` — havuzdan
    /// geri dönüştürülmüş OLABİLİR) bir yığın alır. Performans fazında
    /// (benchmark darboğaz denetimi) bulundu: 256 KiB'lik yığın, HER
    /// `spawn`da tazeden tahsis edilip HER tamamlanmada serbest bırakılırsa,
    /// genel amaçlı ayırıcının (boyutu nedeniyle küçük-nesne hızlı yolunu
    /// atlayıp doğrudan işletim sistemine gitmesi YÜZÜNDEN) baskın bir
    /// darboğaz oluşturuyordu — bkz. `Scheduler`in modül üstü notu.
    pub fn createWithStack(allocator: std.mem.Allocator, entry: FiberFn, arg: *anyopaque, stack: []align(STACK_ALIGN) u8) !*Fiber {
        const self = try allocator.create(Fiber);
        self.* = .{
            .stack = stack,
            .entry = entry,
            .arg = arg,
            .allocator = allocator,
        };
        // İlk yığın işaretçisi: yığının TEPESİ (aşağı doğru büyür), 16
        // baytlık hizalamaya (AAPCS64'ün gerektirdiği) yuvarlanmış.
        const stack_top = @intFromPtr(self.stack.ptr) + self.stack.len;
        self.ctx.sp = stack_top & ~@as(usize, STACK_ALIGN - 1);
        self.ctx.lr = @intFromPtr(&trampoline);
        // `self` işaretçisini x19'a (çağrı-korumalı, bu yüzden ilk
        // `nox_swap_context` onu OLDUĞU GİBİ `trampoline`a taşır)
        // "kaçak" olarak yerleştiriyoruz — bkz. `trampoline`ın x19'u
        // okuması.
        self.ctx.x19 = @intFromPtr(self);
        return self;
    }

    pub fn destroy(self: *Fiber) void {
        self.allocator.free(self.stack);
        self.allocator.destroy(self);
    }

    /// `destroy` ile AYNI, ama yığını SERBEST BIRAKMAZ — çağırana (bkz.
    /// `Scheduler.releaseStack`) geri döner, böylece bir sonraki `spawn`
    /// tarafından yeniden kullanılabilir. Yalnızca `Fiber` struct'ının
    /// kendisi (küçük, sabit boyutlu) serbest bırakılır.
    pub fn destroyKeepStack(self: *Fiber) []align(STACK_ALIGN) u8 {
        const stack = self.stack;
        self.allocator.destroy(self);
        return stack;
    }

    /// `caller_ctx`den bu fiber'a geçer; fiber `yield` edene ya da bitene
    /// kadar (yani `caller_ctx`e geri dönülene kadar) BLOKE eder — ama bu
    /// "bloke etmek" yalnızca ÇAĞIRANIN bakış açısındandır (OS iş parçacığı
    /// hiçbir zaman gerçekten uyumaz, yalnızca hangi mantıksal akışın
    /// çalıştığı değişir).
    pub fn resume_(self: *Fiber, caller_ctx: *Context) void {
        self.return_ctx = caller_ctx;
        nox_swap_context(caller_ctx, &self.ctx);
    }

    /// Fiber'ın KENDİSİ tarafından çağrılır: kontrolü `resume_` eden tarafa
    /// geri verir. `resume_` tekrar çağrılırsa, bu fonksiyon SANKİ normal
    /// bir fonksiyon çağrısından dönmüş gibi devam eder.
    pub fn yield(self: *Fiber) void {
        nox_swap_context(&self.ctx, self.return_ctx.?);
    }
};

/// Bir fiber İLK KEZ resume edildiğinde atlanan nokta. x19, `Fiber.create`
/// tarafından yerleştirilen `self` işaretçisini taşır (bkz. yukarısı).
fn trampoline() callconv(.c) noreturn {
    const self_addr = asm volatile (""
        : [ret] "={x19}" (-> usize),
    );
    const self: *Fiber = @ptrFromInt(self_addr);
    callEntryPadded(self);
    self.finished = true;
    // Kalıcı olarak çağırana dön — bu fiber bir daha ASLA resume edilmez
    // (bkz. zamanlayıcının `finished` denetimi).
    self.yield();
    unreachable;
}

/// `trampoline`in kendisi fiber yığınının SAHTE önyükleme çerçevesinin
/// HEMEN üzerindedir (bkz. modül üstü not, "sahte önyükleme çerçevesi...
/// GERÇEK bir çağrı zincirini TEMSİL ETMEZ"). `std.heap.DebugAllocator`in
/// (varsayılan `stack_trace_frames = 6`) yığın-izi yakalaması, `self.entry`
/// (KULLANICI kodu) İÇİNDEN (ya da entry'nin doğrudan çağırdığı SIĞ bir
/// fonksiyondan) yapılan bir `alloc`/`free`de bu sahte çerçevenin ÖTESİNE
/// geçmeye çalışırsa GEÇERSİZ BELLEĞE düşer (`SIGSEGV`) — bu, `runtime/
/// stdlib_shims/http_client.zig`/`http_server.zig`de GERÇEKTEN yaşanan,
/// nox-teknik-spesifikasyon.md §3.31'in "İKİNCİ, DAHA DERİN keşif"inde
/// belgelenen bir hata. Bu KATMANLI (kasıtlı `never_inline`) sarmalayıcı
/// zinciri, `self.entry`in `trampoline`den HER ZAMAN birkaç GERÇEK çerçeve
/// UZAKTA başlamasını (yığın-izi yakalayıcının ihtiyaç duyduğu GERÇEK
/// derinliği bulabilmesi İÇİN) GARANTİ eder — TÜM fiber tabanlı kod (Task
/// sarmalı, bare fiber, ileride yazılacak HERHANGİ bir async_rt kullanıcısı)
/// İÇİN merkezi, tek seferlik bir çözüm (her çağrı sitesine AYRI AYRI
/// "derinlik dolgusu" eklemek YERİNE).
fn callEntryPadded(self: *Fiber) void {
    @call(.never_inline, callEntryPad7, .{self});
}
fn callEntryPad7(self: *Fiber) void {
    @call(.never_inline, callEntryPad6, .{self});
}
fn callEntryPad6(self: *Fiber) void {
    @call(.never_inline, callEntryPad5, .{self});
}
fn callEntryPad5(self: *Fiber) void {
    @call(.never_inline, callEntryPad4, .{self});
}
fn callEntryPad4(self: *Fiber) void {
    @call(.never_inline, callEntryPad3, .{self});
}
fn callEntryPad3(self: *Fiber) void {
    @call(.never_inline, callEntryPad2, .{self});
}
fn callEntryPad2(self: *Fiber) void {
    @call(.never_inline, callEntryPad1, .{self});
}
fn callEntryPad1(self: *Fiber) void {
    self.entry(self.arg);
}

test "iki fiber arasında birden çok kez geçiş, x19 kaçağı doğru çalışır" {
    // Not: fiber yığınındaki ilk (bootstrap) çerçevenin fp/lr'si gerçek bir
    // çağrı zincirini TEMSİL ETMEZ (bkz. `Fiber.create`) — `std.testing.
    // allocator` (DebugAllocator) her `alloc`de sızıntı-izleme için çerçeve
    // işaretçisi zincirini yürüyerek yığın izi ÇIKARIR; bu, fiber'ın sahte
    // önyükleme çerçevesinin ÖTESİNE geçmeye çalışıp geçersiz belleğe
    // düşer (segfault). Bu yalnızca bu izleme özelliğinin bir yan etkisi —
    // bağlam değişiminin kendisiyle İLGİSİZ — bu yüzden fiber GÖVDESİ
    // içindeki günlüğe izlemesiz bir ayırıcı (`page_allocator`) kullanılır.
    const Harness = struct {
        var log: std.ArrayListUnmanaged(u8) = .empty;
        var main_ctx: Context = .{};

        fn entry(arg: *anyopaque) void {
            const fiber: *Fiber = @ptrCast(@alignCast(arg));
            log.append(std.heap.page_allocator, 'A') catch unreachable;
            fiber.yield();
            log.append(std.heap.page_allocator, 'B') catch unreachable;
            fiber.yield();
            log.append(std.heap.page_allocator, 'C') catch unreachable;
        }
    };
    defer Harness.log.deinit(std.heap.page_allocator);

    const fiber = try Fiber.create(std.testing.allocator, Harness.entry, undefined);
    fiber.arg = fiber; // entry kendi Fiber'ını arg olarak alır (basit bir kendine-referans)
    defer fiber.destroy();

    try std.testing.expect(!fiber.finished);
    fiber.resume_(&Harness.main_ctx);
    try std.testing.expect(!fiber.finished);
    fiber.resume_(&Harness.main_ctx);
    try std.testing.expect(!fiber.finished);
    fiber.resume_(&Harness.main_ctx);
    try std.testing.expect(fiber.finished);

    try std.testing.expectEqualStrings("ABC", Harness.log.items);
}

test "birden çok bağımsız fiber, ara katmanlı (interleaved) resume" {
    const Harness = struct {
        var log: std.ArrayListUnmanaged(u8) = .empty;
        var main_ctx: Context = .{};

        fn makeEntry(comptime tag: u8) FiberFn {
            return struct {
                fn f(arg: *anyopaque) void {
                    const fiber: *Fiber = @ptrCast(@alignCast(arg));
                    log.append(std.heap.page_allocator, tag) catch unreachable;
                    fiber.yield();
                    log.append(std.heap.page_allocator, tag + 1) catch unreachable;
                }
            }.f;
        }
    };
    defer Harness.log.deinit(std.heap.page_allocator);

    const f1 = try Fiber.create(std.testing.allocator, Harness.makeEntry('1'), undefined);
    f1.arg = f1;
    defer f1.destroy();
    const f2 = try Fiber.create(std.testing.allocator, Harness.makeEntry('7'), undefined);
    f2.arg = f2;
    defer f2.destroy();

    f1.resume_(&Harness.main_ctx); // basar '1', yield
    f2.resume_(&Harness.main_ctx); // basar '7', yield
    f1.resume_(&Harness.main_ctx); // basar '2', biter
    f2.resume_(&Harness.main_ctx); // basar '8', biter

    try std.testing.expectEqualStrings("1728", Harness.log.items);
    try std.testing.expect(f1.finished);
    try std.testing.expect(f2.finished);
}
