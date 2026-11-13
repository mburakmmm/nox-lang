//! Faz 9.0 F2 (v2.1.131): tip-yönlendirmeli DİNAMİK paylaşım — sınıf örneği alan bariyerleri (bkz. `project/faz9-kontrol-debug-analizi-2026-11.md` D.3).
//!
//! Paylaşım-yetenekli sınıflar (`Codegen.dyn_classes`) için: yığın tipli alan (`str`/`dict`/sınıf) OKUMASI örnek `SHARED` ise kilit altında RETAIN eder (okuyan kendi referansını tutar);
//! YAZMASI yeni değeri yayımlar (grafiği `SHARED` yapar), kilit altında değiştirir ve ESKİYİ kilit DIŞINDA bırakır. Kilit asla kullanıcı kodu çağrısını kapsamaz (kilitlenme yok).
//! Bayrak kurulu değilse (örnek hiç paylaşılmadıysa) maliyet: bir yükleme + öngörülür dal. Sonuçlar `always_fresh` (sahipli) döner.

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const RT_PARAM = types.RT_PARAM;
const Value = types.Value;
const TypeInfo = types.TypeInfo;
const ClassField = types.ClassField;
const CodegenError = abi.CodegenError;
const isHeapManaged = abi.isHeapManaged;
const HeapKind = types.HeapKind;

/// Bu sınıf için bariyerler üretiliyor mu?
pub fn isDynClass(self: *const Codegen, name: ?[]const u8) bool {
    const n = name orelse return false;
    return self.dyn_classes.contains(n);
}

/// Bir alan, bariyer gerektiren yığın alanı mı (`str` değişmez ama işaretçi değişimi yarışır: o da bariyerlidir)?
pub fn isBarrierField(f: ClassField) bool {
    return switch (f.info.heap) {
        .str, .dict, .class, .list => true,
        else => false,
    };
}

/// Nesnenin `SHARED` bitini (`payload - 8` sözcüğünün 58. biti) okur: `w` sonucu (1 = paylaşılan).
pub fn emitSharedFlag(self: *Codegen, obj_text: []const u8) CodegenError![]const u8 {
    const hdr = try self.newTemp();
    try self.qbeOp2Imm(hdr, .l, "sub", obj_text, @intCast(types.ARC_HEADER_SIZE));
    const w = try self.newTemp();
    try self.qbeLoadL(w, hdr);
    const m = try self.newTemp();
    try self.qbeOp2Imm(m, .l, "and", w, @intCast(types.HDR_SHARED_BIT));
    const f = try self.newTemp();
    try self.qbeOp2Imm(f, .w, "cnel", m, 0);
    return f;
}

fn emitCondCall(self: *Codegen, flag: []const u8, sym: []const u8, args: []const codegen.QbeArg, comptime tag: []const u8) CodegenError!void {
    const yes = try self.newLabel(tag);
    const done = try self.newLabel("dyn_done");
    try self.qbeJnz(flag, yes, done);
    try self.qbeLabel(yes);
    try self.qbeCall(null, sym, args);
    try self.qbeJmp(done);
    try self.qbeLabel(done);
}

/// Yığın elemanlı liste değeri mi VE paylaşılan-liste kilitleri açık mı? (Eleman erişimleri blok kilidi altında sahipli yapılır.)
pub fn listHeapElems(self: *const Codegen, v: Value) bool {
    if (!self.list_locks or v.heap != .list) return false;
    if (v.elem_is_str) return true;
    if (v.elem_heap_info) |e| return isHeapManaged(e.heap);
    return false;
}

/// Liste elemanının yığın türü (`str` ya da `elem_heap_info.heap`).
pub fn listElemHeap(v: Value) HeapKind {
    if (v.elem_heap_info) |e| return e.heap;
    return .str;
}

