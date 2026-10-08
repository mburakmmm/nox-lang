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
/// kaydeder, SONRA modül-global ilklendirme dilimini kaynak SIRASIYLA
/// çalıştırır. Dilim, son terfi etmiş `var_decl`a KADARDIR (dahil) ve
/// şunları içerir: terfi etmiş `var_decl`lar, onlara yapılan üst düzey
/// atamalar (`cfg.secret_key = ...`) ve alıcısı terfi etmiş bir global
/// olan metod çağrıları (`xs.append(...)`). Böylece
/// `application = boot(cfg)` , aynı dilimdeki `cfg = load()` ve
/// `cfg.secret_key = ...` ATAMASINI GÖRÜR. Bu dilimden SONRAKİ deyimler
/// (`print`, `serve`, son bildirimden sonraki atamalar) `$main`de kalır
/// ve worker'larda TEKRARLANMAZ. Ayrıntı: `collectModuleGlobals`.
/// Sadece `Codegen.module_globals.count() > 0` İSE ÇAĞRILIR (bkz.
/// `codegen.zig`nin `generateModule`ı) — global YOKSA bu fonksiyon HİÇ
/// üretilmez, sıfır ek maliyet.
pub fn genNoxInitGlobals(self: *Codegen, module: ast.Module) CodegenError!void {
    // Bulundu (Nyx `application = nyx.app.boot(cfg, setup)` SIGSEGV'si): sınıf
    // metodları `$nox_init_globals`ten ÖNCE üretilir ve `genMethod`/`genFunction`
    // `vars`ı çıkışta DEĞİL girişte temizler — bu fonksiyon son üretilen
    // metodun yerellerini/parametrelerini MİRAS alıyordu. Bir ilklendirici
    // ifadesindeki çıplak isim (`cfg`) önce `vars`ta aranır; son metodun aynı
    // adlı bir parametresi (Nyx'te `Application.__init__(self, cfg)`) KAZANIR
    // ve ifade `loadl %t1` ile başka bir fonksiyonun slotunu okurdu. Ad
    // çakışmıyorsa (`cfgx`) yerel yoktu ve fonksiyon-değeri yedeğine düşülüp
    // `error.Unsupported` verilirdi — ismin sonucu değiştirmesinin nedeni bu.
    // Her fonksiyon-benzeri codegen girişiyle AYNI sıfırlama burada da yapılır
    // (bu fonksiyon `void` döner, `in_main` değildir, `defer` ve `try` bağlamı yoktur).
    self.vars.clearRetainingCapacity();
    self.narrowed_unbox.clearRetainingCapacity();
    self.stack_local_names.clearRetainingCapacity();
    self.growable_arena_names.clearRetainingCapacity();
    self.function_arena = null;
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;
    self.current_ret_qtype = .none;
    self.current_ret_info = .{ .qtype = .none };
    self.current_catch_label = null;
    self.current_defer_list = null;
    self.current_path = "";
    self.in_main = false;

    try self.qbeFuncHeaderStart(null, "$nox_init_globals");
    try self.qbeFuncParam(.l, RT_PARAM, true);
    try self.qbeFuncHeaderEnd();
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_alloc", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.module_globals_size}) } });
    try self.qbeCall(null, "$nox_globals_set", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = block } });

    for (module.body, 0..) |stmt, i| {
        if (!self.stmtRunsInGlobalInit(stmt, i)) continue;
        self.current_raise_line = stmt.line;
        switch (stmt.kind) {
            .var_decl => |v| {
                // Terfi ETMEMİŞ bir `var_decl` buraya DÜŞMEZ
                // (`stmtRunsInGlobalInit`). Yine de `.get` zorunlu
                // açılmaz: P1c'de paket globali + sıradan betik değişkeni
                // bir aradayken panik bu varsayımdan çıkmıştı.
                const g = self.module_globals.get(v.name) orelse continue;
                const v0 = try self.genExprForTarget(v.value, g.info);
                const retained = try self.retainIfAliasing(v.value, v0);
                const val = try self.convert(retained, g.info.qtype);
                const addr = try self.newTemp();
                try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
                try self.qbeStore(g.info.qtype, val.text, addr);
            },
            // `cfg.secret_key = ...` boot()'tan ÖNCE aynı nesneye yazılsın.
            // `genAssign`in global dalı `$main` ile AYNI yoldur.
            .assign => |asg| try self.genAssign(asg),
            .expr_stmt => |e| {
                const ev = try self.genExpr(e);
                try self.releaseIfTemporary(e, ev);
                if (e == .spawn_expr and ev.heap == .task) try self.destroyNonArcValue(ev.text, .task);
            },
            else => {},
        }
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
