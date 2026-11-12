//! Nox WASM köprüsü — ikili format ayrıştırıcı (AGENTS.md §11).
//!
//! WASM 2.0 çekirdeğinin (SIMD ve threads hariç) tüm bölümlerini ayrıştırır: Type, Import, Function, Table, Memory, Global, Export, Start, Element
//! (8 biçim), DataCount, Code, Data; Custom bölümleri (isimler, `producers`...) atlanır. Çok değerli dönüş, bulk-memory, reference types ve
//! sign-extension/saturating dönüşümler dil düzeyinde `compile.zig`de doğrulanır; burada yalnızca YAPI ayrıştırılır. Kod gövdeleri ve veri parçaları
//! girdi baytlarına işaret eder (kopya değil): `bytes`, `Module` yaşadığı sürece canlı kalmalıdır.
//!
//! Tüm kalıcı tahsisler tek bir arenadan gelir (`Module.deinit` hepsini bırakır); bozuk bir ikili (GÜVENİLMEYEN kaynak, AGENTS §9.5) hiçbir yolda
//! sızıntı bırakmaz. Vektör sayıları kalan bayt sayısıyla sınırlanır (her öğe en az 1 bayt): sahte büyük sayı tahsis patlatmaz.

const std = @import("std");

pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
    /// v2.1.98 (W5 SIMD): 128 bit vektör. Yorumlayıcıda değer, `stack[sp]` yuvasının yanında aynı indeksli `vstack[sp]` GÖLGE yuvasında yaşar
    /// (tek yuva/değer düzeni korunur; yalnızca SIMD kullanan işlevler bu gölgeyi okur/yazar).
    v128 = 0x7b,
    funcref = 0x70,
    externref = 0x6f,

    pub fn isRef(self: ValType) bool {
        return self == .funcref or self == .externref;
    }
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,

    pub fn eql(a: FuncType, b: FuncType) bool {
        return std.mem.eql(ValType, a.params, b.params) and std.mem.eql(ValType, a.results, b.results);
    }
};

pub const FuncBody = struct {
    locals: []const ValType,
    code: []const u8,
};

pub const ExportKind = enum(u8) {
    func = 0,
    table = 1,
    mem = 2,
    global = 3,
};

pub const WasmExport = struct {
    name: []const u8,
    kind: ExportKind,
    index: u32,
};

/// `shared`: threads önerisi (bayrak 0x03: üst sınır ZORUNLU); yalnızca bellek için geçerlidir.
pub const Limits = struct { min: u32, max: ?u32, shared: bool = false };
pub const TableType = struct { elem: ValType, limits: Limits };
pub const GlobalType = struct { valtype: ValType, mutable: bool };

pub const ImportDesc = union(enum) {
    func: u32,
    table: TableType,
    mem: Limits,
    global: GlobalType,
};

pub const Import = struct { module: []const u8, name: []const u8, desc: ImportDesc };

/// Sabit ifade (global başlangıcı, segment ofseti, öğe): tek bir sabit talimat.
pub const ConstExpr = union(enum) {
    i32: i32,
    i64: i64,
    f32: u32,
    f64: u64,
    global_get: u32,
    ref_null: ValType,
    ref_func: u32,
};

pub const Global = struct { ty: GlobalType, init: ConstExpr };

pub const ElemMode = enum { active, passive, declarative };
pub const Elem = struct {
    mode: ElemMode,
    table: u32,
    offset: ConstExpr,
    elem_type: ValType,
    items: []const ConstExpr,
};

pub const DataMode = enum { active, passive };
pub const Data = struct {
    mode: DataMode,
    mem: u32,
    offset: ConstExpr,
    bytes: []const u8,
};