/// Liste bloğunun KENDİ kilidini (paylaşılansa) alır; `w` bayrağını döner (`emitCondUnlock` ile bırakılır).
pub fn emitBlockLock(self: *Codegen, list_text: []const u8) CodegenError![]const u8 {
    const fl = try emitSharedFlag(self, list_text);
    try emitCondLock(self, fl, list_text);
    return fl;
}

/// Yığın elemanlı bir listeyi DEĞİŞTİREN işlemin kilit bağlamı: (varsa) tutan örnek kilidi + liste bloğu kilidi; `obj` bayat olmasın diye blok tutandan YENİDEN okunur.
pub const MutCtx = struct {
    obj: Value,
    holder: ?[]const u8 = null,
    holder_flag: ?[]const u8 = null,
    block_flag: ?[]const u8 = null,
    active: bool = false,
    gslot: bool = false,
    recv: ?ast.Expr = null,
    base: ?Value = null,
};

pub fn enterMut(self: *Codegen, recv: ast.Expr, obj: Value) CodegenError!MutCtx {
    var ctx: MutCtx = .{ .obj = obj };
    if (!listHeapElems(self, obj)) return ctx;
    ctx.active = true;
    var list_text = obj.text;
    if (recv == .identifier and !self.vars.contains(recv.identifier) and self.dyn_slot_globals.contains(recv.identifier)) {
        // Global yuvadaki liste: yuva kilidi altında bloğu yuvadan yeniden oku (bayat olmasın).
        const g = self.module_globals.get(recv.identifier).?;
        try emitGslotLock(self);
        const block = try self.newTemp();
        try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
        const addr = try self.newTemp();
        try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
        const t = try self.newTemp();
        try self.qbeLoadL(t, addr);
        list_text = t;
        ctx.gslot = true;
    }
    if (recv == .attribute) {
        const fa = recv.attribute;
        const base = try self.genExpr(fa.obj.*);
        if (base.heap == .class and isDynClass(self, base.class_name)) {
            const cinfo = self.classes.get(base.class_name.?).?;
            for (cinfo.fields.items) |f| {
                if (!std.mem.eql(u8, f.name, fa.attr)) continue;
                const fl = try emitSharedFlag(self, base.text);
                try emitCondLock(self, fl, base.text);
                const addr = try self.newTemp();
                try self.qbeOp2Imm(addr, .l, "add", base.text, @intCast(f.offset));
                const t = try self.newTemp();
                try self.qbeLoadL(t, addr);
                list_text = t;
                ctx.holder = base.text;
                ctx.holder_flag = fl;
                break;
            }
        }
        ctx.base = base;
        ctx.recv = recv;
    }
    ctx.block_flag = try emitBlockLock(self, list_text);
    ctx.obj.text = list_text;
    self.cold_unlock = ctx;
    return ctx;
}

/// Kilitleri bırakır (blok, sonra tutan). Hata yollarında da (raise öncesi) çağrılır.
pub fn exitMut(self: *Codegen, ctx: MutCtx) CodegenError!void {
    if (!ctx.active) return;
    if (ctx.block_flag) |fl| try emitCondUnlock(self, fl, ctx.obj.text);
    if (ctx.holder) |h| try emitCondUnlock(self, ctx.holder_flag.?, h);
    if (ctx.gslot) try emitGslotUnlock(self);
}

/// `exitMut` + (varsa) tutan taban ifadesinin geçici referansını bırakma; kilit bağlamını kapatır (normal yol sonu).
pub fn finishMut(self: *Codegen, ctx: MutCtx) CodegenError!void {
    try abortMut(self, ctx);
    self.cold_unlock = null;
}

/// Hata (raise) yolları için: kilitleri bırakıp tabanı serbest bırakır, bağlam durumunu DEĞİŞTİRMEZ.
pub fn abortMut(self: *Codegen, ctx: MutCtx) CodegenError!void {
    try exitMut(self, ctx);
    if (ctx.active) if (ctx.recv) |r| try self.releaseIfTemporary(r.attribute.obj.*, ctx.base.?);
}

