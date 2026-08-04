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
    try genReflectDecoratorIsHandler(self);
    try genReflectDecoratorHandler(self, decorated);
}

fn genDecoratorTable(self: *Codegen, decorated: []const DecoratedFuncInfo) CodegenError!void {
    var arg_ptrs: std.ArrayListUnmanaged([]const u8) = .empty;
    var records: std.ArrayListUnmanaged(struct { func_name: []const u8, dec_name: []const u8, arg_count: usize, arg_start: usize, is_handler: bool }) = .empty;

    for (decorated) |info| {
        const func_name_ptr = try self.internPinnedStringConst(info.func_name);
        const dec_name_ptr = try self.internPinnedStringConst(info.decorator_name);
        const arg_start = arg_ptrs.items.len;
        for (info.args) |a| {
            try arg_ptrs.append(self.allocator, try self.internPinnedStringConst(a));
        }
        try records.append(self.allocator, .{ .func_name = func_name_ptr, .dec_name = dec_name_ptr, .arg_count = info.args.len, .arg_start = arg_start, .is_handler = info.is_handler_shaped });
    }

    // `data $sym = {...}` direktifleri BU planın (Faz IR.0-14) KAPSAMI
    // DIŞINDA (bkz. plan dosyasının "Kapsam DIŞI" notu) — bu İKİ döngü
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
    if (arg_ptrs.items.len == 0) {
        try self.qbeRawAll("l 0");
    } else {
        for (arg_ptrs.items, 0..) |p, i| {
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

fn genReflectDecoratorArg(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    try self.qbeFuncHeaderStart(.l, "$__nox_reflect_decorator_arg");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncParam(.l, "%i", false);
    try self.qbeFuncParam(.l, "%j", false);
    try self.qbeFuncHeaderEnd();
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
    try self.qbeOp2(arg_addr, .l, "add", "$__nox_decorator_args", arg_off);
    const val = try self.newTemp();
    try self.qbeLoadL(val, arg_addr);
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
