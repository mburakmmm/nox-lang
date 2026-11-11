//! Freestanding varsayılan heap'i (v2.1.54): bitişik bir bellek bölgesi üzerinde, 2'nin kuvveti boyut sınıflı, serbest listeli (free-list) basit bir dağıtıcı.
//!
//! Neden: önceki `kernel.zig` dağıtıcısı sayfa-içi "bump" idi — tek istekte 4096 baytın üstünü REDDEDİYORDU (Nox `list` 512+ eleman, `Set` 1000+ eleman, 8 KiB+ dize, arena parçası büyütmesi
//! hep `null` aldı; çağıran denetlemediği için `null+16`'ya yazıp sessizce BOZULUYORDU) ve `free` hiçbir şey yapmıyordu (her ayırma sızıyordu).
//!
//! Tasarım: sınıf k, `16 << k` baytlık bloktur. İstek, `max(size, alignment, 16)`'yı karşılayan en küçük sınıfa yuvarlanır. Blok, sınıf boyutuna (en çok 4096) hizalı olarak bölgenin "bump"
//! ucundan kesilir; serbest bırakılan blok sınıfın serbest listesine döner ve aynı sınıftaki sonraki istekte yeniden kullanılır. Birleştirme (coalescing) YOKTUR: iç parçalanma ≤ 2x, dış
//! parçalanma sınıf başına sınırlıdır. Nox'un büyüyen listeleri (2'nin kuvveti kapasite) ve ASAP ile hemen serbest bırakılan kısa ömürlü nesneleri bu modelde neredeyse kayıpsızdır.
//!
//! Bu dosya HİÇBİR OS/arch bağımlılığı taşımaz: adresleri `usize` olarak alır ve serbest liste düğümünü blokların kendi içine yazar; kernel (`kernel.zig`) bölgeyi sağlar. İş parçacığı güvenli
//! DEĞİLDİR (freestanding v1 tek çekirdek/tek iş parçacığı).

const std = @import("std");

pub const MIN_SHIFT: u6 = 4; // en küçük blok 16 bayt
pub const NUM_CLASSES: usize = 28; // 16 B .. 2 GiB
pub const MAX_ALIGN: usize = 4096;

pub const SizeClassHeap = struct {
    bump: usize,
    end: usize,
    free_heads: [NUM_CLASSES]usize = @splat(0),

    pub fn init(base: usize, end: usize) SizeClassHeap {
        return .{ .bump = base, .end = end };
    }

    /// `size`/`alignment` isteğini karşılayan sınıf; sınıf yoksa (`alignment > MAX_ALIGN` ya da dev boyut) `null`.
    pub fn classOf(size: usize, alignment: usize) ?usize {
        if (alignment > MAX_ALIGN) return null;
        const need = @max(@max(size, alignment), 1 << MIN_SHIFT);
        if (need > (@as(usize, 1) << (MIN_SHIFT + NUM_CLASSES - 1))) return null;
        const bits = std.math.log2_int_ceil(usize, need);
        return @as(usize, bits) - MIN_SHIFT;
    }

    pub fn classSize(class: usize) usize {
        return @as(usize, 1) << @intCast(MIN_SHIFT + class);
    }

    /// Bellek adresini döner; yetersizse `null`.
    pub fn alloc(self: *SizeClassHeap, size: usize, alignment: usize) ?usize {
        const class = classOf(size, alignment) orelse return null;
        const head = self.free_heads[class];
        if (head != 0) {
            const next: *const usize = @ptrFromInt(head);
            self.free_heads[class] = next.*;
            return head;
        }
        const cs = classSize(class);
        const block_align = @min(cs, MAX_ALIGN);
        const start = std.mem.alignForward(usize, self.bump, block_align);
        if (start > self.end or self.end - start < cs) return null;
        self.bump = start + cs;
        return start;
    }

    /// `addr` daha önce AYNI `size`/`alignment` ile alınmış olmalıdır.
    pub fn free(self: *SizeClassHeap, addr: usize, size: usize, alignment: usize) void {
        const class = classOf(size, alignment) orelse return;
        const node: *usize = @ptrFromInt(addr);
        node.* = self.free_heads[class];
        self.free_heads[class] = addr;
    }
};