/// Faz 9.0 F5: yuva bariyerli global için ortak yuva kilidi (globals bloğundaki ayrılmış 16 bayt; sözde-yük başlığı `+8`).
fn gslotLockPtr(self: *Codegen) CodegenError![]const u8 {
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
    const p = try self.newTemp();
    try self.qbeOp2Imm(p, .l, "add", block, @intCast(self.gslot_lock_offset + 8));
    return p;
}

pub fn emitGslotLock(self: *Codegen) CodegenError!void {
    const p = try gslotLockPtr(self);
    try self.qbeCall(null, "$nox_obj_lock", &.{.{ .ty = .l, .text = p }});
}

pub fn emitGslotUnlock(self: *Codegen) CodegenError!void {
    const p = try gslotLockPtr(self);
    try self.qbeCall(null, "$nox_obj_unlock", &.{.{ .ty = .l, .text = p }});
}

/// Globals bloğu ayrıldıktan sonra yuva kilit sözcüklerini sıfırlar (bellek sıfırlanmış gelmez).
pub fn emitGslotInit(self: *Codegen, block: []const u8) CodegenError!void {
    if (self.dyn_slot_globals.count() == 0) return;
    const a = try self.newTemp();
    try self.qbeOp2Imm(a, .l, "add", block, @intCast(self.gslot_lock_offset));
    try self.qbeStoreImmL(0, a);
    const b = try self.newTemp();
    try self.qbeOp2Imm(b, .l, "add", block, @intCast(self.gslot_lock_offset + 8));
    try self.qbeStoreImmL(0, b);
}

/// Yuva bariyerli globalin SAHİPLİ okuması: kilit altında yükle + retain.
pub fn genSlotRead(self: *Codegen, g: types.GlobalVar) CodegenError!Value {
    try emitGslotLock(self);
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
    const t = try self.newTemp();
    try self.qbeLoadL(t, addr);
    try self.emitInlineRetain(t, g.info.heap);
    try emitGslotUnlock(self);
    return .{ .text = t, .qtype = g.info.qtype, .heap = g.info.heap, .elem_qtype = g.info.elem_qtype, .class_name = g.info.class_name, .elem_heap_info = g.info.elem_heap_info, .elem_is_str = g.info.elem_is_str, .dict_info = g.info.dict_info, .func_sig = g.info.func_sig, .fixed_int = g.info.fixed_int, .elem_fixed_int = g.info.elem_fixed_int, .always_fresh = true };
}

/// Yuva bariyerli globale yazma: yeni değer (zaten sahipli) yayımlanır, kilit altında değiştirilir, eski değer kilit DIŞINDA bırakılır.
pub fn genSlotStore(self: *Codegen, g: types.GlobalVar, val_text: []const u8) CodegenError!void {
    try emitPublishValue(self, val_text, g.info);
    try emitGslotLock(self);
    const block = try self.newTemp();
    try self.qbeCall(.{ .name = block, .ty = .l }, "$nox_globals_get", &.{.{ .ty = .l, .text = RT_PARAM }});
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", block, @intCast(g.offset));
    const old = try self.newTemp();
    try self.qbeLoadL(old, addr);
    try self.qbeStoreL(val_text, addr);
    try emitGslotUnlock(self);
    try self.releaseValueIfSet(old, g.info.heap, g.info.elem_qtype, g.info.class_name, g.info.elem_heap_info, g.info.dict_info);
}

/// Faz 9.0 F4: iş parçacığı sınırını geçen değeri (spawn argümanı, kanal öğesi, görev sonucu) geçişli yayımlar (`SHARED` + dinamik bariyerler etkin).
pub fn emitPublishCrossing(self: *Codegen, v: Value) CodegenError!void {
    if (!self.dyn_crossing) return;
    if (v.heap != .class and v.heap != .list and v.heap != .dict) return;
    try emitPublishValue(self, v.text, abi.typeInfoOfValue(v));
}

