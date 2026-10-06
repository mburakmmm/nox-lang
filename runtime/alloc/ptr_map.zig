//! İşaretçi anahtarlı, açık adreslemeli (open-addressing) küçük hash tablosu —
//! `cycle_detector.zig`nin `CycleGc.meta` yan tablosu İçİN (bkz.
//! nox-teknik-spesifikasyon.md §3.244).
//!
//! **Neden `std.AutoHashMapUnmanaged` DEĞİL:** döngü çözücü HER olası-kök
//! kaydında (`nox_cycle_possible_root`), HER serbest bırakmada
//! (`nox_cycle_forget`) ve toplamadaki HER düğüm ziyaretinde (3 geçiş)
//! tabloya dokunur. İkili-ağaç benchmark'ında (8.4M düğüm) profilin ~%45'i
//! `getOrPut` + `Wyhash` idi — Wyhash genel amaçlı bir bayt-dizisi
//! karması; 8 baytlık, zaten dağılımı iyi bir işaretçi anahtarı İçİn
//! gereksiz pahalı. Burada tek bir çarpma + kaydırma (Fibonacci karması),
//! satır-içi (anahtar+değer bitişik) doğrusal yoklama kullanılır.
//!
//! Anahtar `0` "boş", `1` "mezar taşı"dır — gerçek işaretçiler ASLA 0/1
//! OLAMAZ (`nox_alloc` hizalı, null olmayan adresler döner; `put/getOrPut`
//! yine de bunu `assert`ler). Yük faktörü ≤ 1/2 (boş+mezar taşı dahil).
//! `getOrPut`un döndürdüğü `value_ptr` YALNIZCA bir SONRAKİ `getOrPut`/`put`a
//! KADAR geçerlidir (tablo büyüyebilir) — `std.HashMap` ile AYNI sözleşme.

const std = @import("std");

const EMPTY: usize = 0;
const TOMBSTONE: usize = 1;

pub fn PtrMap(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { key: usize, value: V };
        pub const GetOrPutResult = struct { found_existing: bool, value_ptr: *V };

        entries: []Entry = &.{},
        /// Canlı girdi sayısı.
        len: usize = 0,
        /// Mezar taşı sayısı (yoklama uzunluğunu şişirir; yeniden karmada temizlenir).
        tombs: usize = 0,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.entries.len != 0) allocator.free(self.entries);
            self.* = .{};
        }

        inline fn slotOf(self: *const Self, key: usize) usize {
            const h = (key >> 3) *% 0x9E3779B97F4A7C15;
            const shift: u6 = @intCast(64 - @ctz(self.entries.len));
            return h >> shift;
        }

        pub fn getPtr(self: *Self, ptr: anytype) ?*V {
            const key: usize = keyOf(ptr);
            if (self.entries.len == 0) return null;
            const mask = self.entries.len - 1;
            var i = self.slotOf(key);
            while (true) : (i = (i + 1) & mask) {
                const k = self.entries[i].key;
                if (k == key) return &self.entries[i].value;
                if (k == EMPTY) return null;
            }
        }

        pub fn get(self: *Self, ptr: anytype) ?V {
            return if (self.getPtr(ptr)) |p| p.* else null;
        }

        pub fn remove(self: *Self, ptr: anytype) bool {
            const key: usize = keyOf(ptr);
            if (self.entries.len == 0) return false;
            const mask = self.entries.len - 1;
            var i = self.slotOf(key);
            while (true) : (i = (i + 1) & mask) {
                const k = self.entries[i].key;
                if (k == key) {
                    self.entries[i].key = TOMBSTONE;
                    self.len -= 1;
                    self.tombs += 1;
                    return true;
                }
                if (k == EMPTY) return false;
            }
        }

        pub fn getOrPut(self: *Self, allocator: std.mem.Allocator, ptr: anytype) std.mem.Allocator.Error!GetOrPutResult {
            const key: usize = keyOf(ptr);
            if ((self.len + self.tombs + 1) * 2 > self.entries.len) try self.rehash(allocator);
            const mask = self.entries.len - 1;
            var i = self.slotOf(key);
            var first_tomb: ?usize = null;
            while (true) : (i = (i + 1) & mask) {
                const k = self.entries[i].key;
                if (k == key) return .{ .found_existing = true, .value_ptr = &self.entries[i].value };
                if (k == TOMBSTONE) {
                    if (first_tomb == null) first_tomb = i;
                } else if (k == EMPTY) {
                    const slot = first_tomb orelse i;
                    if (first_tomb != null) self.tombs -= 1;
                    self.entries[slot].key = key;
                    self.entries[slot].value = undefined;
                    self.len += 1;
                    return .{ .found_existing = false, .value_ptr = &self.entries[slot].value };
                }
            }
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, ptr: anytype, value: V) std.mem.Allocator.Error!void {
            const r = try self.getOrPut(allocator, ptr);
            r.value_ptr.* = value;
        }

        fn keyOf(ptr: anytype) usize {
            const key: usize = switch (@typeInfo(@TypeOf(ptr))) {
                .pointer => @intFromPtr(ptr),
                .int, .comptime_int => ptr,
                else => @compileError("PtrMap anahtarı işaretçi/usize olmalı"),
            };
            std.debug.assert(key > TOMBSTONE);
            return key;
        }

        /// Kapasiteyi (gerekirse) ikiye katlayarak yeniden karar; yalnızca mezar
        /// taşı doluysa aynı boyutta temizler.
        fn rehash(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            const live_after = self.len + 1;
            var new_cap: usize = if (self.entries.len == 0) 16 else self.entries.len;
            while (live_after * 4 > new_cap) new_cap *= 2; // hedef yük ≤ 1/4 → sonraki büyümeye kadar rahat
            if (new_cap == self.entries.len and self.tombs == 0) new_cap *= 2;
            const new_entries = try allocator.alloc(Entry, new_cap);
            for (new_entries) |*e| e.key = EMPTY;
            const old = self.entries;
            self.entries = new_entries;
            self.tombs = 0;
            const mask = new_cap - 1;
            for (old) |e| {
                if (e.key <= TOMBSTONE) continue;
                var i = self.slotOf(e.key);
                while (self.entries[i].key != EMPTY) i = (i + 1) & mask;
                self.entries[i] = e;
            }
            if (old.len != 0) allocator.free(old);
        }
    };
}

