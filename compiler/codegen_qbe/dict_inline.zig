//! Dict son-arama önbelleği isabetinin satır içi üretimi (v2.2.24). `if d.contains(k): d[k] = d[k] + 1` kalıbı aynı anahtarı üç kez arar; çalışma zamanı
//! (`runtime/collections/dict.zig` `findIndex`) bunu zaten tek gerçek aramaya indiriyor ama her işlem bir `noxrt` çağrısıdır (~3 ns). Burada isabet yolu IR'a
//! satır içi girer: paylaşılmayan sözlükte (`shared == 0`) `last_idx < entries.len` ve `entries[last_idx].key == key` ise işlem doğrudan yapılır; aksi halde
//! eski çalışma zamanı çağrısı değişmeden çalışır. Alan konumları `shared/abi_layout.zig`te sabitlenir ve `dict.zig`de `comptime` doğrulanır.

const std = @import("std");
const abi_layout = @import("abi_layout");
const types = @import("types.zig");
const abi = @import("abi.zig");
const codegen = @import("codegen.zig");
const Codegen = codegen.Codegen;
const CodegenError = abi.CodegenError;
const RT_PARAM = types.RT_PARAM;

pub const Probe = struct {
    /// İsabet bloğu: burada `entry` (anahtar@0, değer@8 olan 16 baytlık girdinin adresi) geçerlidir.
    hit: []const u8,
    /// Yavaş yol bloğu (çalışma zamanı çağrısı burada üretilir).
    slow: []const u8,
    entry: []const u8,
};

fn addr(self: *Codegen, base: []const u8, off: usize) CodegenError![]const u8 {
    if (off == 0) return base;
    const t = try self.newTemp();
    try self.qbeOp2Imm(t, .l, "add", base, @intCast(off));
    return t;
}

/// `obj` (dict işaretçisi) ve `key` (yük, `.l`) için isabet yoklaması: üç dalla `hit`e ya da `slow`a gider; çağıran önce `hit` sonra `slow` etiketini üretir.
pub fn probe(self: *Codegen, obj: []const u8, key: []const u8) CodegenError!Probe {
    const hit = try self.newLabel("dict_hit");
    const slow = try self.newLabel("dict_slow");
    const chk1 = try self.newLabel("dict_chk");
    const chk2 = try self.newLabel("dict_chk");

    const shared_a = try addr(self, obj, abi_layout.DICT_SHARED_OFF);
    const shared = try self.newTemp();
    try self.qbeLoadUB(shared, shared_a);
    try self.qbeJnz(shared, slow, chk1);

    try self.qbeLabel(chk1);
    const li = try self.newTemp();
    try self.qbeLoadL(li, try addr(self, obj, abi_layout.DICT_LAST_IDX_OFF));
    const len = try self.newTemp();
    try self.qbeLoadL(len, try addr(self, obj, abi_layout.DICT_ENTRIES_OFF + 8));
    const inr = try self.newTemp();
    try self.qbeOp2(inr, .w, "cultl", li, len);
    try self.qbeJnz(inr, chk2, slow);

    try self.qbeLabel(chk2);
    const base = try self.newTemp();
    try self.qbeLoadL(base, try addr(self, obj, abi_layout.DICT_ENTRIES_OFF));
    const off = try self.newTemp();
    try self.qbeOp2Imm(off, .l, "shl", li, 4); // DICT_ENTRY_SIZE == 16
    const e = try self.newTemp();
    try self.qbeOp2(e, .l, "add", base, off);
    const k = try self.newTemp();
    try self.qbeLoadL(k, e);
    const eq = try self.newTemp();
    try self.qbeOp2(eq, .w, "ceql", k, key);
    try self.qbeJnz(eq, hit, slow);
    return .{ .hit = hit, .slow = slow, .entry = e };
}