pub fn emitPublishCrossingInfo(self: *Codegen, text: []const u8, info: TypeInfo) CodegenError!void {
    if (!self.dyn_crossing) return;
    if (info.heap != .class and info.heap != .list and info.heap != .dict) return;
    try emitPublishValue(self, text, info);
}

/// Eski blok paylaşılansa yeni bloğu da paylaşılan işaretler (yalnız bayrak; elemanlar zaten yayımlanmıştır).
pub fn emitPropagateShared(self: *Codegen, old_text: []const u8, new_text: []const u8) CodegenError!void {
    const fl = try emitSharedFlag(self, old_text);
    try emitCondCall(self, fl, "$nox_obj_publish_begin", &.{.{ .ty = .l, .text = new_text }}, "dyn_grow_pub");
}

/// Salt-okunur liste tüketicileri için: blok paylaşılansa kilit altında özel bir kopya (elemanlar retain) alınır ve işlem onun üzerinde yapılır; paylaşılan değilse liste aynen kullanılır.
pub const Snap = struct { v: Value, copied_slot: ?[]const u8 = null };

pub fn snapshotRead(self: *Codegen, v: Value) CodegenError!Snap {
    if (!listHeapElems(self, v)) return .{ .v = v };
    const fl = try emitSharedFlag(self, v.text);
    const slot = try self.newTemp();
    try self.qbeAlloc(slot, .eight, 8);
    try self.qbeStoreL(v.text, slot);
    const cslot = try self.newTemp();
    try self.qbeAlloc(cslot, .eight, 8);
    try self.qbeStoreImmL(0, cslot);
    const yes = try self.newLabel("dyn_snap");
    const done = try self.newLabel("dyn_snap_done");
    try self.qbeJnz(fl, yes, done);
    try self.qbeLabel(yes);
    try self.qbeCall(null, "$nox_obj_lock", &.{.{ .ty = .l, .text = v.text }});
    const c = try self.newTemp();
    try self.qbeCall(.{ .name = c, .ty = .l }, "$nox_list_copy", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = v.text }, .{ .ty = .l, .text = try self.listEszLit(v) }, .{ .ty = .w, .text = self.listKindLit(v) } });
    try self.qbeCall(null, "$nox_obj_unlock", &.{.{ .ty = .l, .text = v.text }});
    try self.qbeStoreL(c, slot);
    try self.qbeStoreImmL(1, cslot);
    try self.qbeJmp(done);
    try self.qbeLabel(done);
    const p = try self.newTemp();
    try self.qbeLoadL(p, slot);
    var nv = v;
    nv.text = p;
    return .{ .v = nv, .copied_slot = cslot };
}

/// `snapshotRead`in kopyasını (alındıysa) bırakır.
pub fn releaseSnap(self: *Codegen, sn: Snap) CodegenError!void {
    const cs = sn.copied_slot orelse return;
    const f = try self.newTemp();
    try self.qbeLoadL(f, cs);
    const yes = try self.newLabel("dyn_snap_rel");
    const done = try self.newLabel("dyn_snap_reld");
    const nz = try self.newTemp();
    try self.qbeOp2Imm(nz, .w, "cnel", f, 0);
    try self.qbeJnz(nz, yes, done);
    try self.qbeLabel(yes);
    try self.releaseValueIfSet(sn.v.text, .list, sn.v.elem_qtype, sn.v.class_name, sn.v.elem_heap_info, sn.v.dict_info);
    try self.qbeJmp(done);
    try self.qbeLabel(done);
}

