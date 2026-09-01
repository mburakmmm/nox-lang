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

/// `bytes`i (SONUNA otomatik bir null-terminator EKLENMİŞ — QBE'nin
/// `b "...", b 0` deseniyle AYNI) LLVM'in `c"..."` DİZİ SABİTİ sözdizimine
/// çevirir — `codegen.zig`nin `generateModule`ı (Faz LLVM.4, bulgu #3)
/// TARAFINDAN, sabit biçim-dizesi ön-bloğu İçin DIŞARIDAN çağrılır (seam'in
/// GERİ KALANININ AKSİNE bu `pub fn` `Codegen`e DEĞİL, DOĞRUDAN metne
/// çalışır — çağrı sitesi HENÜZ bir `Codegen` örneği KURMADAN ÖNCEKİ bir
/// hazırlık adımıdır).
/// `bytes`i (SONA `\00` EKLENMEDEN) LLVM `c"..."` escape kurallarına
/// çevirir — `llvmCStringConstant`/`llvmStrHeaderConstant` PAYLAŞIR.
fn llvmEscapeBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.ArrayListUnmanaged(u8) {
    var escaped: std.ArrayListUnmanaged(u8) = .empty;
    for (bytes) |b| {
        if (b == '\\' or b == '"' or b < 0x20 or b > 0x7E) {
            var buf: [4]u8 = undefined;
            const hex = std.fmt.bufPrint(&buf, "\\{X:0>2}", .{b}) catch unreachable;
            try escaped.appendSlice(allocator, hex);
        } else {
            try escaped.append(allocator, b);
        }
    }
    return escaped;
}

pub fn llvmCStringConstant(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]const u8 {
    var escaped = try llvmEscapeBytes(allocator, bytes);
    try escaped.appendSlice(allocator, "\\00");
    return std.fmt.allocPrint(allocator, "@{s} = private unnamed_addr global [{d} x i8] c\"{s}\"\n", .{ name, bytes.len + 1, escaped.items });
}

/// `str` literallerinin ARC-pinned başlığını (bkz. `abi_layout.zig`nin
/// `packStrHeader`i) TAŞIYAN LLVM struct sabiti — QBE'nin `data $sym = {
/// l PINNED_REFCOUNT, l packed_header, b "...", b 0 }`sinin karşılığı.
/// `{ i64, i64, [N x i8] }` düzeni BİLİNÇLİ: `i64`ler ARADA/SONRASINDA
/// dolgu (padding) GEREKTİRMEZ (8-bayt hizalı alanlar + 1-bayt hizalı
/// dizi), bu YÜZDEN `expr.zig`nin `emitStringLiteral`ının `qbeOp2Imm(addr,
/// .l, "add", sym, ARC_HEADER_SIZE+STR_HEADER_SIZE)` İLE (bkz. `renderOperand`,
/// `$sym` → `ptrtoint (ptr @sym to i64)`) hesapladığı `sym+16` ADRES
/// ARİTMETİĞİ, QBE'DEKİYLE BAYT-BİREBİR AYNI byte-offset'lere İSABET EDER.
pub fn llvmStrHeaderConstant(allocator: std.mem.Allocator, name: []const u8, pinned_refcount: i64, packed_header: i64, bytes: []const u8) ![]const u8 {
    var escaped = try llvmEscapeBytes(allocator, bytes);
    try escaped.appendSlice(allocator, "\\00");
    return std.fmt.allocPrint(
        allocator,
        "@{s} = private unnamed_addr global {{ i64, i64, [{d} x i8] }} {{ i64 {d}, i64 {d}, [{d} x i8] c\"{s}\" }}\n",
        .{ name, bytes.len + 1, pinned_refcount, packed_header, bytes.len + 1, escaped.items },
    );
}

