//! `nox.bigint` Zig kabuğu (v2.1.66): keyfi hassasiyetli tamsayı. Değer, Nox tarafında değişmez bir `str` olarak taşınır (ARC/ömür sorunu yok, `__del__` gerekmez):
//!   bayt 0 = işaret (0 = sıfır ya da pozitif, 1 = negatif), kalan baytlar büyüklüğün küçük-endian ikili temsili (sondaki sıfır baytlar atılır; sıfır = yalnızca işaret baytı).
//! Hiçbir geçerli değer boş değildir: işlevler hata durumunda (sıfıra bölme, geçersiz üs/taban/ayrıştırma) sabit BOŞ `str` döner ve `nox.bigint` bunu `nox_bigint_is_error` ile ayırır.
//! Hesaplama `std.math.big.int.Managed` ile yapılır; geçici bellek her çağrıda tek bir arenadan alınır (`shim_util.scratchAllocator()`: hosted/wasm'da page_allocator,
//! çıplak çekirdekte çekirdeğin allocator'ı) — OS/libc bağımlılığı yoktur, freestanding'de de bağlanır.

const std = @import("std");
const big = std.math.big.int;
const shim_util = @import("shim_util.zig");
const str_mod = @import("../str.zig");

const Managed = big.Managed;
const Const = big.Const;
const Limb = std.math.big.Limb;

const Arena = struct {
    inner: std.heap.ArenaAllocator,

    fn init() Arena {
        return .{ .inner = std.heap.ArenaAllocator.init(shim_util.scratchAllocator()) };
    }
    fn deinit(self: *Arena) void {
        self.inner.deinit();
    }
    fn alloc(self: *Arena) std.mem.Allocator {
        return self.inner.allocator();
    }
};

const Err = error{ Invalid, OutOfMemory };

/// Serileştirilmiş değerden `Managed` kurar.
fn load(a: std.mem.Allocator, s: []const u8) Err!Managed {
    if (s.len == 0) return error.Invalid;
    var m = try Managed.init(a);
    errdefer m.deinit();
    const mag = s[1..];
    const nlimbs = (mag.len + @sizeOf(Limb) - 1) / @sizeOf(Limb);
    if (nlimbs == 0) return m;
    const limbs = try a.alloc(Limb, nlimbs);
    defer a.free(limbs);
    @memset(limbs, 0);
    for (mag, 0..) |b, i| limbs[i / @sizeOf(Limb)] |= @as(Limb, b) << @intCast((i % @sizeOf(Limb)) * 8);
    var len = nlimbs;
    while (len > 1 and limbs[len - 1] == 0) len -= 1;
    const is_zero = len == 1 and limbs[0] == 0;
    try m.copy(.{ .limbs = limbs[0..len], .positive = s[0] == 0 or is_zero });
    return m;
}

/// `Managed`i serileştirir (kanonik: sondaki sıfır baytlar atılır, sıfır pozitiftir).
fn store(rt: ?*anyopaque, m: Managed) ?[*:0]u8 {
    const limbs = m.limbs[0..m.len()];
    var total: usize = 0;
    if (!m.eqlZero()) {
        const top = limbs[limbs.len - 1];
        const top_bytes = (@bitSizeOf(Limb) - @clz(top) + 7) / 8;
        total = (limbs.len - 1) * @sizeOf(Limb) + top_bytes;
    }
    const buf = str_mod.nox_str_alloc_buf(rt, total + 1) orelse return null;
    buf[0] = if (m.isPositive() or total == 0) 0 else 1;
    var n: usize = 0;
    outer: for (limbs) |l| {
        var k: usize = 0;
        while (k < @sizeOf(Limb)) : (k += 1) {
            if (n >= total) break :outer;
            buf[1 + n] = @truncate(l >> @intCast(k * 8));
            n += 1;
        }
    }
    return @ptrCast(buf);
}

fn errStr() ?[*:0]u8 {
    return @constCast(str_mod.nox_empty_str());
}

