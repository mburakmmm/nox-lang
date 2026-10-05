//! Faz 1 decorator (bkz. plan dosyası "Decorator sözdizimi + metadata-tabanlı
//! metaprogramming"): `checker.zig`nin topladığı `DecoratedFuncInfo`
//! listesini (bkz. onun belge notu) statik bir `.data` tablosuna
//! (`layout.zig`nin `genClassVtable`ıyla AYNI desen) VE `nox.reflect`in
//! sorgulayacağı, SABİT-imzalı 7 derleyici yerleşiğine (`__nox_reflect_
//! decorator_*`, bkz. `calls.zig`nin dispatch dalları) çevirir.
//!
//! **Tablo düzeni:** HER decorator kaydı (bir fonksiyon+decorator ÇİFTİ,
//! `checker.zig`nin `registerDecorators`ının doldurduğu SIRAYLA) sabit
//! 4-kelimelik (32 bayt) bir satırdır: `[func_name_ptr, dec_name_ptr,
//! arg_count, arg_start]`. `arg_start`, TÜM kayıtların argümanlarının
//! DÜZLEŞTİRİLİP ART ARDA yazıldığı AYRI bir `$__nox_decorator_args`
//! tablosuna bir İNDEKSTİR. Dize alanları (`func_name_ptr`/`dec_name_ptr`/
//! her argüman), `expr.zig`nin `internPinnedStringConst`ıyla (bkz. onun
//! belge notu) ARC-pinned birer GERÇEK Nox `str`i olarak intern edilir —
//! `nox.reflect`in `str` dönen erişimcileri bu YÜZDEN sıfır-maliyetli
//! (yalnızca bir `data` okuması) çalışır.
//!
//! **`handler` erişimcisi NEDEN AYRI:** decorator'lı bir fonksiyonu
//! ÇAĞRILABİLİR bir DEĞER olarak dışarı vermek (`nox_reflect_decorator_
//! handler(i)`) derleme-zamanı statik veri OKUMASI DEĞİLDİR — `(T) -> U`
//! değerinin çalışma-zamanı temsili TAZE bir ARC bloğu GEREKTİRİR (bkz.
//! `expr.zig`nin `buildFunctionValueForIdentifier`ı, `functions_used_as_
//! value`in belge notu). Bu YÜZDEN `genReflectDecoratorHandler`, HER
//! "handler-şekilli" kayıt İçin `%i`yi karşılaştırıp EŞLEŞEN dalda O
//! fonksiyonun trampoline'ından TAZE bir kapanış İNŞA EDEN bir dallanma
//! zinciri üretir (`checker.zig`nin `registerDecorators`ı ZATEN bu
//! fonksiyonları `functions_used_as_value`e EKLEDİĞİNDEN trampoline
//! `$<isim>__fnval` HER ZAMAN VARDIR) — eşleşme YOKSA (index-şekilsiz YA
//! DA sınır dışı) `0` (None) döner.

const std = @import("std");
const codegen = @import("codegen.zig");
const abi = @import("abi.zig");
const types = @import("types.zig");
const checker_mod = @import("../typecheck/checker.zig");

const Codegen = codegen.Codegen;
const CodegenError = abi.CodegenError;
const RT_PARAM = types.RT_PARAM;

pub const DecoratedFuncInfo = checker_mod.DecoratedFuncInfo;
pub const ClassCtorInfo = checker_mod.ClassCtorInfo;

/// `[func_name_ptr, dec_name_ptr, arg_count, arg_start, is_handler]` — bkz.
/// modül üstü not. `is_handler` (0/1), `__nox_reflect_decorator_is_handler`
/// İçİn — çağıranın (`router_from_decorators()`) `__nox_reflect_decorator_
/// handler(i)`i ÇAĞIRMADAN ÖNCE bunu kontrol etmesi BEKLENİR (bkz.
/// `calls.zig`deki eşdeğer not).
const RECORD_WORDS = 5;
const RECORD_SIZE = RECORD_WORDS * 8;
const FIELD_OFFSET_FUNC_NAME = 0;
const FIELD_OFFSET_DEC_NAME = 8;
const FIELD_OFFSET_ARG_COUNT = 16;
const FIELD_OFFSET_ARG_START = 24;
const FIELD_OFFSET_IS_HANDLER = 32;

