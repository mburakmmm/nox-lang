//! noxc-nightly `ck-diff` (Aşama 3.2): Zig `typecheck/checker.zig` ↔ Nox `selfhost/typecheck.nox` farksal denetimi (kapsam/sembol tabloları). YALNIZCA nightly ikilisinde derlenir.
//!
//! `scope`: rastgele (tohumlu) işlem dizisi — GERÇEK `checker.Scope` ile Nox kapsam tabloları aynı `declare`/`lookupLocal`/`lookup` (yakalama kaydı dahil)/`existsInChain`/`declareVar`
//! karar dizisini görür; sonuçlar ve kapsam başına yakalama kümeleri, ayrıca `module_globals`/`module_int_consts` tablo davranışı (put/get/has/remove/sayım) karşılaştırılır.
//! `assign`: verilen `.nox` dosyalarında GERÇEK `Checker.stmtsAssignName` ↔ Nox `stmts_assign_name`, dosyadaki her sözcük için.

const std = @import("std");
const types = @import("typecheck/types.zig");
const checker = @import("typecheck/checker.zig");
const glue = @import("selfhost_glue.zig");
const td = @import("selfhost_types_diff.zig");
const lexer = @import("lexer/lexer.zig");
const parser_mod = @import("parser/parser.zig");

const Type = types.Type;

const var_names = [_][]const u8{ "x", "y", "total", "i", "__nox_tup_0_2", "self", "Ünï", "日本", "acc", "n", "cb", "it" };

fn fail(comptime fmt: []const u8, args: anytype) error{Mismatch} {
    std.debug.print("ck-diff: " ++ fmt ++ "\n", args);
    return error.Mismatch;
}

pub const ScopeResult = struct { ops: usize, scopes: usize, captures: usize, redecl_rejected: usize };

