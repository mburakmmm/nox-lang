//! noxc-nightly `types-diff` (Aşama 3.1): Zig `typecheck/types.zig` ↔ Nox `selfhost/types.nox` farksal denetimi. YALNIZCA nightly ikilisinde derlenir (`selfhost_glue.zig` ile aynı kural).
//!
//! Rastgele (tohumlu, tekrarlanabilir) tip ağaçları üretir; her biri iki tarafta kurulur ve şunlar karşılaştırılır: `format`/`appendMangled` metni, `isNumeric`/`isBitwiseEligible`,
//! `eql` ⇔ `TypeId` eşitliği (hash-consing), `assignable` (aşağıdaki Zig referansı `checker.zig` `Checker.assignable`/`isSubclassOf` ile birebir aynı mantık), FixedIntKind yardımcıları,
//! yeniden kurmada kimlik kararlılığı ve `ty_validate` invariantları.

const std = @import("std");
const types = @import("typecheck/types.zig");
const glue = @import("selfhost_glue.zig");

const Type = types.Type;

/// Sınıf adı havuzu (UTF-8 dahil); hepsi tek bitişik tampona yazılır (Nox `sym_intern` ofset/uzunlukla okur).
const class_names = [_][]const u8{ "Point", "Vector", "Shape", "Circle", "Box__int", "Ünï", "世界", "A", "__nox_FnBox__x", "Unregistered" };
const registered_count = class_names.len - 1; // son ad HİÇ kaydedilmez (`classes.get(..) orelse false` yolu)

const Hier = struct {
    base: [class_names.len]i32 = [_]i32{-1} ** class_names.len,
    mixins: [class_names.len][3]i32 = [_][3]i32{[_]i32{ -1, -1, -1 }} ** class_names.len,
    reg: [class_names.len]bool = [_]bool{false} ** class_names.len,

    fn isSub(self: *const Hier, sub: usize, sup: usize) bool {
        var cur: i32 = @intCast(sub);
        while (cur >= 0) {
            const c: usize = @intCast(cur);
            if (c == sup) return true;
            if (!self.reg[c]) return false;
            for (self.mixins[c]) |m| if (m >= 0 and self.isSub(@intCast(m), sup)) return true;
            cur = self.base[c];
        }
        return false;
    }
};

