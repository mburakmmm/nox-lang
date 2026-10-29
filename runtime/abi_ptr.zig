//! wasm32 ABI köprüsü (Faz 10): Nox'un derlenmiş kodu HER yerde 64-bit tamsayı (`i64`) kullanır — işaretçiler dahil. Runtime'ın dışa açtığı
//! (`export fn`) imzalardaki işaretçi parametreleri wasm32'de `i32` olur; bu fark çağrı noktasında (derleyici, bkz. `compiler/codegen_qbe/wasm_abi.zig`)
//! daraltılarak/genişletilerek giderilir. Ama derlenmiş KODUN adresini runtime'a GERİ-ÇAĞRI olarak verdiği yerlerde (`$Sınıf_release`, dispatch tabloları,
//! kapanışlar, görev girişleri) fonksiyon işaretçisinin imzası derlenmiş fonksiyonunkidir: işaretçi parametreleri `i64`. Bu tür geri-çağrı tiplerinde işaretçi
//! parametresi `Arg` ile yazılır: 64-bit hedeflerde AYNI `?*anyopaque` (hiçbir şey değişmez), wasm32'de `u64`.

const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch.isWasm();

pub const Arg = if (is_wasm) u64 else ?*anyopaque;

/// İşaretçiyi geri-çağrı argümanına çevirir.
pub inline fn arg(p: anytype) Arg {
    if (comptime is_wasm) return @as(u64, @intFromPtr(p));
    return @ptrCast(@constCast(p));
}

/// Geri-çağrı argümanını (ya da geri-çağrıdan dönen değeri) işaretçiye çevirir.
pub inline fn ptr(comptime T: type, a: Arg) T {
    if (comptime is_wasm) return @ptrFromInt(@as(usize, @intCast(a)));
    return @ptrCast(@alignCast(a));
}

/// Derlenmiş kodun yazdığı/okuduğu 8 baytlık işaretçi yuvası (kapanış başlıkları, iz arabelleği çocukları, global yuvaları): wasm32'de işaretçi 4 bayttır ama
/// Nox nesnelerinin yuvası HER ZAMAN 8 bayttır (`FIELD_SLOT_SIZE`), bu yüzden yuva `u64` olarak okunur/yazılır.
pub const Slot = if (is_wasm) u64 else ?*anyopaque;

pub inline fn slot(p: anytype) Slot {
    return arg(p);
}

pub inline fn slotPtr(s: Slot) ?*anyopaque {
    return ptr(?*anyopaque, s);
}

/// `ClassNameFn`in döndürdüğü C dizesi (wasm32'de `u64` olarak döner).
pub inline fn cstr(r: if (is_wasm) u64 else [*:0]const u8) [*:0]const u8 {
    if (comptime is_wasm) return @ptrFromInt(@as(usize, @intCast(r)));
    return r;
}