pub fn runScope(gpa: std.mem.Allocator, nrt: glue.Runtime, seed: u64, ops: usize) !ScopeResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tapi = nrt.types();
    const api = nrt.check();
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();

    _ = tapi.reset();
    api.reset();
    // sembol havuzu: sınıf adları + değişken adları (tek bitişik tampon)
    var names_buf: std.ArrayListUnmanaged(u8) = .empty;
    const total = td.class_names.len + var_names.len;
    var offs: [total]usize = undefined;
    var lens: [total]usize = undefined;
    for (td.class_names, 0..) |n, i| {
        offs[i] = names_buf.items.len;
        lens[i] = n.len;
        try names_buf.appendSlice(a, n);
    }
    for (var_names, 0..) |n, i| {
        offs[td.class_names.len + i] = names_buf.items.len;
        lens[td.class_names.len + i] = n.len;
        try names_buf.appendSlice(a, n);
    }
    tapi.names(names_buf.items);
    var csyms: [td.class_names.len]i64 = undefined;
    var vsyms: [var_names.len]i64 = undefined;
    for (0..td.class_names.len) |i| csyms[i] = tapi.sym(offs[i], lens[i]);
    for (0..var_names.len) |i| vsyms[i] = tapi.sym(offs[td.class_names.len + i], lens[td.class_names.len + i]);

    // sınıf "ARC dışı alan" bayrakları (declareVar'ın sınıf↔sınıf serbestliği)
    var nonarc: [td.class_names.len]bool = undefined;
    for (&nonarc, 0..) |*f, i| {
        f.* = r.intRangeLessThan(u8, 0, 3) == 0;
        api.setNonArc(csyms[i], f.*);
    }

    // tip havuzu
    const npool = 40;
    var pool: [npool]Type = undefined;
    var pool_ids: [npool]i64 = undefined;
    for (&pool, &pool_ids) |*t, *id| {
        t.* = try td.gen(r, a, 2);
        id.* = td.build(tapi, &csyms, t.*);
    }

    // kapsamlar: rastgele üst bağları, yarısı yakalama kümeli
    const nscopes = 7;
    var zscopes: [nscopes]*checker.Scope = undefined;
    var zcaps: [nscopes]?*std.StringHashMapUnmanaged(Type) = undefined;
    var nscope: [nscopes]i64 = undefined;
    for (0..nscopes) |i| {
        const s = try a.create(checker.Scope);
        s.* = .{};
        const parent_ix: ?usize = if (i > 0 and r.intRangeLessThan(u8, 0, 4) != 0) r.intRangeLessThan(usize, 0, i) else null;
        if (parent_ix) |p| s.parent = zscopes[p];
        const has_caps = i > 0 and r.boolean();
        if (has_caps) {
            const m = try a.create(std.StringHashMapUnmanaged(Type));
            m.* = .{};
            s.captures = m;
            zcaps[i] = m;
        } else zcaps[i] = null;
        zscopes[i] = s;
        nscope[i] = api.scopeNew(if (parent_ix) |p| nscope[p] else -1, has_caps);
    }

    // beyanlar ağırlıklı olarak yakalama kümesiz kapsamlara gider: yakalamalı (iç içe def) kapsamlar adları çoğunlukla ÜST zincirden çözer → yakalama kaydı yolu gerçekten sınanır
    var decl_scopes: [nscopes]usize = undefined;
    var ndecl: usize = 0;
    for (0..nscopes) |i| if (zcaps[i] == null) {
        decl_scopes[ndecl] = i;
        ndecl += 1;
    };
    var redecl_rejected: usize = 0;
    // modül tabloları
    var zglobs: std.StringHashMapUnmanaged(Type) = .{};
    var zconsts: std.StringHashMapUnmanaged(i64) = .{};

    for (0..ops) |_| {
        const si = r.intRangeLessThan(usize, 0, nscopes);
        const ni = r.intRangeLessThan(usize, 0, var_names.len);
        const ti = r.intRangeLessThan(usize, 0, npool);
        const name = var_names[ni];
        switch (r.intRangeLessThan(u8, 0, 12)) {
            0, 1 => {
                const sd = if (r.intRangeLessThan(u8, 0, 10) < 9) decl_scopes[r.intRangeLessThan(usize, 0, ndecl)] else si;
                try zscopes[sd].declare(a, name, pool[ti]);
                api.declare(nscope[sd], vsyms[ni], pool_ids[ti]);
            },
            2 => {
                const zl = zscopes[si].lookupLocal(name);
                const nl = api.lookupLocal(nscope[si], vsyms[ni]);
                try cmpLookup(tapi, &csyms, zl, nl, "lookupLocal", name);
            },
            3, 4 => {
                const zl = try zscopes[si].lookup(a, name);
                const nl = api.lookup(nscope[si], vsyms[ni]);
                try cmpLookup(tapi, &csyms, zl, nl, "lookup", name);
            },
            5 => {
                if (zscopes[si].existsInChain(name) != api.exists(nscope[si], vsyms[ni])) return fail("existsInChain farkı: {s}", .{name});
            },
            6, 7 => {
                // Checker.declareVar (checker.zig) kararının referansı
                const sd = if (r.intRangeLessThan(u8, 0, 10) < 9) decl_scopes[r.intRangeLessThan(usize, 0, ndecl)] else si;
                var ok = true;
                if (zscopes[sd].lookupLocal(name)) |existing| {
                    const both = existing == .class and pool[ti] == .class and
                        (std.mem.eql(u8, existing.class, pool[ti].class) or (!nonarc[classIx(existing.class)] and !nonarc[classIx(pool[ti].class)]));
                    if (!types.eql(existing, pool[ti]) and !both) ok = false;
                }
                if (ok) try zscopes[sd].declare(a, name, pool[ti]) else redecl_rejected += 1;
                const nr = api.declareVar(nscope[sd], vsyms[ni], pool_ids[ti]);
                if ((nr == 0) != ok) return fail("declareVar kararı farkı: {s} (zig ok={}, nox={d})", .{ name, ok, nr });
            },
            8 => {
                try zglobs.put(a, name, pool[ti]);
                api.tabPut(0, vsyms[ni], pool_ids[ti]);
            },
            9 => {
                const zh = zglobs.get(name);
                if ((zh != null) != api.tabHas(0, vsyms[ni])) return fail("module_globals.contains farkı: {s}", .{name});
                if (zh) |t| if (td.build(tapi, &csyms, t) != api.tabGet(0, vsyms[ni])) return fail("module_globals.get farkı: {s}", .{name});
            },
            10 => {
                const v: i64 = r.intRangeAtMost(i64, -50, 50);
                try zconsts.put(a, name, v);
                api.tabPut(1, vsyms[ni], v);
            },
            else => {
                if (r.boolean()) {
                    const zr = zconsts.remove(name);
                    if (zr != api.tabRemove(1, vsyms[ni])) return fail("module_int_consts.remove farkı: {s}", .{name});
                } else {
                    const zh = zconsts.get(name);
                    if ((zh != null) != api.tabHas(1, vsyms[ni])) return fail("module_int_consts.contains farkı: {s}", .{name});
                    if (zh) |v| if (v != api.tabGet(1, vsyms[ni])) return fail("module_int_consts.get farkı: {s}", .{name});
                }
            },
        }
    }

    // yakalama kümeleri: kapsam başına küme eşitliği (Zig HashMap sırası belirsiz → ada göre)
    var ncap: usize = 0;
    for (0..nscopes) |i| {
        const zc = zcaps[i];
        const cn: usize = @intCast(api.capsN(nscope[i]));
        const zn: usize = if (zc) |m| m.count() else 0;
        if (cn != zn) return fail("kapsam {d}: yakalama sayısı zig={d} nox={d}", .{ i, zn, cn });
        ncap += cn;
        var k: i64 = 0;
        while (k < cn) : (k += 1) {
            const sym = api.cap(nscope[i], k, 0);
            const ty = api.cap(nscope[i], k, 1);
            const ni = for (vsyms, 0..) |s, ix| {
                if (s == sym) break ix;
            } else return fail("yakalama sembolü bilinmiyor: {d}", .{sym});
            const zt = zc.?.get(var_names[ni]) orelse return fail("kapsam {d}: Nox yakalaması Zig'de yok: {s}", .{ i, var_names[ni] });
            if (td.build(tapi, &csyms, zt) != ty) return fail("kapsam {d}: yakalama tipi farkı: {s}", .{ i, var_names[ni] });
        }
    }
    if (zglobs.count() != api.tabLive(0)) return fail("module_globals sayısı zig={d} nox={d}", .{ zglobs.count(), api.tabLive(0) });
    if (zconsts.count() != api.tabLive(1)) return fail("module_int_consts sayısı zig={d} nox={d}", .{ zconsts.count(), api.tabLive(1) });
    const v = tapi.validate();
    if (v != 0) return fail("ty_validate hata kodu {d}", .{v});
    return .{ .ops = ops, .scopes = nscopes, .captures = ncap, .redecl_rejected = redecl_rejected };
}