fn bytesOf(p: ?[*:0]const u8) []const u8 {
    return str_mod.nox_str_slice(p orelse return &.{});
}

fn finish(rt: ?*anyopaque, r: Err!Managed) ?[*:0]u8 {
    var m = r catch return errStr();
    defer m.deinit();
    return store(rt, m);
}

pub export fn nox_bigint_is_error(s: ?[*:0]const u8) callconv(.c) i64 {
    return @intFromBool(bytesOf(s).len == 0);
}

pub export fn nox_bigint_from_i64(rt: ?*anyopaque, v: i64) callconv(.c) ?[*:0]u8 {
    var ar = Arena.init();
    defer ar.deinit();
    var m = Managed.initSet(ar.alloc(), v) catch return errStr();
    defer m.deinit();
    return store(rt, m);
}

pub export fn nox_bigint_fits_i64(s: ?[*:0]const u8) callconv(.c) i64 {
    var ar = Arena.init();
    defer ar.deinit();
    var m = load(ar.alloc(), bytesOf(s)) catch return 0;
    defer m.deinit();
    return @intFromBool(m.fits(i64));
}

pub export fn nox_bigint_to_i64(s: ?[*:0]const u8) callconv(.c) i64 {
    var ar = Arena.init();
    defer ar.deinit();
    var m = load(ar.alloc(), bytesOf(s)) catch return 0;
    defer m.deinit();
    return m.toInt(i64) catch 0;
}

/// Python `int(s, base)` benzeri: isteğe bağlı işaret, `_` ayırıcıları, taban 2..36. Boş/geçersiz girdide hata.
pub export fn nox_bigint_parse_raw(rt: ?*anyopaque, s: ?[*:0]const u8, base: i64) callconv(.c) ?[*:0]u8 {
    const txt = bytesOf(s);
    if (txt.len == 0 or base < 2 or base > 36) return errStr();
    var ar = Arena.init();
    defer ar.deinit();
    var body = txt;
    var neg = false;
    if (body[0] == '+' or body[0] == '-') {
        neg = body[0] == '-';
        body = body[1..];
    }
    var digits: usize = 0;
    for (body) |c| {
        if (c == '_') continue;
        digits += 1;
    }
    if (digits == 0) return errStr();
    var m = Managed.init(ar.alloc()) catch return errStr();
    defer m.deinit();
    m.setString(@intCast(base), body) catch return errStr();
    if (neg and !m.eqlZero()) m.negate();
    return store(rt, m);
}

pub export fn nox_bigint_to_string(rt: ?*anyopaque, s: ?[*:0]const u8, base: i64) callconv(.c) ?[*:0]u8 {
    if (base < 2 or base > 36) return errStr();
    var ar = Arena.init();
    defer ar.deinit();
    var m = load(ar.alloc(), bytesOf(s)) catch return errStr();
    defer m.deinit();
    const txt = m.toString(ar.alloc(), @intCast(base), .lower) catch return errStr();
    return str_mod.nox_str_from_bytes(rt, txt);
}

/// Öklid algoritması (`Managed.gcd` Lehmer uygulaması bazı girdilerde dizin taşması veriyor; bu yüzden kendi döngümüz). r = gcd(|x|, |y|).
fn gcdEuclid(al: std.mem.Allocator, r: *Managed, x: *Managed, y: *Managed) !void {
    var a = try x.clone();
    defer a.deinit();
    var b = try y.clone();
    defer b.deinit();
    a.abs();
    b.abs();
    var q = try Managed.init(al);
    defer q.deinit();
    var rem = try Managed.init(al);
    defer rem.deinit();
    while (!b.eqlZero()) {
        try q.divFloor(&rem, &a, &b);
        try a.copy(b.toConst());
        try b.copy(rem.toConst());
    }
    try r.copy(a.toConst());
}

