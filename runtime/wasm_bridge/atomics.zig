//! Nox WASM köprüsü — threads önerisinin atomik komutları (`0xFE` öneki; v2.1.99, TODO 4.6).
//!
//! Kapsam: `memory.atomic.notify/wait32/wait64`, `atomic.fence`, tüm atomik yükleme/depolama/read-modify-write/cmpxchg varyantları ve PAYLAŞIMLI bellek
//! (limits bayrağı 0x03). Yorumlayıcı bir `Instance` başına TEK iş parçacığında çalıştığından atomikler sıradan okuma/yazmadır (başka bir iş parçacığı bu
//! belleği aynı anda değiştiremez); semantik spesifikasyonla aynıdır: hizalama TAM doğal olmalıdır (derleme zamanı) ve hizasız adres çalışma zamanında tuzaktır.
//! Tek iş parçacığında `wait` hiç uyandırılamaz: değer eşit değilse 1, zaman aşımı >= 0 ise 2 (BEKLEMEDEN) döner, sonsuz bekleme `WaitWouldBlock` tuzağıdır
//! (sonsuza dek kilitlenmek yerine). `notify` her zaman 0 uyandırır.

const std = @import("std");
const mod = @import("module.zig");
const shared_mem = @import("shared_mem.zig");
const ValType = mod.ValType;

var fence_cell: std.atomic.Value(u32) = .init(0);

pub const Trap = error{ OutOfBoundsMemoryAccess, UnalignedAtomic, ExpectedSharedMemory, WaitWouldBlock, Canceled };

pub const Kind = enum(u8) { notify, wait32, wait64, fence, load, store, rmw, cmpxchg };

pub const Info = struct {
    kind: Kind,
    /// Erişim genişliği (bayt) ve değerin Wasm tipi.
    width: u8 = 0,
    ty: ValType = .i32,
    /// RMW işlemi (0 add, 1 sub, 2 and, 3 or, 4 xor, 5 xchg).
    op: u8 = 0,
};

const WIDTHS = [7]u8{ 4, 8, 1, 2, 1, 2, 4 };
const TYPES = [7]ValType{ .i32, .i64, .i32, .i32, .i64, .i64, .i64 };

/// Alt-opcode -> imza (null: geçersiz).
pub fn atomicInfo(sub: u32) ?Info {
    switch (sub) {
        0x00 => return .{ .kind = .notify, .width = 4 },
        0x01 => return .{ .kind = .wait32, .width = 4 },
        0x02 => return .{ .kind = .wait64, .width = 8, .ty = .i64 },
        0x03 => return .{ .kind = .fence },
        0x10...0x16 => return .{ .kind = .load, .width = WIDTHS[sub - 0x10], .ty = TYPES[sub - 0x10] },
        0x17...0x1d => return .{ .kind = .store, .width = WIDTHS[sub - 0x17], .ty = TYPES[sub - 0x17] },
        0x1e...0x47 => {
            const g = (sub - 0x1e) / 7;
            const i = (sub - 0x1e) % 7;
            return .{ .kind = .rmw, .width = WIDTHS[i], .ty = TYPES[i], .op = @intCast(g) };
        },
        0x48...0x4e => return .{ .kind = .cmpxchg, .width = WIDTHS[sub - 0x48], .ty = TYPES[sub - 0x48] },
        else => return null,
    }
}

inline fn ea(mem: []const u8, slot: u64, off: u32, size: usize) Trap!usize {
    const e: u64 = @as(u64, @as(u32, @truncate(slot))) + off;
    if (e + size > mem.len) return error.OutOfBoundsMemoryAccess;
    if (e % size != 0) return error.UnalignedAtomic;
    return @intCast(e);
}

inline fn rd(mem: []const u8, e: usize, w: u8) u64 {
    return switch (w) {
        1 => mem[e],
        2 => std.mem.readInt(u16, mem[e..][0..2], .little),
        4 => std.mem.readInt(u32, mem[e..][0..4], .little),
        else => std.mem.readInt(u64, mem[e..][0..8], .little),
    };
}

inline fn wr(mem: []u8, e: usize, w: u8, v: u64) void {
    switch (w) {
        1 => mem[e] = @truncate(v),
        2 => std.mem.writeInt(u16, mem[e..][0..2], @truncate(v), .little),
        4 => std.mem.writeInt(u32, mem[e..][0..4], @truncate(v), .little),
        else => std.mem.writeInt(u64, mem[e..][0..8], v, .little),
    }
}

inline fn maskOf(w: u8) u64 {
    return if (w == 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(w * 8)) - 1;
}

fn wait(mem: []u8, sm: ?*shared_mem.SharedMemory, cancel: ?*const std.atomic.Value(bool), slot: u64, off: u32, w: u8, expected: u64, timeout: u64) Trap!u64 {
    const e = try ea(mem, slot, off, w);
    const shared = sm orelse return error.ExpectedSharedMemory;
    const timeout_ns: i64 = @bitCast(timeout);
    // Bu belleğe başka yürütme durumu bağlı değilse (tek iş parçacığı) eski davranış: bekleme yok.
    if (shared.attached.load(.acquire) <= 1) {
        if (rd(mem, e, w) != (expected & maskOf(w))) return 1;
        if (timeout_ns < 0) return error.WaitWouldBlock;
        return 2;
    }
    const r = shared.wait(e, w, expected, timeout_ns, cancel);
    if (r == shared_mem.CANCELED) return error.Canceled;
    return r;
}

