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

const std = @import("std");

extern "asyncify" fn start_unwind(data: usize) void;
extern "asyncify" fn stop_unwind() void;
extern "asyncify" fn start_rewind(data: usize) void;
extern "asyncify" fn stop_rewind() void;

inline fn getSp() usize {
    return asm volatile ("global.get __stack_pointer\nlocal.set %[r]"
        : [r] "=r" (-> usize),
    );
}

inline fn setSp(v: usize) void {
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

var g_phase: Phase = .normal;
var g_cur_root: *Root = undefined;
var g_next: *Context = undefined;
var free_bufs: [64]usize = undefined;
var free_count: usize = 0;

fn acquireBuf() usize {
    if (free_count > 0) {
        free_count -= 1;
        return free_bufs[free_count];
    }
    const mem = std.heap.wasm_allocator.alignedAlloc(u8, .@"16", BUF_SIZE) catch @panic("asyncify: arabellek ayrılamadı");
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
    std.heap.wasm_allocator.free(sl);
}

/// Bir fiber yok edilirken, askıdayken tuttuğu arabelleği geri verir.
pub fn discard(ctx: *Context) void {
    if (ctx.buf != 0) {
        releaseBuf(ctx.buf);
        ctx.buf = 0;
    }
}

/// `old` akışını kaydedip `new` akışına geçilmesini ister. Çağıran, sürücü `new`i çalıştırıp sonunda `old`u yeniden sardığında buradan döner.
pub noinline fn swap(old: *Context, new: *Context) void {
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
    old.sp = getSp();
    old.buf = acquireBuf();
    const hdr: [*]usize = @ptrFromInt(old.buf);
    hdr[0] = old.buf + 2 * @sizeOf(usize); // geçerli konum
    hdr[1] = old.buf + BUF_SIZE; // son
    g_next = new;
    g_phase = .unwinding;
    start_unwind(old.buf);
}

var g_main_fn: *const fn (i32, u64) callconv(.c) i32 = undefined;
var g_argc: i32 = 0;
var g_argv: u64 = 0;
var g_rc: i32 = 0;

fn mainRun(_: *Root) void {
    g_rc = g_main_fn(g_argc, g_argv);
}

var main_root: Root = .{ .run = mainRun };

/// Programın giriş sürücüsü (`asyncify-removelist` ile dönüşümden muaf tutulur: adında `nox_asyncify_run_main` geçer).
/// `main_fn` ana akışın kökü; fiberler `swap` ile bu döngüye yığın açarak döner.
pub noinline fn nox_asyncify_run_main(main_fn: *const fn (i32, u64) callconv(.c) i32, argc: i32, argv: u64) i32 {
    g_main_fn = main_fn;
    g_argc = argc;
    g_argv = argv;
    const entry_sp = getSp();
    var root: *Root = &main_root;
    while (true) {
        g_cur_root = root;
        root.run(root);
        if (g_phase == .unwinding) {
            stop_unwind();
            g_phase = .normal;
            const next = g_next;
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
        if (root == &main_root) {
            setSp(entry_sp);
            return g_rc;
        }
        @panic("asyncify: bir fiber kökü normal döndü (trampoline `swap` ile bitmelidir)");
    }
}