/// Aether NOX_LIMITATIONS.md yol haritası, Faz A.6 (bkz. nox-teknik-
/// spesifikasyon.md ilgili bölüm, madde 2): `$__nox_decorator_args`ın
/// HER slotunun (HALA bir argüman BAŞINA bir `l` kelimesi — `j`
/// indeksleme semantiği KORUNUR) GERÇEK türü. `$__nox_decorator_arg_
/// kinds` BUNUNLA 1:1 PARALEL, AYRI bir düz dizi — `decorator_arg`
/// (string-döndüren, ESKİ erişimci) kind STRING DIŞINDAYKEN pinned BOŞ
/// dizeye düşer (slotun KENDİSİNİ bir `str` işaretçisi SANIP OKUMAK,
/// int/bool İçin GEÇERSİZ bellek erişimi OLURDU).
const ARG_KIND_STRING: i64 = 0;
const ARG_KIND_INT: i64 = 1;
const ARG_KIND_BOOL: i64 = 2;
const ARG_KIND_LIST_STR: i64 = 3;

/// `generateModule`nin SONUNDA (bkz. onun çağrı sitesi — `genNoxInitGlobals`/
/// `thread_wrappers` GİBİ "programın geri kalanı ÜRETİLDİKTEN SONRA TÜKET"
/// deseni) BİR KEZ çağrılır — `decorated` boş OLSA BİLE tabloları/
/// yerleşikleri ÜRETİR (`$__nox_reflect_decorator_*` sembollerinin HER
/// programda VAR OLMASI GEREKİR, çünkü `stdlib/nox/reflect.nox` HERHANGİ
/// bir programda import EDİLEBİLİR — bkz. `genNoxInitGlobals`nin AYNI
/// "koşulsuz üret" gerekçesi).
pub fn genDecoratorMetadata(self: *Codegen, decorated: []const DecoratedFuncInfo) CodegenError!void {
    try genDecoratorTable(self, decorated);
    try genReflectDecoratorCount(self, decorated.len);
    try genReflectFieldGetter(self, "__nox_reflect_decorator_target_name", FIELD_OFFSET_FUNC_NAME);
    try genReflectFieldGetter(self, "__nox_reflect_decorator_name", FIELD_OFFSET_DEC_NAME);
    try genReflectFieldGetter(self, "__nox_reflect_decorator_arg_count", FIELD_OFFSET_ARG_COUNT);
    try genReflectDecoratorArg(self);
    try genReflectDecoratorArgKind(self);
    try genReflectDecoratorArgInt(self);
    try genReflectDecoratorArgBool(self);
    try genReflectDecoratorArgListLen(self);
    try genReflectDecoratorArgListItem(self);
    try genReflectDecoratorIsHandler(self);
    try genReflectDecoratorHandler(self, decorated);
}

