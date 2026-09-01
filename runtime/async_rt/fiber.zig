//! Nox async runtime — yığınlı (stackful) fiber ilkeli (bkz. nox-teknik-
//! spesifikasyon.md §3.21, "Eşzamanlılık modeli"). Go'nun goroutine'leri
//! gibi: her `Fiber` kendi SABİT boyutlu yığınını alır; bağlam değişimi
//! elle yazılmış montaj rutinleriyle yapılır (Zig'in kendisi 0.11'den beri
//! dilde async/await İÇERMEDİĞİNDEN) — aarch64 İÇİN `swap_aarch64.S`,
//! x86-64 İÇİN `swap_x86_64.S` (Faz R.2, bkz. o dosyanın belge notu).
//!
//! **Kapsam (v0.1: aarch64 + x86-64, Faz R.2):** bu katman TEK BAŞINA
//! "eşzamanlı çalıştırma" sağlamaz — yalnızca "iki bağlam arasında elle
//! geçiş" ilkelini sağlar. Zamanlanma (hangi fiber'ın ne zaman çalışacağı),
//! `Task`/`Channel` semantiği ve deadlock tespiti `scheduler.zig`dedir.
//!
//! **Faz R.2 mimari notu — `Context`in mimariye göre KÖKTEN FARKLI şekli:**
//! aarch64'te callee-saved (çağrı-korumalı) yazmaçlar (x19-x28, fp, lr,
//! d8-d15) `Context`in DÜZ alanlarında SAKLANIR (bkz. `swap_aarch64.S`).
//! x86-64'te İSE SysV ABI'nin callee-saved yazmaçları (rbx, rbp, r12-r15)
//! GELENEKSEL OLARAK yığın üzerinden `push`/`pop` edilir (bkz. `swap_x86_64.
//! S`nin belge notu) — `Context` bu yüzden yalnızca TEK bir alan (`sp`)
//! taşır, kaydedilen yazmaçların KENDİSİ fiber'ın KENDİ yığınının İÇİNDE
//! yaşar. Bu, `Fiber.createWithStack`ın İLK (hiç resume edilmemiş) bağlamı
//! HAZIRLAMA şeklini de DOĞRUDAN etkiler (bkz. o fonksiyonun belge notu) —
//! aarch64'te alanlar DOĞRUDAN atanır, x86-64'te İSE fiber'ın KENDİ
//! yığınına `nox_swap_context`in BEKLEDİĞİ SAHTE bir "önceden push edilmiş"
//! çerçeve ELLE YAZILIR.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64) {
        @compileError("runtime/async_rt şu an yalnızca aarch64/x86-64 için uygulandı (bkz. nox-teknik-spesifikasyon.md §3.21/Faz R.2, v0.1 sınırlaması)");
    }
}

pub const Context = switch (builtin.cpu.arch) {
    // `swap_aarch64.S`teki alan ofsetleriyle BİRE BİR eşleşmelidir — sıra
    // ya da alan eklemek/çıkarmak montaj dosyasını da güncellemeyi gerektirir.
    .aarch64 => extern struct {
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
    },
    // Bkz. `swap_x86_64.S`nin belge notu — callee-saved yazmaçlar yığında
    // yaşadığından tek alan yeterlidir.
    .x86_64 => extern struct {
        sp: usize = 0,
    },
    else => @compileError("runtime/async_rt şu an yalnızca aarch64/x86-64 için uygulandı (bkz. nox-teknik-spesifikasyon.md §3.21/Faz R.2, v0.1 sınırlaması)"),
};

extern fn nox_swap_context(old: *Context, new: *Context) void;

pub const STACK_SIZE: usize = 256 * 1024;
pub const STACK_ALIGN: usize = 16;

