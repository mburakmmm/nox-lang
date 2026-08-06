//! Faz IR.0 (bkz. plan dosyası "QBE metin-emisyonu için bir 'instruction
//! emission' katmanı çıkarma"): `compiler/codegen_qbe/`nin diğer 15
//! dosyasının doğrudan `self.out.writer.print(...)`/`writeAll(...)` ile
//! gömdüğü QBE mnemonic'lerini TEK, adlandırılmış bir API'nin ARKASINA
//! çeker — davranış SIFIR DEĞİŞİKLİK, salt bir metin-render seam'i.
//!
//! **Neden `qbe` ön-eki:** `expr.zig`'in `emitBin`/`emitCmp`'i GİBİ isimler
//! ZATEN Nox-anlamsal (ARC/tip dönüşümü YAPAN) kod İçin `emit*` ön-ekini
//! KULLANIYOR — bu YÜZDEN "SADECE metin render eden, HİÇBİR karar
//! VERMEYEN" bu katman AYRI, çakışmayan bir ön-ekle (`qbe*`) adlandırılır.
//! `self.out.writer`e DOĞRUDAN erişen HERHANGİ bir kod artık SADECE bu
//! dosyada olmalı — `grep -rn "self.out.writer" compiler/codegen_qbe/` bu
//! dosya DIŞINDA hiçbir eşleşme dönmemeli (migrasyon tamamlandığında).
//!
//! **Kapsam DIŞI (bilinçli):** bu dosya bir soyut SSA-graf IR'ı DEĞİLDİR —
//! her metot HÂLÂ doğrudan metin yazıyor, sadece hangi metnin YAZILDIĞI
//! artık TEK bir yerden (mnemonic başına BİR metot) geçiyor. Gelecekte
//! (AYRI bir karar noktası) bir `llvm_emit.zig` AYNI metot isimleriyle
//! ama `.ll` sözdizimli gövdelerle yazılabilir — bu dosya SADECE o seam'i
//! HAZIRLAR, LLVM'e HİÇ dokunmaz.

const std = @import("std");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");

const Codegen = codegen.Codegen;
const QbeType = types.QbeType;
const CodegenError = abi.CodegenError;
const qbeTypeName = abi.qbeTypeName;

/// `qbeCall`e geçirilen TEK bir argüman — `ty`+ÖNCEDEN render edilmiş
/// operand metni (`Value.text` İLE AYNI temsil).
pub const QbeArg = struct {
    ty: QbeType,
    text: []const u8,
};

// ---- Kontrol akışı ---------------------------------------------------

/// Ham bir etiket satırı (`@label\n`) — `newLabel`in ÜRETTİĞİ metni
/// OLDUĞU GİBİ yazar. 144 çağrı sitesinin TÜMÜ bu şekli kullanıyordu
/// (`"{s}\n"`, argüman HER ZAMAN bir `*_label` string'i).
pub fn qbeLabel(self: *Codegen, label: []const u8) CodegenError!void {
    try self.out.writer.print("{s}\n", .{label});
}

pub fn qbeJmp(self: *Codegen, target: []const u8) CodegenError!void {
    try self.out.writer.print("    jmp {s}\n", .{target});
}

pub fn qbeJnz(self: *Codegen, cond: []const u8, t: []const u8, f: []const u8) CodegenError!void {
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond, t, f });
}

/// `qbeJnz`nin `l`-tipli (i64-taşınan) koşul VARYANTI — QBE'nin `jnz`ı
/// GENİŞLİK-BAĞIMSIZ olduğundan (bkz. `Codegen.str_ascii_cache`nin TEK
/// üreticisi, `nox_str_is_ascii`nin GERÇEK `i64` dönüş tipi) BU dal İLE
/// `qbeJnz` BİREBİR AYNI metni üretir — SADECE LLVM'in `icmp`inin doğru
/// operand tipini SEÇMESİ İçin (bkz. `llvm_emit.zig`nin AYNI adı) AYRI
/// bir isim taşır.
pub fn qbeJnzL(self: *Codegen, cond: []const u8, t: []const u8, f: []const u8) CodegenError!void {
    try self.out.writer.print("    jnz {s}, {s}, {s}\n", .{ cond, t, f });
}