pub const MAX_LOCALS: u64 = 50_000;
pub const MAX_PAGES: u32 = 65536;

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    types: []FuncType = &.{},
    imports: []Import = &.{},
    /// Tür indeksleri, TÜM işlev indeks uzayı için (önce içe aktarılanlar, sonra tanımlananlar).
    func_type_indices: []u32 = &.{},
    num_imported_funcs: u32 = 0,
    num_imported_tables: u32 = 0,
    num_imported_mems: u32 = 0,
    num_imported_globals: u32 = 0,
    /// İçe aktarılanlar DAHİL tüm tablo/bellek/global tanımları (indeks uzayı sırası).
    tables: []TableType = &.{},
    mems: []Limits = &.{},
    globals: []GlobalType = &.{},
    /// Yalnızca bu modülün tanımladığı globallerin başlangıç ifadeleri.
    global_inits: []ConstExpr = &.{},
    /// Yalnızca tanımlanan işlevlerin gövdeleri (indeks: `func_index - num_imported_funcs`).
    bodies: []FuncBody = &.{},
    exports: []WasmExport = &.{},
    start: ?u32 = null,
    elems: []Elem = &.{},
    datas: []Data = &.{},
    data_count: ?u32 = null,

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
    }

    /// Adı `name` olan, `func` türünde bir export bulur; işlev indeksini döner.
    pub fn findExportedFunc(self: *const Module, name: []const u8) ?u32 {
        for (self.exports) |e| {
            if (e.kind == .func and std.mem.eql(u8, e.name, name)) return e.index;
        }
        return null;
    }

    pub fn typeOf(self: *const Module, func_index: u32) FuncType {
        return self.types[self.func_type_indices[func_index]];
    }

    pub fn numFuncs(self: *const Module) u32 {
        return @intCast(self.func_type_indices.len);
    }
};

pub const ParseError = error{ InvalidModule, UnsupportedVersion, OutOfMemory };

/// Bayt akışı okuyucusu (modül ayrıştırıcısı ve `compile.zig` paylaşır).
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.pos;
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.bytes.len;
    }

    pub fn byte(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return error.InvalidModule;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn slice(self: *Reader, len: usize) ![]const u8 {
        if (len > self.remaining()) return error.InvalidModule;
        const s = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }

    pub fn skip(self: *Reader, len: usize) !void {
        if (len > self.remaining()) return error.InvalidModule;
        self.pos += len;
    }

    /// LEB128 imzasız tamsayı. En çok `ceil(bits/7)` bayt; son bayttaki fazladan (kanonik olmayan) yüksek bitler reddedilir
    /// (Faz X.1: ESKİ `shift: u5` tasarımı 6+ devam baytında taşma paniğine yol açıyordu).
    fn readUnsigned(self: *Reader, comptime bits: u7) !u64 {
        const max_bytes = (bits + 6) / 7;
        var result: u64 = 0;
        var shift: u7 = 0;
        var n: u8 = 0;
        while (true) {
            if (n >= max_bytes) return error.InvalidModule;
            const b = try self.byte();
            n += 1;
            result |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) {
                if (bits < 64 and result >> @intCast(bits) != 0) return error.InvalidModule;
                return result;
            }
            shift += 7;
        }
    }

    /// LEB128 işaretli tamsayı; sonuç `bits` bitlik işaretli aralığa sığmalıdır.
    fn readSigned(self: *Reader, comptime bits: u7) !i64 {
        const max_bytes = (bits + 6) / 7;
        var result: u64 = 0;
        var shift: u7 = 0;
        var n: u8 = 0;
        while (true) {
            if (n >= max_bytes) return error.InvalidModule;
            const b = try self.byte();
            n += 1;
            result |= @as(u64, b & 0x7f) << @intCast(shift);
            shift += 7;
            if (b & 0x80 == 0) {
                if (shift < 64 and (b & 0x40) != 0) result |= ~@as(u64, 0) << @intCast(shift);
                const v: i64 = @bitCast(result);
                if (bits < 64) {
                    const lim: i64 = @as(i64, 1) << @intCast(bits - 1);
                    if (v < -lim or v >= lim) return error.InvalidModule;
                }
                return v;
            }
        }
    }

    pub fn readVarU32(self: *Reader) !u32 {
        return @intCast(try self.readUnsigned(32));
    }

    pub fn readVarI32(self: *Reader) !i32 {
        return @intCast(try self.readSigned(32));
    }

    pub fn readVarI64(self: *Reader) !i64 {
        return try self.readSigned(64);
    }

    /// Blok tipi için 33 bitlik işaretli LEB128.
    pub fn readVarS33(self: *Reader) !i64 {
        return try self.readSigned(33);
    }

    pub fn readF32Bits(self: *Reader) !u32 {
        const s = try self.slice(4);
        return std.mem.readInt(u32, s[0..4], .little);
    }

    pub fn readF64Bits(self: *Reader) !u64 {
        const s = try self.slice(8);
        return std.mem.readInt(u64, s[0..8], .little);
    }

    pub fn readValType(self: *Reader) !ValType {
        const b = try self.byte();
        return switch (b) {
            0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x70, 0x6f => @enumFromInt(b),
            else => error.InvalidModule,
        };
    }

    pub fn readRefType(self: *Reader) !ValType {
        const t = try self.readValType();
        if (!t.isRef()) return error.InvalidModule;
        return t;
    }

    pub fn readName(self: *Reader) ![]const u8 {
        const len = try self.readVarU32();
        const s = try self.slice(len);
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidModule;
        return s;
    }

    /// Bir vektörün eleman sayısı; her eleman en az 1 bayt kapladığından kalan bayttan büyük sayı reddedilir.
    pub fn readCount(self: *Reader) !usize {
        const n = try self.readVarU32();
        if (n > self.remaining()) return error.InvalidModule;
        return n;
    }

    fn readLimits(self: *Reader) !Limits {
        const flag = try self.byte();
        switch (flag) {
            0 => return .{ .min = try self.readVarU32(), .max = null },
            1 => {
                const min = try self.readVarU32();
                const max = try self.readVarU32();
                if (min > max) return error.InvalidModule;
                return .{ .min = min, .max = max };
            },
            3 => {
                const min = try self.readVarU32();
                const max = try self.readVarU32();
                if (min > max) return error.InvalidModule;
                return .{ .min = min, .max = max, .shared = true };
            },
            else => return error.InvalidModule,
        }
    }
};

