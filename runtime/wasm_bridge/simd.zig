//! Nox WASM köprüsü — sabit-genişlikli SIMD (`0xFD` öneki, v128; v2.1.98, TODO 4.6).
//!
//! İki iş yapar: (1) `simdInfo` doğrulayıcı için her alt-opcode'un tip imzasını/anında (immediate) biçimini söyler (`compile.zig`), (2) `exec`
//! yorumlayıcı için komutu GÖLGE yığın (`vstack: []u128`) üzerinde çalıştırır. v128 değeri, normal `u64` yığınıyla AYNI indeksli `vstack` yuvasında yaşar
//! (u64 yuvası kullanılmaz); böylece çerçeve düzeni, çağrı argüman geçişi ve yükseklik hesabı değişmez. Skaler sonuç/operandlar (extract/splat/shift sayısı/
//! bellek adresi) normal yığındadır.
//!
//! Bit düzeni: v128 `u128` olarak, lane 0 EN DÜŞÜK bitlerde (WASM'ın little-endian bellek temsili); `@bitCast([N]T <-> u128)` bunu verir (host little-endian'dır).
//! Float semantiği: `min/max` NaN/±0 kuralları skaler komutlarla AYNI yardımcılardan (`interp.zig`), `nearest` çifte yuvarlar, NaN yükleri belirsizdir
//! (spesifikasyon izin verir; testler NaN'ı "NaN mı" olarak karşılaştırır).

const std = @import("std");
const mod = @import("module.zig");
const interp = @import("interp.zig");
const ValType = mod.ValType;

pub const Trap = error{OutOfBoundsMemoryAccess};

pub const Kind = enum(u8) { load, store, vconst, shuffle, unary, binary, ternary, test_, shift, splat, extract, replace, load_lane, store_lane };

pub const Info = struct {
    kind: Kind,
    in: [3]ValType = .{ .v128, .v128, .v128 },
    n: u2 = 0,
    out: ?ValType = null,
    align_log2: u8 = 0,
    lanes: u8 = 0,
};

const V: ValType = .v128;

fn mkLoad(al: u8) Info {
    return .{ .kind = .load, .in = .{ .i32, .i32, .i32 }, .n = 1, .out = V, .align_log2 = al };
}
fn mkSplat(t: ValType) Info {
    return .{ .kind = .splat, .in = .{ t, t, t }, .n = 1, .out = V };
}
fn mkExtract(t: ValType, lanes: u8) Info {
    return .{ .kind = .extract, .n = 1, .out = t, .lanes = lanes };
}
fn mkReplace(t: ValType, lanes: u8) Info {
    return .{ .kind = .replace, .in = .{ V, t, t }, .n = 2, .out = V, .lanes = lanes };
}
fn mkLoadLane(al: u8, lanes: u8) Info {
    return .{ .kind = .load_lane, .in = .{ .i32, V, V }, .n = 2, .out = V, .align_log2 = al, .lanes = lanes };
}
fn mkStoreLane(al: u8, lanes: u8) Info {
    return .{ .kind = .store_lane, .in = .{ .i32, V, V }, .n = 2, .out = null, .align_log2 = al, .lanes = lanes };
}

const UN: Info = .{ .kind = .unary, .n = 1, .out = V };
const BIN: Info = .{ .kind = .binary, .n = 2, .out = V };
const TERN: Info = .{ .kind = .ternary, .n = 3, .out = V };
const TEST: Info = .{ .kind = .test_, .n = 1, .out = .i32 };
const SHIFT: Info = .{ .kind = .shift, .in = .{ V, .i32, .i32 }, .n = 2, .out = V };

