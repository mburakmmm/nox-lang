//! Modül-seviyesi global durum codegen'i — bkz. proje belleği "modül-
//! seviyesi global durum" planı. Üst-düzey (script top-level) `var_decl`ları
//! `layout.zig`nin `genTraceDispatch`/`genGcFreeDispatch`/`genClassReleaseDispatch`ıyla
//! AYNI rolü/deseni İZLEYEN İKİ sentezlenmiş fonksiyona ($nox_init_globals/
//! $nox_deinit_globals) çevirir — bu dosya `Codegen.module_globals`in ZATEN
//! DOLU olduğunu (bkz. `registration.zig`nin `collectModuleGlobals`ı)
//! VARSAYAR, yalnızca bu tablonun ÜZERİNDE codegen yapar.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const RT_PARAM = types.RT_PARAM;
const CodegenError = abi.CodegenError;
const isHeapManaged = abi.isHeapManaged;

/// `$nox_init_globals(rt)` üretir: opak globals bloğunu ayırıp `rt`ye
/// kaydeder, SONRA HER üst-düzey `var_decl`nin initializer'ını (bildirim
/// SIRASIYLA — bkz. `stdlib/nox/router.nox`nin "bilinçli v1 semantiği"
/// notu, initializer'lar HER ZAMAN diğer üst-düzey deyimlerden ÖNCE
/// çalışır) `stmt.zig`nin `.var_decl` koluYLA AYNI desende (`genExprForTarget`
/// + `retainIfAliasing` + `convert`) değerlendirip blok+ofsete YAZAR.
/// Sadece `Codegen.module_globals.count() > 0` İSE ÇAĞRILIR (bkz.
/// `codegen.zig`nin `generateModule`ı) — global YOKSA bu fonksiyon HİÇ
/// üretilmez, sıfır ek maliyet.
pub fn genNoxInitGlobals(self: *Codegen, module: ast.Module) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    try self.qbeFuncHeaderStart(null, "$nox_init_globals");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncHeaderEnd();
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.module_globals_size}) } });
    try self.qbeCall(null, "$nox_globals_set", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = block } });

    for (module.body) |stmt| {
        if (stmt.kind != .var_decl) continue;
        const v = stmt.kind.var_decl;
        // Bulundu (P1c — bkz. proje belleği/kullanıcı repro'su): `module.
        // body`deki HER `var_decl`nin `module_globals`e TERFİ ETTİĞİNİ
        // VARSAYMAK YANLIŞTI — TERFİ (bkz. `collectModuleGlobals`) yalnızca
        // adı BİR fonksiyon/metod gövdesinden (iç içe `def`ler DAHİL)
        // REFERANS ALINAN var_decl'lere UYGULANIR; SAF üst-düzey betik
        // değişkenleri (`codegen.zig`nin `loose` inşasında GÖRÜLDÜĞÜ gibi,
        // `$main`in SIRADAN bir yereli olarak KALIR) `module_globals`de
        // HİÇ YOKTUR. ÖNCEKİ `.get(v.name).?` bu YÜZDEN, PROGRAMDA
        // HERHANGİ bir BAŞKA (paket İÇİ DAHİL) global TERFİ ETTİĞİ ANDA
        // (`module_globals.count() > 0` — bu fonksiyonun ÇAĞRILMA koşulu)
        // BU tür TERFİ ETMEMİŞ var_decl'lerde ÇÖKÜYORDU (GERÇEKTEN
        // gözlemlendi: bir paket modülünün OKUNAN/YAZILAN bir globali +
        // programda HERHANGİ bir yerde `mw`/`ctx` GİBİ sıradan üst-düzey
        // betik değişkenleri BİR ARADA olduğunda panik). Düzeltme: terfi
        // ETMEMİŞ bir `var_decl`, `loose`un ZATEN doğru şekilde işlediği
        // gibi burada SESSİZCE ATLANIR.
        const g = self.module_globals.get(v.name) orelse continue;
        const v0 = try self.genExprForTarget(v.value, g.info);
        const retained = try self.retainIfAliasing(v.value, v0);
        const val = try self.convert(retained, g.info.qtype);
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
        try self.qbeStore(g.info.qtype, val.text, addr);
    }
    try self.qbeRet(null);
    try self.qbeFuncEnd();
}

/// `$nox_deinit_globals(rt)` üretir: HER heap-yönetimli global İçin
/// mevcut değeri `self.releaseValueIfSet` (ownership.zig — DOĞRUDAN
/// yeniden kullanılır, YENİ bir release mekanizması İCAT EDİLMEZ) İLE
/// serbest bırakır, SONRA blok'un KENDİSİNİ `nox_free` eder. `$main`/
/// `nox.thread.start` worker'ının `nox_runtime_deinit`den HEMEN ÖNCE
/// çağırdığı fonksiyon — `nox.http.serve_multicore` worker'ı BUNU
/// ÇAĞIRMAZ (bkz. `http_intrinsics.zig`nin `genHttpServeMulticoreWorker`
/// çağrı sitesi notu — o worker SONSUZA dek çalışır, ASLA dönmez).
pub fn genNoxDeinitGlobals(self: *Codegen) CodegenError!void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    try self.qbeFuncHeaderStart(null, "$nox_deinit_globals");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncHeaderEnd();
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});

    var it = self.module_globals.valueIterator();
    while (it.next()) |g| {
        if (!isHeapManaged(g.info.heap)) continue;
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
        const ptr = try self.newTemp();
        try self.qbeLoadL(ptr, addr);
        try self.releaseValueIfSet(ptr, g.info.heap, g.info.elem_qtype, g.info.class_name, g.info.elem_heap_info, g.info.dict_info);
    }
    try self.qbeCall(null, "$nox_free", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = block }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.module_globals_size}) } });
    try self.qbeRet(null);
    try self.qbeFuncEnd();
}