/// Faz MN.8, Bulgu C — GÜVENLİK AĞI: fiber yığınları ARTIK düz `std.mem.
/// Allocator.alignedAlloc` YERİNE `mmap`+`mprotect` (POSIX) / `VirtualAlloc`+
/// `VirtualProtect` (Windows) İLE, KULLANILABİLİR `STACK_SIZE` bölgesinin
/// HEMEN ALTINDA (yığın AŞAĞI doğru büyüdüğünden) 1 sayfalık ERİŞİLEMEZ bir
/// "koruma sayfası" (guard page) İLE tahsis edilir. Bir yığın taşması ARTIK
/// SESSİZCE bitişik belleği bozmak YERİNE BELİRLİ bir SIGSEGV/erişim-ihlaline
/// dönüşür — GERÇEK bir güvenlik/doğruluk kazancı, `STACK_SIZE`in KENDİSİ
/// BU FAZDA DEĞİŞMEZ (256 KiB olarak KALIR; küçültme AYRI, ÖLÇÜME-DAYALI
/// bir gelecek fazdır). `Scheduler.acquireStack`/`releaseStack`nin havuz
/// mantığı (`stack_pool`) DEĞİŞMEZ — bir yığın HAVUZDAN GERİ KAZANILDIĞINDA
/// koruma sayfası ZATEN YERİNDE KALIR (yeniden mmap/mprotect GEREKMEZ,
/// SADECE `acquireStack`nin havuz-BOŞ dalı VE `releaseStack`/`deinit`nin
/// KENDİSİ, `Scheduler`'in KENDİ `allocator`i YERİNE bu fonksiyonları
/// çağıracak şekilde güncellenir).
fn guardPageSize() usize {
    return std.heap.pageSize();
}

const WinVirtual = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(.c) ?*anyopaque;
    extern "kernel32" fn VirtualProtect(lpAddress: *anyopaque, dwSize: usize, flNewProtect: u32, lpflOldProtect: *u32) callconv(.c) i32;
    extern "kernel32" fn VirtualFree(lpAddress: *anyopaque, dwSize: usize, dwFreeType: u32) callconv(.c) i32;
} else struct {};

const WIN_MEM_COMMIT: u32 = 0x1000;
const WIN_MEM_RESERVE: u32 = 0x2000;
const WIN_MEM_RELEASE: u32 = 0x8000;
const WIN_PAGE_READWRITE: u32 = 0x04;
const WIN_PAGE_NOACCESS: u32 = 0x01;

fn allocGuardedStackWindows() ![]align(STACK_ALIGN) u8 {
    const page = guardPageSize();
    const total = page + STACK_SIZE;
    const base = WinVirtual.VirtualAlloc(null, total, WIN_MEM_COMMIT | WIN_MEM_RESERVE, WIN_PAGE_READWRITE) orelse return error.VirtualAllocFailed;
    var old_protect: u32 = 0;
    if (WinVirtual.VirtualProtect(base, page, WIN_PAGE_NOACCESS, &old_protect) == 0) {
        _ = WinVirtual.VirtualFree(base, 0, WIN_MEM_RELEASE);
        return error.VirtualProtectFailed;
    }
    const usable_addr = @intFromPtr(base) + page;
    const usable_ptr: [*]align(STACK_ALIGN) u8 = @ptrFromInt(usable_addr);
    return usable_ptr[0..STACK_SIZE];
}

fn freeGuardedStackWindows(stack: []align(STACK_ALIGN) u8) void {
    const page = guardPageSize();
    const base_addr = @intFromPtr(stack.ptr) - page;
    const base: *anyopaque = @ptrFromInt(base_addr);
    _ = WinVirtual.VirtualFree(base, 0, WIN_MEM_RELEASE);
}