fn classIndex(name: []const u8) usize {
    for (class_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    unreachable;
}

/// `Checker.assignable` referansı (checker.zig:1297): sınıf karşılaştırması `Hier` üzerinden.
fn refAssignable(h: *const Hier, declared: Type, value: Type) bool {
    if (types.eql(declared, value)) return true;
    if (declared == .float and value == .int) return true;
    if (declared == .class and value == .class) return h.isSub(classIndex(value.class), classIndex(declared.class));
    if (declared == .optional) {
        if (value == .none) return true;
        return refAssignable(h, declared.optional.*, value);
    }
    return false;
}

fn gen(r: std.Random, a: std.mem.Allocator, depth: u32) !Type {
    const leaf = depth == 0 or r.intRangeLessThan(u8, 0, 10) < 3;
    const pick = r.intRangeLessThan(u8, 0, if (leaf) 8 else 18);
    switch (pick) {
        0 => return .int,
        1 => return .float,
        2 => return .boolean,
        3 => return .str,
        4 => return .none,
        5 => return .ptr,
        6 => return .{ .fixed_int = @enumFromInt(r.intRangeLessThan(u8, 0, 10)) },
        7 => return .{ .class = class_names[r.intRangeLessThan(usize, 0, class_names.len)] },
        8...15 => {
            const e = try a.create(Type);
            e.* = try gen(r, a, depth - 1);
            return switch (pick) {
                8 => .{ .list = e },
                9 => .{ .task = e },
                10 => .{ .channel = e },
                11 => .{ .thread_handle = e },
                12 => .{ .thread_channel = e },
                13 => .{ .task_local = e },
                14 => .{ .optional = e },
                else => .{ .typed_ptr = e },
            };
        },
        16 => {
            const k = try a.create(Type);
            const v = try a.create(Type);
            k.* = try gen(r, a, depth - 1);
            v.* = try gen(r, a, depth - 1);
            return .{ .dict = .{ .key = k, .value = v } };
        },
        else => {
            const n = r.intRangeLessThan(usize, 0, 4);
            const ps = try a.alloc(Type, n);
            for (ps) |*p| p.* = try gen(r, a, depth - 1);
            const ret = try a.create(Type);
            ret.* = try gen(r, a, depth - 1);
            return .{ .func = .{ .params = ps, .return_type = ret } };
        },
    }
}

/// Nox tarafında `t`yi kurar ve TypeId döner (Zig `Type` birleşim sırası = Nox etiketleri; bkz. `selfhost/types.nox` başlığı).
fn build(api: glue.TypeApi, syms: []const i64, t: Type) i64 {
    return switch (t) {
        .int => api.scalar(0),
        .float => api.scalar(1),
        .boolean => api.scalar(2),
        .str => api.scalar(3),
        .none => api.scalar(4),
        .ptr => api.scalar(12),
        .fixed_int => |k| api.fixed(@intFromEnum(k)),
        .class => |n| api.class(syms[classIndex(n)]),
        .list => |e| api.unary(5, build(api, syms, e.*)),
        .task => |e| api.unary(7, build(api, syms, e.*)),
        .channel => |e| api.unary(8, build(api, syms, e.*)),
        .thread_handle => |e| api.unary(9, build(api, syms, e.*)),
        .thread_channel => |e| api.unary(10, build(api, syms, e.*)),
        .task_local => |e| api.unary(11, build(api, syms, e.*)),
        .optional => |e| api.unary(15, build(api, syms, e.*)),
        .typed_ptr => |e| api.unary(17, build(api, syms, e.*)),
        .dict => |d| blk: {
            const k = build(api, syms, d.key.*);
            const v = build(api, syms, d.value.*);
            break :blk api.dict(k, v);
        },
        .func => |f| blk: {
            // çocuklar ÖNCE kurulur (Nox `func_begin` tek yığın alanı kullanır); sonra begin/param*/end
            var buf: [8]i64 = undefined;
            for (f.params, 0..) |p, i| buf[i] = build(api, syms, p);
            const ret = build(api, syms, f.return_type.*);
            api.funcBegin();
            for (buf[0..f.params.len]) |id| api.funcParam(id);
            break :blk api.funcEnd(ret);
        },
    };
}

pub const Result = struct { types_built: usize, distinct: usize, pairs: usize, assign_true: usize, nox_bytes: i64 };

/// `count` rastgele tipi ikisinde de kurar; ilk uyuşmazlıkta `error.Mismatch` (ayrıntı stderr). `seed` tekrarlanabilirlik içindir.
pub fn run(gpa: std.mem.Allocator, nrt: glue.Runtime, seed: u64, count: usize) !Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const api = nrt.types();
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();

    _ = api.reset();
    // sınıf adları: tek bitişik tampon (Nox ofset/uzunlukla okur)
    var names_buf: std.ArrayListUnmanaged(u8) = .empty;
    var offs: [class_names.len]usize = undefined;
    for (class_names, 0..) |n, i| {
        offs[i] = names_buf.items.len;
        try names_buf.appendSlice(a, n);
    }
    api.names(names_buf.items);
    var syms: [class_names.len]i64 = undefined;
    for (class_names, 0..) |n, i| syms[i] = api.sym(offs[i], n.len);
    // sembol internleme: aynı ad aynı SymbolId, farklı ad farklı
    for (class_names, 0..) |n, i| {
        if (api.sym(offs[i], n.len) != syms[i]) return fail("sembol havuzu: aynı ad farklı SymbolId", .{});
        for (class_names[i + 1 ..], i + 1..) |_, j| if (syms[i] == syms[j]) return fail("sembol havuzu: farklı adlar aynı SymbolId", .{});
    }
    // rastgele sınıf hiyerarşisi (döngüsüz: taban/mixin yalnızca daha küçük indeksten)
    var hier: Hier = .{};
    for (0..registered_count) |i| {
        hier.reg[i] = true;
        api.classReg(syms[i]);
        if (i > 0 and r.boolean()) {
            const b = r.intRangeLessThan(usize, 0, i);
            hier.base[i] = @intCast(b);
            api.classBase(syms[i], syms[b]);
        }
        if (i > 1) {
            var slot: usize = 0;
            while (slot < 3 and r.intRangeLessThan(u8, 0, 3) == 0) : (slot += 1) {
                const m = r.intRangeLessThan(usize, 0, i);
                hier.mixins[i][slot] = @intCast(m);
                api.classMixin(syms[i], syms[m]);
            }
        }
    }

    const ts = try a.alloc(Type, count);
    const ids = try a.alloc(i64, count);
    for (ts, ids) |*t, *id| {
        t.* = try gen(r, a, 4);
        id.* = build(api, &syms, t.*);
    }

    var distinct = std.AutoHashMap(i64, void).init(a);
    for (ids) |id| try distinct.put(id, {});

    // 1) metin + yüklemler
    for (ts, ids) |t, id| {
        const want = try types.toAlloc(a, t);
        const got = try api.formatAlloc(a, id);
        if (!std.mem.eql(u8, want, got)) return fail("format farkı: zig=\"{s}\" nox=\"{s}\"", .{ want, got });
        var mb: std.ArrayListUnmanaged(u8) = .empty;
        try types.appendMangled(a, &mb, t);
        const mg = try api.mangleAlloc(a, id);
        if (!std.mem.eql(u8, mb.items, mg)) return fail("mangle farkı ({s}): zig=\"{s}\" nox=\"{s}\"", .{ want, mb.items, mg });
        if (types.isNumeric(t) != api.numeric(id)) return fail("isNumeric farkı: {s}", .{want});
        if (types.isBitwiseEligible(t) != api.bitwise(id)) return fail("isBitwiseEligible farkı: {s}", .{want});
    }

    // 2) eql ⇔ TypeId eşitliği; assignable (kuşak: ilk 300 tipin tüm çiftleri + 40 000 rastgele çift)
    var pairs: usize = 0;
    var assign_true: usize = 0;
    const full = @min(count, 300);
    var i: usize = 0;
    while (i < full) : (i += 1) {
        var j: usize = 0;
        while (j < full) : (j += 1) try checkPair(&hier, api, ts, ids, i, j, &pairs, &assign_true);
    }
    var k: usize = 0;
    while (count > 0 and k < 40_000) : (k += 1) try checkPair(&hier, api, ts, ids, r.intRangeLessThan(usize, 0, count), r.intRangeLessThan(usize, 0, count), &pairs, &assign_true);

    // 3) yeniden kurma: kimlikler kararlı (hash-consing idempotent), tablo büyümedi
    const before = api.count();
    for (ts, ids) |t, id| if (build(api, &syms, t) != id) return fail("yeniden kurulan tipin TypeId'si değişti", .{});
    if (api.count() != before) return fail("yeniden kurma tablo büyüttü: {d} -> {d}", .{ before, api.count() });
    // 16 sabit kimlik + farklı tipler (sabitler üretilenlerde de olabilir: tablo = 16 + üretilen ara düğümler >= farklı kökler)
    if (api.count() < @as(i64, @intCast(distinct.count()))) return fail("tablo boyutu {d} < farklı kök sayısı {d}", .{ api.count(), distinct.count() });

    // 4) FixedIntKind
    const probes = [_]i64{ std.math.minInt(i64), -4294967297, -2147483649, -2147483648, -32769, -32768, -129, -128, -1, 0, 1, 127, 128, 255, 256, 32767, 32768, 65535, 65536, 2147483647, 2147483648, 4294967295, 4294967296, std.math.maxInt(i64) };
    inline for (@typeInfo(types.FixedIntKind).@"enum".fields, 0..) |f, ki| {
        const kind: types.FixedIntKind = @enumFromInt(f.value);
        if (api.fx(0, @intCast(ki), 0) != kind.bitWidth()) return fail("bitWidth farkı: {s}", .{f.name});
        if ((api.fx(1, @intCast(ki), 0) != 0) != kind.isSigned()) return fail("isSigned farkı: {s}", .{f.name});
        for (probes) |p| if ((api.fx(2, @intCast(ki), p) != 0) != kind.fitsValue(p)) return fail("fitsValue farkı: {s} {d}", .{ f.name, p });
    }
    // sabit kimlikler: Zig adı = Nox adı
    for (0..10) |ki| {
        const want = types.FixedIntKind;
        const kind: want = @enumFromInt(ki);
        const got = try api.formatAlloc(a, 6 + @as(i64, @intCast(ki)));
        if (!std.mem.eql(u8, got, kind.name())) return fail("sabit fixed_int kimliği {d}: nox=\"{s}\" zig=\"{s}\"", .{ 6 + ki, got, kind.name() });
    }

    // 5) invariantlar
    const v = api.validate();
    if (v != 0) return fail("ty_validate hata kodu {d}", .{v});
    return .{ .types_built = count, .distinct = distinct.count(), .pairs = pairs, .assign_true = assign_true, .nox_bytes = api.mem() };
}

