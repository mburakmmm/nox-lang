//! Faz 10 (WASM): wasm32'de `atomics` özelliği yoksa (`+atomics` yalnız iş parçacıklı kipte açılır) 64-bit atomik işlemler derlenmez
//! (`std.atomic.Value(u64)`: "expected 32-bit integer type or smaller"). Tek iş parçacıklı wasm modülünde düz yükle/sakla doğrudur; bu sarmalayıcı aynı arayüzü verir.
//! Diğer tüm hedeflerde `std.atomic.Value` aynen kullanılır.

const std = @import("std");
const builtin = @import("builtin");

const wasm_without_atomics = builtin.cpu.arch.isWasm() and !std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);
const wasm_with_atomics = builtin.cpu.arch.isWasm() and !wasm_without_atomics;
const atomic64 = @import("atomic64.zig");

/// İş parçacıklı wasm: 64-bit atomikler satır içi `i64.atomic.*` ile (Zig'in `std.atomic.Value(u64)`i derlenmez).
fn Asm(comptime T: type) type {
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .raw = v };
        }
        pub fn load(self: *const Self, _: std.builtin.AtomicOrder) T {
            return atomic64.load(T, &self.raw);
        }
        pub fn store(self: *Self, v: T, _: std.builtin.AtomicOrder) void {
            atomic64.store(T, &self.raw, v);
        }
        pub fn swap(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            return atomic64.rmw(T, .xchg, &self.raw, v);
        }
        pub fn fetchAdd(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            return atomic64.rmw(T, .add, &self.raw, v);
        }
        pub fn fetchSub(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            return atomic64.rmw(T, .sub, &self.raw, v);
        }
        pub fn fetchOr(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            return atomic64.rmw(T, .@"or", &self.raw, v);
        }
        pub fn fetchAnd(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            return atomic64.rmw(T, .@"and", &self.raw, v);
        }
        pub fn cmpxchgStrong(self: *Self, expected: T, desired: T, _: std.builtin.AtomicOrder, _: std.builtin.AtomicOrder) ?T {
            const old = atomic64.cas(T, &self.raw, expected, desired);
            return if (old == expected) null else old;
        }
        pub fn cmpxchgWeak(self: *Self, expected: T, desired: T, s: std.builtin.AtomicOrder, f: std.builtin.AtomicOrder) ?T {
            return self.cmpxchgStrong(expected, desired, s, f);
        }
    };
}

fn Plain(comptime T: type) type {
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .raw = v };
        }
        pub fn load(self: *const Self, _: std.builtin.AtomicOrder) T {
            return self.raw;
        }
        pub fn store(self: *Self, v: T, _: std.builtin.AtomicOrder) void {
            self.raw = v;
        }
        pub fn swap(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            const old = self.raw;
            self.raw = v;
            return old;
        }
        pub fn fetchAdd(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            const old = self.raw;
            self.raw = old +% v;
            return old;
        }
        pub fn fetchSub(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            const old = self.raw;
            self.raw = old -% v;
            return old;
        }
        pub fn fetchOr(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            const old = self.raw;
            self.raw = old | v;
            return old;
        }
        pub fn fetchAnd(self: *Self, v: T, _: std.builtin.AtomicOrder) T {
            const old = self.raw;
            self.raw = old & v;
            return old;
        }
        pub fn cmpxchgStrong(self: *Self, expected: T, desired: T, _: std.builtin.AtomicOrder, _: std.builtin.AtomicOrder) ?T {
            if (self.raw != expected) return self.raw;
            self.raw = desired;
            return null;
        }
        pub fn cmpxchgWeak(self: *Self, expected: T, desired: T, s: std.builtin.AtomicOrder, f: std.builtin.AtomicOrder) ?T {
            return self.cmpxchgStrong(expected, desired, s, f);
        }
    };
}

pub fn Value(comptime T: type) type {
    if (comptime wasm_without_atomics and @bitSizeOf(T) > 32) return Plain(T);
    if (comptime wasm_with_atomics and @bitSizeOf(T) > 32) return Asm(T);
    return std.atomic.Value(T);
}
