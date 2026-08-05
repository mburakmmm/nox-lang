//! DENEYSEL (bkz. plan dosyası "`noxc build --release` için deneysel bir
//! LLVM backend'i"): `qbe_emit.zig` İLE AYNI metot isimleriyle, ama `.ll`
//! (LLVM IR metni) sözdizimli gövdelerle yazılan İKİNCİ bir metin-emisyon
//! hedefi. `codegen.zig`nin `qbeX` dispatch sarmalayıcıları (bkz. onların
//! belge notu), `Codegen.backend == .llvm` İKEN her çağrıyı BURAYA yönlendirir.
//!
//! **Faz LLVM.2 (kontrol akışı/başlıklar/tipler) + Faz LLVM.3 (aritmetik/
//! bellek/çağrılar) — İKİSİ de bu dosyada TAMAMLANDI:** TÜM 20 metot artık
//! GERÇEK `.ll` metni üretir (`qbeRaw`/`qbeRawAll` kaçış kapısı HARİÇ —
//! Faz LLVM.4'ün 2 sınırlı düzeltmesi BUNLARI ortadan kaldıracak).
//!
//! **Mnemonic çeviri (Faz LLVM.3):** `qbeOp1`/`qbeOp2`/`qbeOp2Imm`nin
//! `mnemonic` parametresi ÇAĞIRAN tarafın QBE-SÖZDİZİMLİ metnidir
//! (`"add"`/`"csltl"`/`"dtosi"` vb.) — BURADA `arithOpFor`/`cmpSpecFor`
//! TARAFINDAN LLVM opcode'una ÇEVRİLİR. QBE'nin `div`/`rem`i (int/float
//! AYRIMSIZ, dst `ty`sinden ÇIKARILIR) LLVM'de `sdiv`/`fdiv` VE `srem`/
//! `frem`e AYRILIR; QBE'nin karşılaştırma aileleri (`ceqd`/`ceqw`/`ceql`
//! vb. — operand tipi mnemonic SUFFIX'İNDEN gelir, dst HER ZAMAN `w`)
//! `icmp`/`fcmp` + `zext i1 to i32`e (LLVM `br`/karşılaştırma sonucu HER
//! ZAMAN `i1`dir, bu kod tabanı İSE boole'ları `w`/i32 OLARAK taşır).
//!
//! **`qbeCall`nin `declare`-takibi (Faz LLVM.3, KRİTİK bir DENEYSEL
//! bulgu):** `clang`e karşı EMPİRİK olarak doğrulandı — bir sembol İçin
//! HEM `declare` HEM `define` bulunması (SIRA/TEKRAR FARK ETMEKSİZİN)
//! `"invalid redefinition of function"` hatası VERİR; AMA bir `call`in
//! KENDİ `define`İNDEN (dosyanın HERHANGİ bir YERİNDE) ÖNCE gelmesi
//! `declare` OLMADAN da GEÇERLİDİR (LLVM'in metin ayrıştırıcısı sırasız
//! çözer). Bu YÜZDEN `qbeCall`, `self.functions`de (BU modülün KENDİSİNİN
//! `define` edeceği Nox fonksiyonları) KAYITLI OLMAYAN direkt-sembol
//! çağrıları İçin isim başına EN FAZLA BİR `declare` üretir —
//! `Codegen.llvm_pending_declares`e BİRİKTİRİLİR (bir `declare`, bir
//! fonksiyon GÖVDESİNİN İÇİNE YAZILAMAZ — bkz. o alanın belge notu),
//! Faz LLVM.4'te `generateModule`nin SONUNDA flush edilir. **Bilinçli
//! sınırlama:** closure/wrapper/metod sembolleri `self.functions`de
//! KAYITLI DEĞİL (yalnızca üst-düzey `def`ler) — bunlara yapılan çağrılar
//! (Kapsam DIŞI özellikler, bkz. plan dosyası) yanlışlıkla declare
//! edilip GERÇEK bir `clang` sözdizimi hatasına yol AÇABİLİR; bu, planın
//! KENDİSİNİN kabul ettiği "linker/derleme hatasıyla başarısız olma"
//! sınırının İÇİNDE.
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

