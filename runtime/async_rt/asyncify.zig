//! Faz 10 (WASM, ADR-014): wasm32'de GERÇEK fiber (yığın değiştirme) — Binaryen `--asyncify` dönüşümü üzerinden. WebAssembly'de yığın değiştirme yoktur;
//! Asyncify, derlemeden sonra `wasm-opt --asyncify` ile modülün çağrı zincirini "çöz/sar" (unwind/rewind) edebilir hâle getirir: bir fiber askıya alınırken
//! çağrı çerçevelerinin yerelleri bir arabelleğe kaydedilir ve yığın modülün dışına (sürücüye) kadar açılır; geri dönerken aynı çerçeveler arabellekten yeniden kurulur.
//!
//! Bu dosya `async_rt/fiber.zig`nin yerel (`nox_swap_context`) değiştirme düzeneğinin yerine geçer (yalnızca wasm32). Parçalar:
//!  - `Context`: askıya alınmış bir akışın kaydı (gölge yığın işaretçisi `sp`, Asyncify arabelleği `buf`, hangi kökün yeniden çağrılacağı `root`).
//!  - `swap(old, new)`: `old` akışını kaydedip yığını açar; bir sonraki sürücü turunda `new` akışı çalışır.
//!  - `runMain`: EN DIŞ sürücü döngüsü. Asyncify dönüşümünden MUAFTIR (`asyncify-removelist`): `root.run`u çağırır; yığın açılmışsa (unwinding) sıradaki akışı seçer
//!    ve onu ya yeni başlatır ya da `start_rewind` ile sarar. Tüm kökler bu tek sürücü çerçevesinden çağrılır.
//!  - Gölge yığın (`__stack_pointer`, LLVM'in `alloca`ları) akış başına ayrıdır; `swap`/sürücü onu kaydeder ve geri yükler.
//!
//! Asyncify'ın `asyncify.start_unwind/stop_unwind/start_rewind/stop_rewind` import'ları `wasm-opt` tarafından modülün İÇİNDE tanımlanır; ortaya host
//! gerektiren bir import çıkmaz. Durum (`g_state`) burada ayrıca izlenir, çünkü Binaryen `get_state`i import olarak sağlamaz.

//! **Host askıya alma (v2.0.149, spec §3.351).** Bir fiber değil TÜM program, host'a (JS olay döngüsüne) geri dönmek üzere askıya alınabilir: `hostSuspend` ana
//! akışı (zamanlayıcı döngüsü dahil) `swap` ile aynı düzenekle bir arabelleğe kaydedip yığını sürücüye kadar açar ve sürücü `nox_asyncify_run`dan HOST'A DÖNER
//! (`isHostSuspended()`). Host işini bitirince `nox_asyncify_run_resume` aynı akışı arabellekten yeniden sarar. `fetch` tabanlı HTTP istemcisi bunun üstüne kurulur.

const std = @import("std");
const builtin = @import("builtin");

extern "asyncify" fn start_unwind(data: usize) void;
extern "asyncify" fn stop_unwind() void;
extern "asyncify" fn start_rewind(data: usize) void;
extern "asyncify" fn stop_rewind() void;

pub inline fn getSp() usize {
    return asm volatile ("global.get __stack_pointer\nlocal.set %[r]"
        : [r] "=r" (-> usize),
    );
}

pub inline fn setSp(v: usize) void {
    asm volatile ("local.get %[v]\nglobal.set __stack_pointer"
        :
        : [v] "r" (v),
    );
}

/// Bir akışın (ana akış ya da fiber) sürücüden çağrılan KÖKÜ: sarılırken aynı kök yeniden çağrılır ve Asyncify çerçeveleri yeniden kurar.
pub const Root = struct {
    run: *const fn (*Root) void,
};

pub const Context = struct {
    /// Askıya alınırken kaydedilen (ya da yeni fiber için başlangıç) gölge yığın işaretçisi.
    sp: usize = 0,
    /// Asyncify veri arabelleği (askıdayken dolu, sarıldıktan sonra havuza döner); 0 = yok.
    buf: usize = 0,
    root: ?*Root = null,
    /// Henüz hiç çalışmamış fiber: sürücü kökü SARMADAN, yeni gölge yığında çağırır.
    fresh: bool = false,
};

/// Askıdaki bir akışın yerelleri için arabellek boyutu. Asyncify arabelleği taşarsa modül `unreachable` ile durur; derin (özyinelemeli) çağrı zincirleri için cömert.
pub const BUF_SIZE: usize = 256 * 1024;

const Phase = enum { normal, unwinding, rewinding };

