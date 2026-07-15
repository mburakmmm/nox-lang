//! Nox WASM köprüsü — ikili format ayrıştırıcı (AGENTS.md §11).
//!
//! Minimal bir WASM ikili modül ayrıştırıcısı: yalnızca gerçekten
//! İHTİYAÇ duyulan bölümleri (Type=1, Function=3, Export=7, Code=10) tam
//! olarak ayrıştırır; diğer TÜM bölümleri (Import, Table, Memory, Global,
//! Start, Element, Data, ...) kendi bildirdikleri BAYT BOYUTUNA göre
//! atlar — WASM ikili formatının her bölümü kendi boyutunu taşıdığı için
//! bu, içeriklerini hiç anlamadan güvenle atlamayı mümkün kılar.
//!
//! **Kapsam sınırlaması (bilinçli, v0.1):** yalnızca `i32` parametre/dönüş
//! tipleri desteklenir; içe aktarma (import) YOK — yalnızca modülün
//! KENDİ tanımladığı fonksiyonlar. Bkz. nox-teknik-spesifikasyon.md §3.13.

const std = @import("std");

pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
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

pub const Module = struct {
    allocator: std.mem.Allocator,
    types: []FuncType,
    func_type_indices: []u32,
    bodies: []FuncBody,
    exports: []WasmExport,

    pub fn deinit(self: *Module) void {
        for (self.types) |t| {
            self.allocator.free(t.params);
            self.allocator.free(t.results);
        }
        self.allocator.free(self.types);
        self.allocator.free(self.func_type_indices);
        for (self.bodies) |b| self.allocator.free(b.locals);
        self.allocator.free(self.bodies);
        for (self.exports) |e| self.allocator.free(e.name);
        self.allocator.free(self.exports);
    }

    /// Adı `name` olan, `func` türünde bir export bulur; fonksiyon
    /// indeksini döner (bulunamazsa `null`).
    pub fn findExportedFunc(self: *const Module, name: []const u8) ?u32 {
        for (self.exports) |e| {
            if (e.kind == .func and std.mem.eql(u8, e.name, name)) return e.index;
        }
        return null;
    }

    pub fn typeOf(self: *const Module, func_index: u32) FuncType {
        return self.types[self.func_type_indices[func_index]];
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.pos >= self.bytes.len) return error.UnexpectedEof;
        const b = self.bytes[self.pos];
        self.pos += 1;
        return b;
    }

    fn slice(self: *Reader, len: usize) ![]const u8 {
        if (self.pos + len > self.bytes.len) return error.UnexpectedEof;
        const s = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }

    fn skip(self: *Reader, len: usize) !void {
        if (self.pos + len > self.bytes.len) return error.UnexpectedEof;
        self.pos += len;
    }

    /// WASM'ın LEB128 imzasız değişken uzunluklu tamsayı kodlaması
    /// (bölüm/vektör boyutları, indeksler için kullanılır).
    ///
    /// **Faz X.1 (bkz. docs/uretim-hazirlik-analizi.md, P1 bulgusu #12):**
    /// bir `u32` LEB128 kodlaması EN FAZLA 5 baytla temsil edilir (5*7=35 ≥
    /// 32 bit). Bozuk/kötü niyetli bir `.wasm`, ART ARDA devam biti (0x80)
    /// TAŞIYAN 6+ bayt sağlarsa, ESKİ kod (`shift: u5`) `shift += 7`i 5.
    /// bayttan SONRA da çalıştırıp `u5`in TAŞIMASINA (28+7=35 > 31) — bu,
    /// güvenli derlemelerde bir PANİK (DoS), güvensiz derlemelerde
    /// TANIMSIZ DAVRANIŞ demekti. Düzeltme: (1) bayt sayısı 5 İLE
    /// SINIRLANIR (6. devam biti GÖRÜLÜRSE `error.InvalidModule`), (2) HİÇBİR
    /// taşma tuzağı TETİKLEMEMESİ İÇİN birikim `u64`de yapılır (`shift`
    /// yalnızca 0/7/14/21/28 değerlerini ALIR, `u64` İÇİN AÇIKÇA güvenli),
    /// (3) SONUÇ `u32`nin sınırlarını AŞARSA (kanonik-OLMAYAN bir kodlama —
    /// son baytın FAZLADAN yüksek bitleri sıfır DEĞİLSE) `error.InvalidModule`
    /// döner — sessizce KIRPILMAZ.
    fn readVarU32(self: *Reader) !u32 {
        var result: u64 = 0;
        var shift: u6 = 0;
        var nbytes: u8 = 0;
        while (true) {
            if (nbytes >= 5) return error.InvalidModule;
            const b = try self.byte();
            nbytes += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        if (result > std.math.maxInt(u32)) return error.InvalidModule;
        return @intCast(result);
    }

    /// LEB128 işaretli değişken uzunluklu tamsayı kodlaması (`i32.const`
    /// gibi sabit değerler için kullanılır). Bkz. `readVarU32`nin AYNI
    /// Faz X.1 belge notu — burada `i64` birikim + 5 baytlık ÜST SINIR +
    /// SONUÇ `i32` aralığına SIĞMA doğrulaması UYGULANIR.
    fn readVarI32(self: *Reader) !i32 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var nbytes: u8 = 0;
        var b: u8 = 0;
        while (true) {
            if (nbytes >= 5) return error.InvalidModule;
            b = try self.byte();
            nbytes += 1;
            result |= @as(i64, b & 0x7f) << shift;
            shift += 7;
            if (b & 0x80 == 0) break;
        }
        if (shift < 64 and (b & 0x40) != 0) {
            result |= @as(i64, -1) << shift;
        }
        if (result < std.math.minInt(i32) or result > std.math.maxInt(i32)) return error.InvalidModule;
        return @intCast(result);
    }

    fn readValType(self: *Reader) !ValType {
        const b = try self.byte();
        return switch (b) {
            0x7f, 0x7e, 0x7d, 0x7c => @enumFromInt(b),
            else => error.UnsupportedValType,
        };
    }
};