fn readMemLimits(r: *Reader) !Limits {
    const l = try r.readLimits();
    if (l.min > MAX_PAGES) return error.InvalidModule;
    if (l.max) |m| if (m > MAX_PAGES) return error.InvalidModule;
    return l;
}

fn readTableType(r: *Reader) !TableType {
    const elem = try r.readRefType();
    const l = try r.readLimits();
    if (l.shared) return error.InvalidModule;
    return .{ .elem = elem, .limits = l };
}

fn readGlobalType(r: *Reader) !GlobalType {
    const vt = try r.readValType();
    const m = try r.byte();
    if (m > 1) return error.InvalidModule;
    return .{ .valtype = vt, .mutable = m == 1 };
}

fn readConstExpr(r: *Reader) !ConstExpr {
    const op = try r.byte();
    const e: ConstExpr = switch (op) {
        0x41 => .{ .i32 = try r.readVarI32() },
        0x42 => .{ .i64 = try r.readVarI64() },
        0x43 => .{ .f32 = try r.readF32Bits() },
        0x44 => .{ .f64 = try r.readF64Bits() },
        0x23 => .{ .global_get = try r.readVarU32() },
        0xd0 => .{ .ref_null = try r.readRefType() },
        0xd2 => .{ .ref_func = try r.readVarU32() },
        else => return error.InvalidModule,
    };
    if ((try r.byte()) != 0x0b) return error.InvalidModule;
    return e;
}

fn sectionRank(id: u8) ?u8 {
    return switch (id) {
        1...9 => id,
        12 => 10,
        10 => 11,
        11 => 12,
        else => null,
    };
}

pub fn parse(backing: std.mem.Allocator, bytes: []const u8) ParseError!Module {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();
    var m: Module = .{ .arena = undefined };
    parseInto(a, &m, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedVersion => return error.UnsupportedVersion,
        else => return error.InvalidModule,
    };
    m.arena = arena;
    return m;
}