const CmpSpec = struct { float: bool, pred: []const u8, operand_ty: []const u8 };

/// QBE'nin karşılaştırma mnemonic ailesi (`cmpMnemonic`, bkz. abi.zig) —
/// operand tipi mnemonic SUFFIX'İNDEN (`d`/`w`/`l`) gelir, dst HER ZAMAN
/// `w` (bu fonksiyonun `ty` parametresi bu YÜZDEN GÖRMEZDEN gelinir).
fn cmpSpecFor(mnemonic: []const u8) ?CmpSpec {
    const table = [_]struct { []const u8, CmpSpec }{
        .{ "ceqd", .{ .float = true, .pred = "oeq", .operand_ty = "double" } },
        .{ "cned", .{ .float = true, .pred = "one", .operand_ty = "double" } },
        .{ "cltd", .{ .float = true, .pred = "olt", .operand_ty = "double" } },
        .{ "cled", .{ .float = true, .pred = "ole", .operand_ty = "double" } },
        .{ "cgtd", .{ .float = true, .pred = "ogt", .operand_ty = "double" } },
        .{ "cged", .{ .float = true, .pred = "oge", .operand_ty = "double" } },
        .{ "ceqw", .{ .float = false, .pred = "eq", .operand_ty = "i32" } },
        .{ "cnew", .{ .float = false, .pred = "ne", .operand_ty = "i32" } },
        .{ "ceql", .{ .float = false, .pred = "eq", .operand_ty = "i64" } },
        .{ "cnel", .{ .float = false, .pred = "ne", .operand_ty = "i64" } },
        .{ "csltl", .{ .float = false, .pred = "slt", .operand_ty = "i64" } },
        .{ "cslel", .{ .float = false, .pred = "sle", .operand_ty = "i64" } },
        .{ "csgtl", .{ .float = false, .pred = "sgt", .operand_ty = "i64" } },
        .{ "csgel", .{ .float = false, .pred = "sge", .operand_ty = "i64" } },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], mnemonic)) return entry[1];
    }
    return null;
}

/// `add`/`sub`/`mul`/`div`/`rem`/`or`/`and`/`xor` — `div`/`rem` `ty`ye
/// göre imzalı-tamsayı/float ARASINDA AYRILIR (QBE bu ayrımı YAPMAZ, dst
/// tipinden ÇIKARIR; LLVM'de `sdiv`/`fdiv` AYRI opcode'lardır).
fn arithOpFor(mnemonic: []const u8, ty: QbeType) ?[]const u8 {
    const is_float = ty == .d;
    if (std.mem.eql(u8, mnemonic, "add")) return if (is_float) "fadd" else "add";
    if (std.mem.eql(u8, mnemonic, "sub")) return if (is_float) "fsub" else "sub";
    if (std.mem.eql(u8, mnemonic, "mul")) return if (is_float) "fmul" else "mul";
    if (std.mem.eql(u8, mnemonic, "div")) return if (is_float) "fdiv" else "sdiv";
    if (std.mem.eql(u8, mnemonic, "rem")) return if (is_float) "frem" else "srem";
    if (std.mem.eql(u8, mnemonic, "or")) return "or";
    if (std.mem.eql(u8, mnemonic, "and")) return "and";
    if (std.mem.eql(u8, mnemonic, "xor")) return "xor";
    return null;
}

