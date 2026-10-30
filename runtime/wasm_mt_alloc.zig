//! Faz 10 (WASM, ADR-015): iş parçacıklı wasm32'de genel ayırıcı. Zig 0.16'nın `WasmAllocator`ı/`BrkAllocator`ı `-fno-single-threaded` ile derlenmez ve `SmpAllocator`
//! işletim sistemi iş parçacığı yerelleri ister. Bu küçük ayırıcı `memory.grow` ile büyüyen bir bump bölgesi üzerinde boyut-sınıflı serbest listeler tutar
//! ve tek bir kilitle korunur. Boyut sınıfları 2'nin kuvvetleri arasında 4 basamaklıdır (iç parçalanma ≤ %25). Kök dosyadaki `os.heap.page_allocator`
//! geçersiz kılması (lib_wasm.zig) tüm çalışma zamanı kodunu buraya yönlendirir.

const std = @import("std");
const Allocator = std.mem.Allocator;

const PAGE: usize = 64 * 1024;
/// Bump bölgesini en az bu kadar (1 MiB) büyüt.
const MIN_GROW_PAGES: usize = 16;
const MIN_BLOCK: usize = 16;
const CLASS_COUNT = 128;

/// 0 = serbest, 1 = kilitli.
var lock_state: std.atomic.Value(u32) = .init(0);

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

fn lock() void {
    while (lock_state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) futexWait(&lock_state.raw, 1);
}

fn unlock() void {
    lock_state.store(0, .release);
    futexWake(&lock_state.raw);
}

var bump_cur: usize = 0;
var bump_end: usize = 0;
var free_heads: [CLASS_COUNT]usize = @splat(0);

/// `n` baytı kapsayan sınıf boyutu ve indeksi: 16'ya kadar tek sınıf; sonrasında her 2'nin kuvveti 4 eşit basamağa bölünür.
fn classOf(n: usize) struct { size: usize, idx: usize } {
    if (n <= MIN_BLOCK) return .{ .size = MIN_BLOCK, .idx = 0 };
    const p: u5 = @intCast(std.math.log2_int(usize, n - 1)); // 2^p < n <= 2^(p+1)
    const step = @as(usize, 1) << (p - 2);
    const base = @as(usize, 1) << p;
    const k = (n - base + step - 1) / step; // 1..4
    return .{ .size = base + k * step, .idx = 1 + (@as(usize, p) - 4) * 4 + (k - 1) };
}

fn grow(min_bytes: usize) bool {
    var pages = (min_bytes + PAGE - 1) / PAGE;
    if (pages < MIN_GROW_PAGES) pages = MIN_GROW_PAGES;
    const prev = @wasmMemoryGrow(0, pages);
    if (prev == -1) return false;
    const start = @as(usize, @intCast(prev)) * PAGE;
    // Bölge bitişikse sürdür; değilse (başka biri de büyüttü) yeni bölgeyi kullan, eskisini bırak.
    if (start == bump_end and bump_end != 0) {
        bump_end = start + pages * PAGE;
    } else {
        bump_cur = start;
        bump_end = start + pages * PAGE;
    }
    return true;
}

fn allocBlock(size: usize, idx: usize, align_bytes: usize) ?[*]u8 {
    if (align_bytes <= MIN_BLOCK) {
        const head = free_heads[idx];
        if (head != 0) {
            const next: *usize = @ptrFromInt(head);
            free_heads[idx] = next.*;
            return @ptrFromInt(head);
        }
    }
    while (true) {
        const aligned = std.mem.alignForward(usize, bump_cur, @max(align_bytes, MIN_BLOCK));
        if (aligned + size <= bump_end and bump_end != 0) {
            bump_cur = aligned + size;
            return @ptrFromInt(aligned);
        }
        if (!grow(size + align_bytes)) return null;
    }
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const c = classOf(len);
    const align_bytes = alignment.toByteUnits();
    lock();
    defer unlock();
    return allocBlock(c.size, c.idx, align_bytes);
}

fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // Yerinde yalnızca aynı boyut sınıfında kalınıyorsa.
    return classOf(memory.len).size == classOf(new_len).size;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    if (resize(undefined, memory, alignment, new_len, ra)) return memory.ptr;
    return null;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    const c = classOf(memory.len);
    if (alignment.toByteUnits() > MIN_BLOCK) return; // hizalı özel bloklar listeye girmez (nadir; bellek geri alınmaz)
    lock();
    defer unlock();
    const node: *usize = @ptrCast(@alignCast(memory.ptr));
    node.* = free_heads[c.idx];
    free_heads[c.idx] = @intFromPtr(memory.ptr);
}

const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };
