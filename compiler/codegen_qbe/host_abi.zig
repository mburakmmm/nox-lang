//! UR-002 (NoxPy, v2.2.78): `noxc build --host-abi` — `@export` işaretli üst-düzey işlevler için `include/nox_host.h`'in belgelediği, C ABI'li SARMALAYICILAR.
//!
//! Nox işlevleri gizli bir ilk `%rt` (RuntimeState*) parametresi taşır; bu iç ABI özeldir (docs/apis/internal-abi.md) ve host'a ASLA verilmez. Üretilen sarmalayıcı:
//!   `w $nox_host_export_<modül>_<ad>(l %ctx, <parametreler>, [l %out,] l %err)`
//! bağlamdan `rt`yi alır (`nox_host_ctx_rt`; geçersiz bağlam → NOX_HOST_ERR_INVAL), `str` parametrelerini DOĞRULAYIP Nox değerine çevirir (UTF-8 hatası → ERR_UTF8; `bytes` ham geçer),
//! işlevi çağırır, bekleyen Nox istisnasını `NoxHostError`a çevirip YUTAR (`nox_host_capture`: süreç sonlanmaz; unwind tablosu yoktur — İlke #3), sonucu `out`a yazar (`str`/`bytes` →
//! host'a ait kopya tampon) ve geçici değerleri bırakır. Modül başına `nox_host_module_init_<modül>`/`nox_host_module_fini_<modül>` üst-düzey kodu/globalleri bağlam BAŞINA kurar/yıkar
//! (`$nox_lib_init`/`$nox_lib_fini`; `--host-abi` `lib_split` kipini açar). Sembol adları UR-007 `expand --json` `c_symbol` alanıyla BİREBİR aynıdır.

const std = @import("std");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const CodegenError = abi.CodegenError;
const HostExport = codegen.HostExport;
const HostKind = codegen.HostKind;
const QbeArg = codegen.QbeArg;

const ERR_EXCEPTION_RET = "1";
const ERR_INVAL_RET = "3";
const ERR_UTF8_RET = "5";
const ERR_INVALID_HANDLE_RET = "7";

fn qtypeOf(k: HostKind) ?types.QbeType {
    return switch (k) {
        .int, .str, .bytes, .handle => .l,
        .float => .d,
        .bool => .w,
        .none => null,
    };
}

fn resetFn(self: *Codegen) void {
    self.temp_counter = 0;
    self.label_counter = 0;
    self.mod_cache.deinit(self.allocator);
    self.mod_cache = .empty;
}

/// `ctx` → `rt`; `rt == 0` ise `ERR_INVAL` döner. Dönüş: `rt` temp adı.
fn emitCtxCheck(self: *Codegen) CodegenError![]const u8 {
    const rt = try self.newTemp();
    try self.qbeCall(.{ .name = rt, .ty = .l }, "$nox_host_enter", &.{.{ .ty = .l, .text = "%ctx" }}); // bağlam kilidini alır (UR-004); null = geçersiz bağlam (kilit alınmadı)
    const bad = try self.newTemp();
    try self.qbeOp2Imm(bad, .w, "ceql", rt, 0);
    const bad_l = try self.newLabel("host_ctx_bad");
    const go_l = try self.newLabel("host_ctx_ok");
    try self.qbeJnz(bad, bad_l, go_l);
    try self.qbeLabel(bad_l);
    try self.qbeRet(ERR_INVAL_RET);
    try self.qbeLabel(go_l);
    return rt;
}

/// Bekleyen istisna varsa `nox_host_capture(rt, err)` ile durumu döndürür (`on_exc` etiketine, `ok` yoksa ret'e dallanır).
fn emitLeave(self: *Codegen) CodegenError!void {
    try self.qbeCall(null, "$nox_host_leave", &.{.{ .ty = .l, .text = "%ctx" }});
}

fn emitPendingCheck(self: *Codegen, rt: []const u8, exc_label: []const u8, ok_label: []const u8) CodegenError!void {
    const pend = try self.newTemp();
    try self.qbeCall(.{ .name = pend, .ty = .w }, "$nox_exception_pending", &.{.{ .ty = .l, .text = rt }});
    try self.qbeJnz(pend, exc_label, ok_label);
}