fn parseInto(a: std.mem.Allocator, m: *Module, bytes: []const u8) !void {
    var r: Reader = .{ .bytes = bytes };
    if (bytes.len < 8) return error.InvalidModule;
    if (!std.mem.eql(u8, try r.slice(4), "\x00asm")) return error.InvalidModule;
    if (!std.mem.eql(u8, try r.slice(4), "\x01\x00\x00\x00")) return error.UnsupportedVersion;

    var imports: std.ArrayList(Import) = .empty;
    var ftypes: std.ArrayList(u32) = .empty; // tüm işlev indeks uzayı
    var tables: std.ArrayList(TableType) = .empty;
    var mems: std.ArrayList(Limits) = .empty;
    var globals: std.ArrayList(GlobalType) = .empty;
    var ginits: std.ArrayList(ConstExpr) = .empty;
    var exports: std.ArrayList(WasmExport) = .empty;
    var elems: std.ArrayList(Elem) = .empty;
    var datas: std.ArrayList(Data) = .empty;
    var bodies: std.ArrayList(FuncBody) = .empty;
    var types: std.ArrayList(FuncType) = .empty;
    var declared_funcs: usize = 0;
    var saw_code = false;
    var last_rank: u8 = 0;

    while (!r.atEnd()) {
        const id = try r.byte();
        const size = try r.readVarU32();
        if (size > r.remaining()) return error.InvalidModule;
        const end = r.pos + size;
        var sr: Reader = .{ .bytes = bytes[0..end], .pos = r.pos };
        if (id != 0) {
            const rank = sectionRank(id) orelse return error.InvalidModule;
            if (rank <= last_rank) return error.InvalidModule;
            last_rank = rank;
        }
        switch (id) {
            0 => {}, // custom: atla
            1 => {
                const n = try sr.readCount();
                try types.ensureTotalCapacity(a, n);
                for (0..n) |_| {
                    if ((try sr.byte()) != 0x60) return error.InvalidModule;
                    const np = try sr.readCount();
                    const params = try a.alloc(ValType, np);
                    for (params) |*p| p.* = try sr.readValType();
                    const nr = try sr.readCount();
                    const results = try a.alloc(ValType, nr);
                    for (results) |*p| p.* = try sr.readValType();
                    types.appendAssumeCapacity(.{ .params = params, .results = results });
                }
            },
            2 => {
                const n = try sr.readCount();
                try imports.ensureTotalCapacity(a, n);
                for (0..n) |_| {
                    const mod_name = try sr.readName();
                    const name = try sr.readName();
                    const kind = try sr.byte();
                    const desc: ImportDesc = switch (kind) {
                        0 => blk: {
                            const ti = try sr.readVarU32();
                            if (ti >= types.items.len) return error.InvalidModule;
                            try ftypes.append(a, ti);
                            m.num_imported_funcs += 1;
                            break :blk .{ .func = ti };
                        },
                        1 => blk: {
                            const t = try readTableType(&sr);
                            try tables.append(a, t);
                            m.num_imported_tables += 1;
                            break :blk .{ .table = t };
                        },
                        2 => blk: {
                            const l = try readMemLimits(&sr);
                            try mems.append(a, l);
                            m.num_imported_mems += 1;
                            break :blk .{ .mem = l };
                        },
                        3 => blk: {
                            const g = try readGlobalType(&sr);
                            try globals.append(a, g);
                            m.num_imported_globals += 1;
                            break :blk .{ .global = g };
                        },
                        else => return error.InvalidModule,
                    };
                    imports.appendAssumeCapacity(.{ .module = mod_name, .name = name, .desc = desc });
                }
            },
            3 => {
                const n = try sr.readCount();
                declared_funcs = n;
                try ftypes.ensureUnusedCapacity(a, n);
                for (0..n) |_| {
                    const ti = try sr.readVarU32();
                    if (ti >= types.items.len) return error.InvalidModule;
                    ftypes.appendAssumeCapacity(ti);
                }
            },
            4 => {
                const n = try sr.readCount();
                for (0..n) |_| try tables.append(a, try readTableType(&sr));
            },
            5 => {
                const n = try sr.readCount();
                for (0..n) |_| try mems.append(a, try readMemLimits(&sr));
            },
            6 => {
                const n = try sr.readCount();
                for (0..n) |_| {
                    const g = try readGlobalType(&sr);
                    try globals.append(a, g);
                    try ginits.append(a, try readConstExpr(&sr));
                }
            },
            7 => {
                const n = try sr.readCount();
                try exports.ensureTotalCapacity(a, n);
                for (0..n) |_| {
                    const name = try sr.readName();
                    const kb = try sr.byte();
                    if (kb > 3) return error.InvalidModule;
                    const idx = try sr.readVarU32();
                    for (exports.items) |e| if (std.mem.eql(u8, e.name, name)) return error.InvalidModule;
                    exports.appendAssumeCapacity(.{ .name = name, .kind = @enumFromInt(kb), .index = idx });
                }
            },
            8 => m.start = try sr.readVarU32(),
            9 => {
                const n = try sr.readCount();
                try elems.ensureTotalCapacity(a, n);
                for (0..n) |_| elems.appendAssumeCapacity(try readElem(a, &sr));
            },
            12 => m.data_count = try sr.readVarU32(),
            10 => {
                saw_code = true;
                const n = try sr.readCount();
                if (n != declared_funcs) return error.InvalidModule;
                try bodies.ensureTotalCapacity(a, n);
                for (0..n) |_| {
                    const body_size = try sr.readVarU32();
                    if (body_size > sr.remaining()) return error.InvalidModule;
                    const body_end = sr.pos + body_size;
                    var br: Reader = .{ .bytes = bytes[0..body_end], .pos = sr.pos };
                    const ndecl = try br.readCount();
                    var locals: std.ArrayList(ValType) = .empty;
                    var total: u64 = 0;
                    for (0..ndecl) |_| {
                        const cnt = try br.readVarU32();
                        const vt = try br.readValType();
                        total += cnt;
                        if (total > MAX_LOCALS) return error.InvalidModule;
                        try locals.appendNTimes(a, vt, cnt);
                    }
                    bodies.appendAssumeCapacity(.{ .locals = try locals.toOwnedSlice(a), .code = bytes[br.pos..body_end] });
                    sr.pos = body_end;
                }
            },
            11 => {
                const n = try sr.readCount();
                if (m.data_count) |dc| if (dc != n) return error.InvalidModule;
                try datas.ensureTotalCapacity(a, n);
                for (0..n) |_| {
                    const flag = try sr.readVarU32();
                    var d: Data = .{ .mode = .active, .mem = 0, .offset = .{ .i32 = 0 }, .bytes = &.{} };
                    switch (flag) {
                        0 => d.offset = try readConstExpr(&sr),
                        1 => d.mode = .passive,
                        2 => {
                            d.mem = try sr.readVarU32();
                            d.offset = try readConstExpr(&sr);
                        },
                        else => return error.InvalidModule,
                    }
                    const len = try sr.readVarU32();
                    d.bytes = try sr.slice(len);
                    datas.appendAssumeCapacity(d);
                }
            },
            else => return error.InvalidModule,
        }
        if (id != 0 and sr.pos != end) return error.InvalidModule; // bölüm gövdesi tam tüketilmeli
        r.pos = end;
    }

    if (declared_funcs != 0 and !saw_code) return error.InvalidModule;
    if (m.data_count) |dc| if (dc != datas.items.len) return error.InvalidModule;

    m.types = try types.toOwnedSlice(a);
    m.imports = try imports.toOwnedSlice(a);
    m.func_type_indices = try ftypes.toOwnedSlice(a);
    m.tables = try tables.toOwnedSlice(a);
    m.mems = try mems.toOwnedSlice(a);
    m.globals = try globals.toOwnedSlice(a);
    m.global_inits = try ginits.toOwnedSlice(a);
    m.exports = try exports.toOwnedSlice(a);
    m.elems = try elems.toOwnedSlice(a);
    m.datas = try datas.toOwnedSlice(a);
    m.bodies = try bodies.toOwnedSlice(a);
}