/// Alt-opcode -> imza (null: desteklenmeyen/ayrılmış). Relaxed-SIMD (>= 0x100) kapsam dışıdır.
pub fn simdInfo(sub: u32) ?Info {
    return switch (sub) {
        0x00 => mkLoad(4),
        0x01...0x06 => mkLoad(3),
        0x07 => mkLoad(0),
        0x08 => mkLoad(1),
        0x09 => mkLoad(2),
        0x0a => mkLoad(3),
        0x0b => .{ .kind = .store, .in = .{ .i32, V, V }, .n = 2, .out = null, .align_log2 = 4 },
        0x0c => .{ .kind = .vconst, .n = 0, .out = V },
        0x0d => .{ .kind = .shuffle, .n = 2, .out = V },
        0x0e => BIN,
        0x0f...0x11 => mkSplat(.i32),
        0x12 => mkSplat(.i64),
        0x13 => mkSplat(.f32),
        0x14 => mkSplat(.f64),
        0x15, 0x16 => mkExtract(.i32, 16),
        0x17 => mkReplace(.i32, 16),
        0x18, 0x19 => mkExtract(.i32, 8),
        0x1a => mkReplace(.i32, 8),
        0x1b => mkExtract(.i32, 4),
        0x1c => mkReplace(.i32, 4),
        0x1d => mkExtract(.i64, 2),
        0x1e => mkReplace(.i64, 2),
        0x1f => mkExtract(.f32, 4),
        0x20 => mkReplace(.f32, 4),
        0x21 => mkExtract(.f64, 2),
        0x22 => mkReplace(.f64, 2),
        0x23...0x4c => BIN,
        0x4d => UN,
        0x4e...0x51 => BIN,
        0x52 => TERN,
        0x53 => TEST,
        0x54 => mkLoadLane(0, 16),
        0x55 => mkLoadLane(1, 8),
        0x56 => mkLoadLane(2, 4),
        0x57 => mkLoadLane(3, 2),
        0x58 => mkStoreLane(0, 16),
        0x59 => mkStoreLane(1, 8),
        0x5a => mkStoreLane(2, 4),
        0x5b => mkStoreLane(3, 2),
        0x5c => mkLoad(2),
        0x5d => mkLoad(3),
        0x5e, 0x5f => UN,
        0x60...0x62 => UN,
        0x63, 0x64 => TEST,
        0x65, 0x66 => BIN,
        0x67...0x6a => UN,
        0x6b...0x6d => SHIFT,
        0x6e...0x73 => BIN,
        0x74, 0x75 => UN,
        0x76...0x79 => BIN,
        0x7a => UN,
        0x7b => BIN,
        0x7c...0x7f => UN,
        0x80, 0x81 => UN,
        0x82 => BIN,
        0x83, 0x84 => TEST,
        0x85, 0x86 => BIN,
        0x87...0x8a => UN,
        0x8b...0x8d => SHIFT,
        0x8e...0x93 => BIN,
        0x94 => UN,
        0x95...0x99 => BIN,
        0x9b...0x9f => BIN,
        0xa0, 0xa1 => UN,
        0xa3, 0xa4 => TEST,
        0xa7...0xaa => UN,
        0xab...0xad => SHIFT,
        0xae => BIN,
        0xb1 => BIN,
        0xb5...0xba => BIN,
        0xbc...0xbf => BIN,
        0xc0, 0xc1 => UN,
        0xc3, 0xc4 => TEST,
        0xc7...0xca => UN,
        0xcb...0xcd => SHIFT,
        0xce => BIN,
        0xd1 => BIN,
        0xd5...0xdf => BIN,
        0xe0, 0xe1, 0xe3 => UN,
        0xe4...0xeb => BIN,
        0xec, 0xed, 0xef => UN,
        0xf0...0xf7 => BIN,
        0xf8...0xff => UN,
        else => null,
    };
}

// ------------------------------------------------------------------ yardımcılar

inline fn ea(mem: []const u8, slot: u64, off: u32, size: usize) Trap!usize {
    const e: u64 = @as(u64, @as(u32, @truncate(slot))) + off;
    if (e + size > mem.len) return error.OutOfBoundsMemoryAccess;
    return @intCast(e);
}