/// İki dallı bir `phi` — DOĞRULANDI: `ty` `w`/`l` İKİSİ de görülüyor,
/// operandlar (literal `"0"`/`"1"` YA DA değişken metni) HER ZAMAN
/// ÖNCEDEN render edilmiş metin, bu YÜZDEN `ty` SABİTLENMEZ, PARAMETRE.
pub fn qbePhi(self: *Codegen, dst: []const u8, ty: QbeType, l1: []const u8, v1: []const u8, l2: []const u8, v2: []const u8) CodegenError!void {
    try self.out.writer.print("    {s} ={s} phi {s} {s}, {s} {s}\n", .{ dst, qbeTypeName(ty), l1, v1, l2, v2 });
}

/// `value == null` İSE değersiz `ret` (fonksiyonun `None` dönüş tipi İçin).
pub fn qbeRet(self: *Codegen, value: ?[]const u8) CodegenError!void {
    if (value) |v| {
        try self.out.writer.print("    ret {s}\n", .{v});
    } else {
        try self.out.writer.writeAll("    ret\n");
    }
}

/// Fonksiyon gövdesini kapatan `}`. `"    ret {s}\n}}\n"` GİBİ FUSED
/// (tek `print`te İKİ instruction) sitelerin `qbeRet`+`qbeFuncEnd`e
/// BÖLÜNMESİYLE birleştirilmiş çıktı BYTE-BİREBİR AYNI kalır.
pub fn qbeFuncEnd(self: *Codegen) CodegenError!void {
    try self.out.writer.writeAll("}\n");
}

// ---- Aritmetik / mantık / karşılaştırma -------------------------------

/// TEK operandlı bir instruction (`copy`, `extuw`, `uwtof` GİBİ) —
/// `mnemonic` ÇAĞIRAN tarafta ZATEN TAM metin OLARAK var, imzalılık/tip
/// seçimi Nox-anlamsal bir KARAR olarak ÇAĞIRANDA KALIR.
pub fn qbeOp1(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8) CodegenError!void {
    try self.out.writer.print("    {s} ={s} {s} {s}\n", .{ dst, qbeTypeName(ty), mnemonic, a });
}

/// İki operandlı bir instruction (`add`/`sub`/`mul`/`or`/`and`/`xor`/
/// `cslt*`/`ceq*` GİBİ karşılaştırmalar DAHİL) — HER İKİ operand da
/// ÖNCEDEN render edilmiş metin.
pub fn qbeOp2(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8, b: []const u8) CodegenError!void {
    try self.out.writer.print("    {s} ={s} {s} {s}, {s}\n", .{ dst, qbeTypeName(ty), mnemonic, a, b });
}

/// `qbeOp2`nin AYNISI ama ikinci operand ÇALIŞMA-ZAMANI bir tam sayı
/// literali (`{d}`) — `add ..., {d}`/`mul ..., {d}` ailesinin karşılığı.
pub fn qbeOp2Imm(self: *Codegen, dst: []const u8, ty: QbeType, mnemonic: []const u8, a: []const u8, imm: i64) CodegenError!void {
    try self.out.writer.print("    {s} ={s} {s} {s}, {d}\n", .{ dst, qbeTypeName(ty), mnemonic, a, imm });
}

// ---- Yükle / sakla / tahsis -------------------------------------------

/// `dst_ty ={dst_ty} load{mem_ty} addr` — dönüş tipi İLE bellekten
/// okunan tip FARKLI olabilir (ör. `w` bir `l`ye genişletilerek yüklenir).
pub fn qbeLoad(self: *Codegen, dst: []const u8, dst_ty: QbeType, mem_ty: QbeType, addr: []const u8) CodegenError!void {
    try self.out.writer.print("    {s} ={s} load{s} {s}\n", .{ dst, qbeTypeName(dst_ty), qbeTypeName(mem_ty), addr });
}

