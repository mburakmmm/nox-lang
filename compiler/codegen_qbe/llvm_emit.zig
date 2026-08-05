//! DENEYSEL (bkz. plan dosyası "`noxc build --release` için deneysel bir
//! LLVM backend'i"): `qbe_emit.zig` İLE AYNI metot isimleriyle, ama `.ll`
//! (LLVM IR metni) sözdizimli gövdelerle yazılan İKİNCİ bir metin-emisyon
//! hedefi. `codegen.zig`nin `qbeX` dispatch sarmalayıcıları (bkz. onların
//! belge notu), `Codegen.backend == .llvm` İKEN her çağrıyı BURAYA yönlendirir.
//!
//! **Faz LLVM.2 (kontrol akışı/başlıklar/tipler, bu dosyada TAMAMLANDI):**
//! `qbeLabel`/`qbeJmp`/`qbeJnz`/`qbePhi`/`qbeRet`/`qbeFuncEnd`/
//! `qbeFuncHeaderStart`+`qbeFuncParam`+`qbeFuncHeaderEnd`/`qbeAlloc` artık
//! GERÇEK `.ll` metni üretir. **Faz LLVM.3 (SONRAKİ):** aritmetik/bellek/
//! çağrılar (`qbeOp1`/`qbeOp2`/`qbeOp2Imm`/`qbeLoad*`/`qbeStore*`/
//! `qbeCall`) HÂLÂ `error.Unsupported` — bu YÜZDEN bu Faz'da gerçek bir
//! programın TAMAMI derlenemez, sadece kontrol-akışı/başlık sözdizimi
//! standalone `.ll` parçalarıyla `clang`e karşı DOĞRULANIR.
//!
//! **Tip eşlemesi (bilinçli, KESİN):** `l`→`i64`, `w`→`i32`, `d`→`double`,
//! `none`→`void`. `l` İçin `ptr` KULLANILMAZ — bu kod tabanında TÜM
//! işaretçiler ZATEN `i64` olarak taşınıyor (bkz. `qbe_emit.zig`nin `l`
//! kullanım deseni), bu YÜZDEN bellek erişim noktalarında (Faz LLVM.3)
//! `inttoptr`/`ptrtoint` sınır dönüşümleri gerekecek — BURADA (Faz LLVM.2)
//! SADECE `qbeAlloc`nin `alloca`sı bu sınırı geçiyor.
//!
//! **Etiket/sembol sigil dönüşümü:** QBE etiketleri HER ZAMAN `@` İLE
//! (`newLabel`, bkz. registration.zig), sembol adları `$` İLE başlar
//! (ör. `"${s}"`, bkz. `genFunction`). LLVM'de bloklar TANIMLANIRKEN
//! sigilsiz (`etiket:`), REFERANS edilirken `%etiket`; global semboller
//! HER YERDE `@sembol`. `llLabelRef`/`llGlobalRef` bu ÖN-EKİ SIYIRIR,
//! çağıran ASLA kendi metnini elle DÜZENLEMEZ.
//!
//! **Kendi kendini onaran `qbeLabel` (bulgu #4'ün düzeltmesi):**
//! `registration.zig`nin `end_label` siteleri, fonksiyon gövdesi
//! SONRASINDA garanti-öncesi-terminatörü OLMAYAN bir etiket üretiyor
//! (QBE'de LEGAL implicit fallthrough — LLVM'de İLLEGAL, HER blok bir
//! terminatörle BİTMELİDİR). `Codegen.llvm_block_open` bunu İZLER:
//! `qbeFuncHeaderEnd`/`qbeLabel` `true`YA ayarlar, HERHANGİ bir terminatör
//! (`qbeJmp`/`qbeJnz`/`qbeRet`) `false`A döner; `qbeLabel` `true` İKEN
//! YENİ etiketten HEMEN ÖNCE örtük bir `br label` EKLER.