test "classOf: boyut ve hizalamayı 2'nin kuvveti sınıfa yuvarlar" {
    try std.testing.expectEqual(@as(?usize, 0), SizeClassHeap.classOf(1, 1));
    try std.testing.expectEqual(@as(?usize, 0), SizeClassHeap.classOf(16, 8));
    try std.testing.expectEqual(@as(?usize, 1), SizeClassHeap.classOf(17, 8));
    try std.testing.expectEqual(@as(?usize, 3), SizeClassHeap.classOf(100, 8)); // 128
    try std.testing.expectEqual(@as(?usize, 8), SizeClassHeap.classOf(4096, 8));
    try std.testing.expectEqual(@as(?usize, 9), SizeClassHeap.classOf(4097, 8)); // 8192
    try std.testing.expectEqual(@as(?usize, 4), SizeClassHeap.classOf(8, 256)); // hizalama sınıfı büyütür
    try std.testing.expectEqual(@as(?usize, null), SizeClassHeap.classOf(8, 8192));
}

test "alloc: 4096 baytı AŞAN istekler (önceki dağıtıcının reddettiği) karşılanır ve hizalıdır" {
    var buf: [256 * 1024]u8 align(4096) = undefined;
    var h = SizeClassHeap.init(@intFromPtr(&buf), @intFromPtr(&buf) + buf.len);
    const a = h.alloc(2064, 8) orelse return error.OutOfMemory; // list cap 256 (v2.1.54 öncesi null)
    const b = h.alloc(40000, 8) orelse return error.OutOfMemory;
    try std.testing.expect(a % 8 == 0 and b % 8 == 0);
    try std.testing.expect(a + 4096 <= b or b + 65536 <= a); // örtüşmez
}

test "free: serbest bırakılan blok aynı sınıfta yeniden kullanılır (sızıntı yok)" {
    var buf: [64 * 1024]u8 align(4096) = undefined;
    var h = SizeClassHeap.init(@intFromPtr(&buf), @intFromPtr(&buf) + buf.len);
    const first = h.alloc(48, 8).?;
    h.free(first, 48, 8);
    try std.testing.expectEqual(first, h.alloc(40, 8).?); // aynı sınıf (64)
    // 1 milyon ayır/serbest bırak: bölge tükenmez.
    var i: usize = 0;
    while (i < 1_000_000) : (i += 1) {
        const p = h.alloc(i % 3000 + 1, 8) orelse return error.OutOfMemory;
        h.free(p, i % 3000 + 1, 8);
    }
}

test "alloc: bölge tükenince null döner, bozulma yok" {
    var buf: [8192]u8 align(4096) = undefined;
    var h = SizeClassHeap.init(@intFromPtr(&buf), @intFromPtr(&buf) + buf.len);
    try std.testing.expect(h.alloc(4096, 8) != null);
    try std.testing.expect(h.alloc(4096, 8) != null);
    try std.testing.expectEqual(@as(?usize, null), h.alloc(16, 8));
}

test "içerik: bloklar birbirinin verisini ezmez" {
    var buf: [128 * 1024]u8 align(4096) = undefined;
    var h = SizeClassHeap.init(@intFromPtr(&buf), @intFromPtr(&buf) + buf.len);
    var ptrs: [64]usize = undefined;
    for (&ptrs, 0..) |*p, i| {
        p.* = h.alloc(24 + i * 16, 8).?;
        const bytes: [*]u8 = @ptrFromInt(p.*);
        @memset(bytes[0 .. 24 + i * 16], @intCast(i + 1));
    }
    for (ptrs, 0..) |p, i| {
        const bytes: [*]const u8 = @ptrFromInt(p);
        for (bytes[0 .. 24 + i * 16]) |c| try std.testing.expectEqual(@as(u8, @intCast(i + 1)), c);
    }
}