fn checkPair(h: *const Hier, api: glue.TypeApi, ts: []const Type, ids: []const i64, i: usize, j: usize, pairs: *usize, assign_true: *usize) !void {
    pairs.* += 1;
    const same = types.eql(ts[i], ts[j]);
    if (same != (ids[i] == ids[j])) {
        const sa = try types.toAlloc(std.heap.page_allocator, ts[i]);
        const sb = try types.toAlloc(std.heap.page_allocator, ts[j]);
        return fail("eql ⇔ TypeId farkı: \"{s}\" vs \"{s}\" (zig eql={}, nox ids {d}/{d})", .{ sa, sb, same, ids[i], ids[j] });
    }
    const want = refAssignable(h, ts[i], ts[j]);
    if (want) assign_true.* += 1;
    if (want != api.assignable(ids[i], ids[j])) {
        const sa = try types.toAlloc(std.heap.page_allocator, ts[i]);
        const sb = try types.toAlloc(std.heap.page_allocator, ts[j]);
        return fail("assignable farkı: declared=\"{s}\" value=\"{s}\" zig={}", .{ sa, sb, want });
    }
}

fn fail(comptime fmt: []const u8, args: anytype) error{Mismatch} {
    std.debug.print("types-diff: " ++ fmt ++ "\n", args);
    return error.Mismatch;
}

