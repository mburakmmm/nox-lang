//! QBE codegen backend'inin küçük, saf (durumsuz) ABI/isimlendirme
//! yardımcıları — bkz. plan dosyası "QBE codegen backend'ini alt modüllere
//! bölme". Hiçbiri `Codegen` durumuna erişmez (`self` parametresi YOK).

const std = @import("std");
const ast = @import("../parser/ast.zig");
const types = @import("types.zig");
const QbeType = types.QbeType;
const Value = types.Value;
const ElemHeapInfo = types.ElemHeapInfo;
const HeapKind = types.HeapKind;

pub const CodegenError = error{
    OutOfMemory,
    Unsupported,
} || std.Io.Writer.Error;

/// Faz U.4.3: `Codegen.current_path`i (checker'ın `FnCtx.path`iyle AYNI
/// dot-ayrılmış format, ör. `"outer.adder"`) GEÇERLİ bir QBE sembol adına
/// çevirir — QBE tanımlayıcıları `.` İÇEREMEZ, bu yüzden `.`→`_` DÖNÜŞTÜRÜLÜR.
/// `"closure_"` ÖNEKİ, olası bir kullanıcı fonksiyon/sınıf adıyla ÇAKIŞMAYI
/// ÖNLER.
pub fn sanitizePathToSymbol(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(a, "closure_");
    for (path) |c| try buf.append(a, if (c == '.') '_' else c);
    return buf.toOwnedSlice(a);
}

pub fn qbeTypeName(t: QbeType) []const u8 {
    return switch (t) {
        .l => "l",
        .d => "d",
        .w => "w",
        .none => "",
    };
}

pub fn qbeSizeOf(t: QbeType) usize {
    return switch (t) {
        .w => 4,
        .l, .d => 8,
        .none => 0,
    };
}

/// Bir KONTEYNERİN (`list[T]`, `Task[T]`, `Channel[T]`) `elem_qtype`/
/// `elem_heap_info`/`elem_is_str` alanlarından, KENDİSİ okunan TEK bir
/// elemanın (`text`/`qtype` zaten hesaplanmış) TAM `Value`sini (doğru
/// `heap`/`class_name`/iç içe `elem_heap_info` ile) yeniden kurar —
/// `genIndex` (liste indeksleme), `genAwaitExpr` (`Task` sonucu) ve
/// `genChannelOp` (`Channel.recv`) arasında PAYLAŞILAN tek bir mantık.
pub fn valueFromElemDescriptor(text: []const u8, qtype: QbeType, container_elem_heap_info: ?*const ElemHeapInfo, container_elem_is_str: bool) Value {
    return .{
        .text = text,
        .qtype = qtype,
        .heap = if (container_elem_heap_info) |ehi| ehi.heap else if (container_elem_is_str) .str else .none,
        .class_name = if (container_elem_heap_info) |ehi| ehi.class_name else null,
        .elem_qtype = if (container_elem_heap_info) |ehi| ehi.elem_qtype else .none,
        .elem_heap_info = if (container_elem_heap_info) |ehi| ehi.nested else null,
        .func_sig = if (container_elem_heap_info) |ehi| ehi.func_sig else null,
    };
}

pub fn cmpMnemonic(op: ast.BinaryOp, common: QbeType) []const u8 {
    if (common == .d) {
        return switch (op) {
            .eq => "ceqd",
            .ne => "cned",
            .lt => "cltd",
            .le => "cled",
            .gt => "cgtd",
            .ge => "cged",
            else => unreachable,
        };
    }
    if (common == .w) {
        return switch (op) {
            .eq => "ceqw",
            .ne => "cnew",
            else => unreachable,
        };
    }
    return switch (op) {
        .eq => "ceql",
        .ne => "cnel",
        .lt => "csltl",
        .le => "cslel",
        .gt => "csgtl",
        .ge => "csgel",
        else => unreachable,
    };
}

pub fn escapeForQbeString(allocator: std.mem.Allocator, s: []const u8) CodegenError![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

/// `genForList`nin gizli döngü indeksi için `self.vars` içinde kullanılan
/// isim — kullanıcı tanımlı isimlerle asla çakışmayan `$` önekiyle.
pub fn forListIdxName(allocator: std.mem.Allocator, var_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "$idx_{s}", .{var_name});
}

/// Faz FF.3: `.dict` ARTIK `.list`/`.class`/`.str`/`.closure` İLE AYNI TAM
/// ARC modelindedir.
pub fn isHeapManaged(h: HeapKind) bool {
    return h == .list or h == .class or h == .str or h == .closure or h == .dict or h == .boxed_scalar;
}

/// `expr` değerlendirildiğinde TAZE (henüz hiçbir isme/alana/elemana
/// bağlanmamış, hiçbir bağımsız release'i olmayan) bir heap değeri üretir mi?
pub fn isTemporaryExpr(expr: ast.Expr) bool {
    return switch (expr) {
        // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı):
        // `.generic_construct` (`Box[int](...)` — kullanıcı-tanımlı bir
        // generic sınıf İSE) `.call` İLE AYNI şekilde TAZE bir değer üretir
        // — EKLENMEZSE, ör. `Box[int](9).get()` gibi bir GEÇİCİ
        // (bağlanmamış) yapıcı-çağrısı çıktısı, metod çağrısından SONRA HİÇ
        // serbest bırakılmaz (GERÇEK bir sızıntı, doğrulandı). `Channel[T](
        // ...)`/`ThreadChannel[T](...)` İÇİN bu SAYIM DAVRANIŞSAL bir fark
        // YARATMAZ — `releaseIfTemporary`nin `isHeapManaged(v.heap)` ÖN-
        // koşulu ZATEN `.channel`/`.thread_channel`i (ARC-DIŞI, bkz.
        // `isHeapManaged`in belge notu) ELER.
        .call, .list_lit, .dict_lit, .binary, .generic_construct => true,
        .attribute => |a| isTemporaryExpr(a.obj.*),
        .index => |idx| isTemporaryExpr(idx.obj.*),
        else => false,
    };
}

pub fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}