pub fn qbeOp1(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8) CodegenError!void {
    if (std.mem.eql(u8, mnemonic, "copy")) {
        if (ty == .d) {
            try self.out.writer.print("    {s} = fadd double {s}, 0.0\n", .{ dst, a });
        } else {
            try self.out.writer.print("    {s} = add {s} {s}, 0\n", .{ dst, llvmTypeName(ty), a });
        }
        return;
    }
    if (std.mem.eql(u8, mnemonic, "neg")) {
        if (ty == .d) {
            try self.out.writer.print("    {s} = fneg double {s}\n", .{ dst, a });
        } else {
            try self.out.writer.print("    {s} = sub {s} 0, {s}\n", .{ dst, llvmTypeName(ty), a });
        }
        return;
    }
    if (std.mem.eql(u8, mnemonic, "extuw")) {
        try self.out.writer.print("    {s} = zext i32 {s} to i64\n", .{ dst, a });
        return;
    }
    if (std.mem.eql(u8, mnemonic, "sltof")) {
        try self.out.writer.print("    {s} = sitofp i64 {s} to double\n", .{ dst, a });
        return;
    }
    if (std.mem.eql(u8, mnemonic, "uwtof")) {
        try self.out.writer.print("    {s} = uitofp i32 {s} to double\n", .{ dst, a });
        return;
    }
    if (std.mem.eql(u8, mnemonic, "dtosi")) {
        try self.out.writer.print("    {s} = fptosi double {s} to i64\n", .{ dst, a });
        return;
    }
    if (std.mem.eql(u8, mnemonic, "cast")) {
        // `.d` hedef ⇒ kaynak i64 (fromPayload); aksi halde kaynak double
        // (toPayload) — bkz. expr.zig'in `toPayload`/`fromPayload`ı.
        if (ty == .d) {
            try self.out.writer.print("    {s} = bitcast i64 {s} to double\n", .{ dst, a });
        } else {
            try self.out.writer.print("    {s} = bitcast double {s} to i64\n", .{ dst, a });
        }
        return;
    }
    return error.Unsupported;
}

pub fn qbeOp2(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8, b: []const u8) CodegenError!void {
    if (cmpSpecFor(mnemonic)) |spec| {
        const i1_reg = try self.newTemp();
        const cmp_kind: []const u8 = if (spec.float) "fcmp" else "icmp";
        try self.out.writer.print("    {s} = {s} {s} {s} {s}, {s}\n", .{ i1_reg, cmp_kind, spec.pred, spec.operand_ty, a, b });
        try self.out.writer.print("    {s} = zext i1 {s} to i32\n", .{ dst, i1_reg });
        return;
    }
    const op = arithOpFor(mnemonic, ty) orelse return error.Unsupported;
    try self.out.writer.print("    {s} = {s} {s} {s}, {s}\n", .{ dst, op, llvmTypeName(ty), a, b });
}

pub fn qbeOp2Imm(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8, imm: i64) CodegenError!void {
    if (cmpSpecFor(mnemonic)) |spec| {
        const i1_reg = try self.newTemp();
        const cmp_kind: []const u8 = if (spec.float) "fcmp" else "icmp";
        try self.out.writer.print("    {s} = {s} {s} {s} {s}, {d}\n", .{ i1_reg, cmp_kind, spec.pred, spec.operand_ty, a, imm });
        try self.out.writer.print("    {s} = zext i1 {s} to i32\n", .{ dst, i1_reg });
        return;
    }
    const op = arithOpFor(mnemonic, ty) orelse return error.Unsupported;
    try self.out.writer.print("    {s} = {s} {s} {s}, {d}\n", .{ dst, op, llvmTypeName(ty), a, imm });
}

/// `dst_ty != mem_ty` bu kod tabanında HİÇ GÖZLEMLENMEDİ (20/20 çağrı
/// sitesi eşleşiyor, bkz. plan doğrulaması) — GÖZLEMLENMEYEN bu durum
/// GÜVENLİ bir şekilde `error.Unsupported` ile REDDEDİLİR.
pub fn qbeLoad(self: *Codegen, dst: []const u8, dst_ty: QbeType, mem_ty: QbeType, addr: []const u8) CodegenError!void {
    if (dst_ty != mem_ty) return error.Unsupported;
    const ptr_reg = try self.newTemp();
    try self.out.writer.print("    {s} = inttoptr i64 {s} to ptr\n", .{ ptr_reg, addr });
    try self.out.writer.print("    {s} = load {s}, ptr {s}\n", .{ dst, llvmTypeName(dst_ty), ptr_reg });
}

pub fn qbeLoadL(self: *Codegen, dst: []const u8, addr: []const u8) CodegenError!void {
    try qbeLoad(self, dst, .l, .l, addr);
}

pub fn qbeStore(self: *Codegen, ty: QbeType, value: []const u8, addr: []const u8) CodegenError!void {
    const ptr_reg = try self.newTemp();
    try self.out.writer.print("    {s} = inttoptr i64 {s} to ptr\n", .{ ptr_reg, addr });
    try self.out.writer.print("    store {s} {s}, ptr {s}\n", .{ llvmTypeName(ty), value, ptr_reg });
}

