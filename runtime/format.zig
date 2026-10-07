//! Python `format()` mini-dili — f-string `{x:.2f}` / `{n:>5}` / `{i:03d}` ve yerleşik `format(x, spec)` için çalışma zamanı (v1.164.0).
//!
//! Desteklenen: `[[fill]align][sign][#][0][width][,|_][.precision][type]`; tamsayı `b c d n o x X`, ondalık `e E f F g G %` (ve tamsayıya
//! ondalık tip uygulanırsa dönüştürülür), `str` `s`. `f`/`%` biçimi `x`in TAM ikili değeri üzerinde Python gibi doğru yuvarlar
//! (`f"{2.675:.2f}" == "2.67"`, yarım → çifte; `std.math.big.int` ile sabit yığın tamponunda). `e`/`g` en kısa-gidiş-dönüş rakamlarından
//! Zig'in `{e}` biçimlendiricisini kullanır (tam eşitlik noktalarında Python'dan nadiren farklı olabilir).
//!
//! `nox_format_spec_check` önce çağrılır (geçersiz spec → 0 → çağıran `ValueError` fırlatır); `nox_format_*_raw` yalnızca geçerli spec ile çağrılır.

const std = @import("std");
const str_mod = @import("str.zig");

const Spec = struct {
    fill: u21 = ' ',
    align_c: u8 = 0, // '<' '>' '^' '=' ya da 0 (tür varsayılanı)
    sign: u8 = '-',
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    group: u8 = 0, // ',' | '_' | 0
    precision: ?usize = null,
    type_c: u8 = 0,
};

fn parseSpec(spec: []const u8) ?Spec {
    var s: Spec = .{};
    var i: usize = 0;
    // fill + align (fill bir UTF-8 kod noktası olabilir)
    if (spec.len > 0) {
        const cl = std.unicode.utf8ByteSequenceLength(spec[0]) catch 1;
        if (cl <= spec.len and spec.len > cl and isAlign(spec[cl])) {
            s.fill = std.unicode.utf8Decode(spec[0..cl]) catch ' ';
            s.align_c = spec[cl];
            i = cl + 1;
        } else if (isAlign(spec[0])) {
            s.align_c = spec[0];
            i = 1;
        }
    }
    if (i < spec.len and (spec[i] == '+' or spec[i] == '-' or spec[i] == ' ')) {
        s.sign = spec[i];
        i += 1;
    }
    if (i < spec.len and spec[i] == '#') {
        s.alt = true;
        i += 1;
    }
    if (i < spec.len and spec[i] == '0') {
        s.zero = true;
        i += 1;
    }
    var w: usize = 0;
    while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {
        w = w * 10 + (spec[i] - '0');
        if (w > 1 << 20) return null;
    }
    s.width = w;
    if (i < spec.len and (spec[i] == ',' or spec[i] == '_')) {
        s.group = spec[i];
        i += 1;
    }
    if (i < spec.len and spec[i] == '.') {
        i += 1;
        var p: usize = 0;
        var have_p = false;
        while (i < spec.len and spec[i] >= '0' and spec[i] <= '9') : (i += 1) {
            p = p * 10 + (spec[i] - '0');
            have_p = true;
            if (p > 1000) return null;
        }
        if (!have_p) return null;
        s.precision = p;
    }
    if (i < spec.len) {
        s.type_c = spec[i];
        i += 1;
    }
    if (i != spec.len) return null;
    return s;
}

fn isAlign(c: u8) bool {
    return c == '<' or c == '>' or c == '^' or c == '=';
}

const Kind = enum(i32) { int = 0, float = 1, str = 2 };

fn validFor(kind: Kind, s: Spec) bool {
    switch (kind) {
        .int => {
            const float_type = s.type_c == 'e' or s.type_c == 'E' or s.type_c == 'f' or s.type_c == 'F' or s.type_c == 'g' or s.type_c == 'G' or s.type_c == '%';
            if (s.precision != null and !float_type) return false;
            return switch (s.type_c) {
                0, 'b', 'c', 'd', 'n', 'o', 'x', 'X', 'e', 'E', 'f', 'F', 'g', 'G', '%' => true,
                else => false,
            };
        },
        .float => return switch (s.type_c) {
            0, 'e', 'E', 'f', 'F', 'g', 'G', '%' => true,
            else => false,
        },
        .str => {
            if (s.type_c != 0 and s.type_c != 's') return false;
            if (s.sign != '-' or s.alt or s.group != 0 or s.align_c == '=') return false;
            return true;
        },
    }
}