const std = @import("std");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const qbe_emit = @import("qbe_emit.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const CodegenError = abi.CodegenError;
const QbeArg = qbe_emit.QbeArg;
const QbeCallDst = qbe_emit.QbeCallDst;
const QbeAllocSize = qbe_emit.QbeAllocSize;

fn llvmTypeName(ty: QbeType) []const u8 {
    return switch (ty) {
        .l => "i64",
        .w => "i32",
        .d => "double",
        .none => "void",
    };
}

/// `"@fn_end3"` → `"fn_end3"` — blok ETİKETİ referanslarının (`br`/`phi`)
/// LLVM'de `%` ile, TANIMLARININ (bkz. `qbeLabel`) sigilsiz olması İçin.
fn llLabelRef(label: []const u8) []const u8 {
    return if (label.len > 0 and label[0] == '@') label[1..] else label;
}

/// `"$sum_list"` → `"sum_list"` — GLOBAL sembol adlarının LLVM'de HER
/// zaman `@` ön-ekiyle yazılması İçin (bkz. `qbeFuncHeaderStart`).
fn llGlobalRef(text: []const u8) []const u8 {
    return if (text.len > 0 and text[0] == '$') text[1..] else text;
}

pub fn qbeLabel(self: *Codegen, label: []const u8) CodegenError!void {
    if (self.llvm_block_open) {
        try self.out.writer.print("    br label %{s}\n", .{llLabelRef(label)});
    }
    try self.out.writer.print("{s}:\n", .{llLabelRef(label)});
    self.llvm_block_open = true;
}

pub fn qbeJmp(self: *Codegen, target: []const u8) CodegenError!void {
    try self.out.writer.print("    br label %{s}\n", .{llLabelRef(target)});
    self.llvm_block_open = false;
}

/// `cond` BU kod tabanında HER ZAMAN bir `w` (i32) boole değeri (0/1) —
/// LLVM'in `br`ı İSE bir `i1` GEREKTİRİR, bu YÜZDEN önce `icmp ne` İLE
/// daraltılır.
pub fn qbeJnz(self: *Codegen, cond: []const u8, t: []const u8, f: []const u8) CodegenError!void {
    const cmp_reg = try self.newTemp();
    try self.out.writer.print("    {s} = icmp ne i32 {s}, 0\n", .{ cmp_reg, cond });
    try self.out.writer.print("    br i1 {s}, label %{s}, label %{s}\n", .{ cmp_reg, llLabelRef(t), llLabelRef(f) });
    self.llvm_block_open = false;
}

pub fn qbePhi(self: *Codegen, dst: []const u8, ty: QbeType, l1: []const u8, v1: []const u8, l2: []const u8, v2: []const u8) CodegenError!void {
    try self.out.writer.print("    {s} = phi {s} [ {s}, %{s} ], [ {s}, %{s} ]\n", .{ dst, llvmTypeName(ty), v1, llLabelRef(l1), v2, llLabelRef(l2) });
}

/// `self.current_ret_qtype` (HER fonksiyon-girişinde ayarlanır, bkz.
/// `registration.zig`) — bulgu #5: YENİ durum GEREKMEDEN dönüş tipini
/// verir.
pub fn qbeRet(self: *Codegen, value: ?[]const u8) CodegenError!void {
    if (value) |v| {
        try self.out.writer.print("    ret {s} {s}\n", .{ llvmTypeName(self.current_ret_qtype), v });
    } else {
        try self.out.writer.writeAll("    ret void\n");
    }
    self.llvm_block_open = false;
}

/// Normalde (bkz. `emitDefaultReturn`) `qbeFuncEnd`den ÖNCE HER ZAMAN bir
/// terminatör (`qbeRet`) çağrılmış olur — `llvm_block_open` HÂLÂ `true`YSA
/// (beklenmeyen bir çağıran) `unreachable` İLE savunmacı bir şekilde kapatılır.
pub fn qbeFuncEnd(self: *Codegen) CodegenError!void {
    if (self.llvm_block_open) {
        try self.out.writer.writeAll("    unreachable\n");
        self.llvm_block_open = false;
    }
    try self.out.writer.writeAll("}\n");
}

pub fn qbeOp1(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8) CodegenError!void {
    _ = self;
    _ = dst;
    _ = ty;
    _ = mnemonic;
    _ = a;
    return error.Unsupported;
}

pub fn qbeOp2(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8, b: []const u8) CodegenError!void {
    _ = self;
    _ = dst;
    _ = ty;
    _ = mnemonic;
    _ = a;
    _ = b;
    return error.Unsupported;
}

pub fn qbeOp2Imm(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8, imm: i64) CodegenError!void {
    _ = self;
    _ = dst;
    _ = ty;
    _ = mnemonic;
    _ = a;
    _ = imm;
    return error.Unsupported;
}

pub fn qbeLoad(self: *Codegen, dst: []const u8, dst_ty: QbeType, mem_ty: QbeType, addr: []const u8) CodegenError!void {
    _ = self;
    _ = dst;
    _ = dst_ty;
    _ = mem_ty;
    _ = addr;
    return error.Unsupported;
}

pub fn qbeLoadL(self: *Codegen, dst: []const u8, addr: []const u8) CodegenError!void {
    _ = self;
    _ = dst;
    _ = addr;
    return error.Unsupported;
}

pub fn qbeStore(self: *Codegen, ty: QbeType, value: []const u8, addr: []const u8) CodegenError!void {
    _ = self;
    _ = ty;
    _ = value;
    _ = addr;
    return error.Unsupported;
}

pub fn qbeStoreL(self: *Codegen, value: []const u8, addr: []const u8) CodegenError!void {
    _ = self;
    _ = value;
    _ = addr;
    return error.Unsupported;
}

pub fn qbeStoreImmL(self: *Codegen, imm: i64, addr: []const u8) CodegenError!void {
    _ = self;
    _ = imm;
    _ = addr;
    return error.Unsupported;
}

/// QBE'nin `%dst =l alloc{4/8} {n}`i — dönüş HER ZAMAN bir `l` (i64)
/// "işaretçi-olarak-tamsayı" değeridir (bkz. modül üstü not). LLVM'de
/// `alloca` bir GERÇEK `ptr` döner, bu YÜZDEN hemen `ptrtoint` İLE `i64`e
/// indirgenir — bu SINIR geçişi (`qbeLoad`/`qbeStore`nin `inttoptr`si,
/// Faz LLVM.3) HARİÇ, KOD TABANININ geri kalanı bunu HİÇ BİLMEZ.
pub fn qbeAlloc(self: *Codegen, dst: []const u8, size: QbeAllocSize, n: usize) CodegenError!void {
    const ptr_reg = try self.newTemp();
    try self.out.writer.print("    {s} = alloca [{d} x i8], align {d}\n", .{ ptr_reg, n, @intFromEnum(size) });
    try self.out.writer.print("    {s} = ptrtoint ptr {s} to i64\n", .{ dst, ptr_reg });
}

pub fn qbeCall(self: *Codegen, dst: ?QbeCallDst, func_text: []const u8, args: []const QbeArg) CodegenError!void {
    _ = self;
    _ = dst;
    _ = func_text;
    _ = args;
    return error.Unsupported;
}

pub fn qbeFuncHeaderStart(self: *Codegen, ret_ty: ?QbeType, name_text: []const u8) CodegenError!void {
    const rt_name = if (ret_ty) |rt| llvmTypeName(rt) else "void";
    try self.out.writer.print("define {s} @{s}(", .{ rt_name, llGlobalRef(name_text) });
}

pub fn qbeFuncParam(self: *Codegen, ty: QbeType, text: []const u8, first: bool) CodegenError!void {
    if (!first) try self.out.writer.writeAll(", ");
    try self.out.writer.print("{s} {s}", .{ llvmTypeName(ty), text });
}

/// QBE'nin `") {\n@start\n"`i — LLVM'de blok etiketleri sigilsiz TANIMLANIR
/// (bkz. modül üstü not), bu YÜZDEN `start:` (`%start` DEĞİL). Giriş bloğu
/// HENÜZ terminatör ALMADIĞINDAN `llvm_block_open = true`.
pub fn qbeFuncHeaderEnd(self: *Codegen) CodegenError!void {
    try self.out.writer.writeAll(") {\nstart:\n");
    self.llvm_block_open = true;
}

pub fn qbeRaw(self: *Codegen, comptime fmt: []const u8, args: anytype) CodegenError!void {
    _ = self;
    _ = fmt;
    _ = args;
    return error.Unsupported;
}

pub fn qbeRawAll(self: *Codegen, text: []const u8) CodegenError!void {
    _ = self;
    _ = text;
    return error.Unsupported;
}
