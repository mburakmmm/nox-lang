//! DENEYSEL (bkz. plan dosyası "`noxc build --release` için deneysel bir
//! LLVM backend'i"): `qbe_emit.zig` İLE AYNI metot isimleriyle, ama `.ll`
//! (LLVM IR metni) sözdizimli gövdelerle yazılan İKİNCİ bir metin-emisyon
//! hedefi. `codegen.zig`nin `qbeX` dispatch sarmalayıcıları (bkz. onların
//! belge notu), `Codegen.backend == .llvm` İKEN her çağrıyı BURAYA yönlendirir.
//!
//! **Faz LLVM.1 (bu dosya, ŞİMDİLİK):** SADECE iskelet — TÜM metotlar
//! `error.Unsupported` döner. Gerçek `.ll` gövdeleri Faz LLVM.2/3'te
//! (kontrol akışı/tipler, SONRA aritmetik/bellek/çağrılar) eklenecek.

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

pub fn qbeLabel(self: *Codegen, label: []const u8) CodegenError!void {
    _ = self;
    _ = label;
    return error.Unsupported;
}

pub fn qbeJmp(self: *Codegen, target: []const u8) CodegenError!void {
    _ = self;
    _ = target;
    return error.Unsupported;
}

pub fn qbeJnz(self: *Codegen, cond: []const u8, t: []const u8, f: []const u8) CodegenError!void {
    _ = self;
    _ = cond;
    _ = t;
    _ = f;
    return error.Unsupported;
}

pub fn qbePhi(self: *Codegen, dst: []const u8, ty: QbeType, l1: []const u8, v1: []const u8, l2: []const u8, v2: []const u8) CodegenError!void {
    _ = self;
    _ = dst;
    _ = ty;
    _ = l1;
    _ = v1;
    _ = l2;
    _ = v2;
    return error.Unsupported;
}

pub fn qbeRet(self: *Codegen, value: ?[]const u8) CodegenError!void {
    _ = self;
    _ = value;
    return error.Unsupported;
}

pub fn qbeFuncEnd(self: *Codegen) CodegenError!void {
    _ = self;
    return error.Unsupported;
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

pub fn qbeAlloc(self: *Codegen, dst: []const u8, size: QbeAllocSize, n: usize) CodegenError!void {
    _ = self;
    _ = dst;
    _ = size;
    _ = n;
    return error.Unsupported;
}

pub fn qbeCall(self: *Codegen, dst: ?QbeCallDst, func_text: []const u8, args: []const QbeArg) CodegenError!void {
    _ = self;
    _ = dst;
    _ = func_text;
    _ = args;
    return error.Unsupported;
}

pub fn qbeFuncHeaderStart(self: *Codegen, ret_ty: ?QbeType, name_text: []const u8) CodegenError!void {
    _ = self;
    _ = ret_ty;
    _ = name_text;
    return error.Unsupported;
}

pub fn qbeFuncParam(self: *Codegen, ty: QbeType, text: []const u8, first: bool) CodegenError!void {
    _ = self;
    _ = ty;
    _ = text;
    _ = first;
    return error.Unsupported;
}

pub fn qbeFuncHeaderEnd(self: *Codegen) CodegenError!void {
    _ = self;
    return error.Unsupported;
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