pub export fn nox_format_spec_check(kind: i64, spec: ?[*:0]const u8) i64 {
    const sp = spec orelse return 1;
    const s = parseSpec(std.mem.span(sp)) orelse return 0;
    const k: Kind = switch (kind) {
        0 => .int,
        1 => .float,
        else => .str,
    };
    return if (validFor(k, s)) 1 else 0;
}

fn utf8Len(bytes: []const u8) usize {
    return std.unicode.utf8CountCodepoints(bytes) catch bytes.len;
}

/// `body` (işaret/önek ayrı) + dolgu — `out`a yazar.
fn pad(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: Spec, default_align: u8, sign_prefix: []const u8, digits: []const u8) !void {
    var fill = s.fill;
    var al = s.align_c;
    if (al == 0) al = default_align;
    if (s.zero and s.align_c == 0) {
        fill = '0';
        al = '=';
    }
    const content_len = utf8Len(sign_prefix) + utf8Len(digits);
    const total = if (s.width > content_len) s.width - content_len else 0;
    var fbuf: [4]u8 = undefined;
    const fl = std.unicode.utf8Encode(fill, &fbuf) catch blk: {
        fbuf[0] = ' ';
        break :blk 1;
    };
    const left: usize = switch (al) {
        '<' => 0,
        '^' => total / 2,
        '=' => 0,
        else => total,
    };
    const right: usize = if (al == '=') 0 else total - left;
    var k: usize = 0;
    while (k < left) : (k += 1) try out.appendSlice(a, fbuf[0..fl]);
    try out.appendSlice(a, sign_prefix);
    if (al == '=') {
        k = 0;
        while (k < total) : (k += 1) try out.appendSlice(a, fbuf[0..fl]);
    }
    try out.appendSlice(a, digits);
    k = 0;
    while (k < right) : (k += 1) try out.appendSlice(a, fbuf[0..fl]);
}

fn groupDigits(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, int_part: []const u8, sep: u8, every: usize) !void {
    var i: usize = 0;
    while (i < int_part.len) : (i += 1) {
        if (i > 0 and (int_part.len - i) % every == 0) try out.append(a, sep);
        try out.append(a, int_part[i]);
    }
}

fn formatIntBody(a: std.mem.Allocator, v: i64, s: Spec) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const neg = v < 0;
    const mag: u64 = if (neg) @as(u64, @intCast(-(v + 1))) + 1 else @intCast(v);
    var sign_prefix: std.ArrayListUnmanaged(u8) = .empty;
    if (neg) try sign_prefix.append(a, '-') else if (s.sign == '+') try sign_prefix.append(a, '+') else if (s.sign == ' ') try sign_prefix.append(a, ' ');
    var digits_buf: [80]u8 = undefined;
    var digits: []const u8 = undefined;
    switch (s.type_c) {
        'b' => {
            digits = std.fmt.bufPrint(&digits_buf, "{b}", .{mag}) catch unreachable;
            if (s.alt) try sign_prefix.appendSlice(a, "0b");
        },
        'o' => {
            digits = std.fmt.bufPrint(&digits_buf, "{o}", .{mag}) catch unreachable;
            if (s.alt) try sign_prefix.appendSlice(a, "0o");
        },
        'x' => {
            digits = std.fmt.bufPrint(&digits_buf, "{x}", .{mag}) catch unreachable;
            if (s.alt) try sign_prefix.appendSlice(a, "0x");
        },
        'X' => {
            digits = std.fmt.bufPrint(&digits_buf, "{X}", .{mag}) catch unreachable;
            if (s.alt) try sign_prefix.appendSlice(a, "0X");
        },
        'c' => {
            const n = std.unicode.utf8Encode(@intCast(@min(mag, 0x10FFFF)), &digits_buf) catch 0;
            digits = digits_buf[0..n];
        },
        else => digits = std.fmt.bufPrint(&digits_buf, "{d}", .{mag}) catch unreachable,
    }
    var grouped: std.ArrayListUnmanaged(u8) = .empty;
    if (s.group != 0 and (s.type_c == 0 or s.type_c == 'd' or s.type_c == 'n')) {
        try groupDigits(&grouped, a, digits, s.group, 3);
        digits = grouped.items;
    } else if (s.group == '_' and (s.type_c == 'b' or s.type_c == 'o' or s.type_c == 'x' or s.type_c == 'X')) {
        try groupDigits(&grouped, a, digits, '_', 4);
        digits = grouped.items;
    }
    // Sıfır dolgusu + grup ayırıcı için (Python): basitleştirilmiş — genişlik grup ayırıcısız dolgulanır.
    try pad(&out, a, s, '>', sign_prefix.items, digits);
    return out.toOwnedSlice(a);
}

