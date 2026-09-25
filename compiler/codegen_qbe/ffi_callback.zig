//! v2.0 stabilizasyon yol haritası, madde 2.3 (bkz. nox-teknik-
//! spesifikasyon.md §3.189): `@ffi.callback` — C'nin (belirli, DAR/güvenli
//! bir alt-kümede) Nox'a geri çağrı yapabilmesi.
//!
//! **Tasarımın çekirdek fikri (İlke #6'yı — "global/gizli mutable state
//! yasak" — İHLAL ETMEDEN çözer)**: Nox'un HER derlenmiş fonksiyonu gizli
//! bir `%rt` (RuntimeState*) parametresi alır (`registration.zig`nin
//! `genFunction`ı) — ham bir C fonksiyon-işaretçisi yuvası BUNUN İçİn yer
//! AYIRMAZ. `%rt`yi bulmak İçİn YENİ bir global/thread-local EKLEMEK
//! YERİNE, `%rt` HER ÇAĞRIDA C'nin KENDİSİNİN GERİ TAŞIDIĞI bir "userdata"
//! parametresi ÜZERİNDEN taşınır (`@ffi.callback`in `context_param`ı,
//! bkz. `checker.zig`nin `registerExternCallback`ı) — çağrı SİTESİNDE
//! (bkz. `calls.zig`nin extern-çağrı dalı) ÇAĞIRAN fonksiyonun KENDİ,
//! ZATEN kapsam İçİNDEKİ `%rt`si doğrudan geçirilir, YENİ bir tahsis/
//! global YOK.
//!
//! Hedef fonksiyon (checker'ın `checkCallbackTargetArg`ı TARAFINDAN ZATEN
//! doğrulanmış: üst-düzey, senkron, extern OLMAYAN, imzası callback
//! tipinin son-parametre-HARİÇ kalanıyla TAM eşleşen bir `def`) İçİn BURADA
//! üretilen trampoline (`$<isim>__cbtramp`), TAM callback-tipiyle eşleşen
//! (gizli `%rt`/`%env` YOK — ham C ABI) statik bir QBE fonksiyonudur: SON
//! parametreyi (C'nin geri taşıdığı `context_param` değeri) `%rt` OLARAK
//! yorumlar, KALAN parametreleri OLDUĞU GİBİ hedef fonksiyona (derleme-anında
//! BİLİNEN, `$<isim>` — dolaylı DEĞİL) DOĞRUDAN iletir. Hedef bir istisna
//! fırlatıp YAKALANMAZSA (bu sınırın ÖTESİNDE Nox'un KENDİ error-union
//! zinciri YOKTUR — C'ye "istisna" ANLAMSIZDIR), `$nox_unhandled_exception`
//! (ZATEN VAR OLAN, `$main`in KENDİ üst-düzey sızıntı yoluyla AYNI, `noreturn`
//! process-sonlandırma) çağrılır — garbage bir değerin C'ye SIZMASI yerine.

const std = @import("std");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const RT_PARAM = types.RT_PARAM;
const CodegenError = abi.CodegenError;

/// `generateModule`nin `registerFunc` geçişinden HEMEN SONRA, HERHANGİ bir
/// fonksiyon GÖVDESİ üretilmeden ÖNCE — `genFunctionValueTrampoline`nin
/// AYNI çağrı deseni (bkz. `closures.zig`) — HER `@ffi.callback` HEDEFİ
/// İçİn BİR KEZ çağrılır (`callback_targets`, checker'ın `checkCallbackTargetArg`
/// TARAFINDAN doğrulanmış hedef adlarının DÜZ listesi).
pub fn genFfiCallbackTrampoline(self: *Codegen, name: []const u8) CodegenError!void {
    const sig = self.functions.get(name) orelse return error.Unsupported;
    const trampoline_name = try std.fmt.allocPrint(self.allocator, "{s}__cbtramp", .{name});

    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const trampoline_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{trampoline_name});
    try self.qbeFuncHeaderStart(if (sig.ret.qtype == .none) null else sig.ret.qtype, trampoline_sym);
    for (sig.params, 0..) |p, i| {
        const param_text = try std.fmt.allocPrint(self.allocator, "%p{d}", .{i});
        // `qbeFuncParam`in 3. argümanı `is_first` — SADECE gerçekten İLK
        // yayılan parametrede `true` (öncesine VİRGÜL EKLENMEZ), diğer
        // TÜM parametrelerde (ctx_rt DAHİL) `false` OLMALI (bkz. `closures.
        // zig`nin `genFunctionValueTrampoline`ının AYNI deseni).
        try self.qbeFuncParam(p.qtype, param_text, i == 0);
    }
    // Son parametre — checker'ın `registerExternCallback`ı TARAFINDAN
    // ZATEN `ptr` OLARAK doğrulanmış "userdata" yuvası, `%rt` OLARAK
    // yorumlanır (bkz. modül üstü not).
    try self.qbeFuncParam(.l, "%ctx_rt", sig.params.len == 0);
    try self.qbeFuncHeaderEnd();

    const ret_temp: ?[]const u8 = if (sig.ret.qtype == .none) null else try self.newTemp();
    const inner_args = try self.allocator.alloc(codegen.QbeArg, 1 + sig.params.len);
    inner_args[0] = .{ .ty = .l, .text = "%ctx_rt" };
    for (sig.params, 0..) |p, i| {
        inner_args[1 + i] = .{ .ty = p.qtype, .text = try std.fmt.allocPrint(self.allocator, "%p{d}", .{i}) };
    }
    const name_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{name});
    try self.qbeCall(if (ret_temp) |rv| .{ .name = rv, .ty = sig.ret.qtype } else null, name_sym, inner_args);

    // Hedef bir istisna fırlatıp YAKALAMADIYSA (bkz. modül üstü not) —
    // `$main`in KENDİ üst-düzey sızıntı yoluyla (`exceptions.zig`nin
    // `emitExceptionCheck`i, `self.in_main` dalı) AYNI, ZATEN VAR OLAN
    // `noreturn` mekanizma.
    const pending = try self.newTemp();
    try self.qbeCall(.{ .name = pending, .ty = .w }, "$nox_exception_pending", &.{.{ .ty = .l, .text = "%ctx_rt" }});
    const abort_label = try self.newLabel("cb_exc_abort");
    const ok_label = try self.newLabel("cb_exc_ok");
    try self.qbeJnz(pending, abort_label, ok_label);
    try self.qbeLabel(abort_label);
    try self.qbeCall(null, "$nox_unhandled_exception", &.{.{ .ty = .l, .text = "%ctx_rt" }});
    // `nox_unhandled_exception` `noreturn`dur (process.exit çağırır), ama
    // QBE bunu bilmez — bloğun bir sonlandırıcıyla bitmesi için savunmacı
    // (asla çalışmayacak) bir `ret` gerekir.
    try self.emitDefaultReturn(if (sig.ret.qtype == .none) .none else sig.ret.qtype);
    try self.qbeLabel(ok_label);
    try self.qbeRet(ret_temp);
    try self.qbeFuncEnd();
}