fn classIx(name: []const u8) usize {
    for (td.class_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    unreachable;
}

fn cmpLookup(tapi: glue.TypeApi, csyms: []const i64, z: ?Type, n: i64, what: []const u8, name: []const u8) !void {
    if (z) |t| {
        if (n < 0) return fail("{s}({s}): zig buldu, nox bulamadı", .{ what, name });
        if (td.build(tapi, csyms, t) != n) return fail("{s}({s}): tip farkı", .{ what, name });
    } else if (n >= 0) return fail("{s}({s}): nox buldu, zig bulamadı", .{ what, name });
}

pub const AssignResult = struct { files: usize, skipped: usize, names: usize, assigned: usize };

/// Her dosyayı iki ayrıştırıcıyla okur (ayrıştırılamayan hata fixture'ları atlanır) ve dosyadaki her sözcük için `stmtsAssignName` sonucunu karşılaştırır.
pub fn runAssign(gpa: std.mem.Allocator, io: std.Io, nrt: glue.Runtime, paths: []const []const u8) !AssignResult {
    const api = nrt.check();
    var res: AssignResult = .{ .files = 0, .skipped = 0, .names = 0, .assigned = 0 };
    for (paths) |path| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch {
            res.skipped += 1;
            continue;
        };
        // Zig AST (Zig sözcükleyicisiyle; kancayı geçici kapat)
        const saved = lexer.hook;
        lexer.hook = null;
        const toks = lexer.tokenize(a, src) catch {
            lexer.hook = saved;
            res.skipped += 1;
            continue;
        };
        lexer.hook = saved;
        var p = parser_mod.Parser.init(a, toks);
        const module = p.parseModule() catch {
            res.skipped += 1;
            continue;
        };
        if (nrt.parseRaw(src) != 0) {
            std.debug.print("ck-diff: {s}: Zig ayrıştırdı, Nox ayrıştıramadı\n", .{path});
            return error.Mismatch;
        }
        res.files += 1;
        // dosyadaki benzersiz sözcükler (ilk görünüm sırası, en çok 120)
        var seen = std.StringHashMapUnmanaged(void){};
        var i: usize = 0;
        var count: usize = 0;
        while (i < src.len and count < 120) {
            const c = src[i];
            if (std.ascii.isAlphabetic(c) or c == '_') {
                var j = i + 1;
                while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
                const w = src[i..j];
                i = j;
                if (seen.contains(w)) continue;
                try seen.put(a, w, {});
                count += 1;
                const want = checker.Checker.stmtsAssignName(module.body, w);
                const got = api.assignsName(w);
                if (want != got) {
                    std.debug.print("ck-diff: stmtsAssignName farkı: {s} ad={s} zig={} nox={}\n", .{ path, w, want, got });
                    return error.Mismatch;
                }
                res.names += 1;
                if (want) res.assigned += 1;
            } else i += 1;
        }
    }
    return res;
}