/// Sonsuz uzunlukta ikili tümleyen anlamıyla (Python gibi) `&`, `|`, `^`. `Managed.bitOr` karışık işaretli/farklı uzunlukta bazı girdilerde yanlış sonuç veriyor.
fn bitwise(al: std.mem.Allocator, r: *Managed, x: *const Managed, y: *const Managed, comptime op: enum { bit_and, bit_or, bit_xor }) !void {
    const n = @max(x.len(), y.len()) + 1;
    const tx = try twosComp(al, x, n);
    defer al.free(tx);
    const ty = try twosComp(al, y, n);
    defer al.free(ty);
    for (tx, ty) |*a, b| a.* = switch (op) {
        .bit_and => a.* & b,
        .bit_or => a.* | b,
        .bit_xor => a.* ^ b,
    };
    const neg = tx[n - 1] >> (@bitSizeOf(Limb) - 1) == 1;
    if (neg) {
        // büyüklük = ~sonuç + 1
        for (tx) |*a| a.* = ~a.*;
        var carry: Limb = 1;
        for (tx) |*a| {
            const sum = @addWithOverflow(a.*, carry);
            a.* = sum[0];
            carry = sum[1];
        }
    }
    var len = n;
    while (len > 1 and tx[len - 1] == 0) len -= 1;
    try r.copy(.{ .limbs = tx[0..len], .positive = !neg });
}

/// `n` uzuvluklu iki-tümleyen limb dizisi (negatifler işaret-genişletilmiş).
fn twosComp(al: std.mem.Allocator, v: *const Managed, n: usize) ![]Limb {
    const out = try al.alloc(Limb, n);
    @memset(out, 0);
    const src = v.limbs[0..v.len()];
    @memcpy(out[0..src.len], src);
    if (!v.isPositive() and !v.eqlZero()) {
        for (out) |*a| a.* = ~a.*;
        var carry: Limb = 1;
        for (out) |*a| {
            const sum = @addWithOverflow(a.*, carry);
            a.* = sum[0];
            carry = sum[1];
        }
    }
    return out;
}

fn binary(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8, comptime op: enum { add, sub, mul, gcd, bit_and, bit_or, bit_xor }) ?[*:0]u8 {
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var x = load(al, bytesOf(a)) catch return errStr();
    defer x.deinit();
    var y = load(al, bytesOf(b)) catch return errStr();
    defer y.deinit();
    var r = Managed.init(al) catch return errStr();
    defer r.deinit();
    switch (op) {
        .add => r.add(&x, &y) catch return errStr(),
        .sub => r.sub(&x, &y) catch return errStr(),
        .mul => r.mul(&x, &y) catch return errStr(),
        .gcd => gcdEuclid(al, &r, &x, &y) catch return errStr(),
        .bit_and => bitwise(al, &r, &x, &y, .bit_and) catch return errStr(),
        .bit_or => bitwise(al, &r, &x, &y, .bit_or) catch return errStr(),
        .bit_xor => bitwise(al, &r, &x, &y, .bit_xor) catch return errStr(),
    }
    return store(rt, r);
}

pub export fn nox_bigint_add(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return binary(rt, a, b, .add);
}
pub export fn nox_bigint_sub(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return binary(rt, a, b, .sub);
}
pub export fn nox_bigint_mul(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return binary(rt, a, b, .mul);
}
pub export fn nox_bigint_gcd(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return binary(rt, a, b, .gcd);
}
pub export fn nox_bigint_and(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return binary(rt, a, b, .bit_and);
}
pub export fn nox_bigint_or(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return binary(rt, a, b, .bit_or);
}
pub export fn nox_bigint_xor(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return binary(rt, a, b, .bit_xor);
}

/// Taban (floor) bölme: `want_rem` yanlışsa bölüm, doğruysa kalan döner (Python `//` ve `%`: kalan bölenin işaretini taşır). Sıfıra bölmede hata.
fn divide(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8, want_rem: bool) ?[*:0]u8 {
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var x = load(al, bytesOf(a)) catch return errStr();
    defer x.deinit();
    var y = load(al, bytesOf(b)) catch return errStr();
    defer y.deinit();
    if (y.eqlZero()) return errStr();
    var q = Managed.init(al) catch return errStr();
    defer q.deinit();
    var r = Managed.init(al) catch return errStr();
    defer r.deinit();
    q.divFloor(&r, &x, &y) catch return errStr();
    return store(rt, if (want_rem) r else q);
}