fn genDecoratorTable(self: *Codegen, decorated: []const DecoratedFuncInfo) CodegenError!void {
    // `$__nox_decorator_args`in HER elemanı (hâlâ argüman BAŞINA TEK bir
    // `l` kelimesi) BURADA ya ham bir SAYISAL DEĞER (int/bool/paketlenmiş
    // liste start+count) ya da bir pinned `str` İŞARETÇİSİ (string) OLARAK
    // KENDİ İÇERİĞİNİ `data` yönergesine metin OLARAK yazar — `arg_lines`
    // bu YÜZDEN ÖNCEDEN hesaplanmış, QBE'nin `data` sözdizimine HAZIR
    // metin PARÇALARIdır (`l {s}`/`l {d}`), `arg_ptrs`in ESKİ "HER ZAMAN
    // bir işaretçi" varsayımının YERİNE.
    var arg_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var arg_kind_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var list_item_ptrs: std.ArrayListUnmanaged([]const u8) = .empty;
    var records: std.ArrayListUnmanaged(struct { func_name: []const u8, dec_name: []const u8, arg_count: usize, arg_start: usize, is_handler: bool }) = .empty;

    for (decorated) |info| {
        const func_name_ptr = try self.internPinnedStringConst(info.func_name);
        const dec_name_ptr = try self.internPinnedStringConst(info.decorator_name);
        const arg_start = arg_lines.items.len;
        for (info.args) |a| {
            switch (a) {
                .string => |s| {
                    const ptr = try self.internPinnedStringConst(s);
                    try arg_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {s}", .{ptr}));
                    try arg_kind_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {d}", .{ARG_KIND_STRING}));
                },
                .int => |n| {
                    try arg_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {d}", .{n}));
                    try arg_kind_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {d}", .{ARG_KIND_INT}));
                },
                .boolean => |b| {
                    try arg_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {d}", .{@intFromBool(b)}));
                    try arg_kind_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {d}", .{ARG_KIND_BOOL}));
                },
                .list_str => |items| {
                    const list_start = list_item_ptrs.items.len;
                    for (items) |it| {
                        try list_item_ptrs.append(self.allocator, try self.internPinnedStringConst(it));
                    }
                    const packed_val: i64 = (@as(i64, @intCast(list_start)) << 32) | @as(i64, @intCast(items.len));
                    try arg_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {d}", .{packed_val}));
                    try arg_kind_lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "l {d}", .{ARG_KIND_LIST_STR}));
                },
            }
        }
        try records.append(self.allocator, .{ .func_name = func_name_ptr, .dec_name = dec_name_ptr, .arg_count = info.args.len, .arg_start = arg_start, .is_handler = info.is_handler_shaped });
    }

    // `data $sym = {...}` direktifleri BU planın (Faz IR.0-14) KAPSAMI
    // DIŞINDA (bkz. plan dosyasının "Kapsam DIŞI" notu) — bu döngüler
    // BİLİNÇLİ olarak `qbeRaw`/`qbeRawAll` KULLANIR.
    try self.qbeRawAll("data $__nox_decorators = { ");
    if (records.items.len == 0) {
        // Sembol HER ZAMAN çözülmeli (bkz. modül üstü not) — kayıt yoksa
        // tek bir dolgu kelimesi yeterli, hiçbir erişimci geçerli bir
        // `%i` ile buraya asla ulaşmaz (`decorator_count()` 0 döner).
        try self.qbeRawAll("l 0");
    } else {
        for (records.items, 0..) |r, i| {
            if (i > 0) try self.qbeRawAll(", ");
            try self.qbeRaw("l {s}, l {s}, l {d}, l {d}, l {d}", .{ r.func_name, r.dec_name, r.arg_count, r.arg_start, @intFromBool(r.is_handler) });
        }
    }
    try self.qbeRawAll(" }\n");

    try self.qbeRawAll("data $__nox_decorator_args = { ");
    if (arg_lines.items.len == 0) {
        try self.qbeRawAll("l 0");
    } else {
        for (arg_lines.items, 0..) |line, i| {
            if (i > 0) try self.qbeRawAll(", ");
            try self.qbeRawAll(line);
        }
    }
    try self.qbeRawAll(" }\n");

    try self.qbeRawAll("data $__nox_decorator_arg_kinds = { ");
    if (arg_kind_lines.items.len == 0) {
        try self.qbeRawAll("l 0");
    } else {
        for (arg_kind_lines.items, 0..) |line, i| {
            if (i > 0) try self.qbeRawAll(", ");
            try self.qbeRawAll(line);
        }
    }
    try self.qbeRawAll(" }\n");

    try self.qbeRawAll("data $__nox_decorator_list_items = { ");
    if (list_item_ptrs.items.len == 0) {
        try self.qbeRawAll("l 0");
    } else {
        for (list_item_ptrs.items, 0..) |p, i| {
            if (i > 0) try self.qbeRawAll(", ");
            try self.qbeRaw("l {s}", .{p});
        }
    }
    try self.qbeRawAll(" }\n");
}

fn genReflectDecoratorCount(self: *Codegen, n: usize) CodegenError!void {
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_count");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncHeaderEnd();
    const n_text = try std.fmt.allocPrint(self.allocator, "{d}", .{n});
    try self.qbeRet(n_text);
    try self.qbeFuncEnd();
}

/// `target_name`/`name`/`arg_count` ÜÇÜNÜN de İskeleti AYNIDIR: `$__nox_
/// decorators + %i*32 + <field_offset>`i OKUYUP döner (`str` alanları İçin
/// bu, ZATEN pinned bir dize adresidir; `arg_count` İçin düz bir `int`tir —
/// HER İKİSİ de QBE'de `l` genişliğinde OLDUĞUNDAN TEK bir şablon YETERLİ).
fn genReflectFieldGetter(self: *Codegen, func_name: []const u8, field_offset: usize) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    const name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{func_name});
    try self.qbeFuncHeaderStart(.l, name_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncHeaderEnd();
    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "mul", "%i", RECORD_SIZE);
    const base = try self.newTemp();
    try self.qbeOp2(base, .l, "add", "$__nox_decorators", off);
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", base, @intCast(field_offset));
    const val = try self.newTemp();
    try self.qbeLoadL(val, addr);
    try self.qbeRet(val);
    try self.qbeFuncEnd();
}