fn lcg(x: u64) u64 {
    return (x * 1103515245 + 12345) & 2147483647;
}

/// `ck-bench` Zig tarafı: Nox `nox_ck_bench` ile AYNI iş yükü (GERÇEK `checker.Scope`, dize anahtarlı sözlükler) ve AYNI sağlama toplamı. `names` zamanlamanın DIŞINDA hazırlanır.
pub fn benchZig(a: std.mem.Allocator, names: []const []const u8, seed: u64, ns: usize, m: usize) !i64 {
    const nn = names.len;
    const scopes = try a.alloc(checker.Scope, ns);
    const caps = try a.alloc(std.StringHashMapUnmanaged(Type), ns);
    for (scopes, caps, 0..) |*s, *c, i| {
        c.* = .{};
        s.* = .{};
        if (i > 0) s.parent = &scopes[i - 1];
        if (i % 4 == 3) s.captures = c;
    }
    const tys = [_]Type{ .int, .float, .boolean, .str, .none };
    var x: u64 = seed & 2147483647;
    var acc: i64 = 0;
    for (0..m) |_| {
        x = lcg(x);
        const op = (x >> 6) % 10;
        x = lcg(x);
        const s = (x >> 4) % ns;
        x = lcg(x);
        const sym = (x >> 4) % nn;
        if (op < 7) {
            const t = try scopes[s].lookup(a, names[sym]);
            acc += if (t) |v| @as(i64, switch (v) {
                .int => 0,
                .float => 1,
                .boolean => 2,
                .str => 3,
                .none => 4,
                else => unreachable,
            }) + 1 else 0;
        } else {
            x = lcg(x);
            try scopes[s].declare(a, names[sym], tys[(x >> 4) % 5]);
        }
        // Nox: yok = -1 → `-1 + 1 = 0`; var = TypeId + 1
    }
    var ncap: i64 = 0;
    for (caps) |c| ncap += @intCast(c.count());
    return acc + ncap;
}

pub const CheckResult = struct { files: usize, skipped_parse: usize, unsupported: usize, accepted: usize, rejected: usize, diags: usize };