// ---- ondalık ----

/// |x| için TAM ondalık `prec` basamak (yarım → çifte), nokta yok: dönen dize `digits` + ondalık basamak sayısı `prec`.
fn exactFixedDigits(a: std.mem.Allocator, x_abs: f64, prec: usize) ![]u8 {
    const big = std.math.big.int;
    var fba_buf: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const fa = fba.allocator();
    const bits: u64 = @bitCast(x_abs);
    const exp_bits: i32 = @intCast((bits >> 52) & 0x7FF);
    var m: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = undefined;
    if (exp_bits == 0) {
        e = -1074;
    } else {
        m |= (@as(u64, 1) << 52);
        e = exp_bits - 1075;
    }
    var n = try big.Managed.initSet(fa, m);
    var d = try big.Managed.initSet(fa, 1);
    var ten = try big.Managed.initSet(fa, 10);
    var p10 = try big.Managed.initSet(fa, 1);
    var i: usize = 0;
    while (i < prec) : (i += 1) try p10.mul(&p10, &ten);
    try n.mul(&n, &p10);
    if (e >= 0) try n.shiftLeft(&n, @intCast(e)) else try d.shiftLeft(&d, @intCast(-e));
    var q = try big.Managed.init(fa);
    var r = try big.Managed.init(fa);
    try q.divTrunc(&r, &n, &d);
    var r2 = try big.Managed.init(fa);
    try r2.shiftLeft(&r, 1);
    const ord = r2.toConst().order(d.toConst());
    if (ord == .gt or (ord == .eq and q.toConst().isOdd())) {
        var one = try big.Managed.initSet(fa, 1);
        try q.add(&q, &one);
    }
    const qs = try q.toString(fa, 10, .lower);
    return a.dupe(u8, qs);
}

/// `digits` (sondaki `prec` hane ondalık) → "ddd.ddd" (en az 1 tam basamak).
fn insertPoint(a: std.mem.Allocator, digits: []const u8, prec: usize, keep_point: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (prec == 0) {
        try out.appendSlice(a, digits);
        if (keep_point) try out.append(a, '.');
        return out.toOwnedSlice(a);
    }
    if (digits.len <= prec) {
        try out.appendSlice(a, "0.");
        var z: usize = digits.len;
        while (z < prec) : (z += 1) try out.append(a, '0');
        try out.appendSlice(a, digits);
    } else {
        try out.appendSlice(a, digits[0 .. digits.len - prec]);
        try out.append(a, '.');
        try out.appendSlice(a, digits[digits.len - prec ..]);
    }
    return out.toOwnedSlice(a);
}

fn formatExp(a: std.mem.Allocator, x_abs: f64, prec: usize, upper: bool, keep_point: bool) ![]u8 {
    var buf: [1500]u8 = undefined;
    const p = @min(prec, 300);
    const txt = std.fmt.bufPrint(&buf, "{e:.[1]}", .{ x_abs, p }) catch return a.dupe(u8, "nan");
    const e_idx = std.mem.indexOfScalar(u8, txt, 'e') orelse return a.dupe(u8, txt);
    const exp = std.fmt.parseInt(i32, txt[e_idx + 1 ..], 10) catch 0;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, txt[0..e_idx]);
    if (p == 0 and keep_point) try out.append(a, '.');
    try out.append(a, if (upper) 'E' else 'e');
    try out.append(a, if (exp < 0) '-' else '+');
    var eb: [16]u8 = undefined;
    const es = std.fmt.bufPrint(&eb, "{d:0>2}", .{@abs(exp)}) catch unreachable;
    try out.appendSlice(a, es);
    return out.toOwnedSlice(a);
}