/// `qbeLoad(dst, .l, .l, addr)` kısayolu — 71 sitenin (en yoğun tek
/// şekil) doğrudan karşılığı.
pub fn qbeLoadL(self: *Codegen, dst: []const u8, addr: []const u8) CodegenError!void {
    try qbeLoad(self, dst, .l, .l, addr);
}

pub fn qbeStore(self: *Codegen, ty: QbeType, value: []const u8, addr: []const u8) CodegenError!void {
    try self.out.writer.print("    store{s} {s}, {s}\n", .{ qbeTypeName(ty), value, addr });
}

/// `qbeStore(.l, value, addr)` kısayolu — 26 sitenin doğrudan karşılığı.
pub fn qbeStoreL(self: *Codegen, value: []const u8, addr: []const u8) CodegenError!void {
    try qbeStore(self, .l, value, addr);
}

/// `storel {d}, {s}` ailesi — ÇALIŞMA-ZAMANI bir tam sayı literalinin
/// (`storel 0`/`storel 1` DAHİL) DOĞRUDAN bir adrese yazılması.
pub fn qbeStoreImmL(self: *Codegen, imm: i64, addr: []const u8) CodegenError!void {
    try self.out.writer.print("    storel {d}, {s}\n", .{ imm, addr });
}

/// Faz LLVM.7: `genStrIndex`nin ASCII-hızlı-yolunun BAYT-granülerlikli
/// yükleme/saklama çifti (`qbeLoad`/`qbeStore`nin `w`/`l`/`d`-SINIRLI
/// API'sine UYMAZ) — `loadub` HER ZAMAN `w`ye sıfır-genişletir, `storeb`
/// TEK bir bayt yazar (imzasız/imzalı FARK ETMEZ, QBE'de TEK `storeb`).
pub fn qbeLoadUB(self: *Codegen, dst: []const u8, addr: []const u8) CodegenError!void {
    try self.out.writer.print("    {s} =w loadub {s}\n", .{ dst, addr });
}

pub fn qbeStoreB(self: *Codegen, value: []const u8, addr: []const u8) CodegenError!void {
    try self.out.writer.print("    storeb {s}, {s}\n", .{ value, addr });
}

pub const QbeAllocSize = enum(u8) { four = 4, eight = 8 };

pub fn qbeAlloc(self: *Codegen, dst: []const u8, size: QbeAllocSize, n: usize) CodegenError!void {
    try self.out.writer.print("    {s} =l alloc{d} {d}\n", .{ dst, @intFromEnum(size), n });
}

// ---- Çağrılar -----------------------------------------------------------

/// `qbeCall`in dönüş-değeri ayarı — `null` İSE değersiz bir çağrı (`call
/// $fn(...)`, sonuç ATANMAZ), aksi HALDE `{s} ={s} call ...`.
pub const QbeCallDst = struct {
    name: []const u8,
    ty: QbeType,
};

/// `dst ={ty} call func_text(ty1 a1, ty2 a2, ...)` — `calls.zig`/
/// `async_thread.zig`deki elle-yazılmış virgül-bookkeeping döngülerinin
/// (`wrote_arg: bool` + `writeAll(", ")`) YERİNİ alan TEK çağrı; `args`
/// SIFIR ELEMANLI olabilir (parametresiz çağrı).
pub fn qbeCall(self: *Codegen, dst: ?QbeCallDst, func_text: []const u8, args: []const QbeArg) CodegenError!void {
    if (dst) |d| {
        try self.out.writer.print("    {s} ={s} call {s}(", .{ d.name, qbeTypeName(d.ty), func_text });
    } else {
        try self.out.writer.print("    call {s}(", .{func_text});
    }
    for (args, 0..) |arg, i| {
        if (i != 0) try self.out.writer.writeAll(", ");
        try self.out.writer.print("{s} {s}", .{ qbeTypeName(arg.ty), arg.text });
    }
    try self.out.writer.writeAll(")\n");
}

