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
pub fn genFfiCallbackTrampoline(self: *Codegen, key: []const u8) CodegenError!void {
    // `ad` (userdata son parametre) ya da `ad@k` (userdata k. parametre; v2.1.108 `@ffi.callback(..., ud_index=k)`)
    var name = key;
    var ud_at: ?usize = null;
    if (std.mem.indexOfScalar(u8, key, '@')) |at| {
        name = key[0..at];
        ud_at = std.fmt.parseInt(usize, key[at + 1 ..], 10) catch return error.Unsupported;
    }
    const sig = self.functions.get(name) orelse return error.Unsupported;
    const trampoline_name = if (ud_at) |k| try std.fmt.allocPrint(self.allocator, "{s}__cbtramp_u{d}", .{ name, k }) else try std.fmt.allocPrint(self.allocator, "{s}__cbtramp", .{name});

    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const trampoline_sym = try std.fmt.allocPrint(self.allocator, "${s}", .{trampoline_name});
    try self.qbeFuncHeaderStart(if (sig.ret.qtype == .none) null else sig.ret.qtype, trampoline_sym);
    const total = sig.params.len + 1;
    const ud_k: usize = ud_at orelse sig.params.len;
    {
        var j: usize = 0; // hedefin parametre sayacı
        var pos: usize = 0;
        while (pos < total) : (pos += 1) {
            // `qbeFuncParam`in 3. argümanı `is_first` — SADECE gerçekten İLK yayılan parametrede `true`.
            if (pos == ud_k) {
                // checker'ın `registerExternCallback`ı TARAFINDAN ZATEN `ptr` OLARAK doğrulanmış "userdata" yuvası `%rt` OLARAK yorumlanır
                try self.qbeFuncParam(.l, "%ctx_rt", pos == 0);
            } else {
                try self.qbeFuncParam(sig.params[j].qtype, try std.fmt.allocPrint(self.allocator, "%p{d}", .{j}), pos == 0);
                j += 1;
            }
        }
    }
    try self.qbeFuncHeaderEnd();

    const ret_temp: ?[]const u8 = if (sig.ret.qtype == .none) null else try self.newTemp();
    const inner_args = try self.allocator.alloc(codegen.QbeArg, 1 + sig.params.len);
    inner_args[0] = .{ .ty = .l, .text = "%ctx_rt" };
    for (sig.params, 0..) |p, i| {
        inner_args[1 + i] = .{ .ty = p.qtype, .text = try std.fmt.allocPrint(self.allocator, "%p{d}", .{i}) };
    }
    const name_sym = try self.userFnSym(name);
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

/// v2.1.101 (TODO 3.4 F2): `nox.ffi.Callback` tutamaçları için BİR `@ffi.callback` extern def başına closure-trampoline'ı (`$<extern>__clotramp`).
/// C'nin geri taşıdığı `userdata`, `nox_cb_box_new`in kurduğu kutudur: `[rt@0, closure@8]`. Trampoline `rt`yi ve closure'ı kutudan okur, closure'ın
/// `fn_ptr`ini (`closure@0`) `(rt, closure, args...)` ile çağırır (bkz. `calls.zig`nin `genIndirectCallThroughClosurePtr`ı); sonrası `genFfiCallbackTrampoline`
/// ile aynı: yakalanmamış istisna `$nox_unhandled_exception` ile süreci sonlandırır.
pub fn genClosureCallbackTrampoline(self: *Codegen, extern_name: []const u8) CodegenError!void {
    const esig = self.extern_functions.get(extern_name) orelse return error.Unsupported;
    const cb = esig.callback orelse return;
    const fsig = esig.params[cb.param_idx].func_sig orelse return error.Unsupported;
    if (fsig.params.len == 0) return error.Unsupported;
    const n = fsig.params.len - 1; // userdata hariç parametre sayısı
    const ud_k = cb.ud_pos;

    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;

    const sym = try std.fmt.allocPrint(self.allocator, "${s}__clotramp", .{extern_name});
    try self.qbeFuncHeaderStart(if (fsig.ret.qtype == .none) null else fsig.ret.qtype, sym);
    {
        var j: usize = 0;
        var pos: usize = 0;
        while (pos < fsig.params.len) : (pos += 1) {
            if (pos == ud_k) {
                try self.qbeFuncParam(.l, "%ud", pos == 0);
            } else {
                try self.qbeFuncParam(fsig.params[pos].qtype, try std.fmt.allocPrint(self.allocator, "%p{d}", .{j}), pos == 0);
                j += 1;
            }
        }
    }
    try self.qbeFuncHeaderEnd();

    const rt = try self.newTemp();
    try self.qbeLoadL(rt, "%ud");
    const clo_slot = try self.newTemp();
    try self.qbeOp2Imm(clo_slot, .l, "add", "%ud", 8);
    const clo = try self.newTemp();
    try self.qbeLoadL(clo, clo_slot);
    // Faz 9.4: `close()` kutudaki closure işaretçisini sıfırlar; C kütüphanesi kapanıştan SONRA hâlâ çağırırsa serbest bırakılmış closure'ı okumak yerine net bir iletiyle sonlanılır.
    const closed_t = try self.newTemp();
    try self.qbeOp2Imm(closed_t, .w, "ceql", clo, 0);
    const closed_label = try self.newLabel("clocb_closed");
    const live_label = try self.newLabel("clocb_live");
    try self.qbeJnz(closed_t, closed_label, live_label);
    try self.qbeLabel(closed_label);
    try self.qbeCall(null, "$nox_cb_closed_abort", &.{});
    try self.emitDefaultReturn(if (fsig.ret.qtype == .none) .none else fsig.ret.qtype);
    try self.qbeLabel(live_label);
    const fn_ptr = try self.newTemp();
    try self.qbeLoadL(fn_ptr, clo);

    const ret_temp: ?[]const u8 = if (fsig.ret.qtype == .none) null else try self.newTemp();
    const call_args = try self.allocator.alloc(codegen.QbeArg, 2 + n);
    call_args[0] = .{ .ty = .l, .text = rt };
    call_args[1] = .{ .ty = .l, .text = clo };
    {
        var j: usize = 0;
        for (fsig.params, 0..) |p, pos| {
            if (pos == ud_k) continue;
            call_args[2 + j] = .{ .ty = p.qtype, .text = try std.fmt.allocPrint(self.allocator, "%p{d}", .{j}) };
            j += 1;
        }
    }
    try self.qbeCall(if (ret_temp) |rv| .{ .name = rv, .ty = fsig.ret.qtype } else null, fn_ptr, call_args);

    const pending = try self.newTemp();
    try self.qbeCall(.{ .name = pending, .ty = .w }, "$nox_exception_pending", &.{.{ .ty = .l, .text = rt }});
    const abort_label = try self.newLabel("clocb_exc_abort");
    const ok_label = try self.newLabel("clocb_exc_ok");
    try self.qbeJnz(pending, abort_label, ok_label);
    try self.qbeLabel(abort_label);
    try self.qbeCall(null, "$nox_unhandled_exception", &.{.{ .ty = .l, .text = rt }});
    try self.emitDefaultReturn(if (fsig.ret.qtype == .none) .none else fsig.ret.qtype);
    try self.qbeLabel(ok_label);
    try self.qbeRet(ret_temp);
    try self.qbeFuncEnd();
}