fn formatFloatBody(a: std.mem.Allocator, x: f64, s0: Spec) ![]u8 {
    var s = s0;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (std.math.isNan(x) or std.math.isInf(x)) {
        const upper = s.type_c == 'E' or s.type_c == 'F' or s.type_c == 'G';
        const word = if (std.math.isNan(x)) (if (upper) "NAN" else "nan") else if (upper) "INF" else "inf";
        var sp: std.ArrayListUnmanaged(u8) = .empty;
        if (std.math.signbit(x) and !std.math.isNan(x)) try sp.append(a, '-') else if (s.sign == '+') try sp.append(a, '+') else if (s.sign == ' ') try sp.append(a, ' ');
        s.zero = false;
        try pad(&out, a, s, '>', sp.items, word);
        return out.toOwnedSlice(a);
    }
    const neg = std.math.signbit(x);
    const ax = @abs(x);
    var sp: std.ArrayListUnmanaged(u8) = .empty;
    if (neg) try sp.append(a, '-') else if (s.sign == '+') try sp.append(a, '+') else if (s.sign == ' ') try sp.append(a, ' ');
    var body: []u8 = undefined;
    var percent = false;
    switch (s.type_c) {
        'f', 'F' => {
            const prec = s.precision orelse 6;
            const digits = try exactFixedDigits(a, ax, prec);
            body = try insertPoint(a, digits, prec, s.alt);
        },
        '%' => {
            const prec = s.precision orelse 6;
            const digits = try exactFixedDigits(a, ax * 100.0, prec);
            body = try insertPoint(a, digits, prec, s.alt);
            percent = true;
        },
        'e', 'E' => body = try formatExp(a, ax, s.precision orelse 6, s.type_c == 'E', s.alt),
        'g', 'G' => {
            var p = s.precision orelse 6;
            if (p == 0) p = 1;
            if (ax == 0) {
                body = try a.dupe(u8, if (s.alt) "0." else "0");
                if (s.alt) {
                    var z: usize = 1;
                    var tmp: std.ArrayListUnmanaged(u8) = .empty;
                    try tmp.appendSlice(a, "0.");
                    while (z < p) : (z += 1) try tmp.append(a, '0');
                    body = try tmp.toOwnedSlice(a);
                }
            } else {
                var ebuf: [1500]u8 = undefined;
                const et = std.fmt.bufPrint(&ebuf, "{e:.[1]}", .{ ax, p - 1 }) catch "0e0";
                const ei = std.mem.indexOfScalar(u8, et, 'e').?;
                const exp10 = std.fmt.parseInt(i32, et[ei + 1 ..], 10) catch 0;
                if (exp10 >= -4 and exp10 < @as(i32, @intCast(p))) {
                    const fprec: usize = @intCast(@as(i32, @intCast(p)) - 1 - exp10);
                    const digits = try exactFixedDigits(a, ax, fprec);
                    body = try insertPoint(a, digits, fprec, s.alt);
                } else {
                    body = try formatExp(a, ax, p - 1, s.type_c == 'G', s.alt);
                }
                if (!s.alt) body = try stripTrailingZeros(a, body);
            }
        },
        else => {
            // tür yok: precision yoksa repr; varsa 'g' benzeri.
            if (s.precision == null) {
                var rb: [64]u8 = undefined;
                const r = str_mod.formatFloatRepr(&rb, ax);
                body = try a.dupe(u8, r);
            } else {
                var s2 = s;
                s2.type_c = 'g';
                const inner = try formatFloatBody(a, ax, .{ .precision = s2.precision, .type_c = 'g', .alt = s.alt });
                body = inner;
            }
        },
    }
    if (percent) {
        var tmp: std.ArrayListUnmanaged(u8) = .empty;
        try tmp.appendSlice(a, body);
        try tmp.append(a, '%');
        body = try tmp.toOwnedSlice(a);
    }
    if (s.group != 0) {
        // yalnızca tam kısım gruplanır
        const dot = std.mem.indexOfAny(u8, body, ".eE%") orelse body.len;
        var g: std.ArrayListUnmanaged(u8) = .empty;
        try groupDigits(&g, a, body[0..dot], s.group, 3);
        try g.appendSlice(a, body[dot..]);
        body = try g.toOwnedSlice(a);
    }
    try pad(&out, a, s, '>', sp.items, body);
    return out.toOwnedSlice(a);
}

