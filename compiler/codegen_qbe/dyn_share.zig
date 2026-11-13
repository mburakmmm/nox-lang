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

/// Bu sınıf için bariyerler üretiliyor mu?
pub fn isDynClass(self: *const Codegen, name: ?[]const u8) bool {
    const n = name orelse return false;
    return self.dyn_classes.contains(n);
}

/// Bir alan, bariyer gerektiren yığın alanı mı (`str` değişmez ama işaretçi değişimi yarışır: o da bariyerlidir)?
pub fn isBarrierField(f: ClassField) bool {
    return switch (f.info.heap) {
        .str, .dict, .class => true,
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

/// `$nox_publish_<Sınıf>(rt, p)`: nesneyi (ilk kez ise) `SHARED` yapar ve yığın alanlarını geçişli yayımlar. Her `dyn_classes` sınıfı için bir kez üretilir.
pub fn genPublishFunctions(self: *Codegen) CodegenError!void {
    var it = self.dyn_classes.keyIterator();
    while (it.next()) |kp| {
        const cn = kp.*;
        const cinfo = self.classes.get(cn) orelse continue;
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
        for (cinfo.fields.items) |f| {
            if (!isBarrierField(f)) continue;
            const addr = try self.newTemp();
            try self.qbeOp2Imm(addr, .l, "add", "%p", @intCast(f.offset));
            const v = try self.newTemp();
            try self.qbeLoadL(v, addr);
            try emitPublishValue(self, v, f.info);
        }
        try self.qbeJmp(done_l);
        try self.qbeLabel(done_l);
        try self.qbeRet(null);
        try self.qbeFuncEnd();
    }
}