fn exportKindFromByte(b: u8) !ExportKind {
    return switch (b) {
        0, 1, 2, 3 => @enumFromInt(b),
        else => error.UnsupportedExportKind,
    };
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Module {
    var r: Reader = .{ .bytes = bytes };

    if (bytes.len < 8) return error.InvalidModule;
    const magic = try r.slice(4);
    if (!std.mem.eql(u8, magic, "\x00asm")) return error.InvalidModule;
    const version = try r.slice(4);
    if (!std.mem.eql(u8, version, "\x01\x00\x00\x00")) return error.UnsupportedVersion;

    var types: std.ArrayListUnmanaged(FuncType) = .empty;
    var func_type_indices: std.ArrayListUnmanaged(u32) = .empty;
    var bodies: std.ArrayListUnmanaged(FuncBody) = .empty;
    var exports: std.ArrayListUnmanaged(WasmExport) = .empty;

    while (r.pos < bytes.len) {
        const section_id = try r.byte();
        const section_size = try r.readVarU32();
        const section_end = r.pos + section_size;

        switch (section_id) {
            1 => { // Type
                const count = try r.readVarU32();
                try types.ensureTotalCapacity(allocator, count);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const form = try r.byte();
                    if (form != 0x60) return error.UnsupportedTypeForm;
                    const nparams = try r.readVarU32();
                    const params = try allocator.alloc(ValType, nparams);
                    for (params) |*p| p.* = try r.readValType();
                    const nresults = try r.readVarU32();
                    const results = try allocator.alloc(ValType, nresults);
                    for (results) |*res| res.* = try r.readValType();
                    try types.append(allocator, .{ .params = params, .results = results });
                }
            },
            3 => { // Function
                const count = try r.readVarU32();
                try func_type_indices.ensureTotalCapacity(allocator, count);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try func_type_indices.append(allocator, try r.readVarU32());
                }
            },
            7 => { // Export
                const count = try r.readVarU32();
                try exports.ensureTotalCapacity(allocator, count);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const name_len = try r.readVarU32();
                    const name = try allocator.dupe(u8, try r.slice(name_len));
                    const kind = try exportKindFromByte(try r.byte());
                    const index = try r.readVarU32();
                    try exports.append(allocator, .{ .name = name, .kind = kind, .index = index });
                }
            },
            10 => { // Code
                const count = try r.readVarU32();
                try bodies.ensureTotalCapacity(allocator, count);
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const body_size = try r.readVarU32();
                    const body_end = r.pos + body_size;
                    const local_decl_count = try r.readVarU32();
                    var locals: std.ArrayListUnmanaged(ValType) = .empty;
                    var j: u32 = 0;
                    while (j < local_decl_count) : (j += 1) {
                        const n = try r.readVarU32();
                        const vt = try r.readValType();
                        try locals.appendNTimes(allocator, vt, n);
                    }
                    const code = try r.slice(body_end - r.pos);
                    try bodies.append(allocator, .{ .locals = try locals.toOwnedSlice(allocator), .code = code });
                }
            },
            else => try r.skip(section_size),
        }
        r.pos = section_end;
    }

    return .{
        .allocator = allocator,
        .types = try types.toOwnedSlice(allocator),
        .func_type_indices = try func_type_indices.toOwnedSlice(allocator),
        .bodies = try bodies.toOwnedSlice(allocator),
        .exports = try exports.toOwnedSlice(allocator),
    };
}

