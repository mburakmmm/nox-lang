//! GG.20 (bkz. plan dosyası "ASAP güçlendirmesi — Tur 4"): PAYLAŞILAN,
//! GENEL bir "bir düğüm KÖTÜyse, ONA BAĞIMLI olan HER düğüm de KÖTÜ olur"
//! yayılım motoru — `compiler/codegen_qbe/exceptions.zig`nin `computeMustNotRaise`ı
//! İÇİN ZATEN kanıtlanmış ters-çağrı-grafiği + worklist algoritmasının
//! (`callers_of` inşası → `direct_unsafe` tohumlarından worklist İLE
//! YAYILIM → O(F+E), naif O(F²) `while(changed)` YERİNE) GENELLEŞTİRİLMİŞ/
//! ÇIKARILMIŞ hali.
//!
//! HEM `compiler/typecheck/checker.zig`nin SpawnSharedMutation'ının
//! transitif genellemesi (bir parametrenin BAŞKA bir yardımcı fonksiyon
//! ÜZERİNDEN mutasyona uğrayıp uğramadığı) HEM `compiler/codegen_qbe/inlining.zig`nin
//! `paramNeverEscapes`inin interprocedural genellemesi (bir parametrenin
//! BAŞKA bir fonksiyona argüman olarak geçtiğinde kaçıp kaçmadığı) BU
//! AYNI matematiksel şekli (monoton, TERS-grafik üzerinden OR-yayılımı)
//! paylaşır — SADECE düğümler `(fonksiyon_adı)` YERİNE `(fonksiyon_adı,
//! parametre_indeksi)` ÇİFTLERİ VE "kötü" tanımı (mutasyon VS kaçış)
//! FARKLIDIR. `checker.zig` `codegen_qbe`yi HİÇ İMPORT EDEMEYECEĞİNDEN
//! (TERS yönde — `codegen_qbe/decorators.zig` ZATEN `checker.zig`yi
//! import ediyor) BU dosya İKİSİNİN de BAĞIMSIZ olarak import edebileceği,
//! checker/codegen ARASINDA HİÇBİR bağımlılık KURMAYAN NÖTR bir modüldür
//! — PAYLAŞILAN olan VERİ DEĞİL, ALGORİTMADIR (HER taraf KENDİ grafiğini/
//! tohum kümesini İNŞA EDER).

const std = @import("std");

/// Bir düğüm: `(fonksiyon_adı, parametre_indeksi)` çifti.
pub const NodeKey = struct {
    func: []const u8,
    index: u32,
};

pub const NodeKeyContext = struct {
    pub fn hash(self: @This(), k: NodeKey) u64 {
        _ = self;
        var h = std.hash.Wyhash.init(0);
        h.update(k.func);
        h.update(std.mem.asBytes(&k.index));
        return h.final();
    }
    pub fn eql(self: @This(), a: NodeKey, b: NodeKey) bool {
        _ = self;
        return a.index == b.index and std.mem.eql(u8, a.func, b.func);
    }
};

pub const NodeSet = std.HashMapUnmanaged(NodeKey, void, NodeKeyContext, std.hash_map.default_max_load_percentage);
pub const ReverseEdges = std.HashMapUnmanaged(NodeKey, std.ArrayListUnmanaged(NodeKey), NodeKeyContext, std.hash_map.default_max_load_percentage);

/// `reverse_edges[K]`: "K KÖTÜyse, BUNLAR da KÖTÜ olur" listesi
/// (`computeMustNotRaise`nin `callers_of`uyla AYNI YÖN — TERS kenar,
/// "kim BUNA bağımlı" DEĞİL "K'ye bağımlı olan KİM" sorgusuna göre
/// İNŞA EDİLMİŞ olmalı). `seeds`: BAŞTAN KÖTÜ olan düğümler (`direct_
/// unsafe`nin AYNISI). Döner: `seeds` + TÜM ULAŞILABİLEN düğümlerin
/// kümesi — HER düğüm/kenar EN FAZLA BİR KEZ işlenir (worklist, naif
/// "değişti mi" taraması DEĞİL) — O(düğüm+kenar).
pub fn propagateBad(allocator: std.mem.Allocator, reverse_edges: *const ReverseEdges, seeds: []const NodeKey) !NodeSet {
    var bad: NodeSet = .empty;
    var worklist: std.ArrayListUnmanaged(NodeKey) = .empty;
    defer worklist.deinit(allocator);
    for (seeds) |s| {
        const gop = try bad.getOrPut(allocator, s);
        if (gop.found_existing) continue;
        try worklist.append(allocator, s);
    }
    while (worklist.pop()) |k| {
        const dependents = reverse_edges.get(k) orelse continue;
        for (dependents.items) |dep| {
            const gop = try bad.getOrPut(allocator, dep);
            if (gop.found_existing) continue;
            try worklist.append(allocator, dep);
        }
    }
    return bad;
}
