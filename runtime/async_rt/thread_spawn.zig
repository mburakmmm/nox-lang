//! Faz 10 (WASM, ADR-015): iş parçacığı başlatma. Yerel hedeflerde `std.Thread`. wasm32'de (wasi-threads tarzı: `wasi::thread-spawn` import'u + `wasi_thread_start` dışa aktarımı)
//! Zig 0.16'nın `WasiThreadImpl`i KULLANILMAZ: gölge yığın işaretçisini ayrılan bölgenin ALT ucuna kurar (yığın aşağı büyüdüğünden yalnızca bir sayfa kullanılabilir, ötesi komşu
//! bloğu ezer) ve `std.Io.Threaded` futex'ine dayanır (tip hatası). Burada yığın bloğu (TLS + yığın) sıfırlanmış olarak ayrılır, işaretçi doğru uca kurulur ve gövde bu iş
//! parçacığının KENDİ Asyncify sürücüsü altında çalışır (her işçinin fiber'ları o işçiye ait `unwind/rewind` durumuyla döner).
//!
//! Sınır: `detach` edilen iş parçacıklarının bellek bloğu, iş parçacığı kendi yığınında çalıştığı için geri verilmez (az sayıda, ömürlü sürücü iş parçacıkları).

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
        /// [TLS | yığın]; `__wasm_init_tls` bu bloğun başına, gölge yığın bloğun ÜST ucuna kurulur.
        block: []u8,
        tls_size: usize,
        entry: *const fn (usize) callconv(.c) i32,
        arg: usize,
    };

    inst: *Instance,

    extern "wasi" fn @"thread-spawn"(arg: *Instance) i32;
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

            fn thunk(p: usize) callconv(.c) i32 {
                const pack: *Pack = @ptrFromInt(p);
                @call(.auto, function, pack.args);
                return 0;
            }
        };
    }

    fn spawn(comptime function: anytype, args: anytype) SpawnError!WasmThread {
        const W = Wrapped(function, @TypeOf(args));
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
        inst.* = .{ .stack_top = @intFromPtr(block.ptr) + block.len, .block = block, .tls_size = tls_size, .entry = &W.thunk, .arg = @intFromPtr(pack) };
        const tid = @"thread-spawn"(inst);
        if (tid < 0) return error.SystemResources;
        return .{ .inst = inst };
    }

    pub fn join(self: WasmThread) void {
        while (true) {
            const s = self.inst.state.load(.seq_cst);
            if (s != @intFromEnum(State.running)) break;
            futexWait(&self.inst.state.raw, s);
        }
        // Bu noktada iş parçacığı bitti (son `state` yazısından sonra kendi yığınına dokunmaz); blok ve örnek geri verilir. Argüman paketi küçük, sızdırılır değil: aşağıda.
        const a = std.heap.page_allocator;
        a.free(self.inst.block);
        const pack_ptr: *anyopaque = @ptrFromInt(self.inst.arg);
        _ = pack_ptr; // paket bir tür-silinmiş küçük ayırımdır; boyutu bilinmediğinden `Instance` ile birlikte bırakılır (iş parçacığı başına birkaç bayt).
        a.destroy(self.inst);
    }

    pub fn detach(self: WasmThread) void {
        // Çalışmaya devam eden iş parçacığı bloğunu kendi yığınından geri veremez; bırakılır (bkz. modül notu).
        const prev = self.inst.state.swap(@intFromEnum(State.detached), .seq_cst);
        if (prev == @intFromEnum(State.completed)) self.join();
    }

    /// Host'un çağırdığı giriş (`wasi_thread_start(tid, arg)`, WASI-threads ABI'si). YENİ bir wasm örneğinin `__stack_pointer`ı, tüm iş parçacıkları için AYNI statik
    /// (ana iş parçacığının) yığın tepesidir; Debug derlemelerinde sıradan bir işlev önsözü bu paylaşılan bölgede çerçeve açıp parametreleri oraya döker ve eş zamanlı
    /// başlayan iş parçacıkları birbirinin `arg`ını ezer. Bu yüzden giriş ÖNSÖZSÜZ (`naked`) yazılır: yığın işaretçisini önce bu iş parçacığının KENDİ bloğuna kurar,
    /// ardından gerçek gövdeyi çağırır.
    fn threadStartNaked(tid: i32, arg: *Instance) callconv(.naked) void {
        _ = tid;
        _ = arg;
        asm volatile (
            \\.functype nox_wasm_thread_main (i32, i32) -> ()
            \\local.get 1
            \\i32.load 0
            \\global.set __stack_pointer
            \\local.get 0
            \\local.get 1
            \\call nox_wasm_thread_main
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
        @export(&threadStartNaked, .{ .name = "wasi_thread_start" });
        @export(&threadMain, .{ .name = "nox_wasm_thread_main" });
    }
} else struct {};