/// `ck-diff check`: her dosyayı iki ayrıştırıcıyla okur; Nox denetleyicisi KAPSAM İÇİ dediği (durum 0/1) programlarda GERÇEK `checker.check` ile sonuç (kabul/ret), hata kodu adı, ileti ve
/// TÜM tanılamalar (kod, satır, ileti, span) eşit olmalıdır. Kapsam dışı (durum 2) dosyalar sayılır, karşılaştırılmaz.
pub fn runCheck(gpa: std.mem.Allocator, io: std.Io, nrt: glue.Runtime, paths: []const []const u8, verbose: bool) !CheckResult {
    const api = nrt.check();
    var res: CheckResult = .{ .files = 0, .skipped_parse = 0, .unsupported = 0, .accepted = 0, .rejected = 0, .diags = 0 };
    for (paths) |path| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch {
            res.skipped_parse += 1;
            continue;
        };
        const saved = lexer.hook;
        lexer.hook = null;
        const toks = lexer.tokenize(a, src) catch {
            lexer.hook = saved;
            res.skipped_parse += 1;
            continue;
        };
        lexer.hook = saved;
        var p = parser_mod.Parser.init(a, toks);
        const module = p.parseModule() catch {
            res.skipped_parse += 1;
            continue;
        };
        if (nrt.parseRaw(src) != 0) {
            std.debug.print("ck-diff: {s}: Zig ayrıştırdı, Nox ayrıştıramadı\n", .{path});
            return error.Mismatch;
        }
        res.files += 1;
        _ = nrt.types().reset(); // tip tablosu + sembol havuzu taze (sabit kimlikler kurulu)
        const status = api.checkRun();
        if (status < 0) {
            std.debug.print("ck-diff: {s}: Nox iç hata (beklenmeyen istisna)\n", .{path});
            return error.Mismatch;
        }
        if (status == 2) {
            res.unsupported += 1;
            continue;
        }
        const outcome = checker.check(a, module);
        switch (outcome) {
            .ok => {
                if (status != 0) {
                    std.debug.print("ck-diff: {s}: Zig kabul etti, Nox status={d}\n", .{ path, status });
                    return error.Mismatch;
                }
                res.accepted += 1;
            },
            .err => |e| {
                if (status != 1) {
                    std.debug.print("ck-diff: {s}: Zig reddetti ({s}: {s}), Nox status={d}\n", .{ path, @errorName(e.code), e.message, status });
                    return error.Mismatch;
                }
                res.rejected += 1;
                const ncode = try api.text(a, 0, 0);
                const nmsg = try api.text(a, 1, 0);
                if (!std.mem.eql(u8, ncode, @errorName(e.code)) or !std.mem.eql(u8, nmsg, e.message)) {
                    std.debug.print("ck-diff: {s}: sonuç farkı\n  zig: {s}: {s}\n  nox: {s}: {s}\n", .{ path, @errorName(e.code), e.message, ncode, nmsg });
                    return error.Mismatch;
                }
                if (e.all.len != @as(usize, @intCast(api.diagN()))) {
                    std.debug.print("ck-diff: {s}: tanılama sayısı zig={d} nox={d}\n", .{ path, e.all.len, api.diagN() });
                    for (e.all) |d| std.debug.print("  zig: {s} satır {d}: {s}\n", .{ @errorName(d.code), d.line, d.message });
                    var di: i64 = 0;
                    while (di < api.diagN()) : (di += 1) std.debug.print("  nox: {s} satır {d}: {s}\n", .{ try api.text(a, 2, di), api.diagInt(di, 0), try api.text(a, 3, di) });
                    return error.Mismatch;
                }
                for (e.all, 0..) |d, i| {
                    const ii: i64 = @intCast(i);
                    const dc = try api.text(a, 2, ii);
                    const dm = try api.text(a, 3, ii);
                    const sp = d.span;
                    const same = std.mem.eql(u8, dc, @errorName(d.code)) and std.mem.eql(u8, dm, d.message) and api.diagInt(ii, 0) == d.line and
                        api.diagInt(ii, 1) == sp.start_byte and api.diagInt(ii, 2) == sp.end_byte and api.diagInt(ii, 3) == sp.start_line and
                        api.diagInt(ii, 4) == sp.start_col and api.diagInt(ii, 5) == sp.end_line and api.diagInt(ii, 6) == sp.end_col;
                    if (!same) {
                        std.debug.print("ck-diff: {s}: tanılama {d} farkı\n  zig: {s} satır {d}: {s} span {d}-{d} {d}:{d}-{d}:{d}\n  nox: {s} satır {d}: {s} span {d}-{d} {d}:{d}-{d}:{d}\n", .{
                            path,                  i,                  @errorName(d.code),    d.line,                 d.message,              sp.start_byte,          sp.end_byte,            sp.start_line,          sp.start_col,
                            sp.end_line,           sp.end_col,         dc,                    api.diagInt(ii, 0),     dm,                     api.diagInt(ii, 1),     api.diagInt(ii, 2),     api.diagInt(ii, 3),
                            api.diagInt(ii, 4),    api.diagInt(ii, 5), api.diagInt(ii, 6),
                        });
                        return error.Mismatch;
                    }
                    res.diags += 1;
                }
            },
        }
        if (verbose) std.debug.print("ck-diff: {s}: eşit\n", .{path});
    }
    return res;
}