fn stripTrailingZeros(a: std.mem.Allocator, body: []const u8) ![]u8 {
    const epos = std.mem.indexOfAny(u8, body, "eE");
    const mant = if (epos) |ep| body[0..ep] else body;
    const tail = if (epos) |ep| body[ep..] else "";
    var m = mant;
    if (std.mem.indexOfScalar(u8, m, '.') != null) {
        while (m.len > 0 and m[m.len - 1] == '0') m = m[0 .. m.len - 1];
        if (m.len > 0 and m[m.len - 1] == '.') m = m[0 .. m.len - 1];
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, m);
    try out.appendSlice(a, tail);
    return out.toOwnedSlice(a);
}

fn formatStrBody(a: std.mem.Allocator, v: []const u8, s: Spec) ![]u8 {
    var body = v;
    if (s.precision) |p| {
        var it = std.unicode.Utf8View.initUnchecked(v).iterator();
        var count: usize = 0;
        var end: usize = 0;
        while (count < p) : (count += 1) {
            const cp = it.nextCodepointSlice() orelse break;
            end += cp.len;
        }
        body = v[0..end];
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var s2 = s;
    s2.zero = false;
    if (s.zero and s.align_c == 0) {
        // Python: `{:010}` str için fill='0', align '<'
        s2.fill = '0';
        s2.align_c = '<';
    }
    try pad(&out, a, s2, '<', "", body);
    return out.toOwnedSlice(a);
}

fn finish(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    var ascii = true;
    for (bytes) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    return str_mod.allocStr(rt, bytes, if (ascii) str_mod.ASCII_TRUE else str_mod.ASCII_FALSE);
}

pub export fn nox_format_int_raw(rt: ?*anyopaque, v: i64, spec: ?[*:0]const u8) ?[*:0]u8 {
    var arena_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const a = fba.allocator();
    const s = parseSpec(if (spec) |sp| std.mem.span(sp) else "") orelse return null;
    if (s.type_c == 'e' or s.type_c == 'E' or s.type_c == 'f' or s.type_c == 'F' or s.type_c == 'g' or s.type_c == 'G' or s.type_c == '%') {
        const r = formatFloatBody(a, @floatFromInt(v), s) catch return null;
        return finish(rt, r);
    }
    const r = formatIntBody(a, v, s) catch return null;
    return finish(rt, r);
}

pub export fn nox_format_float_raw(rt: ?*anyopaque, v: f64, spec: ?[*:0]const u8) ?[*:0]u8 {
    var arena_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const a = fba.allocator();
    const s = parseSpec(if (spec) |sp| std.mem.span(sp) else "") orelse return null;
    const r = formatFloatBody(a, v, s) catch return null;
    return finish(rt, r);
}

pub export fn nox_format_str_raw(rt: ?*anyopaque, v: ?[*:0]const u8, spec: ?[*:0]const u8) ?[*:0]u8 {
    var arena_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const a = fba.allocator();
    const s = parseSpec(if (spec) |sp| std.mem.span(sp) else "") orelse return null;
    const text: []const u8 = if (v) |p| std.mem.span(p) else "";
    // Çok uzun dizeler için sabit tampon yetmez: doğrudan tahsis et.
    if (text.len > 4096) return finish(rt, text);
    const r = formatStrBody(a, text, s) catch return null;
    return finish(rt, r);
}

test "format: tamsayı" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { v: i64, spec: []const u8, want: []const u8 }{
        .{ .v = 7, .spec = "5d", .want = "    7" },
        .{ .v = 7, .spec = "03d", .want = "007" },
        .{ .v = 7, .spec = ">6", .want = "     7" },
        .{ .v = 7, .spec = "<6", .want = "7     " },
        .{ .v = 7, .spec = "^6", .want = "  7   " },
        .{ .v = 255, .spec = "x", .want = "ff" },
        .{ .v = 255, .spec = "#X", .want = "0XFF" },
        .{ .v = 5, .spec = "b", .want = "101" },
        .{ .v = 1234567, .spec = ",", .want = "1,234,567" },
        .{ .v = -42, .spec = "+d", .want = "-42" },
        .{ .v = 42, .spec = "+d", .want = "+42" },
        .{ .v = -42, .spec = "06d", .want = "-00042" },
        .{ .v = 3, .spec = "*^7", .want = "***3***" },
    };
    for (cases) |c| {
        const s = parseSpec(c.spec).?;
        const got = try formatIntBody(a, c.v, s);
        try std.testing.expectEqualStrings(c.want, got);
    }
}