pub fn genHostModuleEntry(self: *Codegen, mod: []const u8) CodegenError!void {
    resetFn(self);
    // nox_host_module_init_<mod>(ctx, err)
    const init_sym = try std.fmt.allocPrint(self.allocator, "$nox_host_module_init_{s}", .{mod});
    try self.qbeFuncHeaderStart(.w, init_sym);
    try self.qbeFuncParam(.l, "%ctx", true);
    try self.qbeFuncParam(.l, "%err", false);
    try self.qbeFuncHeaderEnd();
    const rt = try emitCtxCheck(self);
    try self.qbeCall(null, "$nox_lib_init", &.{.{ .ty = .l, .text = rt }});
    const exc_l = try self.newLabel("host_init_exc");
    const ok_l = try self.newLabel("host_init_ok");
    try emitPendingCheck(self, rt, exc_l, ok_l);
    try self.qbeLabel(exc_l);
    const st = try self.newTemp();
    try self.qbeCall(.{ .name = st, .ty = .w }, "$nox_host_capture", &.{ .{ .ty = .l, .text = "%ctx" }, .{ .ty = .l, .text = "%err" } });
    try emitLeave(self);
    try self.qbeRet(st);
    try self.qbeLabel(ok_l);
    try emitLeave(self);
    try self.qbeRet("0");
    try self.qbeFuncEnd();

    resetFn(self);
    // nox_host_module_fini_<mod>(ctx)
    const fini_sym = try std.fmt.allocPrint(self.allocator, "$nox_host_module_fini_{s}", .{mod});
    try self.qbeFuncHeaderStart(null, fini_sym);
    try self.qbeFuncParam(.l, "%ctx", true);
    try self.qbeFuncHeaderEnd();
    const rt2 = try self.newTemp();
    try self.qbeCall(.{ .name = rt2, .ty = .l }, "$nox_host_enter", &.{.{ .ty = .l, .text = "%ctx" }});
    const none = try self.newTemp();
    try self.qbeOp2Imm(none, .w, "ceql", rt2, 0);
    const skip_l = try self.newLabel("host_fini_skip");
    const do_l = try self.newLabel("host_fini_do");
    try self.qbeJnz(none, skip_l, do_l);
    try self.qbeLabel(do_l);
    try self.qbeCall(null, "$nox_lib_fini", &.{.{ .ty = .l, .text = rt2 }});
    try emitLeave(self);
    try self.qbeRet(null);
    try self.qbeLabel(skip_l);
    try self.qbeRet(null);
    try self.qbeFuncEnd();
}