pub export fn nox_bigint_floordiv(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return divide(rt, a, b, false);
}
pub export fn nox_bigint_mod(rt: ?*anyopaque, a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    return divide(rt, a, b, true);
}

pub export fn nox_bigint_neg(rt: ?*anyopaque, a: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    var ar = Arena.init();
    defer ar.deinit();
    var x = load(ar.alloc(), bytesOf(a)) catch return errStr();
    defer x.deinit();
    if (!x.eqlZero()) x.negate();
    return store(rt, x);
}

pub export fn nox_bigint_abs(rt: ?*anyopaque, a: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    var ar = Arena.init();
    defer ar.deinit();
    var x = load(ar.alloc(), bytesOf(a)) catch return errStr();
    defer x.deinit();
    x.abs();
    return store(rt, x);
}

/// -1, 0 ya da 1.
pub export fn nox_bigint_cmp(a: ?[*:0]const u8, b: ?[*:0]const u8) callconv(.c) i64 {
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var x = load(al, bytesOf(a)) catch return 0;
    defer x.deinit();
    var y = load(al, bytesOf(b)) catch return 0;
    defer y.deinit();
    return switch (x.order(y)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub export fn nox_bigint_sign(a: ?[*:0]const u8) callconv(.c) i64 {
    const s = bytesOf(a);
    if (s.len <= 1) return 0;
    return if (s[0] == 0) 1 else -1;
}

pub export fn nox_bigint_pow(rt: ?*anyopaque, a: ?[*:0]const u8, e: i64) callconv(.c) ?[*:0]u8 {
    if (e < 0 or e > std.math.maxInt(u32)) return errStr();
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var x = load(al, bytesOf(a)) catch return errStr();
    defer x.deinit();
    var r = Managed.init(al) catch return errStr();
    defer r.deinit();
    r.pow(&x, @intCast(e)) catch return errStr();
    return store(rt, r);
}

/// `base ** exp mod m` (m > 0, exp >= 0); sonuç `[0, m)` aralığında.
pub export fn nox_bigint_powmod(rt: ?*anyopaque, a: ?[*:0]const u8, e: ?[*:0]const u8, m: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var base = load(al, bytesOf(a)) catch return errStr();
    defer base.deinit();
    var ex = load(al, bytesOf(e)) catch return errStr();
    defer ex.deinit();
    var md = load(al, bytesOf(m)) catch return errStr();
    defer md.deinit();
    if (!ex.isPositive() and !ex.eqlZero()) return errStr();
    if (!md.isPositive() or md.eqlZero()) return errStr();
    var result = Managed.initSet(al, 1) catch return errStr();
    defer result.deinit();
    var q = Managed.init(al) catch return errStr();
    defer q.deinit();
    var tmp = Managed.init(al) catch return errStr();
    defer tmp.deinit();
    // base %= m
    q.divFloor(&tmp, &base, &md) catch return errStr();
    base.copy(tmp.toConst()) catch return errStr();
    // result %= m (m == 1 ise sonuç 0)
    q.divFloor(&tmp, &result, &md) catch return errStr();
    result.copy(tmp.toConst()) catch return errStr();
    const bits = ex.bitCountAbs();
    var i: usize = 0;
    while (i < bits) : (i += 1) {
        if (ex.toConst().limbs[i / @bitSizeOf(Limb)] >> @intCast(i % @bitSizeOf(Limb)) & 1 == 1) {
            tmp.mul(&result, &base) catch return errStr();
            q.divFloor(&result, &tmp, &md) catch return errStr();
        }
        tmp.sqr(&base) catch return errStr();
        q.divFloor(&base, &tmp, &md) catch return errStr();
    }
    return store(rt, result);
}

pub export fn nox_bigint_shl(rt: ?*anyopaque, a: ?[*:0]const u8, n: i64) callconv(.c) ?[*:0]u8 {
    if (n < 0 or n > (1 << 31)) return errStr();
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var x = load(al, bytesOf(a)) catch return errStr();
    defer x.deinit();
    var r = Managed.init(al) catch return errStr();
    defer r.deinit();
    r.shiftLeft(&x, @intCast(n)) catch return errStr();
    return store(rt, r);
}

/// Aritmetik (taban) sağa kaydırma: Python `>>` gibi negatif değerler -inf'e yuvarlanır.
pub export fn nox_bigint_shr(rt: ?*anyopaque, a: ?[*:0]const u8, n: i64) callconv(.c) ?[*:0]u8 {
    if (n < 0) return errStr();
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var x = load(al, bytesOf(a)) catch return errStr();
    defer x.deinit();
    var r = Managed.init(al) catch return errStr();
    defer r.deinit();
    r.shiftRight(&x, @intCast(@min(n, std.math.maxInt(u32)))) catch return errStr();
    return store(rt, r);
}

pub export fn nox_bigint_bit_length(a: ?[*:0]const u8) callconv(.c) i64 {
    var ar = Arena.init();
    defer ar.deinit();
    var x = load(ar.alloc(), bytesOf(a)) catch return 0;
    defer x.deinit();
    return @intCast(x.bitCountAbs());
}

pub export fn nox_bigint_isqrt(rt: ?*anyopaque, a: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var x = load(al, bytesOf(a)) catch return errStr();
    defer x.deinit();
    if (!x.isPositive() and !x.eqlZero()) return errStr();
    var r = Managed.init(al) catch return errStr();
    defer r.deinit();
    r.sqrt(&x) catch return errStr();
    return store(rt, r);
}

pub export fn nox_bigint_is_odd(a: ?[*:0]const u8) callconv(.c) i64 {
    const s = bytesOf(a);
    return @intFromBool(s.len > 1 and s[1] & 1 == 1);
}

/// FNV-1a: eşit değerler (kanonik temsil) eşit özet verir.
pub export fn nox_bigint_hash(a: ?[*:0]const u8) callconv(.c) i64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytesOf(a)) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return @bitCast(h & 0x7fff_ffff_ffff_ffff);
}