/// Faz LLVM.4: `qbeCall`in variadic (`...`) versiyonu — `genPrint`/
/// `genPrintFragment`nin `printf`e yaptığı çağrılar İçin (QBE'nin `...`
/// işaretinin `qbeCall`de karşılığı YOK, bu YÜZDEN bu ayrı metot). `fixed`
/// `...`DAN ÖNCEKİ, `variadic` SONRAKİ argümanlar — bu kod tabanında HER
/// ZAMAN `fixed.len == 1` (biçim dizesi) + `variadic.len == 1` (basılacak
/// değer), ama İMZA genel BIRAKILDI.
pub fn qbeCallVariadic(self: *Codegen, dst: ?QbeCallDst, func_text: []const u8, fixed: []const QbeArg, variadic: []const QbeArg) CodegenError!void {
    if (dst) |d| {
        try self.out.writer.print("    {s} ={s} call {s}(", .{ d.name, qbeTypeName(d.ty), func_text });
    } else {
        try self.out.writer.print("    call {s}(", .{func_text});
    }
    for (fixed) |arg| {
        try self.out.writer.print("{s} {s}, ", .{ qbeTypeName(arg.ty), arg.text });
    }
    try self.out.writer.writeAll("...");
    for (variadic) |arg| {
        try self.out.writer.print(", {s} {s}", .{ qbeTypeName(arg.ty), arg.text });
    }
    try self.out.writer.writeAll(")\n");
}

// ---- Fonksiyon başlıkları -----------------------------------------------
//
// Her dosyada farklı sabit parametre isimleri (`%argp`/`%env`/`%p_self`/
// `%ctx`/`%tag` vb.) kullanıldığından, TEK bir "FunctionSignature" tipi
// İNŞA ETMEYE ÇALIŞILMAZ (kapsam-dışı, gereksiz büyük tasarım) — mevcut
// ADIM-ADIM `print`+`writeAll` dizileri AYNI SIRAYLA bu ÜÇ metoda MEKANİK
// olarak çevrilir.

/// `"export function "` + (VARSA) `"{s} "` dönüş tipi + `name_text` +
/// `"("`. `name_text` çağıranın önceden hazırladığı sembol metni
/// (`"${s}"` GİBİ) — bu katman sembol adlandırmasına KARIŞMAZ.
pub fn qbeFuncHeaderStart(self: *Codegen, ret_ty: ?QbeType, name_text: []const u8) CodegenError!void {
    try self.out.writer.writeAll("export function ");
    if (ret_ty) |rt| try self.out.writer.print("{s} ", .{qbeTypeName(rt)});
    try self.out.writer.print("{s}(", .{name_text});
}

/// TEK bir parametre — `first=true` İSE ÖNCESİNDE virgül YAZILMAZ.
pub fn qbeFuncParam(self: *Codegen, ty: QbeType, text: []const u8, first: bool) CodegenError!void {
    if (!first) try self.out.writer.writeAll(", ");
    try self.out.writer.print("{s} {s}", .{ qbeTypeName(ty), text });
}

pub fn qbeFuncHeaderEnd(self: *Codegen) CodegenError!void {
    try self.out.writer.writeAll(") {\n@start\n");
}

// ---- Kaçış kapısı ---------------------------------------------------

/// BİLİNÇLİ, GEÇİCİ kaçış kapısı — HENÜZ isimlendirilmemiş/nadir şekiller
/// (ör. `decorators.zig`nin `data $sym = {...}` array-literal döngüleri)
/// İçin. Migrasyonun "bitti" ölçütü "HER site artık bir `qbe*` metodu
/// çağırıyor" — HEPSİNİN İSİMLİ (Raw OLMAYAN) bir metot kullanması ŞART
/// DEĞİL; kalan `qbeRaw` çağrıları görünür, kabul edilebilir bir sonraki-
/// iyileştirme işaretidir.
pub fn qbeRaw(self: *Codegen, comptime fmt: []const u8, args: anytype) CodegenError!void {
    try self.out.writer.print(fmt, args);
}

pub fn qbeRawAll(self: *Codegen, text: []const u8) CodegenError!void {
    try self.out.writer.writeAll(text);
}