test "parse: gerçek zig-derlenmiş bir add_one modülünü ayrıştırır" {
    // `export fn add_one(x: i32) i32 { return x + 1; }` — wasm32-freestanding
    // hedefine `zig build-exe ... --export=add_one` ile derlenmiş gerçek
    // bir modülün ham baytları (bkz. tests/compat/wasm_ext, Faz 13).
    const bytes = "\x00asm\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x04\x05\x01\x70\x01\x01\x01\x05\x03\x01\x00\x10\x06\x09\x01\x7f\x01\x41\x80\x80\xc0\x00\x0b\x07\x14\x02\x06memory\x02\x00\x07add_one\x00\x00\x0a\x09\x01\x07\x00\x20\x00\x41\x01\x6a\x0b";
    var mod = try parse(std.testing.allocator, bytes);
    defer mod.deinit();

    try std.testing.expectEqual(@as(usize, 1), mod.types.len);
    try std.testing.expectEqual(@as(usize, 1), mod.types[0].params.len);
    try std.testing.expectEqual(ValType.i32, mod.types[0].params[0]);
    try std.testing.expectEqual(@as(usize, 1), mod.types[0].results.len);

    const idx = mod.findExportedFunc("add_one") orelse return error.NotFound;
    try std.testing.expectEqual(@as(u32, 0), idx);
    try std.testing.expectEqual(@as(usize, 1), mod.bodies.len);
    try std.testing.expectEqualSlices(u8, "\x20\x00\x41\x01\x6a\x0b", mod.bodies[0].code);
}

test "readVarU32: kanonik değerler doğru çözülür" {
    var r1 = Reader{ .bytes = &.{0x00} };
    try std.testing.expectEqual(@as(u32, 0), try r1.readVarU32());
    var r2 = Reader{ .bytes = &.{0x7f} };
    try std.testing.expectEqual(@as(u32, 127), try r2.readVarU32());
    var r3 = Reader{ .bytes = &.{ 0x80, 0x01 } };
    try std.testing.expectEqual(@as(u32, 128), try r3.readVarU32());
    var r4 = Reader{ .bytes = &.{ 0xac, 0x02 } };
    try std.testing.expectEqual(@as(u32, 300), try r4.readVarU32());
    // maxInt(u32) — tam olarak 5 bayt kullanan, geçerli/kanonik en büyük kodlama.
    var r5 = Reader{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x0f } };
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), try r5.readVarU32());
}

test "readVarU32: Faz X.1 — 6+ devam baytı taşma sınırına takılır" {
    // İlk 5 bayt HEPSİ devam bitini (0x80) taşıyor — geçerli bir u32
    // LEB128 kodlaması EN FAZLA 5 bayt sürdüğünden, bu 6. bayta ULAŞMADAN
    // `error.InvalidModule` İLE reddedilmeli (ESKİ kodda `shift: u5`nin
    // TAŞMASINA/panik'e yol açardı — bkz. modül üstü not).
    var r = Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 } };
    try std.testing.expectError(error.InvalidModule, r.readVarU32());
}

test "readVarU32: Faz X.1 — kanonik olmayan (u32 sınırını aşan) son bayt reddedilir" {
    // maxInt(u32)'nin geçerli kodlamasıyla (yukarı) AYNI 5 baytlık uzunluk,
    // AMA son bayt FAZLADAN bir bit taşıyor (0x1f yerine 0x0f OLMALIYDI) —
    // bu, 32 bitin ÖTESİNDE anlamlı bit taşıyan (kanonik-olmayan) bir
    // kodlamadır, SESSİZCE kırpılmak YERİNE reddedilmelidir.
    var r = Reader{ .bytes = &.{ 0xff, 0xff, 0xff, 0xff, 0x1f } };
    try std.testing.expectError(error.InvalidModule, r.readVarU32());
}

test "readVarI32: kanonik değerler doğru çözülür" {
    var r1 = Reader{ .bytes = &.{0x00} };
    try std.testing.expectEqual(@as(i32, 0), try r1.readVarI32());
    var r2 = Reader{ .bytes = &.{0x7f} };
    try std.testing.expectEqual(@as(i32, -1), try r2.readVarI32());
    var r3 = Reader{ .bytes = &.{ 0xff, 0x00 } };
    try std.testing.expectEqual(@as(i32, 127), try r3.readVarI32());
    var r4 = Reader{ .bytes = &.{ 0x80, 0x7f } };
    try std.testing.expectEqual(@as(i32, -128), try r4.readVarI32());
}

test "readVarI32: Faz X.1 — 6+ devam baytı taşma sınırına takılır" {
    var r = Reader{ .bytes = &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 } };
    try std.testing.expectError(error.InvalidModule, r.readVarI32());
}