/// Miller-Rabin: ilk 12 asal taban (n < 3.3e24 için kesin), `rounds` fazladan sabit-türetilmiş taban (büyük n için olasılıksal). 1 = muhtemelen asal.
pub export fn nox_bigint_is_probable_prime(a: ?[*:0]const u8, extra_rounds: i64) callconv(.c) i64 {
    var ar = Arena.init();
    defer ar.deinit();
    const al = ar.alloc();
    var n = load(al, bytesOf(a)) catch return 0;
    defer n.deinit();
    if (!n.isPositive() or n.eqlZero()) return 0;
    if (n.fits(u64)) {
        const v = n.toInt(u64) catch return 0;
        if (v < 2) return 0;
        for ([_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 }) |p| {
            if (v == p) return 1;
            if (v % p == 0) return 0;
        }
    } else if (n.isEven()) return 0;
    // n - 1 = d * 2^s
    var nm1 = Managed.initSet(al, 1) catch return 0;
    defer nm1.deinit();
    var one = Managed.initSet(al, 1) catch return 0;
    defer one.deinit();
    nm1.sub(&n, &one) catch return 0;
    var s: usize = 0;
    var d = nm1.clone() catch return 0;
    defer d.deinit();
    var tmp0 = Managed.init(al) catch return 0;
    defer tmp0.deinit();
    while (d.isEven() and !d.eqlZero()) {
        tmp0.shiftRight(&d, 1) catch return 0;
        d.copy(tmp0.toConst()) catch return 0;
        s += 1;
    }
    var bases: [12 + 64]u64 = undefined;
    const fixed = [_]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37 };
    @memcpy(bases[0..12], &fixed);
    const extra: usize = @intCast(@min(@max(extra_rounds, 0), 64));
    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15 ^ @as(u64, @intCast(n.bitCountAbs())));
    for (0..extra) |i| bases[12 + i] = prng.random().int(u64) | 2;
    var x = Managed.init(al) catch return 0;
    defer x.deinit();
    var tmp = Managed.init(al) catch return 0;
    defer tmp.deinit();
    var q = Managed.init(al) catch return 0;
    defer q.deinit();
    var base = Managed.init(al) catch return 0;
    defer base.deinit();
    for (bases[0 .. 12 + extra]) |bv| {
        base.set(bv) catch return 0;
        q.divFloor(&tmp, &base, &n) catch return 0;
        if (tmp.eqlZero()) continue;
        base.copy(tmp.toConst()) catch return 0;
        // x = base ** d mod n (soldan-sağa kare-çarp)
        x.set(1) catch return 0;
        var i: usize = d.bitCountAbs();
        while (i > 0) {
            i -= 1;
            tmp.sqr(&x) catch return 0;
            q.divFloor(&x, &tmp, &n) catch return 0;
            if (d.toConst().limbs[i / @bitSizeOf(Limb)] >> @intCast(i % @bitSizeOf(Limb)) & 1 == 1) {
                tmp.mul(&x, &base) catch return 0;
                q.divFloor(&x, &tmp, &n) catch return 0;
            }
        }
        if (x.toConst().order(one.toConst()) == .eq or x.toConst().order(nm1.toConst()) == .eq) continue;
        var composite = true;
        var r: usize = 1;
        while (r < s) : (r += 1) {
            tmp.sqr(&x) catch return 0;
            q.divFloor(&x, &tmp, &n) catch return 0;
            if (x.toConst().order(nm1.toConst()) == .eq) {
                composite = false;
                break;
            }
        }
        if (composite) return 0;
    }
    return 1;
}

