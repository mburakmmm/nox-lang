//! Faz 10 (WASM, ADR-015): wasm32'de 64-bit atomik işlemler. Zig 0.16 wasm32'de `@atomicLoad/@atomicRmw(u64, ...)`i derlemez ("expected 32-bit integer type
//! or smaller") — oysa WebAssembly threads önerisi `i64.atomic.*` komutlarını sağlar. ARC başlığı (64-bit sözcük) ve zamanlayıcı sayaçları bu yüzden satır içi
//! montajla (wasm `i64.atomic.*`, hep sıralı-tutarlı) erişilir. Diğer hedeflerde standart atomikler; `atomics` özelliği olmayan (tek iş parçacıklı) wasm'de düz erişim.

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch.isWasm();
/// `+atomics` açık wasm: gerçek iş parçacığı kipi (ADR-015).
pub const wasm_threads = is_wasm and std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);
/// `+atomics` kapalı wasm: tek iş parçacıklı, 64-bit işlemler düzdür.
pub const wasm_plain = is_wasm and !wasm_threads;

pub const Op = enum { add, sub, @"and", @"or", xor, xchg };

inline fn asmLoad(p: *const u64) u64 {
    return asm volatile ("local.get %[p]\ni64.atomic.load 0\nlocal.set %[r]"
        : [r] "=r" (-> u64),
        : [p] "r" (p),
        : .{ .memory = true });
}

inline fn asmStore(p: *u64, v: u64) void {
    asm volatile ("local.get %[p]\nlocal.get %[v]\ni64.atomic.store 0"
        :
        : [p] "r" (p),
          [v] "r" (v),
        : .{ .memory = true });
}

inline fn asmRmw(comptime op: Op, p: *u64, v: u64) u64 {
    const ins = switch (op) {
        .add => "i64.atomic.rmw.add 0",
        .sub => "i64.atomic.rmw.sub 0",
        .@"and" => "i64.atomic.rmw.and 0",
        .@"or" => "i64.atomic.rmw.or 0",
        .xor => "i64.atomic.rmw.xor 0",
        .xchg => "i64.atomic.rmw.xchg 0",
    };
    return asm volatile ("local.get %[p]\nlocal.get %[v]\n" ++ ins ++ "\nlocal.set %[r]"
        : [r] "=r" (-> u64),
        : [p] "r" (p),
          [v] "r" (v),
        : .{ .memory = true });
}

inline fn asmCas(p: *u64, expected: u64, desired: u64) u64 {
    return asm volatile ("local.get %[p]\nlocal.get %[e]\nlocal.get %[d]\ni64.atomic.rmw.cmpxchg 0\nlocal.set %[r]"
        : [r] "=r" (-> u64),
        : [p] "r" (p),
          [e] "r" (expected),
          [d] "r" (desired),
        : .{ .memory = true });
}

/// Atomik yükleme (`T`: 64-bit tamsayı).
pub inline fn load(comptime T: type, p: *const T) T {
    if (comptime wasm_threads) return @bitCast(asmLoad(@ptrCast(p)));
    if (comptime wasm_plain) return p.*;
    return @atomicLoad(T, p, .seq_cst);
}

pub inline fn store(comptime T: type, p: *T, v: T) void {
    if (comptime wasm_threads) return asmStore(@ptrCast(p), @bitCast(v));
    if (comptime wasm_plain) {
        p.* = v;
        return;
    }
    @atomicStore(T, p, v, .seq_cst);
}

/// Okuma-değiştirme-yazma; ESKİ değeri döner.
pub inline fn rmw(comptime T: type, comptime op: Op, p: *T, v: T) T {
    if (comptime wasm_threads) return @bitCast(asmRmw(op, @ptrCast(p), @bitCast(v)));
    if (comptime wasm_plain) {
        const old = p.*;
        p.* = switch (op) {
            .add => old +% v,
            .sub => old -% v,
            .@"and" => old & v,
            .@"or" => old | v,
            .xor => old ^ v,
            .xchg => v,
        };
        return old;
    }
    return @atomicRmw(T, p, switch (op) {
        .add => .Add,
        .sub => .Sub,
        .@"and" => .And,
        .@"or" => .Or,
        .xor => .Xor,
        .xchg => .Xchg,
    }, v, .seq_cst);
}

/// Karşılaştır-ve-değiştir; ESKİ değeri döner (`== expected` ise değişti).
pub inline fn cas(comptime T: type, p: *T, expected: T, desired: T) T {
    if (comptime wasm_threads) return @bitCast(asmCas(@ptrCast(p), @bitCast(expected), @bitCast(desired)));
    if (comptime wasm_plain) {
        const old = p.*;
        if (old == expected) p.* = desired;
        return old;
    }
    return @cmpxchgStrong(T, p, expected, desired, .seq_cst, .seq_cst) orelse expected;
}