/// Liste bloğu paylaşılansa `val` elemanını (yeni eleman olarak eklenmeden ÖNCE) yayımlar.
pub fn emitPublishElemIfShared(self: *Codegen, list_text: []const u8, val_text: []const u8, elem: Value) CodegenError!void {
    const info = abi.typeInfoOfValue(abi.valueFromElemDescriptor("0", elem.elem_qtype, elem.elem_heap_info, elem.elem_is_str, elem.elem_fixed_int));
    if (info.heap != .class and info.heap != .dict and info.heap != .list) return;
    const fl = try emitSharedFlag(self, list_text);
    const yes = try self.newLabel("dyn_pub_elem");
    const done = try self.newLabel("dyn_pub_done");
    try self.qbeJnz(fl, yes, done);
    try self.qbeLabel(yes);
    try emitPublishValue(self, val_text, info);
    try self.qbeJmp(done);
    try self.qbeLabel(done);
}

/// Örnek kilidini (paylaşılansa) alır / bırakır — `flag` `emitSharedFlag` sonucudur.
pub fn emitCondLock(self: *Codegen, flag: []const u8, obj_text: []const u8) CodegenError!void {
    try emitCondCall(self, flag, "$nox_obj_lock", &.{.{ .ty = .l, .text = obj_text }}, "dyn_hold_lock");
}

pub fn emitCondUnlock(self: *Codegen, flag: []const u8, obj_text: []const u8) CodegenError!void {
    try emitCondCall(self, flag, "$nox_obj_unlock", &.{.{ .ty = .l, .text = obj_text }}, "dyn_hold_unlock");
}

/// Yığın tipli alanın SAHİPLİ okuması: örnek paylaşılansa kilit altında yükle+retain; değilse yükle+retain (kilitsiz). Dönen işaretçi çağırana aittir.
pub fn emitOwnedFieldLoad(self: *Codegen, obj_text: []const u8, f: ClassField) CodegenError![]const u8 {
    const shared = try emitSharedFlag(self, obj_text);
    try emitCondCall(self, shared, "$nox_obj_lock", &.{.{ .ty = .l, .text = obj_text }}, "dyn_rd_lock");
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", obj_text, @intCast(f.offset));
    const r = try self.newTemp();
    try self.qbeLoadL(r, addr);
    try self.emitInlineRetain(r, f.info.heap);
    try emitCondCall(self, shared, "$nox_obj_unlock", &.{.{ .ty = .l, .text = obj_text }}, "dyn_rd_unlock");
    return r;
}