test "PtrMap: getOrPut/getPtr/remove/put temel davranış" {
    const a = std.testing.allocator;
    var m: PtrMap(u32) = .empty;
    defer m.deinit(a);

    var xs: [64]u64 = undefined;
    for (&xs, 0..) |*x, i| {
        const r = try m.getOrPut(a, x);
        try std.testing.expect(!r.found_existing);
        r.value_ptr.* = @intCast(i);
    }
    try std.testing.expectEqual(@as(usize, 64), m.len);
    for (&xs, 0..) |*x, i| try std.testing.expectEqual(@as(u32, @intCast(i)), m.get(x).?);
    // Var olanı bul.
    const again = try m.getOrPut(a, &xs[5]);
    try std.testing.expect(again.found_existing);
    try std.testing.expectEqual(@as(u32, 5), again.value_ptr.*);
    // Sil, yokluğunu doğrula, yeniden ekle (mezar taşı yeniden kullanımı).
    try std.testing.expect(m.remove(&xs[5]));
    try std.testing.expect(!m.remove(&xs[5]));
    try std.testing.expect(m.getPtr(&xs[5]) == null);
    try std.testing.expectEqual(@as(usize, 63), m.len);
    try m.put(a, &xs[5], 99);
    try std.testing.expectEqual(@as(u32, 99), m.get(&xs[5]).?);
    try std.testing.expectEqual(@as(usize, 64), m.len);
}

test "PtrMap: yoğun ekleme/silme (mezar taşı birikimi) doğruluğu bozmaz" {
    const a = std.testing.allocator;
    var m: PtrMap(u64) = .empty;
    defer m.deinit(a);
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var shadow = std.AutoHashMap(usize, u64).init(a);
    defer shadow.deinit();
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        const key: usize = (rnd.uintLessThan(usize, 4096) + 2) * 16;
        if (rnd.boolean()) {
            const r = try m.getOrPut(a, key);
            r.value_ptr.* = i;
            try shadow.put(key, i);
        } else {
            const removed = m.remove(key);
            try std.testing.expectEqual(shadow.remove(key), removed);
        }
        try std.testing.expectEqual(shadow.count(), m.len);
    }
    var it = shadow.iterator();
    while (it.next()) |e| try std.testing.expectEqual(e.value_ptr.*, m.get(e.key_ptr.*).?);
}