fn readElem(a: std.mem.Allocator, r: *Reader) !Elem {
    const flag = try r.readVarU32();
    if (flag > 7) return error.InvalidModule;
    var e: Elem = .{ .mode = .active, .table = 0, .offset = .{ .i32 = 0 }, .elem_type = .funcref, .items = &.{} };
    const passive_or_decl = flag & 1 != 0;
    const explicit_table = flag & 2 != 0;
    const exprs = flag & 4 != 0;
    if (!passive_or_decl) {
        if (explicit_table) e.table = try r.readVarU32();
        e.offset = try readConstExpr(r);
    } else {
        e.mode = if (explicit_table) .declarative else .passive;
    }
    if (passive_or_decl or explicit_table) {
        if (exprs) {
            e.elem_type = try r.readRefType();
        } else {
            if ((try r.byte()) != 0x00) return error.InvalidModule; // elemkind: funcref
        }
    }
    const n = try r.readCount();
    const items = try a.alloc(ConstExpr, n);
    for (items) |*it| {
        if (exprs) {
            it.* = try readConstExpr(r);
        } else {
            it.* = .{ .ref_func = try r.readVarU32() };
        }
    }
    e.items = items;
    return e;
}

const add_one_bytes = "\x00asm\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x04\x05\x01\x70\x01\x01\x01\x05\x03\x01\x00\x10\x06\x09\x01\x7f\x01\x41\x80\x80\xc0\x00\x0b\x07\x14\x02\x06memory\x02\x00\x07add_one\x00\x00\x0a\x09\x01\x07\x00\x20\x00\x41\x01\x6a\x0b";