fn lcg(x: u64) u64 {
    return (x * 1103515245 + 12345) & 2147483647;
}

/// `types-bench` Zig tarafı: Nox `nox_ty_bench` ile AYNI iş yükü (LCG, havuz kurma, `eql`/`assignable`/seyrek `format`) ve AYNI sağlama toplamı. Zig'de hash-consing yoktur (yapısal `eql`).
pub fn benchZig(a: std.mem.Allocator, seed: u64, k: usize, m: usize) !i64 {
    var pool: std.ArrayListUnmanaged(Type) = .empty;
    for ([_]Type{ .int, .float, .boolean, .str, .none }) |t| try pool.append(a, t);
    var x: u64 = seed & 2147483647;
    for (0..k) |_| {
        x = lcg(x);
        const kind = (x >> 8) % 7;
        x = lcg(x);
        const ta = pool.items[(x >> 4) % pool.items.len];
        x = lcg(x);
        const tb = pool.items[(x >> 4) % pool.items.len];
        x = lcg(x);
        const tc = pool.items[(x >> 4) % pool.items.len];
        const pa = try a.create(Type);
        pa.* = ta;
        const t: Type = switch (kind) {
            0 => .{ .list = pa },
            1 => .{ .optional = pa },
            2 => blk: {
                const pb = try a.create(Type);
                pb.* = tb;
                break :blk .{ .dict = .{ .key = pa, .value = pb } };
            },
            3 => blk: {
                const ps = try a.alloc(Type, 2);
                ps[0] = ta;
                ps[1] = tb;
                const pr = try a.create(Type);
                pr.* = tc;
                break :blk .{ .func = .{ .params = ps, .return_type = pr } };
            },
            4 => .{ .class = class_names[(x >> 3) % 8] },
            5 => .{ .task = pa },
            else => .{ .fixed_int = @enumFromInt((x >> 3) % 10) },
        };
        try pool.append(a, t);
    }
    var acc: i64 = 0;
    const empty: Hier = .{};
    var tmp: std.ArrayListUnmanaged(u8) = .empty;
    for (0..m) |j| {
        x = lcg(x);
        const p = pool.items[(x >> 4) % pool.items.len];
        x = lcg(x);
        const q = pool.items[(x >> 4) % pool.items.len];
        if (types.eql(p, q)) acc += 1;
        if (refAssignable(&empty, p, q)) acc += 3;
        if (j % 64 == 0) {
            tmp.clearRetainingCapacity();
            var aw: std.Io.Writer.Allocating = .fromArrayList(a, &tmp);
            types.format(p, &aw.writer) catch return error.OutOfMemory;
            tmp = aw.toArrayList();
            acc += @intCast(tmp.items.len);
        }
    }
    // Nox sağlama toplamı tablo boyutunu (benzersiz tip + 16 sabit) ekler: Zig'de eşdeğer = yapısal olarak benzersiz tip sayısı. Aşağıda `distinctCount` hesaplar.
    return acc + @as(i64, @intCast(try distinctCount(a, pool.items)));
}