/// `%i`/`%j` parametrelerinin ZATEN bildirildiği (fonksiyon başlığı
/// AÇILMIŞ) bir bağlamda, `table_sym` dizisindeki (`$__nox_decorator_args`
/// VEYA `$__nox_decorator_arg_kinds` — HER İKİSİ de kayıt başına AYNI
/// `arg_start`/`arg_count` indekslemesini PAYLAŞIR, bkz. `genDecoratorTable`nin
/// belge notu) `i`. decoratörün `j`. argüman SLOTUNUN ADRESİNİ hesaplar.
fn emitArgSlotAddr(self: *Codegen, table_sym: []const u8) CodegenError![]const u8 {
    const rec_off = try self.newTemp();
    try self.qbeOp2Imm(rec_off, .l, "mul", "%i", RECORD_SIZE);
    const rec_base = try self.newTemp();
    try self.qbeOp2(rec_base, .l, "add", "$__nox_decorators", rec_off);
    const start_addr = try self.newTemp();
    try self.qbeOp2Imm(start_addr, .l, "add", rec_base, FIELD_OFFSET_ARG_START);
    const arg_start = try self.newTemp();
    try self.qbeLoadL(arg_start, start_addr);
    const idx = try self.newTemp();
    try self.qbeOp2(idx, .l, "add", arg_start, "%j");
    const arg_off = try self.newTemp();
    try self.qbeOp2Imm(arg_off, .l, "mul", idx, 8);
    const arg_addr = try self.newTemp();
    try self.qbeOp2(arg_addr, .l, "add", table_sym, arg_off);
    return arg_addr;
}

/// Faz A.6 ÖNCESİ: BU erişimci TEK başına, HER slotun bir `str`
/// işaretçisi OLDUĞUNU varsayarak ÇALIŞIYORDU — ARTIK kind STRING
/// DIŞINDAYSA (int/bool/liste) pinned BOŞ bir dize döner (slotun KENDİ
/// ham sayısal DEĞERİNİ bir işaretçi SANIP OKUMAK, GEÇERSİZ bellek
/// erişimine yol AÇARDI) — çağıran ÖNCE `decorator_arg_kind`e BAKMALIDIR.
fn genReflectDecoratorArg(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_arg");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%j", false);
    try self.qbeFuncHeaderEnd();
    const kind_addr = try emitArgSlotAddr(self, "$__nox_decorator_arg_kinds");
    const kind = try self.newTemp();
    try self.qbeLoadL(kind, kind_addr);
    const is_string = try self.newTemp();
    try self.qbeOp2Imm(is_string, .w, "ceql", kind, ARG_KIND_STRING);
    const string_label = try self.newLabel("dec_arg_is_string");
    const other_label = try self.newLabel("dec_arg_not_string");
    try self.qbeJnz(is_string, string_label, other_label);
    try self.qbeLabel(other_label);
    const empty = try self.emitStringLiteral("");
    try self.qbeRet(empty.text);
    try self.qbeLabel(string_label);
    const arg_addr = try emitArgSlotAddr(self, "$__nox_decorator_args");
    const val = try self.newTemp();
    try self.qbeLoadL(val, arg_addr);
    try self.qbeRet(val);
    try self.qbeFuncEnd();
}

/// `i`. decoratörün `j`. argümanının TÜRÜ — `ARG_KIND_*`den biri (0=string/
/// 1=int/2=bool/3=string-listesi). Çağıranın `decorator_arg`/`decorator_
/// arg_int`/`decorator_arg_bool`/`decorator_arg_list_len`den HANGİSİNİN
/// GÜVENLE çağrılabileceğini belirlemesi İçindir.
fn genReflectDecoratorArgKind(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_arg_kind");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%j", false);
    try self.qbeFuncHeaderEnd();
    const kind_addr = try emitArgSlotAddr(self, "$__nox_decorator_arg_kinds");
    const kind = try self.newTemp();
    try self.qbeLoadL(kind, kind_addr);
    try self.qbeRet(kind);
    try self.qbeFuncEnd();
}