pub fn genHostExport(self: *Codegen, mod: []const u8, ex: HostExport) CodegenError!void {
    resetFn(self);
    const sym = try std.fmt.allocPrint(self.allocator, "$nox_host_export_{s}_{s}", .{ mod, ex.export_name orelse ex.name });
    try self.qbeFuncHeaderStart(.w, sym);
    try self.qbeFuncParam(.l, "%ctx", true);
    for (ex.params, 0..) |k, i| {
        switch (k) {
            .int, .handle => try self.qbeFuncParam(.l, try std.fmt.allocPrint(self.allocator, "%a{d}", .{i}), false),
            .float => try self.qbeFuncParam(.d, try std.fmt.allocPrint(self.allocator, "%a{d}", .{i}), false),
            .bool => try self.qbeFuncParam(.w, try std.fmt.allocPrint(self.allocator, "%a{d}", .{i}), false),
            .str, .bytes => {
                try self.qbeFuncParam(.l, try std.fmt.allocPrint(self.allocator, "%d{d}", .{i}), false);
                try self.qbeFuncParam(.l, try std.fmt.allocPrint(self.allocator, "%n{d}", .{i}), false);
            },
            .none => return error.Unsupported,
        }
    }
    if (ex.ret != .none) try self.qbeFuncParam(.l, "%out", false);
    try self.qbeFuncParam(.l, "%err", false);
    try self.qbeFuncHeaderEnd();

    const rt = try emitCtxCheck(self);

    // 1) `str` parametrelerinin UTF-8 doğrulaması (değer oluşturulmadan ÖNCE: erken dönüşte sızıntı olmaz).
    for (ex.params, 0..) |k, i| {
        if (k != .str) continue;
        const ok = try self.newTemp();
        try self.qbeCall(.{ .name = ok, .ty = .w }, "$nox_host_utf8_ok", &.{
            .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "%d{d}", .{i}) },
            .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "%n{d}", .{i}) },
        });
        const bad_l = try self.newLabel("host_utf8_bad");
        const next_l = try self.newLabel("host_utf8_ok");
        try self.qbeJnz(ok, next_l, bad_l);
        try self.qbeLabel(bad_l);
        try emitLeave(self);
        try self.qbeRet(ERR_UTF8_RET);
        try self.qbeLabel(next_l);
    }

    // 1b) `class` parametreleri: handle'lar ÖNCEDEN doğrulanır (geçersiz/sahte/başka bağlamın handle'ı → ERR_INVALID_HANDLE); nesneler BORÇLU geçer.
    var handle_objs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (ex.params, 0..) |k, i| {
        if (k != .handle) {
            try handle_objs.append(self.allocator, "");
            continue;
        }
        const obj = try self.newTemp();
        try self.qbeCall(.{ .name = obj, .ty = .l }, "$nox_host_handle_obj", &.{
            .{ .ty = .l, .text = "%ctx" },
            .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "%a{d}", .{i}) },
        });
        const isnull = try self.newTemp();
        try self.qbeOp2Imm(isnull, .w, "ceql", obj, 0);
        const bad_l = try self.newLabel("host_handle_bad");
        const next_l = try self.newLabel("host_handle_ok");
        try self.qbeJnz(isnull, bad_l, next_l);
        try self.qbeLabel(bad_l);
        try emitLeave(self);
        try self.qbeRet(ERR_INVALID_HANDLE_RET);
        try self.qbeLabel(next_l);
        try handle_objs.append(self.allocator, obj);
    }

    // 2) Nox değerlerini kur: `str`/`bytes` kopyalanır (host belleği Nox'a ödünç verilmez); `bool` 0/1'e normalleştirilir (C ABI üst bitleri garanti etmez).
    var call_args: std.ArrayListUnmanaged(QbeArg) = .empty;
    try call_args.append(self.allocator, .{ .ty = .l, .text = rt });
    var owned: std.ArrayListUnmanaged([]const u8) = .empty; // çağrı sonrası bırakılacak `str` temp'leri
    for (ex.params, 0..) |k, i| {
        switch (k) {
            .int => try call_args.append(self.allocator, .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "%a{d}", .{i}) }),
            .handle => try call_args.append(self.allocator, .{ .ty = .l, .text = handle_objs.items[i] }),
            .float => try call_args.append(self.allocator, .{ .ty = .d, .text = try std.fmt.allocPrint(self.allocator, "%a{d}", .{i}) }),
            .bool => {
                const masked = try self.newTemp();
                try self.qbeOp2Imm(masked, .w, "and", try std.fmt.allocPrint(self.allocator, "%a{d}", .{i}), 255);
                const norm = try self.newTemp();
                try self.qbeOp2Imm(norm, .w, "cnew", masked, 0);
                try call_args.append(self.allocator, .{ .ty = .w, .text = norm });
            },
            .str, .bytes => {
                const s = try self.newTemp();
                try self.qbeCall(.{ .name = s, .ty = .l }, "$nox_host_str_new", &.{
                    .{ .ty = .l, .text = rt },
                    .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "%d{d}", .{i}) },
                    .{ .ty = .l, .text = try std.fmt.allocPrint(self.allocator, "%n{d}", .{i}) },
                });
                try owned.append(self.allocator, s);
                try call_args.append(self.allocator, .{ .ty = .l, .text = s });
            },
            .none => return error.Unsupported,
        }
    }

    // 3) çağrı
    const fn_sym = try self.userFnSym(ex.name);
    const rty = qtypeOf(ex.ret);
    const result: ?[]const u8 = if (rty != null) try self.newTemp() else null;
    try self.qbeCall(if (result) |r| .{ .name = r, .ty = rty.? } else null, fn_sym, call_args.items);

    // 4) istisna?
    const exc_l = try self.newLabel("host_exc");
    const ok_l = try self.newLabel("host_ok");
    try emitPendingCheck(self, rt, exc_l, ok_l);

    try self.qbeLabel(exc_l);
    const st = try self.newTemp();
    try self.qbeCall(.{ .name = st, .ty = .w }, "$nox_host_capture", &.{ .{ .ty = .l, .text = "%ctx" }, .{ .ty = .l, .text = "%err" } });
    for (owned.items) |s| try self.qbeCall(null, "$nox_str_release", &.{ .{ .ty = .l, .text = rt }, .{ .ty = .l, .text = s } });
    try emitLeave(self);
    try self.qbeRet(st);

    // 5) başarı: sonucu `out`a yaz
    try self.qbeLabel(ok_l);
    var status: []const u8 = "0";
    if (result) |r| {
        switch (ex.ret) {
            .int => try self.qbeStore(.l, r, "%out"),
            .handle => {
                // handle sahipliği (ARC +1) bağlam tablosuna geçer; tablo dolu/bellek yoksa nesne bırakılır ve ERR_NOMEM döner.
                const hh = try self.newTemp();
                try self.qbeCall(.{ .name = hh, .ty = .l }, "$nox_host_handle_new", &.{ .{ .ty = .l, .text = "%ctx" }, .{ .ty = .l, .text = r } });
                try self.qbeStore(.l, hh, "%out");
                const bad = try self.newTemp();
                try self.qbeOp2Imm(bad, .w, "ceql", hh, 0);
                const st3 = try self.newTemp();
                try self.qbeOp2Imm(st3, .w, "mul", bad, 2);
                status = st3;
            },
            .float => try self.qbeStore(.d, r, "%out"),
            .bool => try self.qbeStoreB(r, "%out"),
            .str, .bytes => {
                const st2 = try self.newTemp();
                try self.qbeCall(.{ .name = st2, .ty = .w }, "$nox_host_str_out", &.{ .{ .ty = .l, .text = r }, .{ .ty = .l, .text = "%out" } });
                try self.qbeCall(null, "$nox_str_release", &.{ .{ .ty = .l, .text = rt }, .{ .ty = .l, .text = r } });
                status = st2;
            },
            .none => {},
        }
    }
    for (owned.items) |s| try self.qbeCall(null, "$nox_str_release", &.{ .{ .ty = .l, .text = rt }, .{ .ty = .l, .text = s } });
    try emitLeave(self);
    try self.qbeRet(status);
    try self.qbeFuncEnd();
}