/// `d.contains(k)` / `k in d`: isabette `1`, aksi halde `nox_dict_contains` çağrısı. Sonuç `.w` `dst`.
/// wasm32 hedeflerinde işaretçi/dilim genişliği 4 bayttır (Dict düzeni farklı): satır içi yoklama yalnızca 64-bit hedeflerde üretilir.
fn enabled(self: *const Codegen) bool {
    return !self.isWasmTarget();
}

pub fn contains(self: *Codegen, dst: []const u8, obj: []const u8, key_is_str_lit: []const u8, key: []const u8) CodegenError!void {
    if (!enabled(self)) {
        try self.qbeCall(.{ .name = dst, .ty = .w }, "$nox_dict_contains", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key } });
        return;
    }
    const pr = try probe(self, obj, key);
    const done = try self.newLabel("dict_done");
    try self.qbeLabel(pr.hit);
    try self.qbeJmp(done);
    try self.qbeLabel(pr.slow);
    const slow_v = try self.newTemp();
    try self.qbeCall(.{ .name = slow_v, .ty = .w }, "$nox_dict_contains", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key } });
    try self.qbeJmp(done);
    try self.qbeLabel(done);
    try self.qbePhi(dst, .w, pr.hit, "1", pr.slow, slow_v);
}

/// `d[k]` okuması (anahtarın var olduğu zaten doğrulanmış): isabette `entries[last_idx].value`, aksi halde `nox_dict_get`. Sonuç `.l` `dst`.
pub fn get(self: *Codegen, dst: []const u8, obj: []const u8, key_is_str_lit: []const u8, key: []const u8) CodegenError!void {
    if (!enabled(self)) {
        try self.qbeCall(.{ .name = dst, .ty = .l }, "$nox_dict_get", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key } });
        return;
    }
    const pr = try probe(self, obj, key);
    const done = try self.newLabel("dict_done");
    try self.qbeLabel(pr.hit);
    const vaddr = try addr(self, pr.entry, abi_layout.DICT_ENTRY_VALUE_OFF);
    const hit_v = try self.newTemp();
    try self.qbeLoadL(hit_v, vaddr);
    try self.qbeJmp(done);
    try self.qbeLabel(pr.slow);
    const slow_v = try self.newTemp();
    try self.qbeCall(.{ .name = slow_v, .ty = .l }, "$nox_dict_get", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj }, .{ .ty = .w, .text = key_is_str_lit }, .{ .ty = .l, .text = key } });
    try self.qbeJmp(done);
    try self.qbeLabel(done);
    try self.qbePhi(dst, .l, pr.hit, hit_v, pr.slow, slow_v);
}

/// `d[k] = v` (anahtar ve değer skaler: ARC/`str` serbest bırakma yok): isabette değeri yerinde günceller, aksi halde `nox_dict_set`.
pub fn setScalar(self: *Codegen, obj: []const u8, key: []const u8, value: []const u8) CodegenError!void {
    if (!enabled(self)) {
        try self.qbeCall(null, "$nox_dict_set", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj }, .{ .ty = .w, .text = "0" }, .{ .ty = .w, .text = "0" }, .{ .ty = .w, .text = "0" }, .{ .ty = .l, .text = key }, .{ .ty = .l, .text = value } });
        return;
    }
    const pr = try probe(self, obj, key);
    const done = try self.newLabel("dict_done");
    try self.qbeLabel(pr.hit);
    try self.qbeStoreL(value, try addr(self, pr.entry, abi_layout.DICT_ENTRY_VALUE_OFF));
    try self.qbeJmp(done);
    try self.qbeLabel(pr.slow);
    try self.qbeCall(null, "$nox_dict_set", &.{ .{ .ty = .l, .text = RT_PARAM }, .{ .ty = .l, .text = obj }, .{ .ty = .w, .text = "0" }, .{ .ty = .w, .text = "0" }, .{ .ty = .w, .text = "0" }, .{ .ty = .l, .text = key }, .{ .ty = .l, .text = value } });
    try self.qbeJmp(done);
    try self.qbeLabel(done);
}