inline fn L(comptime T: type, x: u128) [16 / @sizeOf(T)]T {
    return @bitCast(x);
}
inline fn U(x: anytype) u128 {
    return @bitCast(x);
}
fn UInt(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

fn splatN(comptime T: type, v: T) u128 {
    var r: [16 / @sizeOf(T)]T = undefined;
    for (&r) |*d| d.* = v;
    return U(r);
}

// ------------------------------------------------------------------ bellek

fn extLoad(comptime S: type, comptime D: type, m: []const u8) u128 {
    var r: [16 / @sizeOf(D)]D = undefined;
    for (&r, 0..) |*d, i| {
        const s = std.mem.readInt(S, m[i * @sizeOf(S) ..][0..@sizeOf(S)], .little);
        d.* = s;
    }
    return U(r);
}

fn loadOp(sub: u32, mem: []const u8, slot: u64, off: u32) Trap!u128 {
    switch (sub) {
        0x00 => {
            const e = try ea(mem, slot, off, 16);
            return std.mem.readInt(u128, mem[e..][0..16], .little);
        },
        0x01...0x06 => {
            const e = try ea(mem, slot, off, 8);
            const m = mem[e..][0..8];
            return switch (sub) {
                0x01 => extLoad(i8, i16, m),
                0x02 => extLoad(u8, u16, m),
                0x03 => extLoad(i16, i32, m),
                0x04 => extLoad(u16, u32, m),
                0x05 => extLoad(i32, i64, m),
                else => extLoad(u32, u64, m),
            };
        },
        0x07 => {
            const e = try ea(mem, slot, off, 1);
            return splatN(u8, mem[e]);
        },
        0x08 => {
            const e = try ea(mem, slot, off, 2);
            return splatN(u16, std.mem.readInt(u16, mem[e..][0..2], .little));
        },
        0x09 => {
            const e = try ea(mem, slot, off, 4);
            return splatN(u32, std.mem.readInt(u32, mem[e..][0..4], .little));
        },
        0x0a => {
            const e = try ea(mem, slot, off, 8);
            return splatN(u64, std.mem.readInt(u64, mem[e..][0..8], .little));
        },
        0x5c => {
            const e = try ea(mem, slot, off, 4);
            return std.mem.readInt(u32, mem[e..][0..4], .little);
        },
        else => { // 0x5d
            const e = try ea(mem, slot, off, 8);
            return std.mem.readInt(u64, mem[e..][0..8], .little);
        },
    }
}

fn loadLaneT(comptime T: type, mem: []const u8, slot: u64, off: u32, v: u128, lane: usize) Trap!u128 {
    const e = try ea(mem, slot, off, @sizeOf(T));
    var r = L(T, v);
    r[lane] = std.mem.readInt(T, mem[e..][0..@sizeOf(T)], .little);
    return U(r);
}

fn storeLaneT(comptime T: type, mem: []u8, slot: u64, off: u32, v: u128, lane: usize) Trap!void {
    const e = try ea(mem, slot, off, @sizeOf(T));
    std.mem.writeInt(T, mem[e..][0..@sizeOf(T)], L(T, v)[lane], .little);
}

// ------------------------------------------------------------------ lane aritmetiği

fn addW(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = p.* +% q;
    return U(x);
}
fn subW(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = p.* -% q;
    return U(x);
}
fn mulW(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = p.* *% q;
    return U(x);
}
fn addSat(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = p.* +| q;
    return U(x);
}
fn subSat(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = p.* -| q;
    return U(x);
}
fn minL(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = @min(p.*, q);
    return U(x);
}
fn maxL(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = @max(p.*, q);
    return U(x);
}
fn avgr(comptime T: type, a: u128, b: u128) u128 {
    var x = L(T, a);
    const y = L(T, b);
    for (&x, y) |*p, q| p.* = @intCast((@as(u32, p.*) + @as(u32, q) + 1) >> 1);
    return U(x);
}
fn absL(comptime T: type, a: u128) u128 {
    var x = L(T, a);
    for (&x) |*p| p.* = if (p.* < 0) 0 -% p.* else p.*;
    return U(x);
}
fn negL(comptime T: type, a: u128) u128 {
    var x = L(T, a);
    for (&x) |*p| p.* = 0 -% p.*;
    return U(x);
}

const Cmp = enum { eq, ne, lt, gt, le, ge };

fn cmpLanes(comptime T: type, a: u128, b: u128, comptime op: Cmp) u128 {
    const R = UInt(T);
    const x = L(T, a);
    const y = L(T, b);
    var r: [x.len]R = undefined;
    for (&r, x, y) |*d, p, q| {
        const t = switch (op) {
            .eq => p == q,
            .ne => p != q,
            .lt => p < q,
            .gt => p > q,
            .le => p <= q,
            .ge => p >= q,
        };
        d.* = if (t) ~@as(R, 0) else 0;
    }
    return U(r);
}

/// `k`: 0 eq, 1 ne, 2 lt_s, 3 lt_u, 4 gt_s, 5 gt_u, 6 le_s, 7 le_u, 8 ge_s, 9 ge_u
fn icmp(comptime S: type, comptime Un: type, a: u128, b: u128, k: u32) u128 {
    return switch (k) {
        0 => cmpLanes(Un, a, b, .eq),
        1 => cmpLanes(Un, a, b, .ne),
        2 => cmpLanes(S, a, b, .lt),
        3 => cmpLanes(Un, a, b, .lt),
        4 => cmpLanes(S, a, b, .gt),
        5 => cmpLanes(Un, a, b, .gt),
        6 => cmpLanes(S, a, b, .le),
        7 => cmpLanes(Un, a, b, .le),
        8 => cmpLanes(S, a, b, .ge),
        else => cmpLanes(Un, a, b, .ge),
    };
}

fn fcmp(comptime F: type, a: u128, b: u128, k: u32) u128 {
    return switch (k) {
        0 => cmpLanes(F, a, b, .eq),
        1 => cmpLanes(F, a, b, .ne),
        2 => cmpLanes(F, a, b, .lt),
        3 => cmpLanes(F, a, b, .gt),
        4 => cmpLanes(F, a, b, .le),
        else => cmpLanes(F, a, b, .ge),
    };
}

fn satTo(comptime D: type, v: anytype) D {
    const lo = std.math.minInt(D);
    const hi = std.math.maxInt(D);
    return @intCast(@max(lo, @min(hi, v)));
}

fn narrow(comptime S: type, comptime D: type, a: u128, b: u128) u128 {
    const sa = L(S, a);
    const sb = L(S, b);
    var r: [16 / @sizeOf(D)]D = undefined;
    for (0..sa.len) |i| {
        r[i] = satTo(D, sa[i]);
        r[sa.len + i] = satTo(D, sb[i]);
    }
    return U(r);
}

fn extend(comptime S: type, comptime D: type, a: u128, high: bool) u128 {
    const s = L(S, a);
    var r: [s.len / 2]D = undefined;
    const off: usize = if (high) r.len else 0;
    for (&r, 0..) |*d, i| d.* = s[off + i];
    return U(r);
}

fn extmul(comptime S: type, comptime D: type, a: u128, b: u128, high: bool) u128 {
    const sa = L(S, a);
    const sb = L(S, b);
    var r: [sa.len / 2]D = undefined;
    const off: usize = if (high) r.len else 0;
    for (&r, 0..) |*d, i| d.* = @as(D, sa[off + i]) * @as(D, sb[off + i]);
    return U(r);
}

fn extadd(comptime S: type, comptime D: type, a: u128) u128 {
    const s = L(S, a);
    var r: [s.len / 2]D = undefined;
    for (&r, 0..) |*d, i| d.* = @as(D, s[2 * i]) + @as(D, s[2 * i + 1]);
    return U(r);
}

fn q15mulr(a: u128, b: u128) u128 {
    var x = L(i16, a);
    const y = L(i16, b);
    for (&x, y) |*p, q| {
        const prod = @as(i32, p.*) * @as(i32, q);
        p.* = satTo(i16, (prod + 0x4000) >> 15);
    }
    return U(x);
}

fn dot(a: u128, b: u128) u128 {
    const x = L(i16, a);
    const y = L(i16, b);
    var r: [4]i32 = undefined;
    for (&r, 0..) |*d, i| {
        const p0 = @as(i32, x[2 * i]) * @as(i32, y[2 * i]);
        const p1 = @as(i32, x[2 * i + 1]) * @as(i32, y[2 * i + 1]);
        d.* = p0 +% p1;
    }
    return U(r);
}

fn popcntL(a: u128) u128 {
    var x = L(u8, a);
    for (&x) |*p| p.* = @popCount(p.*);
    return U(x);
}

const FUn = enum { abs, neg, ceil, floor, trunc, nearest, sqrt };

fn fun(comptime F: type, a: u128, comptime which: FUn) u128 {
    const B = UInt(F);
    const sign: B = @as(B, 1) << (@bitSizeOf(F) - 1);
    var x = L(F, a);
    for (&x) |*e| {
        e.* = switch (which) {
            .abs => @bitCast(@as(B, @bitCast(e.*)) & ~sign),
            .neg => @bitCast(@as(B, @bitCast(e.*)) ^ sign),
            .ceil => @ceil(e.*),
            .floor => @floor(e.*),
            .trunc => @trunc(e.*),
            .nearest => interp.nearest(F, e.*),
            .sqrt => @sqrt(e.*),
        };
    }
    return U(x);
}

const FBin = enum { add, sub, mul, div, min, max, pmin, pmax };

fn fbin(comptime F: type, a: u128, b: u128, comptime which: FBin) u128 {
    var x = L(F, a);
    const y = L(F, b);
    for (&x, y) |*p, q| {
        p.* = switch (which) {
            .add => p.* + q,
            .sub => p.* - q,
            .mul => p.* * q,
            .div => p.* / q,
            .min => interp.fmin(F, p.*, q),
            .max => interp.fmax(F, p.*, q),
            .pmin => if (q < p.*) q else p.*,
            .pmax => if (p.* < q) q else p.*,
        };
    }
    return U(x);
}

fn convF32FromI(comptime I: type, a: u128) u128 {
    const s = L(I, a);
    var r: [4]f32 = undefined;
    for (&r, s) |*d, e| d.* = @floatFromInt(e);
    return U(r);
}

fn truncSatF32(comptime I: type, a: u128) u128 {
    const s = L(f32, a);
    var r: [4]I = undefined;
    for (&r, s) |*d, e| d.* = interp.truncSat(I, f32, e);
    return U(r);
}

fn truncSatF64Zero(comptime I: type, a: u128) u128 {
    const s = L(f64, a);
    var r: [4]I = .{ 0, 0, 0, 0 };
    r[0] = interp.truncSat(I, f64, s[0]);
    r[1] = interp.truncSat(I, f64, s[1]);
    return U(r);
}

fn convLowF64(comptime I: type, a: u128) u128 {
    const s = L(I, a);
    var r: [2]f64 = undefined;
    r[0] = @floatFromInt(s[0]);
    r[1] = @floatFromInt(s[1]);
    return U(r);
}

fn demote(a: u128) u128 {
    const s = L(f64, a);
    var r: [4]f32 = .{ 0, 0, 0, 0 };
    r[0] = @floatCast(s[0]);
    r[1] = @floatCast(s[1]);
    return U(r);
}

fn promote(a: u128) u128 {
    const s = L(f32, a);
    var r: [2]f64 = undefined;
    r[0] = s[0];
    r[1] = s[1];
    return U(r);
}

fn shl(comptime T: type, a: u128, c: u32) u128 {
    var x = L(T, a);
    const s: std.math.Log2Int(T) = @intCast(c % @bitSizeOf(T));
    for (&x) |*p| p.* = p.* << s;
    return U(x);
}
fn shr(comptime T: type, a: u128, c: u32) u128 {
    var x = L(T, a);
    const s: std.math.Log2Int(T) = @intCast(c % @bitSizeOf(T));
    for (&x) |*p| p.* = p.* >> s;
    return U(x);
}

fn allTrue(comptime T: type, a: u128) u32 {
    for (L(T, a)) |e| if (e == 0) return 0;
    return 1;
}

fn bitmask(comptime T: type, a: u128) u32 {
    var m: u32 = 0;
    for (L(T, a), 0..) |e, i| {
        if ((e >> (@bitSizeOf(T) - 1)) != 0) m |= @as(u32, 1) << @intCast(i);
    }
    return m;
}

fn swizzle(a: u128, idx: u128) u128 {
    const x = L(u8, a);
    var r = L(u8, idx);
    for (&r) |*p| p.* = if (p.* < 16) x[p.*] else 0;
    return U(r);
}

fn shuffle(a: u128, b: u128, mask: u128) u128 {
    const x = L(u8, a);
    const y = L(u8, b);
    var r = L(u8, mask);
    for (&r) |*p| p.* = if (p.* < 16) x[p.*] else y[p.* - 16];
    return U(r);
}

// ------------------------------------------------------------------ sınıf yürütücüleri

fn unop(sub: u32, a: u128) u128 {
    return switch (sub) {
        0x4d => ~a,
        0x5e => demote(a),
        0x5f => promote(a),
        0x60 => absL(i8, a),
        0x61 => negL(i8, a),
        0x62 => popcntL(a),
        0x67 => fun(f32, a, .ceil),
        0x68 => fun(f32, a, .floor),
        0x69 => fun(f32, a, .trunc),
        0x6a => fun(f32, a, .nearest),
        0x74 => fun(f64, a, .ceil),
        0x75 => fun(f64, a, .floor),
        0x7a => fun(f64, a, .trunc),
        0x94 => fun(f64, a, .nearest),
        0x7c => extadd(i8, i16, a),
        0x7d => extadd(u8, u16, a),
        0x7e => extadd(i16, i32, a),
        0x7f => extadd(u16, u32, a),
        0x80 => absL(i16, a),
        0x81 => negL(i16, a),
        0x87 => extend(i8, i16, a, false),
        0x88 => extend(i8, i16, a, true),
        0x89 => extend(u8, u16, a, false),
        0x8a => extend(u8, u16, a, true),
        0xa0 => absL(i32, a),
        0xa1 => negL(i32, a),
        0xa7 => extend(i16, i32, a, false),
        0xa8 => extend(i16, i32, a, true),
        0xa9 => extend(u16, u32, a, false),
        0xaa => extend(u16, u32, a, true),
        0xc0 => absL(i64, a),
        0xc1 => negL(i64, a),
        0xc7 => extend(i32, i64, a, false),
        0xc8 => extend(i32, i64, a, true),
        0xc9 => extend(u32, u64, a, false),
        0xca => extend(u32, u64, a, true),
        0xe0 => fun(f32, a, .abs),
        0xe1 => fun(f32, a, .neg),
        0xe3 => fun(f32, a, .sqrt),
        0xec => fun(f64, a, .abs),
        0xed => fun(f64, a, .neg),
        0xef => fun(f64, a, .sqrt),
        0xf8 => truncSatF32(i32, a),
        0xf9 => truncSatF32(u32, a),
        0xfa => convF32FromI(i32, a),
        0xfb => convF32FromI(u32, a),
        0xfc => truncSatF64Zero(i32, a),
        0xfd => truncSatF64Zero(u32, a),
        0xfe => convLowF64(i32, a),
        else => convLowF64(u32, a), // 0xff
    };
}

fn binop(sub: u32, a: u128, b: u128) u128 {
    return switch (sub) {
        0x0e => swizzle(a, b),
        0x23...0x2c => icmp(i8, u8, a, b, sub - 0x23),
        0x2d...0x36 => icmp(i16, u16, a, b, sub - 0x2d),
        0x37...0x40 => icmp(i32, u32, a, b, sub - 0x37),
        0x41...0x46 => fcmp(f32, a, b, sub - 0x41),
        0x47...0x4c => fcmp(f64, a, b, sub - 0x47),
        0x4e => a & b,
        0x4f => a & ~b,
        0x50 => a | b,
        0x51 => a ^ b,
        0x65 => narrow(i16, i8, a, b),
        0x66 => narrow(i16, u8, a, b),
        0x6e => addW(u8, a, b),
        0x6f => addSat(i8, a, b),
        0x70 => addSat(u8, a, b),
        0x71 => subW(u8, a, b),
        0x72 => subSat(i8, a, b),
        0x73 => subSat(u8, a, b),
        0x76 => minL(i8, a, b),
        0x77 => minL(u8, a, b),
        0x78 => maxL(i8, a, b),
        0x79 => maxL(u8, a, b),
        0x7b => avgr(u8, a, b),
        0x82 => q15mulr(a, b),
        0x85 => narrow(i32, i16, a, b),
        0x86 => narrow(i32, u16, a, b),
        0x8e => addW(u16, a, b),
        0x8f => addSat(i16, a, b),
        0x90 => addSat(u16, a, b),
        0x91 => subW(u16, a, b),
        0x92 => subSat(i16, a, b),
        0x93 => subSat(u16, a, b),
        0x95 => mulW(u16, a, b),
        0x96 => minL(i16, a, b),
        0x97 => minL(u16, a, b),
        0x98 => maxL(i16, a, b),
        0x99 => maxL(u16, a, b),
        0x9b => avgr(u16, a, b),
        0x9c => extmul(i8, i16, a, b, false),
        0x9d => extmul(i8, i16, a, b, true),
        0x9e => extmul(u8, u16, a, b, false),
        0x9f => extmul(u8, u16, a, b, true),
        0xae => addW(u32, a, b),
        0xb1 => subW(u32, a, b),
        0xb5 => mulW(u32, a, b),
        0xb6 => minL(i32, a, b),
        0xb7 => minL(u32, a, b),
        0xb8 => maxL(i32, a, b),
        0xb9 => maxL(u32, a, b),
        0xba => dot(a, b),
        0xbc => extmul(i16, i32, a, b, false),
        0xbd => extmul(i16, i32, a, b, true),
        0xbe => extmul(u16, u32, a, b, false),
        0xbf => extmul(u16, u32, a, b, true),
        0xce => addW(u64, a, b),
        0xd1 => subW(u64, a, b),
        0xd5 => mulW(u64, a, b),
        0xd6 => cmpLanes(u64, a, b, .eq),
        0xd7 => cmpLanes(u64, a, b, .ne),
        0xd8 => cmpLanes(i64, a, b, .lt),
        0xd9 => cmpLanes(i64, a, b, .gt),
        0xda => cmpLanes(i64, a, b, .le),
        0xdb => cmpLanes(i64, a, b, .ge),
        0xdc => extmul(i32, i64, a, b, false),
        0xdd => extmul(i32, i64, a, b, true),
        0xde => extmul(u32, u64, a, b, false),
        0xdf => extmul(u32, u64, a, b, true),
        0xe4 => fbin(f32, a, b, .add),
        0xe5 => fbin(f32, a, b, .sub),
        0xe6 => fbin(f32, a, b, .mul),
        0xe7 => fbin(f32, a, b, .div),
        0xe8 => fbin(f32, a, b, .min),
        0xe9 => fbin(f32, a, b, .max),
        0xea => fbin(f32, a, b, .pmin),
        0xeb => fbin(f32, a, b, .pmax),
        0xf0 => fbin(f64, a, b, .add),
        0xf1 => fbin(f64, a, b, .sub),
        0xf2 => fbin(f64, a, b, .mul),
        0xf3 => fbin(f64, a, b, .div),
        0xf4 => fbin(f64, a, b, .min),
        0xf5 => fbin(f64, a, b, .max),
        0xf6 => fbin(f64, a, b, .pmin),
        else => fbin(f64, a, b, .pmax), // 0xf7
    };
}

fn testop(sub: u32, a: u128) u32 {
    return switch (sub) {
        0x53 => @intFromBool(a != 0),
        0x63 => allTrue(u8, a),
        0x64 => bitmask(u8, a),
        0x83 => allTrue(u16, a),
        0x84 => bitmask(u16, a),
        0xa3 => allTrue(u32, a),
        0xa4 => bitmask(u32, a),
        0xc3 => allTrue(u64, a),
        else => bitmask(u64, a), // 0xc4
    };
}

fn shiftop(sub: u32, a: u128, c: u32) u128 {
    return switch (sub) {
        0x6b => shl(u8, a, c),
        0x6c => shr(i8, a, c),
        0x6d => shr(u8, a, c),
        0x8b => shl(u16, a, c),
        0x8c => shr(i16, a, c),
        0x8d => shr(u16, a, c),
        0xab => shl(u32, a, c),
        0xac => shr(i32, a, c),
        0xad => shr(u32, a, c),
        0xcb => shl(u64, a, c),
        0xcc => shr(i64, a, c),
        else => shr(u64, a, c), // 0xcd
    };
}

fn splatop(sub: u32, x: u64) u128 {
    return switch (sub) {
        0x0f => splatN(u8, @truncate(x)),
        0x10 => splatN(u16, @truncate(x)),
        0x11, 0x13 => splatN(u32, @truncate(x)),
        else => splatN(u64, x), // 0x12, 0x14
    };
}

fn extractop(sub: u32, lane: u32, a: u128) u64 {
    return switch (sub) {
        0x15 => @as(u32, @bitCast(@as(i32, L(i8, a)[lane]))),
        0x16 => L(u8, a)[lane],
        0x18 => @as(u32, @bitCast(@as(i32, L(i16, a)[lane]))),
        0x19 => L(u16, a)[lane],
        0x1b, 0x1f => L(u32, a)[lane],
        else => L(u64, a)[lane], // 0x1d, 0x21
    };
}

fn replaceop(sub: u32, lane: u32, a: u128, x: u64) u128 {
    switch (sub) {
        0x17 => {
            var r = L(u8, a);
            r[lane] = @truncate(x);
            return U(r);
        },
        0x1a => {
            var r = L(u16, a);
            r[lane] = @truncate(x);
            return U(r);
        },
        0x1c, 0x20 => {
            var r = L(u32, a);
            r[lane] = @truncate(x);
            return U(r);
        },
        else => { // 0x1e, 0x22
            var r = L(u64, a);
            r[lane] = x;
            return U(r);
        },
    }
}

/// Bir SIMD komutunu yürütür; yeni `sp`yi döndürür. `kind` derleyicinin `Instr.arity` alanına yazdığı `Kind`, `a`/`b` anlık değerlerdir
/// (bellek ofseti | lane | sabit havuzu indeksi / lane).
pub fn exec(
    mem: []u8,
    kind: Kind,
    sub: u32,
    a_imm: u32,
    b_imm: u64,
    consts: []const u128,
    stack: []u64,
    vstack: []u128,
    sp0: usize,
) Trap!usize {
    var sp = sp0;
    switch (kind) {
        .load => vstack[sp - 1] = try loadOp(sub, mem, stack[sp - 1], a_imm),
        .store => {
            sp -= 2;
            const e = try ea(mem, stack[sp], a_imm, 16);
            std.mem.writeInt(u128, mem[e..][0..16], vstack[sp + 1], .little);
        },
        .vconst => {
            vstack[sp] = consts[a_imm];
            sp += 1;
        },
        .shuffle => {
            sp -= 1;
            vstack[sp - 1] = shuffle(vstack[sp - 1], vstack[sp], consts[a_imm]);
        },
        .unary => vstack[sp - 1] = unop(sub, vstack[sp - 1]),
        .binary => {
            sp -= 1;
            vstack[sp - 1] = binop(sub, vstack[sp - 1], vstack[sp]);
        },
        .ternary => {
            sp -= 2;
            const v1 = vstack[sp - 1];
            const v2 = vstack[sp];
            const c = vstack[sp + 1];
            vstack[sp - 1] = (v1 & c) | (v2 & ~c);
        },
        .test_ => stack[sp - 1] = testop(sub, vstack[sp - 1]),
        .shift => {
            sp -= 1;
            vstack[sp - 1] = shiftop(sub, vstack[sp - 1], @truncate(stack[sp]));
        },
        .splat => vstack[sp - 1] = splatop(sub, stack[sp - 1]),
        .extract => stack[sp - 1] = extractop(sub, a_imm, vstack[sp - 1]),
        .replace => {
            sp -= 1;
            vstack[sp - 1] = replaceop(sub, a_imm, vstack[sp - 1], stack[sp]);
        },
        .load_lane => {
            sp -= 1;
            const lane: usize = @intCast(b_imm);
            vstack[sp - 1] = switch (sub) {
                0x54 => try loadLaneT(u8, mem, stack[sp - 1], a_imm, vstack[sp], lane),
                0x55 => try loadLaneT(u16, mem, stack[sp - 1], a_imm, vstack[sp], lane),
                0x56 => try loadLaneT(u32, mem, stack[sp - 1], a_imm, vstack[sp], lane),
                else => try loadLaneT(u64, mem, stack[sp - 1], a_imm, vstack[sp], lane),
            };
        },
        .store_lane => {
            sp -= 2;
            const lane: usize = @intCast(b_imm);
            switch (sub) {
                0x58 => try storeLaneT(u8, mem, stack[sp], a_imm, vstack[sp + 1], lane),
                0x59 => try storeLaneT(u16, mem, stack[sp], a_imm, vstack[sp + 1], lane),
                0x5a => try storeLaneT(u32, mem, stack[sp], a_imm, vstack[sp + 1], lane),
                else => try storeLaneT(u64, mem, stack[sp], a_imm, vstack[sp + 1], lane),
            }
        },
    }
    return sp;
}