/// UR-009: kapsayıcı adaptörleri (`host_adapt.zig`) sınıf örneklerini `extern def nox_hv_obj_<Sınıf>(h) -> Sınıf` / `nox_hv_new_obj_<Sınıf>(o: Sınıf) -> int` ile alır/verir: `extern def` sembol adı = Nox adı olduğundan
/// her sınıf için ince bir kısayol gerekir; ikisi de çalışma zamanının sınıf-bağımsız ilkellerine (`nox_hv_obj_take`/`nox_hv_new_obj`) devreder (ARC sözleşmesi: dönen sınıf nesnesi +1, parametre ödünç).
fn genHostClassStubs(self: *Codegen, cn: []const u8) CodegenError!void {
    resetFn(self);
    const take_sym = try std.fmt.allocPrint(self.allocator, "$nox_hv_obj_{s}", .{cn});
    try self.qbeFuncHeaderStart(.l, take_sym);
    try self.qbeFuncParam(.l, "%rt", true);
    try self.qbeFuncParam(.l, "%h", false);
    try self.qbeFuncHeaderEnd();
    const r1 = try self.newTemp();
    try self.qbeCall(.{ .name = r1, .ty = .l }, "$nox_hv_obj_take", &.{ .{ .ty = .l, .text = "%rt" }, .{ .ty = .l, .text = "%h" } });
    try self.qbeRet(r1);
    try self.qbeFuncEnd();

    resetFn(self);
    const new_sym = try std.fmt.allocPrint(self.allocator, "$nox_hv_new_obj_{s}", .{cn});
    try self.qbeFuncHeaderStart(.l, new_sym);
    try self.qbeFuncParam(.l, "%rt", true);
    try self.qbeFuncParam(.l, "%o", false);
    try self.qbeFuncHeaderEnd();
    const r2 = try self.newTemp();
    try self.qbeCall(.{ .name = r2, .ty = .l }, "$nox_hv_new_obj", &.{ .{ .ty = .l, .text = "%rt" }, .{ .ty = .l, .text = "%o" } });
    try self.qbeRet(r2);
    try self.qbeFuncEnd();
}

/// `generateModule`nin `registerFunc` geçişinden SONRA, işlev gövdeleri üretilmeden ÖNCE çağrılır (bkz. `ffi_callback.zig`nin aynı konumu).
pub fn genHostAbi(self: *Codegen, opts: codegen.HostAbiOpts) CodegenError!void {
    try genHostModuleEntry(self, opts.module_name);
    for (opts.classes) |cn| try genHostClassStubs(self, cn);
    for (opts.exports) |ex| try genHostExport(self, opts.module_name, ex);
}