/// Kind INT DEĞİLSE (bkz. `genReflectDecoratorArg`nin AYNI savunma
/// gerekçesi) `0` döner — slotun KENDİSİ HER ZAMAN ham bir `l` DEĞERİDİR
/// (int İçin GERÇEK değer, DİĞER türler İçin ANLAMSIZ ama GEÇERLİ bir
/// bellek okuması, ASLA bir çökme).
fn genReflectDecoratorArgInt(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_arg_int");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%j", false);
    try self.qbeFuncHeaderEnd();
    const kind_addr = try emitArgSlotAddr(self, "$__nox_decorator_arg_kinds");
    const kind = try self.newTemp();
    try self.qbeLoadL(kind, kind_addr);
    const is_int = try self.newTemp();
    try self.qbeOp2Imm(is_int, .w, "ceql", kind, ARG_KIND_INT);
    const match_label = try self.newLabel("dec_arg_is_int");
    const mismatch_label = try self.newLabel("dec_arg_not_int");
    try self.qbeJnz(is_int, match_label, mismatch_label);
    try self.qbeLabel(mismatch_label);
    try self.qbeRet("0");
    try self.qbeLabel(match_label);
    const arg_addr = try emitArgSlotAddr(self, "$__nox_decorator_args");
    const val = try self.newTemp();
    try self.qbeLoadL(val, arg_addr);
    try self.qbeRet(val);
    try self.qbeFuncEnd();
}

/// Kind BOOL DEĞİLSE `0` (`False`) döner — bkz. `genReflectDecoratorArgInt`
/// İLE AYNI savunma gerekçesi. Dönüş tipi `w` (Nox `bool`un QBE genişliği,
/// bkz. `genReflectDecoratorIsHandler`nin AYNI notu).
fn genReflectDecoratorArgBool(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.w, "$__nox_reflect_decorator_arg_bool");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%j", false);
    try self.qbeFuncHeaderEnd();
    const kind_addr = try emitArgSlotAddr(self, "$__nox_decorator_arg_kinds");
    const kind = try self.newTemp();
    try self.qbeLoadL(kind, kind_addr);
    const is_bool = try self.newTemp();
    try self.qbeOp2Imm(is_bool, .w, "ceql", kind, ARG_KIND_BOOL);
    const match_label = try self.newLabel("dec_arg_is_bool");
    const mismatch_label = try self.newLabel("dec_arg_not_bool");
    try self.qbeJnz(is_bool, match_label, mismatch_label);
    try self.qbeLabel(mismatch_label);
    try self.qbeRet("0");
    try self.qbeLabel(match_label);
    const arg_addr = try emitArgSlotAddr(self, "$__nox_decorator_args");
    const val = try self.newTemp();
    try self.qbeLoadL(val, arg_addr);
    const narrowed = try self.newTemp();
    try self.qbeOp1(narrowed, .w, "copy", val);
    try self.qbeRet(narrowed);
    try self.qbeFuncEnd();
}

/// Kind STRING-LİSTESİ DEĞİLSE `0` döner. STRING-LİSTESİYSE, slotta
/// PAKETLENMİŞ `(start << 32) | count`ın SADECE `count` (alt 32 bit)
/// yarısını ÇIKARIR (bkz. `genDecoratorTable`nin paketleme notu).
fn genReflectDecoratorArgListLen(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_arg_list_len");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%j", false);
    try self.qbeFuncHeaderEnd();
    const kind_addr = try emitArgSlotAddr(self, "$__nox_decorator_arg_kinds");
    const kind = try self.newTemp();
    try self.qbeLoadL(kind, kind_addr);
    const is_list = try self.newTemp();
    try self.qbeOp2Imm(is_list, .w, "ceql", kind, ARG_KIND_LIST_STR);
    const match_label = try self.newLabel("dec_arg_is_list");
    const mismatch_label = try self.newLabel("dec_arg_not_list");
    try self.qbeJnz(is_list, match_label, mismatch_label);
    try self.qbeLabel(mismatch_label);
    try self.qbeRet("0");
    try self.qbeLabel(match_label);
    const arg_addr = try emitArgSlotAddr(self, "$__nox_decorator_args");
    const packed_val = try self.newTemp();
    try self.qbeLoadL(packed_val, arg_addr);
    const count = try self.newTemp();
    try self.qbeOp2Imm(count, .l, "and", packed_val, 0xffffffff);
    try self.qbeRet(count);
    try self.qbeFuncEnd();
}