/// `syms`i (sembol adları, `$`/`@` ÖN-EKİ OLMADAN) fonksiyon-işaretçisi-
/// olarak-`i64` DİZİSİNE çeviren bir LLVM GLOBAL sabiti üretir — `layout.
/// zig`nin `genClassVtable`ı (bkz. onun belge notu, Faz 7 vtable) İçin,
/// QBE'nin `data $name = { l $sym1, l $sym2, ... }`inin LLVM karşılığı.
/// `layout.zig` (`codegen.zig`nin `generateModule`ı GİBİ) BU fonksiyonu
/// DOĞRUDAN çağırır — sınıf-makinesi HER programda (core.nox'un KOŞULSUZ
/// birleşimi YÜZÜNDEN) tetiklendiğinden, `qbeX` seam'İNİN "İSİMLİ metot"
/// deseninin DIŞINDA, `generateModule`nin direkt-yazıcı ÖRNEĞİYLE TUTARLI
/// bir "hazırlık yardımcısı" olarak sunulur.
pub fn llvmPtrArrayConstant(allocator: std.mem.Allocator, name: []const u8, syms: []const []const u8) ![]const u8 {
    var items: std.ArrayListUnmanaged(u8) = .empty;
    for (syms, 0..) |sym, i| {
        if (i != 0) try items.appendSlice(allocator, ", ");
        const entry = try std.fmt.allocPrint(allocator, "i64 ptrtoint (ptr @{s} to i64)", .{sym});
        try items.appendSlice(allocator, entry);
    }
    return std.fmt.allocPrint(allocator, "@{s} = private unnamed_addr constant [{d} x i64] [{s}]\n", .{ name, syms.len, items.items });
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

/// `qbeJnz`nin `l`-tipli (i64) koşul VARYANTI — bkz. `qbe_emit.zig`nin
/// AYNI adının belge notu (`nox_str_is_ascii`nin GERÇEK `i64` dönüşü,
/// `Codegen.str_ascii_cache`nin TEK üreticisi).
pub fn qbeJnzL(self: *Codegen, cond: []const u8, t: []const u8, f: []const u8) CodegenError!void {
    const cmp_reg = try self.newTemp();
    try self.out.writer.print("    {s} = icmp ne i64 {s}, 0\n", .{ cmp_reg, cond });
    try self.out.writer.print("    br i1 {s}, label %{s}, label %{s}\n", .{ cmp_reg, llLabelRef(t), llLabelRef(f) });
    self.llvm_block_open = false;
}

/// `v1`/`v2` — `genClassNameDispatch` GİBİ siteler BURAYA bir `$sembol`
/// metni (bkz. modül üstü not, `renderOperand`) GEÇİREBİLİR — bu YÜZDEN
/// HER ikisi de `renderOperand`DAN geçirilir (sıradan register/literal
/// operandlar İçin NO-OP, `$sembol` İçin `ptrtoint` sabit-ifadesi).
pub fn qbePhi(self: *Codegen, dst: []const u8, ty: QbeType, l1: []const u8, v1: []const u8, l2: []const u8, v2: []const u8) CodegenError!void {
    const rv1 = try renderOperand(self, v1);
    const rv2 = try renderOperand(self, v2);
    try self.out.writer.print("    {s} = phi {s} [ {s}, %{s} ], [ {s}, %{s} ]\n", .{ dst, llvmTypeName(ty), rv1, llLabelRef(l1), rv2, llLabelRef(l2) });
}

/// `self.current_ret_qtype` (HER fonksiyon-girişinde ayarlanır, bkz.
/// `registration.zig`) — bulgu #5: YENİ durum GEREKMEDEN dönüş tipini
/// verir. `value` — `genClassNameDispatch` GİBİ siteler (bkz. modül üstü
/// not) BURAYA bir `$sembol` metni GEÇİREBİLİR, bu YÜZDEN `renderOperand`
/// DAN geçirilir.
pub fn qbeRet(self: *Codegen, value: ?[]const u8) CodegenError!void {
    if (value) |v| {
        const rendered = try renderOperand(self, v);
        try self.out.writer.print("    ret {s} {s}\n", .{ llvmTypeName(self.current_ret_qtype), rendered });
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

pub fn qbeOp1(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a_raw: []const u8) CodegenError!void {
    const a = try renderOperand(self, a_raw);
    if (std.mem.eql(u8, mnemonic, "copy")) {
        if (ty == .d) {
            try self.out.writer.print("    {s} = fadd double {s}, 0.0\n", .{ dst, a });
        } else if (ty == .w) {
            // `w` hedefli `copy` BU projede YALNIZCA `l` (i64) kaynaktan
            // DARALTMA İçİn kullanılır (bkz. `expr.zig`nin `fromPayload`si
            // + `decorators.zig`nin `genReflectDecoratorIsHandler`i — İKİSİ
            // de QBE'nin "l->w copy = düşük 32 bit" idyomunu kullanır).
            // QBE'nin KENDİSİ İçİn bu GEÇERLİ (temps statik tipsiz), AMA
            // LLVM `add i32 <i64-değer>, 0` KABUL ETMEZ (operand tipi TAM
            // eşleşmeli) — doğru LLVM karşılığı AÇIK bir `trunc`tur.
            try self.out.writer.print("    {s} = trunc i64 {s} to i32\n", .{ dst, a });
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

pub fn qbeOp2(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a_raw: []const u8, b_raw: []const u8) CodegenError!void {
    const a = try renderOperand(self, a_raw);
    const b = try renderOperand(self, b_raw);
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

pub fn qbeOp2Imm(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a_raw: []const u8, imm: i64) CodegenError!void {
    const a = try renderOperand(self, a_raw);
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

/// Faz LLVM.8 (bkz. `qbeAlloc`nin belge notu): `addr` KAYITLI bir
/// alloca-ptr (yani `qbeAlloc`nin DOĞRUDAN dst'i) İSE o `ptr`-tipli SSA
/// register'ı SIFIR ek instruction İLE DOĞRUDAN döner — bu, `alloca`nın
/// mem2reg TARAFINDAN terfi edilebilir KALMASININ tek koşuludur (SADECE
/// load/store kullanımı). KAYITLI DEĞİLSE (`addr` bir heap-tahsis
/// çağrısının/aritmetiğin sonucu YA DA `renderOperand` YOLUYLA
/// materyalize edilmiş bir Desen-B adresi), eski davranışa (`inttoptr`)
/// düşer.
fn resolveAddrPtr(self: *Codegen, addr: []const u8) CodegenError![]const u8 {
    if (self.llvm_alloca_ptrs.get(addr)) |ptr_reg| return ptr_reg;
    const ptr_reg = try self.newTemp();
    try self.out.writer.print("    {s} = inttoptr i64 {s} to ptr\n", .{ ptr_reg, addr });
    return ptr_reg;
}

/// Faz MN.1 (bkz. plan dosyası "LLVM-only atomic ARC"): `addr`deki `i64`
/// ARC refcount alanını GERÇEKTEN atomik olarak `imm` KADAR artırır,
/// İŞLEM-SONRASI (NEW) değeri döner — `qbe_emit.zig`nin AYNI-isimli
/// (ama atomik OLMAYAN, `--release` bayrağı OLMADAN QBE'nin ürettiği
/// binary'ler DEĞİŞMESİN diye) metoduyla AYNI dönüş SÖZLEŞMESİNİ
/// paylaşır — `ownership.zig`nin ÇAĞIRAN kodu (`emitInlineRetain`/
/// `emitInlinePredecrement`) İKİ backend arasında TAMAMEN AYNI kalır,
/// hangi backend'in AKTİF olduğunu HİÇ bilmesi GEREKMEZ (bkz. `qbeJnzL`
/// öncedeni, Faz LLVM.7).
///
/// Sıralama (memory ordering) KARARI: `acq_rel` (HEM `retain` HEM
/// `predecrement` İçin, tekdüze). Araştırmanın önerdiği DAHA UCUZ şema
/// (relaxed retain / release predecrement / SADECE sıfıra-düşme
/// dalında koşullu acquire fence) BİLİNÇLİ olarak BURADA UYGULANMADI —
/// bu şema, `should_free`i KONTROL EDİP `nox_rc_free_payload`/
/// `$ClassName_release`i ÇAĞIRAN (`ownership.zig`nin DIŞINDA, onlarca
/// site) HER `emitInlinePredecrement` ÇAĞRI SİTESİNE bir fence
/// eklenmesini GEREKTİRİRDİ — geniş bir alan yayılımı, İNCE bir
/// sıralama hatası riskiyle. `acq_rel` DAHA UCUZ olmasa DA KESİN doğru
/// VE TEK bir yerde (bu iki metot) UYGULANIYOR — M:N ardışık düzeni
/// UÇTAN UCA kanıtlandıktan SONRA, gelecekte DAR bir perf-optimizasyonu
/// olarak GÖZDEN GEÇİRİLEBİLİR (bkz. plan dosyası).
pub fn qbeAtomicAdd(self: *Codegen, addr: []const u8, imm: i64) CodegenError![]const u8 {
    const ptr_reg = try resolveAddrPtr(self, addr);
    const old = try self.newTemp();
    try self.out.writer.print("    {s} = atomicrmw add ptr {s}, i64 {d} acq_rel\n", .{ old, ptr_reg, imm });
    const new = try self.newTemp();
    try self.out.writer.print("    {s} = add i64 {s}, {d}\n", .{ new, old, imm });
    return new;
}

/// `qbeAtomicAdd`nin AYNISI, `atomicrmw sub` İLE.
pub fn qbeAtomicSub(self: *Codegen, addr: []const u8, imm: i64) CodegenError![]const u8 {
    const ptr_reg = try resolveAddrPtr(self, addr);
    const old = try self.newTemp();
    try self.out.writer.print("    {s} = atomicrmw sub ptr {s}, i64 {d} acq_rel\n", .{ old, ptr_reg, imm });
    const new = try self.newTemp();
    try self.out.writer.print("    {s} = sub i64 {s}, {d}\n", .{ new, old, imm });
    return new;
}

/// `dst_ty != mem_ty` bu kod tabanında HİÇ GÖZLEMLENMEDİ (20/20 çağrı
/// sitesi eşleşiyor, bkz. plan doğrulaması) — GÖZLEMLENMEYEN bu durum
/// GÜVENLİ bir şekilde `error.Unsupported` ile REDDEDİLİR.
pub fn qbeLoad(self: *Codegen, dst: []const u8, dst_ty: QbeType, mem_ty: QbeType, addr: []const u8) CodegenError!void {
    if (dst_ty != mem_ty) return error.Unsupported;
    const ptr_reg = try resolveAddrPtr(self, addr);
    try self.out.writer.print("    {s} = load {s}, ptr {s}\n", .{ dst, llvmTypeName(dst_ty), ptr_reg });
}

pub fn qbeLoadL(self: *Codegen, dst: []const u8, addr: []const u8) CodegenError!void {
    try qbeLoad(self, dst, .l, .l, addr);
}

pub fn qbeStore(self: *Codegen, ty: QbeType, value_raw: []const u8, addr: []const u8) CodegenError!void {
    const value = try renderOperand(self, value_raw);
    const ptr_reg = try resolveAddrPtr(self, addr);
    try self.out.writer.print("    store {s} {s}, ptr {s}\n", .{ llvmTypeName(ty), value, ptr_reg });
}

pub fn qbeStoreL(self: *Codegen, value: []const u8, addr: []const u8) CodegenError!void {
    try qbeStore(self, .l, value, addr);
}

pub fn qbeStoreImmL(self: *Codegen, imm: i64, addr: []const u8) CodegenError!void {
    const text = try std.fmt.allocPrint(self.allocator, "{d}", .{imm});
    try qbeStore(self, .l, text, addr);
}

/// QBE'nin `loadub`u (`w`ye SIFIR-genişleten TEK-bayt yükleme) — `genStrIndex`nin
/// ASCII-hızlı-yolu İçin (bkz. `qbe_emit.zig`nin AYNI eklentisinin belge
/// notu).
pub fn qbeLoadUB(self: *Codegen, dst: []const u8, addr: []const u8) CodegenError!void {
    const ptr_reg = try resolveAddrPtr(self, addr);
    const byte_reg = try self.newTemp();
    try self.out.writer.print("    {s} = load i8, ptr {s}\n", .{ byte_reg, ptr_reg });
    try self.out.writer.print("    {s} = zext i8 {s} to i32\n", .{ dst, byte_reg });
}

/// QBE'nin `storeb`i (TEK bayt saklama, imzalı/imzasız FARK ETMEZ) —
/// `value_raw` HER ZAMAN `w`/i32-taşınan bir değer (register YA DA `0`
/// GİBİ bir literal) OLDUĞUNDAN önce `i8`e KIRPILIR (`trunc` bir sabit
/// İçin de GEÇERLİDİR).
pub fn qbeStoreB(self: *Codegen, value_raw: []const u8, addr: []const u8) CodegenError!void {
    const value = try renderOperand(self, value_raw);
    const ptr_reg = try resolveAddrPtr(self, addr);
    const byte_reg = try self.newTemp();
    try self.out.writer.print("    {s} = trunc i32 {s} to i8\n", .{ byte_reg, value });
    try self.out.writer.print("    store i8 {s}, ptr {s}\n", .{ byte_reg, ptr_reg });
}

/// QBE'nin `%dst =l alloc{4/8} {n}`i — dönüş HER ZAMAN bir `l` (i64)
/// "işaretçi-olarak-tamsayı" değeridir (bkz. modül üstü not). Faz LLVM.8
/// (bkz. plan dosyası "LLVM.8: qbeAlloc'nin mem2reg'i engelleyen ptrtoint
/// deseni"): `dst`, ARTIK bir LLVM SSA değeri OLARAK TANIMLANMAZ — `alloca`
/// SONUCU (`ptr_reg`) SADECE `self.llvm_alloca_ptrs`e (dst → ptr_reg)
/// KAYDEDİLİR. `qbeLoad`/`qbeStore`/vb. (`resolveAddrPtr` ÜZERİNDEN) bu
/// kaydı BULDUĞUNDA `ptr_reg`i SIFIR ek instruction İLE DOĞRUDAN kullanır;
/// `renderOperand` İSE `dst`nin bir DEĞER olarak (çağrı argümanı/başka bir
/// slota yazılan değer/aritmetik operandı) kaçtığı NADİR durumda TALEP
/// ÜZERİNE bir `ptrtoint` YAYAR. Bu, `alloca`nın SONUCUNUN (adresi bir
/// DEĞER olarak HİÇ kullanılmayan — Nox'taki EZİCİ ÇOĞUNLUK — sıradan
/// yerel değişkenler İçin) SADECE load/store'da kullanılmasını KORUYARAK
/// LLVM'in `mem2reg`/SROA geçişinin GERÇEKTEN register'a terfi
/// ettirebilmesini SAĞLAR (eskiden HER `alloca` `ptrtoint` İLE "kaçtığı"
/// İçin BU HİÇ mümkün DEĞİLDİ — bkz. plan dosyasının kök-neden analizi).
pub fn qbeAlloc(self: *Codegen, dst: []const u8, size: QbeAllocSize, n: usize) CodegenError!void {
    const ptr_reg = try self.newTemp();
    try self.out.writer.print("    {s} = alloca [{d} x i8], align {d}\n", .{ ptr_reg, n, @intFromEnum(size) });
    try self.llvm_alloca_ptrs.put(self.allocator, dst, ptr_reg);
}

/// İKİ bağımsız ham-metin sızıntısını render eden GENEL operand
/// dönüştürücü — HER `qbeX` metodunun TEXT alan operandı (dst/addr
/// HARİÇ) bunu ÇAĞIRMALIDIR:
///
/// 1. **`$sym`** (bir DEĞER operandı OLARAK — çağrı HEDEFİ OLARAK DEĞİL,
///    bkz. `qbeCall`): ör. `printf`e bir `$fmt_int` biçim-dizesi
///    sembolünü ARGÜMAN olarak geçirmek — sembolün ADRESİNİ `i64`e (bu
///    kod tabanının HER YERDE kullandığı "işaretçi-olarak-tamsayı"
///    temsiline) çeviren bir LLVM SABİT-İFADESİ üretir. `clang`e karşı
///    EMPİRİK doğrulandı (`ptrtoint_check.ll`).
/// 2. **`d_N`** (Faz LLVM.5, GERÇEK bir bulgu — `t1.nox` GİBİ EN basit
///    bir programda BİLE `core.nox`nin `JsonValue`si [`n: float` alanı]
///    ÜZERİNDEN tetiklenir): `expr.zig`nin `.float_lit` kolu (bkz. onun
///    belge notu, bulgu #6) float literallerini `Value.text`e QBE'nin
///    KENDİ `d_{d}` sözdizimiyle DOĞRUDAN gömer — bu metin `qbeOp1`/
///    `qbeOp2`/`qbeStore` GİBİ metotlara da (SADECE `qbeCall`nin
///    argümanlarına DEĞİL) bir operand OLARAK ULAŞABİLİR. LLVM'in double
///    sabitleri BİR ondalık NOKTASI gerektirdiğinden (`0` GEÇERSİZ, `0.0`
///    GEÇERLİ) `d_` ÖN-EKİ SIYRILIP, nokta YOKSA `.0` eklenir. **Bilinçli,
///    DAR kapsam:** bu SADECE operand RENDER noktasındaki bir metin
///    dönüşümüdür — float literal TEMSİLİNİN KENDİSİ (`expr.zig`)
///    DEĞİŞMEDİ, bu YÜZDEN float'ların GENEL desteği (aritmetik/
///    fonksiyon-imzaları/vb.) HÂLÂ Kapsam DIŞI kalır (bkz. plan dosyası).
fn renderOperand(self: *Codegen, text: []const u8) CodegenError![]const u8 {
    // Faz LLVM.8 (bkz. `qbeAlloc`nin belge notu, "Desen B"): `text`
    // KAYITLI bir alloca-ptr İSE, adresi bir DEĞER olarak (çağrı argümanı/
    // başka bir slota yazılan değer/aritmetik operandı) KULLANMAK ÜZERE
    // TALEP ÜZERİNE materyalize eder — `$sym`nin AKSİNE (link-zamanı
    // SABİTİ) bir alloca'nın adresi ÇALIŞMA-ZAMANI değeridir, bu YÜZDEN
    // bir SABİT-İFADE DEĞİL, GERÇEK bir `ptrtoint` INSTRUCTION'I yayılır.
    if (self.llvm_alloca_ptrs.get(text)) |ptr_reg| {
        const iv = try self.newTemp();
        try self.out.writer.print("    {s} = ptrtoint ptr {s} to i64\n", .{ iv, ptr_reg });
        return iv;
    }
    if (text.len > 0 and text[0] == '$') {
        return std.fmt.allocPrint(self.allocator, "ptrtoint (ptr @{s} to i64)", .{text[1..]});
    }
    if (text.len > 2 and text[0] == 'd' and text[1] == '_') {
        const num = text[2..];
        if (std.mem.indexOfScalar(u8, num, '.') == null) {
            return std.fmt.allocPrint(self.allocator, "{s}.0", .{num});
        }
        return num;
    }
    return text;
}

/// `self.functions`de (BU modülün KENDİSİNİN `define` edeceği üst-düzey
/// Nox fonksiyonları) KAYITLI OLMAYAN, HENÜZ declare EDİLMEMİŞ direkt-
/// sembol çağrıları İçin BİR `declare` üretip `llvm_pending_declares`e
/// biriktirir (bkz. modül üstü not, declare+define ÇAKIŞIR).
fn ensureDeclared(self: *Codegen, name: []const u8, ret_str: []const u8, fixed_args: []const QbeArg, variadic: bool) CodegenError!void {
    if (self.llvm_declared_externs.contains(name)) return;
    var params_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (fixed_args, 0..) |arg, i| {
        if (i != 0) try params_buf.appendSlice(self.allocator, ", ");
        try params_buf.appendSlice(self.allocator, llvmTypeName(arg.ty));
    }
    if (variadic) {
        if (fixed_args.len != 0) try params_buf.appendSlice(self.allocator, ", ");
        try params_buf.appendSlice(self.allocator, "...");
    }
    const decl_line = try std.fmt.allocPrint(self.allocator, "declare {s} @{s}({s})\n", .{ ret_str, name, params_buf.items });
    try self.llvm_pending_declares.append(self.allocator, .{ .name = name, .line = decl_line });
    try self.llvm_declared_externs.put(self.allocator, name, {});
}

/// `func_text` bir `$sembol` İSE (direkt çağrı) `"@sembol"` metnini
/// döner; AKSİ HALDE (dolaylı çağrı — `func_text` bir `i64`-taşınan
/// fonksiyon işaretçisi) `inttoptr` İLE `ptr`a çevirip o geçici kaydı
/// döner. `clang`e karşı EMPİRİK doğrulandı (`loadstore_indirect_check.
/// ll`): LLVM 21'in opak-işaretçi modu dolaylı çağrı sitesinde AYRI bir
/// fonksiyon-tipi GEREKTİRMİYOR.
fn resolveCallee(self: *Codegen, func_text: []const u8) CodegenError![]const u8 {
    if (func_text.len > 0 and func_text[0] == '$') {
        return std.fmt.allocPrint(self.allocator, "@{s}", .{func_text[1..]});
    }
    const ptr_reg = try self.newTemp();
    try self.out.writer.print("    {s} = inttoptr i64 {s} to ptr\n", .{ ptr_reg, func_text });
    return ptr_reg;
}

pub fn qbeCall(self: *Codegen, dst: ?QbeCallDst, func_text: []const u8, args: []const QbeArg) CodegenError!void {
    if (func_text.len > 0 and func_text[0] == '$') {
        const ret_str = if (dst) |d| llvmTypeName(d.ty) else "void";
        try ensureDeclared(self, func_text[1..], ret_str, args, false);
    }
    const callee_text = try resolveCallee(self, func_text);

    // Faz LLVM.8 (bkz. `qbeAlloc`nin belge notu): argümanlar `call ...(`
    // AÇILIŞ satırı YAZILMADAN ÖNCE render EDİLİR — `renderOperand`nin
    // Desen-B "talep üzerine materyalize" dalı (`self.out.writer`e AYRI
    // bir `ptrtoint` INSTRUCTION'I yazabilir) çağrı satırı ZATEN yarım
    // yazılmışKEN çalışırsa, o instruction'ın metni çağrı satırının
    // ORTASINA SIZAR (GEÇERSİZ LLVM IR — `lowlevel_arena` fixture'ında
    // GERÇEKTEN gözlemlenip DÜZELTİLDİ).
    var args_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (args, 0..) |arg, i| {
        if (i != 0) try args_buf.appendSlice(self.allocator, ", ");
        const rendered = try renderOperand(self, arg.text);
        try args_buf.appendSlice(self.allocator, llvmTypeName(arg.ty));
        try args_buf.append(self.allocator, ' ');
        try args_buf.appendSlice(self.allocator, rendered);
    }

    if (dst) |d| {
        try self.out.writer.print("    {s} = call {s} {s}({s})\n", .{ d.name, llvmTypeName(d.ty), callee_text, args_buf.items });
    } else {
        try self.out.writer.print("    call void {s}({s})\n", .{ callee_text, args_buf.items });
    }
}

/// `qbeCall`in variadic (`...`) versiyonu — `genPrint`/`genPrintFragment`nin
/// `printf`e yaptığı çağrılar İçin. LLVM'de variadic çağrılar `call`
/// SİTESİNDE TAM fonksiyon-tipini (`(sabit_tipler, ...)`) İSTER — `clang`e
/// karşı EMPİRİK doğrulandı (`ptrtoint_check.ll`).
pub fn qbeCallVariadic(self: *Codegen, dst: ?QbeCallDst, func_text: []const u8, fixed: []const QbeArg, variadic: []const QbeArg) CodegenError!void {
    const ret_str = if (dst) |d| llvmTypeName(d.ty) else "void";
    if (func_text.len > 0 and func_text[0] == '$') {
        try ensureDeclared(self, func_text[1..], ret_str, fixed, true);
    }
    const callee_text = try resolveCallee(self, func_text);

    var fixed_types_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (fixed, 0..) |arg, i| {
        if (i != 0) try fixed_types_buf.appendSlice(self.allocator, ", ");
        try fixed_types_buf.appendSlice(self.allocator, llvmTypeName(arg.ty));
    }

    // Faz LLVM.8 (bkz. `qbeCall`nin AYNI belge notu): argümanlar `call
    // (...) ...(` AÇILIŞ satırı YAZILMADAN ÖNCE render EDİLİR.
    var args_buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    for (fixed) |arg| {
        if (!first) try args_buf.appendSlice(self.allocator, ", ");
        first = false;
        const rendered = try renderOperand(self, arg.text);
        try args_buf.appendSlice(self.allocator, llvmTypeName(arg.ty));
        try args_buf.append(self.allocator, ' ');
        try args_buf.appendSlice(self.allocator, rendered);
    }
    for (variadic) |arg| {
        if (!first) try args_buf.appendSlice(self.allocator, ", ");
        first = false;
        const rendered = try renderOperand(self, arg.text);
        try args_buf.appendSlice(self.allocator, llvmTypeName(arg.ty));
        try args_buf.append(self.allocator, ' ');
        try args_buf.appendSlice(self.allocator, rendered);
    }

    if (dst) |d| {
        try self.out.writer.print("    {s} = call {s} ({s}, ...) {s}({s})\n", .{ d.name, ret_str, fixed_types_buf.items, callee_text, args_buf.items });
    } else {
        try self.out.writer.print("    call void ({s}, ...) {s}({s})\n", .{ fixed_types_buf.items, callee_text, args_buf.items });
    }
}

/// Bulundu (Faz LLVM.5, `t1.nox` GİBİ EN basit bir programda BİLE
/// tetiklenen GERÇEK bir hata): `current_ret_qtype`nin (bulgu #5, Faz
/// LLVM.2) "HER fonksiyon-girişinde ayarlanır" varsayımı YANLIŞTI —
/// `registration.zig`nin `genFunction`/`genMethod`/`genMain`ı BUNU
/// KENDİLERİ ayarlıyor, AMA `layout.zig`nin sentetik yardımcıları
/// (`genClassEq`/`genClassRelease`/`genClassTrace`/`genClassGcFree`/
/// dispatch fonksiyonları) HİÇ ayarlamıyor — QBE'nin `ret`i TİP
/// GEREKTİRMEDİĞİNDEN bu ONLARIN İçin ÖNEMSİZDİ. Sonuç: bu yardımcıların
/// `qbeRet`i eski/varsayılan `.none`u (`ret void 1` GİBİ GEÇERSİZ LLVM
/// üretiyordu) kullanıyordu. Düzeltme: `qbeFuncHeaderStart`nin KENDİSİ
/// `current_ret_qtype`i AYARLAR — TEK, kapsayıcı doğruluk kaynağı (ZATEN
/// doğru ayarlayan `genFunction` GİBİ çağıranlar İçin bu AYNI değerle
/// YİNELENEN, zararsız bir atama).
pub fn qbeFuncHeaderStart(self: *Codegen, ret_ty: ?QbeType, name_text: []const u8) CodegenError!void {
    // Faz LLVM.8: `self.llvm_alloca_ptrs`i (bkz. `qbeAlloc`nin belge notu)
    // temizle — `temp_counter` (29 AYRI sitede, 8 sibling dosyada dağınık
    // olarak sıfırlanıyor) İLE AYNI "her fonksiyon-benzeri codegen girişi"
    // noktasıdır (`qbeFuncHeaderStart` HER BİRİNDE TAM OLARAK BİR KEZ
    // çağrılıyor) — bu TEK satır TÜM harici sıfırlama sitelerini kapsar,
    // çapraz-fonksiyon `%tN` çakışmasını (bir SONRAKİ fonksiyonun %t5'inin
    // YANLIŞLIKLA ÖNCEKİ fonksiyonun alloca-ptr'ına eşlenmesi) önler.
    self.llvm_alloca_ptrs.clearRetainingCapacity();
    self.current_ret_qtype = ret_ty orelse .none;
    const name = llGlobalRef(name_text);
    // Bulundu (Faz LLVM.5): `self.llvm_defined_syms`e KAYIT — `qbeCall`nin
    // `declare`-takibinin (bkz. `Codegen.llvm_pending_declares`nin belge
    // notu) `generateModule`nin SONUNDAKİ flush'ının TEK doğruluk kaynağı.
    try self.llvm_defined_syms.put(self.allocator, name, {});
    const rt_name = if (ret_ty) |rt| llvmTypeName(rt) else "void";
    try self.out.writer.print("define {s} @{s}(", .{ rt_name, name });
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
