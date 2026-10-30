//! Faz 10 (WASM): wasm32'de `atomics` özelliği yoksa (`+atomics` yalnız iş parçacıklı kipte açılır) 64-bit atomik işlemler derlenmez
//! (`std.atomic.Value(u64)`: "expected 32-bit integer type or smaller"). Tek iş parçacıklı wasm modülünde düz yükle/sakla doğrudur; bu sarmalayıcı aynı arayüzü verir.
//! Diğer tüm hedeflerde `std.atomic.Value` aynen kullanılır.

const std = @import("std");
const builtin = @import("builtin");

const wasm_without_atomics = builtin.cpu.arch.isWasm() and !std.Target.wasm.featureSetHas(builtin.cpu.features, .atomics);

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
    return std.atomic.Value(T);
}