// ---------------------------------------------------------------- testler

fn testRt() ?*anyopaque {
    return @import("../alloc/asap.zig").nox_runtime_init();
}

/// Testlerde üretilen `str`leri izleyip sonda bırakır (sızıntı denetimi).
const Bag = struct {
    rt: ?*anyopaque,
    items: std.ArrayList([*:0]u8) = .empty,

    fn deinit(self: *Bag) void {
        for (self.items.items) |p| str_mod.nox_str_release(self.rt, p);
        self.items.deinit(std.testing.allocator);
    }
    fn keep(self: *Bag, p: ?[*:0]u8) [*:0]u8 {
        const q = p.?;
        self.items.append(std.testing.allocator, q) catch unreachable;
        return q;
    }
    fn dec(self: *Bag, txt: []const u8) [*:0]u8 {
        return self.keep(nox_bigint_parse_raw(self.rt, self.keep(str_mod.nox_str_from_bytes(self.rt, txt)), 10));
    }
    fn int(self: *Bag, v: i64) [*:0]u8 {
        return self.keep(nox_bigint_from_i64(self.rt, v));
    }
    fn show(self: *Bag, v: [*:0]const u8) []const u8 {
        return str_mod.nox_str_slice(self.keep(nox_bigint_to_string(self.rt, v, 10)));
    }
};