/// `i`. decoratörün `j`. argümanı (bir string-listesi OLDUĞU ÖNCEDEN
/// `decorator_arg_kind`/`decorator_arg_list_len` İLE doğrulanmış
/// olmalıdır) İÇİNDEKİ `k`. öğeyi döner. Kind STRING-LİSTESİ DEĞİLSE YA
/// DA `k` SINIR DIŞIYSA pinned boş dize döner (ASLA çökme).
fn genReflectDecoratorArgListItem(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_arg_list_item");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%j", false);
    try self.qbeFuncParam(.l, "%k", false);
    try self.qbeFuncHeaderEnd();
    const kind_addr = try emitArgSlotAddr(self, "$__nox_decorator_arg_kinds");
    const kind = try self.newTemp();
    try self.qbeLoadL(kind, kind_addr);
    const is_list = try self.newTemp();
    try self.qbeOp2Imm(is_list, .w, "ceql", kind, ARG_KIND_LIST_STR);
    const match_label = try self.newLabel("dec_arg_list_item_match");
    const mismatch_label = try self.newLabel("dec_arg_list_item_mismatch");
    try self.qbeJnz(is_list, match_label, mismatch_label);
    try self.qbeLabel(mismatch_label);
    const empty = try self.emitStringLiteral("");
    try self.qbeRet(empty.text);
    try self.qbeLabel(match_label);
    const arg_addr = try emitArgSlotAddr(self, "$__nox_decorator_args");
    const packed_val = try self.newTemp();
    try self.qbeLoadL(packed_val, arg_addr);
    const count = try self.newTemp();
    try self.qbeOp2Imm(count, .l, "and", packed_val, 0xffffffff);
    const in_bounds = try self.newTemp();
    try self.qbeOp2(in_bounds, .w, "cultl", "%k", count);
    const bounds_ok_label = try self.newLabel("dec_arg_list_item_bounds_ok");
    const bounds_bad_label = try self.newLabel("dec_arg_list_item_bounds_bad");
    try self.qbeJnz(in_bounds, bounds_ok_label, bounds_bad_label);
    try self.qbeLabel(bounds_bad_label);
    const empty2 = try self.emitStringLiteral("");
    try self.qbeRet(empty2.text);
    try self.qbeLabel(bounds_ok_label);
    const list_start = try self.newTemp();
    try self.qbeOp2Imm(list_start, .l, "shr", packed_val, 32);
    const item_idx = try self.newTemp();
    try self.qbeOp2(item_idx, .l, "add", list_start, "%k");
    const item_off = try self.newTemp();
    try self.qbeOp2Imm(item_off, .l, "mul", item_idx, 8);
    const item_addr = try self.newTemp();
    try self.qbeOp2(item_addr, .l, "add", "$__nox_decorator_list_items", item_off);
    const val = try self.newTemp();
    try self.qbeLoadL(val, item_addr);
    try self.qbeRet(val);
    try self.qbeFuncEnd();
}

/// `is_handler` alanı `l` (0/1) olarak SAKLANIR ama Nox `bool`u QBE'de `w`
/// genişliğindedir (bkz. `expr.zig`nin `.bool_lit` dalı) — bu YÜZDEN
/// `genReflectFieldGetter`in AYNI şablonu YERİNE burada AYRI bir dar (`w`)
/// kopya ADIMI GEREKİR.
fn genReflectDecoratorIsHandler(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.w, "$__nox_reflect_decorator_is_handler");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncHeaderEnd();
    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "mul", "%i", RECORD_SIZE);
    const base = try self.newTemp();
    try self.qbeOp2(base, .l, "add", "$__nox_decorators", off);
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", base, FIELD_OFFSET_IS_HANDLER);
    const val = try self.newTemp();
    try self.qbeLoadL(val, addr);
    const narrowed = try self.newTemp();
    try self.qbeOp1(narrowed, .w, "copy", val);
    try self.qbeRet(narrowed);
    try self.qbeFuncEnd();
}

/// Bkz. modül üstü not ("handler erişimcisi NEDEN AYRI") — `%i` bilinen
/// "handler-şekilli" kayıtlardan biriyle EŞLEŞMİYORSA (ya da hiç yoksa)
/// `0` (Optional'ın `None`ı, bkz. `types.Type.optional`nin çalışma-zamanı
/// temsili) döner.
fn genReflectDecoratorHandler(self: *Codegen, decorated: []const DecoratedFuncInfo) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_handler");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncHeaderEnd();
    for (decorated, 0..) |info, idx| {
        if (!info.is_handler_shaped) continue;
        const cmp = try self.newTemp();
        try self.qbeOp2Imm(cmp, .w, "ceql", "%i", @intCast(idx));
        const match_label = try self.newLabel("dec_handler_match");
        const next_label = try self.newLabel("dec_handler_next");
        try self.qbeJnz(cmp, match_label, next_label);
        try self.qbeLabel(match_label);
        const val = try self.buildFunctionValueForIdentifier(info.func_name);
        try self.qbeRet(val.text);
        try self.qbeLabel(next_label);
    }
    try self.qbeRet("0");
    try self.qbeFuncEnd();
}