inline fn aRd(mem: []u8, e: usize, w: u8) u64 {
    return shared_mem.atomicLoad(mem.ptr, e, w);
}

inline fn aWr(mem: []u8, e: usize, w: u8, v: u64) void {
    switch (w) {
        1 => @atomicStore(u8, @as(*u8, @ptrCast(mem.ptr + e)), @truncate(v), .seq_cst),
        2 => @atomicStore(u16, @as(*u16, @ptrCast(@alignCast(mem.ptr + e))), @truncate(v), .seq_cst),
        4 => @atomicStore(u32, @as(*u32, @ptrCast(@alignCast(mem.ptr + e))), @truncate(v), .seq_cst),
        else => @atomicStore(u64, @as(*u64, @ptrCast(@alignCast(mem.ptr + e))), v, .seq_cst),
    }
}

inline fn aRmw(comptime T: type, p: *T, op: u8, v: T) T {
    return switch (op) {
        0 => @atomicRmw(T, p, .Add, v, .seq_cst),
        1 => @atomicRmw(T, p, .Sub, v, .seq_cst),
        2 => @atomicRmw(T, p, .And, v, .seq_cst),
        3 => @atomicRmw(T, p, .Or, v, .seq_cst),
        4 => @atomicRmw(T, p, .Xor, v, .seq_cst),
        else => @atomicRmw(T, p, .Xchg, v, .seq_cst),
    };
}

fn atomicRmwW(mem: []u8, e: usize, w: u8, op: u8, v: u64) u64 {
    return switch (w) {
        1 => aRmw(u8, @ptrCast(mem.ptr + e), op, @truncate(v)),
        2 => aRmw(u16, @ptrCast(@alignCast(mem.ptr + e)), op, @truncate(v)),
        4 => aRmw(u32, @ptrCast(@alignCast(mem.ptr + e)), op, @truncate(v)),
        else => aRmw(u64, @ptrCast(@alignCast(mem.ptr + e)), op, v),
    };
}

fn atomicCmpxchgW(mem: []u8, e: usize, w: u8, expected: u64, new: u64) u64 {
    return switch (w) {
        1 => cx(u8, @ptrCast(mem.ptr + e), @truncate(expected), @truncate(new)),
        2 => cx(u16, @ptrCast(@alignCast(mem.ptr + e)), @truncate(expected), @truncate(new)),
        4 => cx(u32, @ptrCast(@alignCast(mem.ptr + e)), @truncate(expected), @truncate(new)),
        else => cx(u64, @ptrCast(@alignCast(mem.ptr + e)), expected, new),
    };
}

inline fn cx(comptime T: type, p: *T, expected: T, new: T) T {
    return @cmpxchgStrong(T, p, expected, new, .seq_cst, .seq_cst) orelse expected;
}

/// Bir atomik komutu yürütür; yeni `sp`yi döndürür. `sm != null`: paylaşımlı bellek (gerçek donanım atomikleri + gerçek wait/notify); aksi halde tek iş parçacığında sıradan okuma/yazma.
pub fn exec(mem: []u8, sm: ?*shared_mem.SharedMemory, cancel: ?*const std.atomic.Value(bool), kind: Kind, sub: u32, off: u32, stack: []u64, sp0: usize) Trap!usize {
    var sp = sp0;
    const info = atomicInfo(sub).?;
    const w = info.width;
    const shared = sm != null;
    switch (kind) {
        .notify => {
            sp -= 1;
            const e = try ea(mem, stack[sp - 1], off, 4);
            const count: u32 = @truncate(stack[sp]);
            stack[sp - 1] = if (sm) |m| m.notify(e, count) else 0;
        },
        .wait32, .wait64 => {
            sp -= 2;
            stack[sp - 1] = try wait(mem, sm, cancel, stack[sp - 1], off, w, stack[sp], stack[sp + 1]);
        },
        .fence => {
            if (shared) _ = fence_cell.fetchAdd(0, .seq_cst); // tam bellek bariyeri (`@fence` Zig 0.16'da yok: seq_cst RMW aynı sırayı verir)
        },
        .load => {
            const e = try ea(mem, stack[sp - 1], off, w);
            stack[sp - 1] = if (shared) aRd(mem, e, w) else rd(mem, e, w);
        },
        .store => {
            sp -= 2;
            const e = try ea(mem, stack[sp], off, w);
            if (shared) aWr(mem, e, w, stack[sp + 1]) else wr(mem, e, w, stack[sp + 1]);
        },
        .rmw => {
            sp -= 1;
            const e = try ea(mem, stack[sp - 1], off, w);
            const v = stack[sp];
            if (shared) {
                stack[sp - 1] = atomicRmwW(mem, e, w, info.op, v);
            } else {
                const old = rd(mem, e, w);
                const new: u64 = switch (info.op) {
                    0 => old +% v,
                    1 => old -% v,
                    2 => old & v,
                    3 => old | v,
                    4 => old ^ v,
                    else => v,
                };
                wr(mem, e, w, new);
                stack[sp - 1] = old;
            }
        },
        .cmpxchg => {
            sp -= 2;
            const e = try ea(mem, stack[sp - 1], off, w);
            if (shared) {
                stack[sp - 1] = atomicCmpxchgW(mem, e, w, stack[sp] & maskOf(w), stack[sp + 1]);
            } else {
                const old = rd(mem, e, w);
                if (old == (stack[sp] & maskOf(w))) wr(mem, e, w, stack[sp + 1]);
                stack[sp - 1] = old;
            }
        },
    }
    return sp;
}
