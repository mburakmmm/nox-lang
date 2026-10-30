//! Faz 10 (WASM, ADR-015): iş parçacığı başlatma. Yerel hedeflerde `std.Thread`. wasm32'de (wasi-threads tarzı: `wasi::thread-spawn` import'u + `wasi_thread_start` dışa aktarımı)
//! Zig 0.16'nın `WasiThreadImpl`i KULLANILMAZ: gölge yığın işaretçisini ayrılan bölgenin ALT ucuna kurar (yığın aşağı büyüdüğünden yalnızca bir sayfa kullanılabilir, ötesi komşu
//! bloğu ezer) ve `std.Io.Threaded` futex'ine dayanır (tip hatası). Burada yığın bloğu (TLS + yığın) sıfırlanmış olarak ayrılır, işaretçi doğru uca kurulur ve gövde bu iş
//! parçacığının KENDİ Asyncify sürücüsü altında çalışır (her işçinin fiber'ları o işçiye ait `unwind/rewind` durumuyla döner).
//!
//! `detach` edilen iş parçacıklarının bloğu, iş parçacığı kendi yığınında çalışırken geri verilemez; bir hurda listesinde tutulur ve iş parçacığı `exited` olunca
//! sonraki `spawn`/`detach`te toplanır (liste sınırsızdır: bağlı liste, sabit boyutlu dizi değil).

const std = @import("std");
const builtin = @import("builtin");
const atomic64 = @import("atomic64.zig");

/// Yalnızca `+atomics` açık (iş parçacıklı) wasm kendi iş parçacığı uygulamasını kullanır; tek iş parçacıklı wasm ve yerel hedefler `std.Thread`.
const is_wasm = atomic64.wasm_threads;
const asyncify = if (builtin.cpu.arch.isWasm()) @import("asyncify.zig") else struct {};

/// wasm32: her iş parçacığının yığını (fiber'lar kendi yığınlarını kullanır; burada yalnızca sürücü + zamanlayıcı döngüsü yaşar).
const WASM_THREAD_STACK: usize = 1024 * 1024;

pub const Id = if (is_wasm) u32 else std.Thread.Id;

/// Geçerli iş parçacığının kimliği (ana iş parçacığı = 0).
pub fn currentId() Id {
    if (comptime is_wasm) return WasmThread.tls_id;
    return std.Thread.getCurrentId();
}

pub const Thread = if (is_wasm) WasmThread else std.Thread;

/// İşlemciyi bırakır. Yerelde/wasi'de `std.Thread.yield`; wasm32-freestanding'de (`sched_yield` yok) kısa bir bekleme ipucu.
pub fn yield() void {
    if (comptime is_wasm and builtin.os.tag == .freestanding) {
        std.atomic.spinLoopHint();
        return;
    }
    std.Thread.yield() catch {};
}

pub fn spawn(comptime function: anytype, args: anytype) SpawnError!Thread {
    if (comptime is_wasm) return WasmThread.spawn(function, args);
    return std.Thread.spawn(.{}, function, args);
}

pub const SpawnError = std.Thread.SpawnError;

const WasmThread = if (is_wasm) struct {
    pub threadlocal var tls_id: u32 = 0;

    const State = enum(u32) { running = 0, completed = 1, detached = 2 };

    const Instance = struct {
        /// DEĞİŞMEZ: `threadStartNaked` gölge yığın işaretçisini bu alanı (ofset 0) okuyarak kurar; başka bir alanın önüne geçmemeli.
        stack_top: usize,
        state: std.atomic.Value(u32) = .init(@intFromEnum(State.running)),
        /// İş parçacığının SON bellek yazısı (`threadStartNaked` kuyruğu, gövde döndükten sonra): 1 olunca iş parçacığı artık kendi yığınına/TLS'ine DOKUNMAZ,
        /// blok güvenle geri verilebilir. (`state == completed` bundan birkaç komut öncedir; Debug çerçeveleri hâlâ yığını okuyor olabilir.)
        exited: std.atomic.Value(u32) = .init(0),
        /// Argüman paketini (tür-silinmiş) serbest bırakır.
        free_pack: *const fn (usize) void,
        /// [TLS | yığın]; `__wasm_init_tls` bu bloğun başına, gölge yığın bloğun ÜST ucuna kurulur.
        block: []u8,
        tls_size: usize,
        entry: *const fn (usize) callconv(.c) i32,
        arg: usize,
        /// Hurda listesi (`zombies`) bağlantısı; yalnızca `zombie_lock` altında okunur/yazılır.
        next_zombie: ?*Instance = null,
    };

    inst: *Instance,

    /// WASI-threads ABI'si (`wasi::thread-spawn`) ya da freestanding için Nox host sözleşmesi (`nox_host::thread_spawn`, ADR-013/015).
    const is_freestanding_os = builtin.os.tag == .freestanding;
    const spawnImport = if (is_freestanding_os) struct {
        extern "nox_host" fn thread_spawn(arg: *Instance) i32;
    }.thread_spawn else struct {
        extern "wasi" fn @"thread-spawn"(arg: *Instance) i32;
    }.@"thread-spawn";
    const start_export_name = if (is_freestanding_os) "nox_host_thread_start" else "wasi_thread_start";
    extern fn __wasm_init_tls(memory: [*]u8) void;

    /// Bağlayıcının ürettiği değişmez wasm global'leri (TLS bölümünün boyutu ve hizası).
    inline fn tlsSize() usize {
        return asm volatile (
            \\.globaltype __tls_size, i32, immutable
            \\global.get __tls_size
            \\local.set %[ret]
            : [ret] "=r" (-> usize),
        );
    }

    inline fn futexWait(ptr: *const u32, expected: u32) void {
        const exp: i32 = @bitCast(expected);
        _ = asm volatile ("local.get %[ptr]\nlocal.get %[exp]\ni64.const -1\nmemory.atomic.wait32 0\nlocal.set %[ret]"
            : [ret] "=r" (-> u32),
            : [ptr] "r" (ptr),
              [exp] "r" (exp),
            : .{ .memory = true });
    }

    inline fn futexWake(ptr: *const u32) void {
        _ = asm volatile ("local.get %[ptr]\ni32.const 1\nmemory.atomic.notify 0\nlocal.set %[ret]"
            : [ret] "=r" (-> u32),
            : [ptr] "r" (ptr),
            : .{ .memory = true });
    }

    fn Wrapped(comptime function: anytype, comptime Args: type) type {
        return struct {
            const Pack = struct { args: Args };

            fn freePack(p: usize) void {
                const pack: *Pack = @ptrFromInt(p);
                std.heap.page_allocator.destroy(pack);
            }

            fn thunk(p: usize) callconv(.c) i32 {
                const pack: *Pack = @ptrFromInt(p);
                @call(.auto, function, pack.args);
                return 0;
            }
        };
    }

    fn spawn(comptime function: anytype, args: anytype) SpawnError!WasmThread {
        const W = Wrapped(function, @TypeOf(args));
        reap();
        const a = std.heap.page_allocator;
        const inst = a.create(Instance) catch return error.SystemResources;
        errdefer a.destroy(inst);
        const pack = a.create(W.Pack) catch return error.SystemResources;
        errdefer a.destroy(pack);
        pack.* = .{ .args = args };
        const tls_size = std.mem.alignForward(usize, tlsSize(), 16);
        const block = a.alignedAlloc(u8, .@"16", tls_size + WASM_THREAD_STACK) catch return error.SystemResources;
        errdefer a.free(block);
        // `__wasm_init_tls` yalnızca `.tdata`yı kopyalar; `.tbss` (ve yığın) sıfırlanmış olmalıdır.
        @memset(block, 0);
        inst.* = .{ .stack_top = @intFromPtr(block.ptr) + block.len, .free_pack = &W.freePack, .block = block, .tls_size = tls_size, .entry = &W.thunk, .arg = @intFromPtr(pack) };
        const tid = spawnImport(inst);
        if (tid < 0) return error.SystemResources;
        return .{ .inst = inst };
    }

    fn release(inst: *Instance) void {
        const a = std.heap.page_allocator;
        a.free(inst.block);
        inst.free_pack(inst.arg);
        a.destroy(inst);
    }

    pub fn join(self: WasmThread) void {
        // `exited` iş parçacığının son yazısıdır: bundan sonra yığın/TLS bloğu güvenle geri verilebilir.
        while (true) {
            const e = self.inst.exited.load(.seq_cst);
            if (e != 0) break;
            futexWait(&self.inst.exited.raw, e);
        }
        release(self.inst);
    }

    /// Ayrılan (detach) iş parçacıkları: bitmemiş olanların bloğu iş parçacığı kendi yığınında çalışırken geri verilemez; örnek burada bekletilir ve sonraki `spawn`/`detach`
    /// çağrılarında `exited` olanlar toplanır (`reap`). Liste bağlıdır, dolmaz: detach edilen her iş parçacığı sonunda toplanır.
    var zombies: ?*Instance = null;
    var zombie_lock: std.atomic.Value(u32) = .init(0);

    fn zombieLock() void {
        while (zombie_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) futexWait(&zombie_lock.raw, 1);
    }

    fn zombieUnlock() void {
        zombie_lock.store(0, .release);
        futexWake(&zombie_lock.raw);
    }

    fn reap() void {
        zombieLock();
        defer zombieUnlock();
        var link: *?*Instance = &zombies;
        while (link.*) |inst| {
            if (inst.exited.load(.seq_cst) != 0) {
                link.* = inst.next_zombie;
                release(inst);
            } else {
                link = &inst.next_zombie;
            }
        }
    }

    pub fn detach(self: WasmThread) void {
        _ = self.inst.state.swap(@intFromEnum(State.detached), .seq_cst);
        zombieLock();
        self.inst.next_zombie = zombies;
        zombies = self.inst;
        zombieUnlock();
        reap();
    }

    /// Host'un çağırdığı giriş (`wasi_thread_start(tid, arg)`, WASI-threads ABI'si). YENİ bir wasm örneğinin `__stack_pointer`ı, tüm iş parçacıkları için AYNI statik
    /// (ana iş parçacığının) yığın tepesidir; Debug derlemelerinde sıradan bir işlev önsözü bu paylaşılan bölgede çerçeve açıp parametreleri oraya döker ve eş zamanlı
    /// başlayan iş parçacıkları birbirinin `arg`ını ezer. Bu yüzden giriş ÖNSÖZSÜZ (`naked`) yazılır: yığın işaretçisini önce bu iş parçacığının KENDİ bloğuna kurar,
    /// ardından gerçek gövdeyi çağırır.
    fn threadStartNaked(tid: i32, arg: *Instance) callconv(.naked) void {
        _ = tid;
        _ = arg;
        const exited_off = std.fmt.comptimePrint("{d}", .{@offsetOf(Instance, "exited")});
        asm volatile (
            \\.functype nox_wasm_thread_main (i32, i32) -> ()
            \\local.get 1
            \\i32.load 0
            \\global.set __stack_pointer
            \\local.get 0
            \\local.get 1
            \\call nox_wasm_thread_main
            \\local.get 1
            \\i32.const 1
            \\i32.atomic.store 
        ++ exited_off ++ "\n" ++
            \\local.get 1
            \\i32.const 1
            \\memory.atomic.notify 
        ++ exited_off ++ "\n" ++
            \\drop
            \\return
        );
    }

    fn threadMain(tid: i32, arg: *Instance) callconv(.c) void {
        __wasm_init_tls(arg.block.ptr);
        tls_id = @intCast(tid);
        _ = asyncify.nox_asyncify_run(arg.entry, arg.arg);
        const prev = arg.state.swap(@intFromEnum(State.completed), .seq_cst);
        _ = prev;
        futexWake(&arg.state.raw);
    }

    comptime {
        @export(&threadStartNaked, .{ .name = start_export_name });
        @export(&threadMain, .{ .name = "nox_wasm_thread_main" });
    }
} else struct {};