/// Havuzdaki yapısal olarak benzersiz tip sayısı + hiç yaratılmamış sabit kimlikler (Nox tablosunda daima bulunan 16 sabit) — Nox `len(tt.tag)` ile aynı olmalı.
fn distinctCount(a: std.mem.Allocator, pool: []const Type) !usize {
    var seen: std.ArrayListUnmanaged(Type) = .empty;
    defer seen.deinit(a);
    // 16 sabit: int float bool str None ptr + 10 fixed_int
    try seen.append(a, .int);
    try seen.append(a, .float);
    try seen.append(a, .boolean);
    try seen.append(a, .str);
    try seen.append(a, .none);
    try seen.append(a, .ptr);
    inline for (@typeInfo(types.FixedIntKind).@"enum".fields) |f| try seen.append(a, .{ .fixed_int = @enumFromInt(f.value) });
    // Nox havuz kurarken alt tipleri (ör. func'ın çocukları) zaten havuzdadır; tabloya yalnız havuz üyeleri girer.
    outer: for (pool) |t| {
        for (seen.items) |s| if (types.eql(s, t)) continue :outer;
        try seen.append(a, t);
    }
    return seen.items.len;
}

/// Nox tarafı bench hazırlığı: taze tablo + `class_names[0..8]` sırayla internlenir (SymbolId 0..7 = indeks).
pub fn benchPrepare(a: std.mem.Allocator, api: glue.TypeApi) !void {
    _ = api.reset();
    var names_buf: std.ArrayListUnmanaged(u8) = .empty;
    var offs: [class_names.len]usize = undefined;
    for (class_names, 0..) |n, i| {
        offs[i] = names_buf.items.len;
        try names_buf.appendSlice(a, n);
    }
    api.names(names_buf.items);
    for (class_names[0..8], 0..) |n, i| {
        if (api.sym(offs[i], n.len) != @as(i64, @intCast(i))) return error.Mismatch;
    }
}