/// Değeri yayımlar (paylaşılan bir yere yazılmadan ÖNCE): sınıf → `$nox_publish_<Sınıf>`, sözlük → paylaşılan işaretle, `str` → gerekmez.
pub fn emitPublishValue(self: *Codegen, ptr_text: []const u8, info: TypeInfo) CodegenError!void {
    switch (info.heap) {
        .class => {
            const cn = info.class_name orelse return;
            if (!isDynClass(self, cn)) return;
            const sym = try std.fmt.allocPrint(self.allocator, "$nox_publish_{s}", .{cn});
            try self.qbeCall(null, sym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr_text } });
        },
        .dict => try self.qbeCall(null, "$nox_dict_make_shared", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = ptr_text } }),
        // Liste bloğu: `SHARED` bitini kur; sınıf/sözlük/liste elemanları ilk kez yayımlanıyorsa tek tek yayımlanır.
        .list => {
            const elem_info = abi.typeInfoOfValue(abi.valueFromElemDescriptor("0", info.elem_qtype, info.elem_heap_info, info.elem_is_str, info.elem_fixed_int));
            const first = try self.newTemp();
            try self.qbeCall(.{ .name = first, .ty = .w }, "$nox_obj_publish_begin", &.{.{ .ty = .l, .text = ptr_text }});
            const needs = (elem_info.heap == .class and isDynClass(self, elem_info.class_name)) or elem_info.heap == .dict or elem_info.heap == .list;
            if (!needs) return;
            const pre = try self.newLabel("pub_list_pre");
            const cond = try self.newLabel("pub_list_cond");
            const body = try self.newLabel("pub_list_body");
            const end = try self.newLabel("pub_list_end");
            try self.qbeJnz(first, pre, end);
            try self.qbeLabel(pre);
            const slot = try self.newTemp();
            try self.qbeAlloc(slot, .eight, 8);
            try self.qbeStoreImmL(0, slot);
            const len = try self.newTemp();
            try self.qbeLoadL(len, ptr_text);
            try self.qbeJmp(cond);
            try self.qbeLabel(cond);
            const i = try self.newTemp();
            try self.qbeLoadL(i, slot);
            const c = try self.newTemp();
            try self.qbeOp2(c, .w, "csltl", i, len);
            try self.qbeJnz(c, body, end);
            try self.qbeLabel(body);
            const off = try self.newTemp();
            try self.qbeOp2Imm(off, .l, "mul", i, 8);
            const off16 = try self.newTemp();
            try self.qbeOp2Imm(off16, .l, "add", off, 16);
            const addr = try self.newTemp();
            try self.qbeOp2(addr, .l, "add", ptr_text, off16);
            const e = try self.newTemp();
            try self.qbeLoadL(e, addr);
            // null eleman yayımlanmaz
            const have = try self.newLabel("pub_list_have");
            const skip = try self.newLabel("pub_list_skip");
            const nz = try self.newTemp();
            try self.qbeOp2Imm(nz, .w, "cnel", e, 0);
            try self.qbeJnz(nz, have, skip);
            try self.qbeLabel(have);
            try emitPublishValue(self, e, elem_info);
            try self.qbeJmp(skip);
            try self.qbeLabel(skip);
            const inext = try self.newTemp();
            try self.qbeOp2Imm(inext, .l, "add", i, 1);
            try self.qbeStoreL(inext, slot);
            try self.qbeJmp(cond);
            try self.qbeLabel(end);
        },
        else => {},
    }
}

/// Yığın tipli alana YAZMA (yeni değer `val_text` zaten sahipli/retain edilmiş): örnek paylaşılansa yeni değeri yayımla, kilit altında değiştir, kilidi bırak, ESKİYİ bırak.
pub fn emitBarrierFieldStore(self: *Codegen, obj_text: []const u8, f: ClassField, val_text: []const u8) CodegenError!void {
    const shared = try emitSharedFlag(self, obj_text);
    // yayımla (paylaşılan örneğe yazılan değer artık paylaşılır)
    {
        const pub_l = try self.newLabel("dyn_wr_pub");
        const lock_l = try self.newLabel("dyn_wr_lockp");
        try self.qbeJnz(shared, pub_l, lock_l);
        try self.qbeLabel(pub_l);
        try emitPublishValue(self, val_text, f.info);
        try self.qbeJmp(lock_l);
        try self.qbeLabel(lock_l);
    }
    try emitCondCall(self, shared, "$nox_obj_lock", &.{.{ .ty = .l, .text = obj_text }}, "dyn_wr_lock");
    const addr = try self.newTemp();
    try self.qbeOp2Imm(addr, .l, "add", obj_text, @intCast(f.offset));
    const old_ptr = try self.newTemp();
    try self.qbeLoadL(old_ptr, addr);
    try self.qbeStore(f.info.qtype, val_text, addr);
    try emitCondCall(self, shared, "$nox_obj_unlock", &.{.{ .ty = .l, .text = obj_text }}, "dyn_wr_unlock");
    try self.releaseValueIfSet(old_ptr, f.info.heap, f.info.elem_qtype, f.info.class_name, f.info.elem_heap_info, f.info.dict_info);
}