test "bigint: ayrıştırma, yazdırma, aritmetik (Python referans değerleri)" {
    const asap = @import("../alloc/asap.zig");
    const rt = testRt() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    var g: Bag = .{ .rt = rt };
    defer g.deinit();
    const a = g.dec("123456789012345678901234567890");
    const b = g.dec("-987654321098765432109876543210");
    try std.testing.expectEqualStrings("-864197532086419753208641975320", g.show(g.keep(nox_bigint_add(rt, a, b))));
    try std.testing.expectEqualStrings("-121932631137021795226185032733622923332237463801111263526900", g.show(g.keep(nox_bigint_mul(rt, a, b))));
    try std.testing.expectEqualStrings("1111111110111111111011111111100", g.show(g.keep(nox_bigint_sub(rt, a, b))));
    // taban bölme/kalan: Python (-7) // 2 == -4, (-7) % 2 == 1; 7 // -2 == -4, 7 % -2 == -1
    const m7 = g.int(-7);
    const two = g.int(2);
    try std.testing.expectEqual(@as(i64, -4), nox_bigint_to_i64(g.keep(nox_bigint_floordiv(rt, m7, two))));
    try std.testing.expectEqual(@as(i64, 1), nox_bigint_to_i64(g.keep(nox_bigint_mod(rt, m7, two))));
    const p7 = g.int(7);
    const m2 = g.int(-2);
    try std.testing.expectEqual(@as(i64, -4), nox_bigint_to_i64(g.keep(nox_bigint_floordiv(rt, p7, m2))));
    try std.testing.expectEqual(@as(i64, -1), nox_bigint_to_i64(g.keep(nox_bigint_mod(rt, p7, m2))));
    const zero = g.int(0);
    try std.testing.expectEqual(@as(i64, 1), nox_bigint_is_error(nox_bigint_floordiv(rt, p7, zero)));
    const nz = g.keep(nox_bigint_neg(rt, zero));
    try std.testing.expectEqual(@as(i64, 0), nox_bigint_sign(nz));
    try std.testing.expectEqual(@as(i64, 0), nox_bigint_cmp(nz, zero));
    // ayrıştırma hataları ve işaret
    try std.testing.expectEqual(@as(i64, 1), nox_bigint_is_error(nox_bigint_parse_raw(rt, g.keep(str_mod.nox_str_from_bytes(rt, "12x")), 10)));
    try std.testing.expectEqual(@as(i64, 1), nox_bigint_is_error(nox_bigint_parse_raw(rt, g.keep(str_mod.nox_str_from_bytes(rt, "-")), 10)));
}

test "bigint: pow, powmod, gcd, kaydırma, isqrt, asallık" {
    const asap = @import("../alloc/asap.zig");
    const rt = testRt() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);
    var g: Bag = .{ .rt = rt };
    defer g.deinit();
    const two = g.int(2);
    const p = g.keep(nox_bigint_pow(rt, two, 100));
    try std.testing.expectEqualStrings("1267650600228229401496703205376", g.show(p));
    try std.testing.expectEqual(@as(i64, 101), nox_bigint_bit_length(p));
    const md = g.int(1000000007);
    try std.testing.expectEqual(@as(i64, 0x8200cd5), nox_bigint_to_i64(g.keep(nox_bigint_powmod(rt, g.int(3), g.int(200), md))));
    try std.testing.expectEqual(@as(i64, 21), nox_bigint_to_i64(g.keep(nox_bigint_gcd(rt, g.int(1071), g.int(462)))));
    // Python: -5 >> 1 == -3, 5 << 70 >> 70 == 5
    try std.testing.expectEqual(@as(i64, -3), nox_bigint_to_i64(g.keep(nox_bigint_shr(rt, g.int(-5), 1))));
    try std.testing.expectEqual(@as(i64, 5), nox_bigint_to_i64(g.keep(nox_bigint_shr(rt, g.keep(nox_bigint_shl(rt, g.int(5), 70)), 70))));
    try std.testing.expectEqual(@as(i64, 31622), nox_bigint_to_i64(g.keep(nox_bigint_isqrt(rt, g.int(1000000000)))));
    try std.testing.expectEqual(@as(i64, 1), nox_bigint_is_probable_prime(g.int(1000000007), 0));
    try std.testing.expectEqual(@as(i64, 0), nox_bigint_is_probable_prime(g.int(1000000011), 0));
    try std.testing.expectEqual(@as(i64, 1), nox_bigint_is_probable_prime(g.dec("170141183460469231731687303715884105727"), 4)); // 2^127 - 1
    try std.testing.expectEqual(@as(i64, 0), nox_bigint_is_probable_prime(g.int(561), 0)); // Carmichael
    try std.testing.expectEqual(@as(i64, 0), nox_bigint_is_probable_prime(g.dec("170141183460469231731687303715884105729"), 4));
}