pub fn qbeStoreL(self: *Codegen, value: []const u8, addr: []const u8) CodegenError!void {
    try qbeStore(self, .l, value, addr);
}

pub fn qbeStoreImmL(self: *Codegen, imm: i64, addr: []const u8) CodegenError!void {
    const text = try std.fmt.allocPrint(self.allocator, "{d}", .{imm});
    try qbeStore(self, .l, text, addr);
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

/// `$sym` metnini bir DEĞER operandı OLARAK (çağrı HEDEFİ OLARAK DEĞİL —
/// bkz. `qbeCall`) kullanan siteler İçin (ör. `printf`e bir `$fmt_int`
/// biçim-dizesi sembolünü ARGÜMAN olarak geçirmek) — bir global sembolün
/// ADRESİNİ `i64`e (bu kod tabanının HER YERDE kullandığı "işaretçi-
/// olarak-tamsayı" temsiline) çeviren bir LLVM SABİT-İFADESİ üretir.
/// `clang`e karşı EMPİRİK doğrulandı (`ptrtoint_check.ll`).
fn renderOperand(self: *Codegen, text: []const u8) CodegenError![]const u8 {
    if (text.len > 0 and text[0] == '$') {
        return std.fmt.allocPrint(self.allocator, "ptrtoint (ptr @{s} to i64)", .{text[1..]});
    }
    return text;
}

pub fn qbeCall(self: *Codegen, dst: ?QbeCallDst, func_text: []const u8, args: []const QbeArg) CodegenError!void {
    var callee_text: []const u8 = undefined;
    if (func_text.len > 0 and func_text[0] == '$') {
        const name = func_text[1..];
        // `self.functions`: BU modülün KENDİSİNİN `define` edeceği üst-
        // düzey Nox fonksiyonları (registerFunc, generateModule'ün
        // TÜM gövde codegen'İNDEN ÖNCE dolar) — bunlar İçin `declare`
        // ÜRETME (bkz. modül üstü not, declare+define ÇAKIŞIR).
        if (!self.functions.contains(name) and !self.llvm_declared_externs.contains(name)) {
            var params_buf: std.ArrayListUnmanaged(u8) = .empty;
            for (args, 0..) |arg, i| {
                if (i != 0) try params_buf.appendSlice(self.allocator, ", ");
                try params_buf.appendSlice(self.allocator, llvmTypeName(arg.ty));
            }
            const ret_str = if (dst) |d| llvmTypeName(d.ty) else "void";
            const decl_line = try std.fmt.allocPrint(self.allocator, "declare {s} @{s}({s})\n", .{ ret_str, name, params_buf.items });
            try self.llvm_pending_declares.append(self.allocator, decl_line);
            try self.llvm_declared_externs.put(self.allocator, name, {});
        }
        callee_text = try std.fmt.allocPrint(self.allocator, "@{s}", .{name});
    } else {
        // Dolaylı çağrı: `func_text` bir `i64`-taşınan fonksiyon işaretçisi
        // (kaçış/`.func` değerleri) — `clang`e karşı EMPİRİK doğrulandı
        // (`loadstore_indirect_check.ll`): LLVM 21'in opak-işaretçi modu
        // dolaylı çağrı sitesinde AYRI bir fonksiyon-tipi GEREKTİRMİYOR.
        const ptr_reg = try self.newTemp();
        try self.out.writer.print("    {s} = inttoptr i64 {s} to ptr\n", .{ ptr_reg, func_text });
        callee_text = ptr_reg;
    }

    if (dst) |d| {
        try self.out.writer.print("    {s} = call {s} {s}(", .{ d.name, llvmTypeName(d.ty), callee_text });
    } else {
        try self.out.writer.print("    call void {s}(", .{callee_text});
    }
    for (args, 0..) |arg, i| {
        if (i != 0) try self.out.writer.writeAll(", ");
        const rendered = try renderOperand(self, arg.text);
        try self.out.writer.print("{s} {s}", .{ llvmTypeName(arg.ty), rendered });
    }
    try self.out.writer.writeAll(")\n");
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