test "parse: gerçek zig-derlenmiş bir add_one modülünü ayrıştırır" {
    var mod = try parse(std.testing.allocator, add_one_bytes);
    defer mod.deinit();

    try std.testing.expectEqual(@as(usize, 1), mod.types.len);
    try std.testing.expectEqual(@as(usize, 1), mod.types[0].params.len);
    try std.testing.expectEqual(ValType.i32, mod.types[0].params[0]);
    try std.testing.expectEqual(@as(usize, 1), mod.types[0].results.len);

    const idx = mod.findExportedFunc("add_one") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u32, 0), idx);
    try std.testing.expectEqual(@as(usize, 1), mod.bodies.len);
    try std.testing.expectEqualSlices(u8, "\x20\x00\x41\x01\x6a\x0b", mod.bodies[0].code);
    // bellek, tablo ve global bölümleri artık anlaşılır
    try std.testing.expectEqual(@as(usize, 1), mod.tables.len);
    try std.testing.expectEqual(@as(usize, 1), mod.mems.len);
    try std.testing.expectEqual(@as(u32, 16), mod.mems[0].min);
    try std.testing.expectEqual(@as(usize, 1), mod.globals.len);
    try std.testing.expect(mod.globals[0].mutable);
    try std.testing.expectEqual(@as(i32, 1048576), mod.global_inits[0].i32);
}

test "Reader.readVarU32: kanonik değerler doğru çözülür" {
    var r1 = Reader{ .bytes = &.{0x00} };
    try std.testing.expectEqual(@as(u32, 0), try r1.readVarU32());
    var r2 = Reader{ .bytes = &.{0x7f} };
    try std.testing.expectEqual(@as(u32, 127), try r2.readVarU32());
    var r3 = Reader{ .bytes = &.{ 0x80, 0x01 } };
    try std.testing.expectEqual(@as(u32, 128), try r3.readVarU32());
    var r4 = Reader{ .bytes = &.{ 0xac, 0x02 } };
    try std.testing.expectEqual(@as(u32, 300), try r4.readVarU32());
    var r5 = Reader{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x0f } };
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), try r5.readVarU32());
}

test "Reader.readVarU32: Faz X.1 — 6+ devam baytı ve kanonik olmayan son bayt reddedilir" {
    var r = Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 } };
    try std.testing.expectError(error.InvalidModule, r.readVarU32());
    var r2 = Reader{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x1f } };
    try std.testing.expectError(error.InvalidModule, r2.readVarU32());
}