fn allocGuardedStackPosix() ![]align(STACK_ALIGN) u8 {
    const page = guardPageSize();
    const total = page + STACK_SIZE;
    const region = try std.posix.mmap(
        null,
        total,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer std.posix.munmap(region);
    // Koruma sayfası — KULLANILABİLİR bölgenin ALTINDA (stack AŞAĞI büyür).
    if (std.c.mprotect(@ptrCast(region.ptr), page, .{}) != 0) {
        return error.MprotectFailed;
    }
    const usable_addr = @intFromPtr(region.ptr) + page;
    const usable_ptr: [*]align(STACK_ALIGN) u8 = @ptrFromInt(usable_addr);
    return usable_ptr[0..STACK_SIZE];
}

fn freeGuardedStackPosix(stack: []align(STACK_ALIGN) u8) void {
    const page = guardPageSize();
    const base_addr = @intFromPtr(stack.ptr) - page;
    const base_ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(base_addr);
    std.posix.munmap(base_ptr[0 .. page + STACK_SIZE]);
}

pub fn allocGuardedStack() ![]align(STACK_ALIGN) u8 {
    if (builtin.os.tag == .windows) return allocGuardedStackWindows();
    return allocGuardedStackPosix();
}

pub fn freeGuardedStack(stack: []align(STACK_ALIGN) u8) void {
    if (builtin.os.tag == .windows) {
        freeGuardedStackWindows(stack);
        return;
    }
    freeGuardedStackPosix(stack);
}

// GG.23 (bkz. plan dosyası "fiber-stack sertleştirmesi", Madde 4): fiber
// yığınlarının GERÇEK yüksek-su-işaretini (high-water-mark) ölçen KALICI,
// SIFIR-varsayılan-maliyetli bir "stack-painting" aracı — `NOX_STRESS_
// ROUNDS`/`NOX_SOAK_SECONDS`nin AYNI "env-değişkeniyle KAPILI, VARSAYILAN
// SIFIR maliyet" deseni (bkz. `worker_pool.zig`nin `stressRoundsFromEnv`ı),
// `fiber_ever_active`/`pool_ever_active`nin AYNI "bir kez çözülüp atomik'e
// önbelleğe alınan bayrak" deseni (bkz. `asap.zig`). ARAŞTIRMA turunun
// GEÇİCİ/worktree'ye özel enstrümantasyonunun KALICI sürümü — bu turun
// KENDİSİ bir STACK_SIZE kararı ALDIĞINDAN VE gelecekte YENİ özyinelemeli
// runtime kodu eklenebileceğinden, bu KÜÇÜK aracı KALICI TUTMAK gelecekteki
// benzer araştırmaları SIFIRDAN İNŞA ETMEKTEN daha İYİdir.
//
// Teknik: `NOX_STACK_PAINT` AYARLIYSA, bir yığın havuzdan/tazeden
// EDİNİLDİĞİNDE (`Scheduler.acquireStack`) KULLANILABİLİR TÜM bölge
// imzalı bir 8-baytlık desenle (`0xDEADBEEFCAFEBABE`) BOYANIR; yığın
// GERİ VERİLDİĞİNDE (`Scheduler.releaseStack`) GUARD SAYFASINA en yakın
// (DÜŞÜK adresli, yığın AŞAĞI büyüdüğünden EN DERİN kullanım noktası)
// UÇTAN taranıp desenin İLK bozulduğu nokta bulunur — `STACK_SIZE - o
// nokta` GERÇEK yüksek-su-işaretidir. Süreç-çapında bir atomik MAX'a
// katkıda bulunur, `nox_runtime_deinit` (bkz. `asap.zig`) BUNU stderr'e
// `NOX_STACK_HWM_BYTES=<n>` OLARAK (kolay `grep`lenebilir TEK bir satır)
// yazar.
const STACK_PAINT_MAGIC: u64 = 0xDEADBEEFCAFEBABE;

var g_stack_paint_resolved = std.atomic.Value(bool).init(false);
var g_stack_paint_enabled = std.atomic.Value(bool).init(false);
var g_stack_hwm_max = std.atomic.Value(usize).init(0);

/// Süreç-genelinde BİR KEZ `NOX_STACK_PAINT` env-değişkenini okuyup
/// atomik bir bayrağa önbelleğe alır — AYARLANMAMIŞSA (varsayılan,
/// GERÇEK `noxc` derlemelerinin/testlerin EZİCİ ÇOĞUNLUĞU) `acquireStack`/
/// `releaseStack`in her çağrısında SADECE İKİ ATOMİK OKUMA maliyeti
/// (paint/measure gövdelerinin KENDİSİ HİÇ ÇALIŞMAZ). Birden fazla iş
/// parçacığının AYNI ANDA çözmesi ZARARSIZDIR (env-değişkeni SÜREÇ BOYUNCA
/// SABİTTİR, HER iş parçacığı AYNI değeri hesaplar — `cycle_detector.zig`nin
/// `resolveSymbol`ıyla AYNI "idempotent redundant-write" gerekçesi).
fn stackPaintEnabled() bool {
    if (!g_stack_paint_resolved.load(.monotonic)) {
        const enabled = std.c.getenv("NOX_STACK_PAINT") != null;
        g_stack_paint_enabled.store(enabled, .monotonic);
        g_stack_paint_resolved.store(true, .monotonic);
    }
    return g_stack_paint_enabled.load(.monotonic);
}

/// `stack`in KULLANILABİLİR TÜM bölgesini imzalı desenle boyar —
/// `Scheduler.acquireStack`nin HER dönüşünde (havuzdan geri kazanılan VE
/// taze tahsis edilen, İKİSİ de) çağrılır.
pub fn paintStackForResearch(stack: []align(STACK_ALIGN) u8) void {
    if (!stackPaintEnabled()) return;
    const n_words = stack.len / @sizeOf(u64);
    const words: [*]u64 = @ptrCast(@alignCast(stack.ptr));
    var i: usize = 0;
    while (i < n_words) : (i += 1) words[i] = STACK_PAINT_MAGIC;
}

/// `stack`i GUARD SAYFASINA en yakın (DÜŞÜK adresli) UÇTAN tarayıp
/// deseni bozan İLK 8-baytlık kelimeyi bulur — bu, BU fiber-kullanımının
/// yüksek-su-işaretidir. Süreç-çapında atomik MAX'a katkıda bulunur.
/// `Scheduler.releaseStack`nin HER çağrısında (yığın havuza/genel
/// ayırıcıya GERİ VERİLMEDEN HEMEN ÖNCE) çağrılır.
pub fn measureStackHwmForResearch(stack: []align(STACK_ALIGN) u8) void {
    if (!stackPaintEnabled()) return;
    const n_words = stack.len / @sizeOf(u64);
    const words: [*]const u64 = @ptrCast(@alignCast(stack.ptr));
    var i: usize = 0;
    while (i < n_words) : (i += 1) {
        if (words[i] != STACK_PAINT_MAGIC) break;
    }
    const hwm = (n_words - i) * @sizeOf(u64);
    var cur = g_stack_hwm_max.load(.monotonic);
    while (hwm > cur) {
        cur = g_stack_hwm_max.cmpxchgWeak(cur, hwm, .monotonic, .monotonic) orelse break;
    }
}

/// Süreç-çapında ölçülen maksimumu stderr'e yazar — `nox_runtime_deinit`
/// (bkz. `asap.zig`) TARAFINDAN çağrılır. `NOX_STACK_PAINT` AYARLANMADIYSA
/// (varsayılan) HİÇBİR ŞEY YAZMAZ (SESSİZ, mevcut sızıntı-denetimi "boş
/// stderr" varsayımını BOZMAZ — bkz. `codegen_golden_test.zig`nin `expectGolden`ı).
pub fn printStackHwmMaxForResearch() void {
    if (!stackPaintEnabled()) return;
    std.debug.print("NOX_STACK_HWM_BYTES={d}\n", .{g_stack_hwm_max.load(.monotonic)});
}

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
    /// Faz MN.2: eskiden `RuntimeState.pending_exception`/`pending_
    /// exception_line`di (bkz. `runtime/errors/handle.zig`) — bir istisna
    /// `raise` EDİLDİĞİNDEN yakalanana/YENİDEN fırlatılana KADAR, ARADA
    /// hiçbir yield noktası GEÇMEDEN, SAF senkron QBE kontrol akışıyla
    /// (her çağrı sitesi `nox_exception_pending`i KONTROL EDER) yayılır
    /// — bu YÜZDEN Fiber'e taşımak GÜVENLİDİR (hash-tohumunun AKSİNE,
    /// bkz. `dict.zig`nin belge notu — burada AYNI OS iş parçacığında
    /// farklı iki fiber'ın AYNI bekleyen istisnayı GÖRMESİ gerekmez,
    /// ÇÜNKÜ bir istisna ASLA bir fiber'ın kendi çalışma penceresini
    /// AŞAN bir ömre sahip DEĞİLDİR). `RuntimeState`te BIRAKILMIŞ olması
    /// (`pending_exception`, önceki tasarım) MN.3b/MN.4'te (`RuntimeState`
    /// BİRDEN FAZLA worker OS iş parçacığı ARASINDA PAYLAŞILDIĞINDA) GERÇEK
    /// bir yarış durumu (İKİ worker'ın AYNI ANDA `raise` etmesi) OLURDU —
    /// bu YÜZDEN buraya taşınması ZORUNLUYDU (hash-tohumunun AKSİNE, bir
    /// "BİLİNÇLİ taşınmadı" durumu DEĞİL).
    pending_exception: ?*anyopaque = null,
    pending_exception_line: i64 = 0,
    /// Faz OO.2 (bkz. nox-teknik-spesifikasyon.md §3.83, `TaskLocal[T]`):
    /// bu fiber'a ÖZGÜ, `TaskLocal` tutamacı işaretçisiyle ANAHTARLANMIŞ
    /// depolama — `runtime/async_rt/task_local.zig`nin `nox_tasklocal_
    /// get/set/clear`i BU haritayı okur/yazar (`bridge.zig`nin `currentFiber()`
    /// erişimcisi ÜZERİNDEN). Fiber yok edilirken (`destroy`/
    /// `destroyKeepStack`) TAMAMEN boşaltılır — bkz. o fonksiyonların
    /// belge notu (leftover değerlerin `release_kind`e göre serbest
    /// bırakılması `task_local.zig`nin `drainTaskLocals`inde yapılır).
    task_locals: std.AutoHashMapUnmanaged(*anyopaque, ?*anyopaque) = .empty,

    /// Faz MN.2 (bkz. proje planı "LLVM-only atomic ARC + M:N zamanlayıcı"):
    /// eskiden `threadlocal var` OLAN, ama GERÇEKTEN mutasyona uğrayan
    /// (idempotent önbellek DEĞİL) runtime-içi durum — `nox.random`
    /// (`prng`/`prng_seeded`), `nox.path`/`nox.fs`in "son işlem başarılı
    /// mıydı" bayrakları (`path_last_ok`/`fs_last_ok`), `nox.fs.size`/
    /// `mtime_ms`in ÖNBELLEĞİ (`fs_last_size`/`fs_last_mtime_ms`),
    /// `nox.io.read_line`in satır-arası tampon fazlası (`stdin_leftover`),
    /// VE `nox.json`nin "son ayrıştırma başarılı mıydı" bayrağı
    /// (`json_last_op_ok`). Bir `threadlocal`, work-stealing altında
    /// fiber TAŞINDIĞINDA (bkz. `bridge.currentFiber()`) YANLIŞ OS iş
    /// parçacığının belleğine sessizce çözülürdü — bu alanlar fiber'IN
    /// KENDİSİYLE TAŞINARAK bu tehlikeyi ORTADAN KALDIRIR. İlgili
    /// `runtime/stdlib_shims/*.zig`, fiber DIŞINDA (senkron üst-düzey
    /// kod, `bridge.currentFiber() == null`) ÇAĞRILDIĞINDA KENDİ dosya-
    /// yerel `threadlocal` YEDEĞİNE (BUGÜNKÜ davranışla BİREBİR aynı)
    /// DÜŞER — bkz. o dosyaların KENDİ "fallback" belge notları.
    ///
    /// **BİLİNÇLİ olarak BURAYA TAŞINMAYAN**: `dict.zig`nin hash-tohumu
    /// (`g_hash_seed`/`g_hash_seed_init`) — bkz. `dict.zig`nin KENDİ
    /// belge notu, "neden Fiber'e taşınmadı" (fiber-affine yapmak, AYNI
    /// dict'e AYNI OS iş parçacığında farklı iki fiber'ın dokunması
    /// durumunda insert/lookup arasında SESSİZ bir hash-tutarsızlığı
    /// hatası YARATIRDI — `RuntimeState`e taşınması GEREKİR, ki bu da
    /// `nox_dict_contains`ın ABI'sini değiştirmeyi gerektiren, MN.2'nin
    /// kapsamı DIŞINDA AYRI bir iş).
    prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    prng_seeded: bool = false,
    path_last_ok: bool = true,
    fs_last_ok: bool = true,
    fs_last_size: i64 = 0,
    fs_last_mtime_ms: i64 = 0,
    stdin_leftover: std.ArrayListUnmanaged(u8) = .empty,
    json_last_op_ok: bool = true,

    pub fn create(allocator: std.mem.Allocator, entry: FiberFn, arg: *anyopaque) !*Fiber {
        const stack = try allocGuardedStack();
        errdefer freeGuardedStack(stack);
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
        // baytlık hizalamaya (AAPCS64/SysV ABI'nin gerektirdiği) yuvarlanmış.
        const stack_top = @intFromPtr(self.stack.ptr) + self.stack.len;
        const stack_top_aligned = stack_top & ~@as(usize, STACK_ALIGN - 1);
        switch (builtin.cpu.arch) {
            .aarch64 => {
                self.ctx.sp = stack_top_aligned;
                self.ctx.lr = @intFromPtr(&trampoline);
                // `self` işaretçisini x19'a (çağrı-korumalı, bu yüzden ilk
                // `nox_swap_context` onu OLDUĞU GİBİ `trampoline`a taşır)
                // "kaçak" olarak yerleştiriyoruz — bkz. `trampoline`ın x19'u
                // okuması.
                self.ctx.x19 = @intFromPtr(self);
            },
            .x86_64 => {
                if (builtin.os.tag == .windows) {
                    // Faz LL.3 (bkz. nox-teknik-spesifikasyon.md §3.71):
                    // Win64 ABI'nin `swap_x86_64.S`nin Windows dalının
                    // BEKLEDİĞİ SAHTE çerçeve — 160 bayt xmm6-15 (SIFIRLANMIŞ,
                    // İLK açılışta ANLAMLI bir önceki değer YOK) + 8 GPR (r15,
                    // r14, r13, r12, rsi, rdi, rbx, rbp — BU SIRAYLA) + dönüş
                    // adresi (232 bayt). `self`i rbx'e ("kaçak" olarak — SysV
                    // dalıyla AYNI hile, `trampoline` platform-bağımsız OLARAK
                    // rbx okur) yerleştiriyoruz.
                    //
                    // **`- 240`, `- 232` DEĞİL (GERÇEK bir hata, GERÇEK Windows
                    // CI'de segfault OLARAK yakalandı):** SysV dalının KENDİ
                    // `frame_base = stack_top_aligned - 64`sı (56 baytlık
                    // çerçeve İçin bile) KASITLI 8 bayt FAZLA ayırır — `ret`
                    // SONRASI `trampoline`ın gördüğü `rsp`nin `stack_top_
                    // aligned - 8` (8-mod-16, NORMAL bir `call`/`ret` SONRASI
                    // BEKLENEN hizalama) OLMASI İçin. `- 232` kullanılsaydı
                    // `ret` SONRASI rsp TAM `stack_top_aligned` (16-hizalı,
                    // YANLIŞ) olurdu — `- 240` (232 + AYNI 8 baytlık boşluk)
                    // `ret` SONRASI rsp'yi `stack_top_aligned - 8`e getirir.
                    const frame_base = stack_top_aligned - 240;
                    const xmm_area: *[160]u8 = @ptrFromInt(frame_base);
                    @memset(xmm_area, 0);
                    const gpr: *[8]usize = @ptrFromInt(frame_base + 160);
                    gpr[0] = 0; // r15 (kullanılmıyor)
                    gpr[1] = 0; // r14 (kullanılmıyor)
                    gpr[2] = 0; // r13 (kullanılmıyor)
                    gpr[3] = 0; // r12 (kullanılmıyor)
                    gpr[4] = 0; // rsi (kullanılmıyor)
                    gpr[5] = 0; // rdi (kullanılmıyor)
                    gpr[6] = @intFromPtr(self); // rbx — "kaçak" self işaretçisi
                    gpr[7] = 0; // rbp (kullanılmıyor)
                    const ret_slot: *usize = @ptrFromInt(frame_base + 224);
                    ret_slot.* = @intFromPtr(&trampoline);
                    self.ctx.sp = frame_base;
                } else {
                    // Faz R.2: `swap_x86_64.S`nin SysV dalının `pop` dizisinin
                    // (r15, r14, r13, r12, rbx, rbp — BU SIRAYLA) ve ARDINDAN
                    // `ret`in BEKLEDİĞİ SAHTE çerçeveyi fiber'ın KENDİ yığınına
                    // ELLE yazıyoruz (bkz. o dosyanın belge notu, "sahte ilk
                    // çerçeve hizalaması"). `self`i rbx'e ("kaçak" olarak —
                    // çağrı-korumalı, `trampoline` OKUYACAK) yerleştiriyoruz.
                    const frame_base = stack_top_aligned - 64;
                    const frame: *[7]usize = @ptrFromInt(frame_base);
                    frame[0] = 0; // r15 (kullanılmıyor)
                    frame[1] = 0; // r14 (kullanılmıyor)
                    frame[2] = 0; // r13 (kullanılmıyor)
                    frame[3] = 0; // r12 (kullanılmıyor)
                    frame[4] = @intFromPtr(self); // rbx — "kaçak" self işaretçisi
                    frame[5] = 0; // rbp (kullanılmıyor)
                    frame[6] = @intFromPtr(&trampoline); // dönüş adresi (ret hedefi)
                    self.ctx.sp = frame_base;
                }
            },
            else => comptime unreachable,
        }
        return self;
    }

    pub fn destroy(self: *Fiber) void {
        self.task_locals.deinit(self.allocator);
        self.stdin_leftover.deinit(self.allocator);
        freeGuardedStack(self.stack);
        self.allocator.destroy(self);
    }

    /// `destroy` ile AYNI, ama yığını SERBEST BIRAKMAZ — çağırana (bkz.
    /// `Scheduler.releaseStack`) geri döner, böylece bir sonraki `spawn`
    /// tarafından yeniden kullanılabilir. Yalnızca `Fiber` struct'ının
    /// kendisi (küçük, sabit boyutlu) serbest bırakılır.
    ///
    /// **`task_locals`nin BİLİNÇLİ v1 sınırlaması:** BURADA (VE `destroy`da)
    /// SADECE haritanın KENDİ Zig-İÇİ ayırımı boşaltılır — SAKLANAN Nox
    /// DEĞERLERİ serbest BIRAKILMAZ. `scheduler.zig`/`fiber.zig` KASITLI
    /// OLARAK `RuntimeState`ten BAĞIMSIZDIR (bkz. modül üstü not, "İlke
    /// #6") — bu YÜZDEN burada `nox_class_release_dispatch` GİBİ bir
    /// çağrı YAPILAMAZ (`rt` yoktur). Bu, iyi-davranışlı kodun (nyx'in
    /// İSTEK-sonu middleware zincirinin ZATEN doğal olarak yapacağı gibi)
    /// bir fiber bitmeden ÖNCE KENDİ `TaskLocal`larını `clear()`
    /// ETMESİNİ gerektiren, BELGELENMİŞ bir v1 sınırlamasıdır (aksi
    /// halde o TEK değerin referansı sızar — TÜM programın çökmesine
    /// YOL AÇMAZ, yalnızca o değerin serbest bırakılmasını GECİKTİRİR/
    /// engeller).
    pub fn destroyKeepStack(self: *Fiber) []align(STACK_ALIGN) u8 {
        self.task_locals.deinit(self.allocator);
        self.stdin_leftover.deinit(self.allocator);
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

/// Bir fiber İLK KEZ resume edildiğinde atlanan nokta. aarch64'te x19,
/// x86-64'te rbx `Fiber.create`/`createWithStack` tarafından yerleştirilen
/// `self` işaretçisini taşır (bkz. yukarısı — İKİ mimaride de callee-saved
/// bir yazmaç, "kaçak" taşıma İÇİN seçildi).
fn trampoline() callconv(.c) noreturn {
    const self_addr = switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (""
            : [ret] "={x19}" (-> usize),
        ),
        .x86_64 => asm volatile (""
            : [ret] "={rbx}" (-> usize),
        ),
        else => comptime unreachable,
    };
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

test "Faz MN.8, Bulgu C: yığın taşması guard page İLE BELİRLİ bir çökmeye dönüşür (sessizce bozulma DEĞİL)" {
    // BU test KENDİ süreci İçİNDE bir yığın taşması ÜRETEMEZ (test binary'sinin
    // TAMAMINI çökertirdi) — bunun yerine `guard_overflow_repro.zig`yi AYRI
    // bir süreç OLARAK derleyip ÇALIŞTIRIR VE o sürecin TEMİZ (çıkış kodu 0)
    // BİTMEDİĞİNİ (guard page'e GERÇEKTEN ÇARPTIĞINI) doğrular.
    if (builtin.os.tag == .windows) return error.SkipZigTest; // TODO: Windows repro ayrı ele alınacak
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const swap_o_path = switch (builtin.cpu.arch) {
        .aarch64 => "runtime/async_rt/swap_aarch64.o",
        .x86_64 => "runtime/async_rt/swap_x86_64.o",
        else => return error.SkipZigTest,
    };
    // v1.35.0 (bkz. plan dosyası "Bilinen iki test flake'ini kalıcı olarak
    // düzeltme"): BU test (`fiber.zig`nin KENDİSİ transitively import
    // edildiğinden) `scheduler_test`/`channel_test`/`io_test`/`noxrt_test`de
    // de AYRI AYRI çalışır — `zig build test` bu ikilileri PARALEL
    // çalıştırdığından, SABİT bir `/tmp` yolu (`"/tmp/nox_guard_overflow_
    // repro_bin"`) BİRDEN FAZLA sürecin AYNI ANDA AYNI dosyaya `zig build-exe`
    // ÇIKTISI yazıp AYNI dosyayı ÇALIŞTIRMAYA çalışmasına (GERÇEK bir TOCTOU
    // yarışı — `processSpawnPosix`nin ARALIKLI başarısızlıklarının KÖK
    // NEDENİ, GERÇEKTEN GÖZLEMLENDİ) yol AÇIYORDU. `tests/cli/install_test.
    // zig`/`tests/compat/http_serve_golden_test.zig`nin ZATEN kurulu
    // `std.testing.tmpDir` konvansiyonuna GEÇİLDİ — HER çalıştırma KENDİ
    // İZOLE dizinini alır, çakışma YAPISAL olarak İMKANSIZ hale gelir.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/nox_guard_overflow_repro_bin", .{dir_path});
    defer allocator.free(bin_path);
    const femit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{bin_path});
    defer allocator.free(femit_arg);

    {
        const build_result = try std.process.run(allocator, io, .{
            .argv = &.{ "zig", "build-exe", "runtime/async_rt/guard_overflow_repro.zig", swap_o_path, "-lc", femit_arg },
        });
        defer allocator.free(build_result.stdout);
        defer allocator.free(build_result.stderr);
        if (build_result.term != .exited or build_result.term.exited != 0) {
            std.debug.print("guard_overflow_repro derlenemedi: {s}\n", .{build_result.stderr});
            return error.ReproBuildFailed;
        }
    }

    const run_result = try std.process.run(allocator, io, .{ .argv = &.{bin_path} });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);
    // Temiz (0) çıkış BEKLENMEZ — guard page GERÇEKTEN ÇARPILDIYSA süreç
    // anormal SONLANIR (sinyal/panik-abort). `.exited` DAHİ olsa sıfır
    // DEĞİLSE (panik-çıkışı) KABUL edilir.
    switch (run_result.term) {
        .exited => |code| try std.testing.expect(code != 0),
        .signal, .stopped, .unknown => {},
    }
}