threadlocal var g_phase: Phase = .normal;
/// Host askıya alma: `hostSuspend` çağrısında kaydedilen ana akış, işaretçi kimliği olarak kullanılan `host_marker` ve sürücünün ilk girişteki gölge yığın işaretçisi.
threadlocal var g_host_ctx: Context = .{};
threadlocal var g_host_suspended: bool = false;
threadlocal var g_entry_sp: usize = 0;
var host_marker: Context = .{};
threadlocal var g_cur_root: *Root = undefined;
threadlocal var g_next: *Context = undefined;
threadlocal var free_bufs: [64]usize = undefined;
threadlocal var free_count: usize = 0;

fn acquireBuf() usize {
    if (free_count > 0) {
        free_count -= 1;
        return free_bufs[free_count];
    }
    const mem = std.heap.page_allocator.alignedAlloc(u8, .@"16", BUF_SIZE) catch @panic("asyncify: arabellek ayrılamadı");
    return @intFromPtr(mem.ptr);
}

fn releaseBuf(b: usize) void {
    if (free_count < free_bufs.len) {
        free_bufs[free_count] = b;
        free_count += 1;
        return;
    }
    const p: [*]align(16) u8 = @ptrFromInt(b);
    const sl: []align(16) u8 = p[0..BUF_SIZE];
    std.heap.page_allocator.free(sl);
}

/// Bir fiber yok edilirken, askıdayken tuttuğu arabelleği geri verir.
pub fn discard(ctx: *Context) void {
    if (ctx.buf != 0) {
        releaseBuf(ctx.buf);
        ctx.buf = 0;
    }
}

/// `old` akışını kaydedip `new` akışına geçilmesini ister. Çağıran, sürücü `new`i çalıştırıp sonunda `old`u yeniden sardığında buradan döner.
///
/// Gölge yığın işaretçisi ÇAĞIRANIN içinde (satır içi) okunur: sürücü yeniden sararken `swap` yeni bir çağrı olarak yeniden girilir ve kendi önsöz/epilogu
/// simetrik çalışır, bu yüzden sürücü işaretçiyi `swapImpl`in İÇİNDE okunan değere değil, ÇAĞIRANIN çağrı noktasında gördüğü değere kurmalıdır. Aksi halde her
/// askıya alma `swapImpl` çerçevesi kadar (ReleaseFast'te 32, ReleaseSafe'te 96 bayt) sızar ve 8 MiB'lık gölge yığın birkaç yüz bin `await` sonra taşar.
pub inline fn swap(old: *Context, new: *Context) void {
    swapImpl(old, new, getSp());
}

noinline fn swapImpl(old: *Context, new: *Context, caller_sp: usize) void {
    if (g_phase == .rewinding) {
        // `old` yeniden kuruldu: çağrı zinciri tamam, buradan normal akışa devam.
        stop_rewind();
        g_phase = .normal;
        if (old.buf != 0) {
            releaseBuf(old.buf);
            old.buf = 0;
        }
        return;
    }
    old.root = g_cur_root;
    old.sp = caller_sp;
    old.buf = acquireBuf();
    const hdr: [*]usize = @ptrFromInt(old.buf);
    hdr[0] = old.buf + 2 * @sizeOf(usize); // geçerli konum
    hdr[1] = old.buf + BUF_SIZE; // son
    g_next = new;
    g_phase = .unwinding;
    start_unwind(old.buf);
}

/// Program host'a dönmek üzere askıdaysa `true` (sürücü `nox_asyncify_run`dan döndü, ama program bitmedi): host işini yapıp `nox_asyncify_run_resume` çağırmalıdır.
pub fn isHostSuspended() bool {
    return g_host_suspended;
}

/// Çalışan akışı (ana akış; zamanlayıcı döngüsü dahil) host'a dönmek üzere askıya alır; `nox_asyncify_run_resume` ile devam edildiğinde buradan döner.
/// `swap` ile aynı gerekçeyle gölge yığın işaretçisi ÇAĞIRANIN içinde okunur.
pub inline fn hostSuspend() void {
    hostSuspendImpl(getSp());
}

noinline fn hostSuspendImpl(caller_sp: usize) void {
    if (g_phase == .rewinding) {
        stop_rewind();
        g_phase = .normal;
        if (g_host_ctx.buf != 0) {
            releaseBuf(g_host_ctx.buf);
            g_host_ctx.buf = 0;
        }
        return;
    }
    g_host_ctx.root = g_cur_root;
    g_host_ctx.sp = caller_sp;
    g_host_ctx.buf = acquireBuf();
    const hdr: [*]usize = @ptrFromInt(g_host_ctx.buf);
    hdr[0] = g_host_ctx.buf + 2 * @sizeOf(usize);
    hdr[1] = g_host_ctx.buf + BUF_SIZE;
    g_next = &host_marker;
    g_phase = .unwinding;
    start_unwind(g_host_ctx.buf);
}