test "Reader.readVarI32/I64/S33: işaretli LEB128" {
    var r1 = Reader{ .bytes = &.{0x00} };
    try std.testing.expectEqual(@as(i32, 0), try r1.readVarI32());
    var r2 = Reader{ .bytes = &.{0x7f} };
    try std.testing.expectEqual(@as(i32, -1), try r2.readVarI32());
    var r3 = Reader{ .bytes = &.{ 0xff, 0x00 } };
    try std.testing.expectEqual(@as(i32, 127), try r3.readVarI32());
    var r4 = Reader{ .bytes = &.{ 0x80, 0x7f } };
    try std.testing.expectEqual(@as(i32, -128), try r4.readVarI32());
    // INT32_MIN ve INT32_MAX
    var r5 = Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x78 } };
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), try r5.readVarI32());
    var r6 = Reader{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x07 } };
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), try r6.readVarI32());
    // i32 aralığı dışı reddedilir
    var r7 = Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x08 } };
    try std.testing.expectError(error.InvalidModule, r7.readVarI32());
    var r8 = Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 } };
    try std.testing.expectError(error.InvalidModule, r8.readVarI32());
    // i64 uçları
    var r9 = Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7f } };
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), try r9.readVarI64());
    var r10 = Reader{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 } };
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try r10.readVarI64());
    // blok tipi: -64 (0x40 = boş), 5 (tür indeksi)
    var r11 = Reader{ .bytes = &.{0x40} };
    try std.testing.expectEqual(@as(i64, -64), try r11.readVarS33());
    var r12 = Reader{ .bytes = &.{0x05} };
    try std.testing.expectEqual(@as(i64, 5), try r12.readVarS33());
}

test "parse: bozuk girdiler InvalidModule verir, sızıntı yok" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidModule, parse(a, ""));
    try std.testing.expectError(error.InvalidModule, parse(a, "\x00asx\x01\x00\x00\x00"));
    try std.testing.expectError(error.UnsupportedVersion, parse(a, "\x00asm\x02\x00\x00\x00"));
    // sahte büyük vektör sayısı: tür bölümü 0xffffffff girdi iddia eder
    try std.testing.expectError(error.InvalidModule, parse(a, "\x00asm\x01\x00\x00\x00\x01\x06\xff\xff\xff\xff\x0f\x00"));
    // add_one'ın her kısaltılmış öneki: ya geçerli ya InvalidModule, asla çökme/sızıntı
    for (0..add_one_bytes.len) |n| {
        if (parse(a, add_one_bytes[0..n])) |*ok| {
            var mm = ok.*;
            mm.deinit();
        } else |_| {}
    }
}

test "parse: import, element ve data bölümleri" {
    // (module (import "env" "f" (func (param i32))) (table 2 funcref) (memory 1) (elem (i32.const 0) func 0) (data (i32.const 8) "hi"))
    const bytes = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x05\x01\x60\x01\x7f\x00" ++ // type
        "\x02\x09\x01\x03env\x01f\x00\x00" ++ // import env.f func type0
        "\x04\x04\x01\x70\x00\x02" ++ // table funcref min 2
        "\x05\x03\x01\x00\x01" ++ // memory min 1
        "\x09\x07\x01\x00\x41\x00\x0b\x01\x00" ++ // elem active table0 offset 0, [func 0]
        "\x0b\x08\x01\x00\x41\x08\x0b\x02hi"; // data active mem0 offset 8 "hi"
    var mod = try parse(std.testing.allocator, bytes);
    defer mod.deinit();
    try std.testing.expectEqual(@as(u32, 1), mod.num_imported_funcs);
    try std.testing.expectEqual(@as(usize, 1), mod.func_type_indices.len);
    try std.testing.expectEqualStrings("env", mod.imports[0].module);
    try std.testing.expectEqual(@as(usize, 1), mod.elems.len);
    try std.testing.expectEqual(@as(u32, 0), mod.elems[0].items[0].ref_func);
    try std.testing.expectEqualStrings("hi", mod.datas[0].bytes);
    try std.testing.expectEqual(@as(i32, 8), mod.datas[0].offset.i32);
}