/// `$nox_publish_<Sınıf>(rt, p)`: nesneyi (ilk kez ise) `SHARED` yapar ve yığın alanlarını geçişli yayımlar. Kalıtım hiyerarşisinde çalışma-zamanı etiketine göre
/// gerçek sınıfın gövdesine (`$nox_publish_body_<Sınıf>`) dağıtır. Her `dyn_classes` sınıfı için bir kez üretilir.
pub fn genPublishFunctions(self: *Codegen) CodegenError!void {
    var it = self.dyn_classes.keyIterator();
    while (it.next()) |kp| {
        const cn = kp.*;
        const cinfo = self.classes.get(cn) orelse continue;
        // 1) gövde: bu sınıfın (miras alınanlar dahil) yığın alanlarını yayımlar
        {
            self.temp_counter = 0;
            self.label_counter = 0;
            self.mod_cache.deinit(self.allocator);
            self.mod_cache = .empty;
            const sym = try std.fmt.allocPrint(self.allocator, "$nox_publish_body_{s}", .{cn});
            try self.qbeFuncHeaderStart(null, sym);
            try self.qbeFuncParam(.l, RT_PARAM, true);
            try self.qbeFuncParam(.l, "%p", false);
            try self.qbeFuncHeaderEnd();
            for (cinfo.fields.items) |f| {
                if (!isBarrierField(f)) continue;
                const addr = try self.newTemp();
                try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
                const v = try self.newTemp();
                try self.qbeLoadL(v, addr);
                try emitPublishValue(self, v, f.info);
            }
            try self.qbeRet(null);
            try self.qbeFuncEnd();
        }
        // 2) giriş: yalnız ilk yayımlamada gövdeye (kalıtımda etikete göre) gider
        self.temp_counter = 0;
        self.label_counter = 0;
        self.mod_cache.deinit(self.allocator);
        self.mod_cache = .empty;
        const sym = try std.fmt.allocPrint(self.allocator, "$nox_publish_{s}", .{cn});
        try self.qbeFuncHeaderStart(null, sym);
        try self.qbeFuncParam(.l, RT_PARAM, true);
        try self.qbeFuncParam(.l, "%p", false);
        try self.qbeFuncHeaderEnd();
        const first = try self.newTemp();
        try self.qbeCall(.{ .name = first, .ty = .w }, "$nox_obj_publish_begin", &.{.{ .ty = .l, .text = "%p" }});
        const body_l = try self.newLabel("pub_body");
        const done_l = try self.newLabel("pub_done");
        try self.qbeJnz(first, body_l, done_l);
        try self.qbeLabel(body_l);
        if (cinfo.has_vtable and cinfo.descendant_class_ids.len > 1) {
            const tag = try self.newTemp();
            try self.qbeLoadL(tag, "%p");
            for (cinfo.descendant_class_ids) |id| {
                // `id` -> sınıf adı
                var name: ?[]const u8 = null;
                var cit = self.classes.iterator();
                while (cit.next()) |e| {
                    if (e.value_ptr.class_id == id) {
                        name = e.key_ptr.*;
                        break;
                    }
                }
                const dn = name orelse continue;
                if (!self.dyn_classes.contains(dn)) continue;
                const eq = try self.newTemp();
                try self.qbeOp2Imm(eq, .w, "ceql", tag, @intCast(id));
                const case_l = try self.newLabel("pub_case");
                const next_l = try self.newLabel("pub_next");
                try self.qbeJnz(eq, case_l, next_l);
                try self.qbeLabel(case_l);
                const bsym = try std.fmt.allocPrint(self.allocator, "$nox_publish_body_{s}", .{dn});
                try self.qbeCall(null, bsym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" } });
                try self.qbeJmp(done_l);
                try self.qbeLabel(next_l);
            }
            try self.qbeJmp(done_l);
        } else {
            const bsym = try std.fmt.allocPrint(self.allocator, "$nox_publish_body_{s}", .{cn});
            try self.qbeCall(null, bsym, &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = "%p" } });
            try self.qbeJmp(done_l);
        }
        try self.qbeLabel(done_l);
        try self.qbeRet(null);
        try self.qbeFuncEnd();
    }
}