// ---- Faz B.5 + C.3: imza / constructor metadata tabloları -------------
//
// **Tablo düzenleri (hepsi `l` kelimeleri):**
//   `$__nox_dec_sigs`        — dekore edilmiş kayıt i'ye 1:1 paralel,
//                              `[param_count, param_start, return_type_ptr]`
//   `$__nox_dec_sig_params`  — düzleştirilmiş `(name_ptr, type_ptr)` çiftleri
//   `$__nox_class_table`     — `[name_ptr, param_count, param_start]`
//   `$__nox_class_params`    — düzleştirilmiş `(name_ptr, type_ptr)` çiftleri
// Dizelerin HEPSİ `internPinnedStringConst` İLE pinned birer GERÇEK Nox
// `str`idir (A.6'nın `$__nox_decorator_args`ıyla AYNI gerekçe). Bu tablolar
// YALNIZCA `uses_reflect_meta` set EDİLMİŞSE üretilir (bkz. `calls.zig`).
const SIG_RECORD_WORDS = 3;
const SIG_RECORD_SIZE = SIG_RECORD_WORDS * 8;
const PAIR_SIZE = 16;

fn emitMetaPairs(self: *Codegen, params: []const checker_mod.ParamMeta, out: *std.ArrayListUnmanaged([]const u8)) CodegenError!void {
    for (params) |p| {
        const name_ptr = try self.internPinnedStringConst(p.name);
        const type_ptr = try self.internPinnedStringConst(p.type_name);
        try out.append(self.allocator, name_ptr);
        try out.append(self.allocator, type_ptr);
    }
}

fn emitDataWords(self: *Codegen, sym: []const u8, words: []const []const u8) CodegenError!void {
    try self.qbeRaw("data ${s} = {{ ", .{sym});
    if (words.len == 0) {
        try self.qbeRawAll("l 0");
    } else {
        for (words, 0..) |w, i| {
            if (i > 0) try self.qbeRawAll(", ");
            try self.qbeRaw("l {s}", .{w});
        }
    }
    try self.qbeRawAll(" }\n");
}

pub fn genReflectMetadata(self: *Codegen, decorated: []const DecoratedFuncInfo, class_ctors: []const ClassCtorInfo) CodegenError!void {
    if (!self.uses_reflect_meta) return;

    var sig_words: std.ArrayListUnmanaged([]const u8) = .empty;
    var sig_pairs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (decorated) |info| {
        const start = sig_pairs.items.len / 2;
        try emitMetaPairs(self, info.params, &sig_pairs);
        try sig_words.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{info.params.len}));
        try sig_words.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{start}));
        try sig_words.append(self.allocator, try self.internPinnedStringConst(info.return_type));
    }
    try emitDataWords(self, "__nox_dec_sigs", sig_words.items);
    try emitDataWords(self, "__nox_dec_sig_params", sig_pairs.items);

    var class_words: std.ArrayListUnmanaged([]const u8) = .empty;
    var class_pairs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (class_ctors) |ci| {
        const start = class_pairs.items.len / 2;
        try emitMetaPairs(self, ci.params, &class_pairs);
        try class_words.append(self.allocator, try self.internPinnedStringConst(ci.class_name));
        try class_words.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{ci.params.len}));
        try class_words.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{start}));
    }
    try emitDataWords(self, "__nox_class_table", class_words.items);
    try emitDataWords(self, "__nox_class_params", class_pairs.items);

    try genMetaWordGetter(self, "__nox_reflect_decorator_param_count", "$__nox_dec_sigs", SIG_RECORD_SIZE, 0, .l);
    try genMetaWordGetter(self, "__nox_reflect_decorator_return_type", "$__nox_dec_sigs", SIG_RECORD_SIZE, 16, .l);
    try genMetaPairGetter(self, "__nox_reflect_decorator_param_name", "$__nox_dec_sigs", "$__nox_dec_sig_params", 0);
    try genMetaPairGetter(self, "__nox_reflect_decorator_param_type", "$__nox_dec_sigs", "$__nox_dec_sig_params", 8);

    try genMetaConstGetter(self, "__nox_reflect_class_count", class_ctors.len);
    try genMetaWordGetter(self, "__nox_reflect_class_name", "$__nox_class_table", SIG_RECORD_SIZE, 0, .l);
    try genMetaWordGetter(self, "__nox_reflect_class_init_param_count", "$__nox_class_table", SIG_RECORD_SIZE, 8, .l);
    try genMetaPairGetter(self, "__nox_reflect_class_init_param_name", "$__nox_class_table", "$__nox_class_params", 0);
    try genMetaPairGetter(self, "__nox_reflect_class_init_param_type", "$__nox_class_table", "$__nox_class_params", 8);
}