/// **Host çağrıları için ayrılan gölge yığın bölgesi (v2.0.171).** Program `hostSuspend` ile askıdayken host, modülün dışa aktarımlarını (`nox_host_alloc`,
/// `nox_host_fetch_pending`, `nox_host_fetch_complete`, `nox_host_http_dispatch`, ...) çağırır; bunlar gölge yığın işaretçisi sürücünün giriş değerinde (yığın
/// TEPESİ) iken çalışır ve çerçevelerini tepeden aşağı doğru yazar. Askıdaki programın en dıştaki çerçeveleri (ana akışın `main`, zamanlayıcı döngüsü, sürücü
/// çağrı zinciri; `Buf`/`ArrayList` gibi adresi alınan yereller) tam o bölgede durur: host çağrısı bunları sessizce ezer, program sarılınca ezilmiş yereller
/// (ör. `ArrayList.capacity`) `free`ye bozuk boyut verir. Asyncify yalnızca WASM yerellerini kaydeder, gölge yığın BELLEĞİNİ kaydetmez. Bu yüzden program, tepeden
/// `HOST_RESERVE` bayt aşağıda çalışır; host çağrıları bu ayrılmış bölgeyi kullanır. (Optimizasyon kipine göre çerçeve boyutları değişir; ReleaseFast'te nox.postgres
/// sorgusunun çerçevesi ezilen bölgeye düşüyordu, ReleaseSafe'te düşmüyordu.) İş parçacıklı kipte askıya alma yoktur, bu yüzden ayrılmaz.
pub const HOST_RESERVE: usize = 64 * 1024;

/// Sürücü köküne verilen giriş: tek `usize` argümanlı, `i32` dönen işlev (ana akış için `main`, havuz işçisi için işçi gövdesi).
pub const EntryFn = *const fn (usize) callconv(.c) i32;

threadlocal var g_entry: EntryFn = undefined;
threadlocal var g_entry_arg: usize = 0;
threadlocal var g_rc: i32 = 0;

fn entryRun(_: *Root) void {
    g_rc = g_entry(g_entry_arg);
}

threadlocal var entry_root: Root = .{ .run = entryRun };

/// Bir iş parçacığının (ana ya da havuz işçisi) giriş sürücüsü: `entry(arg)`yi KÖK akış olarak çalıştırır. Fiber'lar `swap` ile bu döngüye yığın açarak döner.
/// `asyncify-removelist` ile dönüşümden muaf tutulur (adında `nox_asyncify_run` geçer). Her iş parçacığı kendi sürücü durumuna (threadlocal) sahiptir.
/// Program `hostSuspend` ile askıya alındıysa 0 döner ve `isHostSuspended()` doğrudur.
pub noinline fn nox_asyncify_run(entry: EntryFn, arg: usize) i32 {
    g_entry = entry;
    g_entry_arg = arg;
    g_entry_sp = getSp();
    if (comptime builtin.single_threaded) {
        // Program çerçeveleri yığın tepesinden HOST_RESERVE bayt aşağıda başlar (aşağıdaki açıklamaya bakınız).
        setSp(g_entry_sp - HOST_RESERVE);
    }
    return nox_asyncify_run_loop(&entry_root);
}

/// `hostSuspend` ile askıya alınan programı sürdürür (host işini bitirdikten sonra); program biterse dönüş kodunu, yeniden askıya alınırsa 0 döner (`isHostSuspended()`).
pub noinline fn nox_asyncify_run_resume() i32 {
    g_host_suspended = false;
    setSp(g_host_ctx.sp);
    start_rewind(g_host_ctx.buf);
    g_phase = .rewinding;
    return nox_asyncify_run_loop(g_host_ctx.root.?);
}

noinline fn nox_asyncify_run_loop(start_root: *Root) i32 {
    var root = start_root;
    while (true) {
        g_cur_root = root;
        root.run(root);
        if (g_phase == .unwinding) {
            stop_unwind();
            g_phase = .normal;
            const next = g_next;
            if (next == &host_marker) {
                // Tüm program host için askıda: yığın modülün dışına (JS'e) kadar boşalır.
                g_host_suspended = true;
                setSp(g_entry_sp);
                return 0;
            }
            root = next.root.?;
            setSp(next.sp);
            if (next.fresh) {
                next.fresh = false;
            } else {
                start_rewind(next.buf);
                g_phase = .rewinding;
            }
            continue;
        }
        if (root == &entry_root) {
            setSp(g_entry_sp);
            return g_rc;
        }
        @panic("asyncify: bir fiber kökü normal döndü (trampoline `swap` ile bitmelidir)");
    }
}