/// `(rt, i)` → `table[i * stride + field_off]` (ham `l` kelimesi; `str`
/// alanlarında bu ZATEN pinned dize adresidir).
fn genMetaWordGetter(self: *Codegen, func_name: []const u8, table: []const u8, stride: usize, field_off: usize, ret_ty: types.QbeType) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    const name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{func_name});
    try self.qbeFuncHeaderStart(ret_ty, name_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncHeaderEnd();
    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "mul", "%i", @intCast(stride));
    const base = try self.newTemp();
    try self.qbeOp2(base, .l, "add", table, off);
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", base, @intCast(field_off));
    const val = try self.newTemp();
    try self.qbeLoadL(val, addr);
    try self.qbeRet(val);
    try self.qbeFuncEnd();
}

/// `(rt, i, k)` → `i`. kaydın `k`. `(name, type)` çiftinin `item_off`
/// alanı. Kayıt düzeni `[... count@8, start@16]` DEĞİL — dekore edilmiş
/// imza tablosu `[count@0, start@8, ret@16]`, sınıf tablosu `[name@0,
/// count@8, start@16]` — bu YÜZDEN `count`/`start` ofsetleri tablo
/// sembolüne göre seçilir. `k` SINIR DIŞIYSA pinned boş dize döner.
fn genMetaPairGetter(self: *Codegen, func_name: []const u8, table: []const u8, items_table: []const u8, item_off: usize) CodegenError!void {
    const is_class = std.mem.eql(u8, table, "$__nox_class_table");
    const count_off: usize = if (is_class) 8 else 0;
    const start_off: usize = if (is_class) 16 else 8;
    self.temp_counter = 0;
    self.label_counter = 0;
    const name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{func_name});
    try self.qbeFuncHeaderStart(.l, name_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%k", false);
    try self.qbeFuncHeaderEnd();
    const rec_off = try self.newTemp();
    try self.qbeOp2Imm(rec_off, .l, "mul", "%i", SIG_RECORD_SIZE);
    const rec = try self.newTemp();
    try self.qbeOp2(rec, .l, "add", table, rec_off);
    const count_addr = try self.newTemp();
    try self.qbeOp2Imm(count_addr, .l, "add", rec, @intCast(count_off));
    const count = try self.newTemp();
    try self.qbeLoadL(count, count_addr);
    const in_bounds = try self.newTemp();
    try self.qbeOp2(in_bounds, .w, "cultl", "%k", count);
    const ok_label = try self.newLabel("meta_pair_ok");
    const bad_label = try self.newLabel("meta_pair_bad");
    try self.qbeJnz(in_bounds, ok_label, bad_label);
    try self.qbeLabel(bad_label);
    const empty = try self.emitStringLiteral("");
    try self.qbeRet(empty.text);
    try self.qbeLabel(ok_label);
    const start_addr = try self.newTemp();
    try self.qbeOp2Imm(start_addr, .l, "add", rec, @intCast(start_off));
    const start = try self.newTemp();
    try self.qbeLoadL(start, start_addr);
    const idx = try self.newTemp();
    try self.qbeOp2(idx, .l, "add", start, "%k");
    const pair_off = try self.newTemp();
    try self.qbeOp2Imm(pair_off, .l, "mul", idx, PAIR_SIZE);
    const pair = try self.newTemp();
    try self.qbeOp2(pair, .l, "add", items_table, pair_off);
    const item_addr = try self.newTemp();
    try self.qbeOp2Imm(item_addr, .l, "add", pair, @intCast(item_off));
    const val = try self.newTemp();
    try self.qbeLoadL(val, item_addr);
    try self.qbeRet(val);
    try self.qbeFuncEnd();
}

/// `(rt)` → sabit `n` (ör. sınıf sayısı).
fn genMetaConstGetter(self: *Codegen, func_name: []const u8, n: usize) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    const name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{func_name});
    try self.qbeFuncHeaderStart(.l, name_sym);
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncHeaderEnd();
    const n_text = try std.fmt.allocPrint(self.allocator, "{d}", .{n});
    try self.qbeRet(n_text);
    try self.qbeFuncEnd();
}
