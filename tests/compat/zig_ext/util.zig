//! Nox'un `extern def` (C ABI FFI) uyumluluk testi için GERÇEK, minimal bir
//! Zig dosyası (bkz. nox-teknik-spesifikasyon.md §3.20). `zig build-obj` ile
//! sıradan bir nesne dosyasına derlenir — `export fn ... callconv(.c)`
//! DIŞINDA hiçbir özel gereksinim yok; Nox'un bakış açısından bu, bir C
//! kütüphanesinden (bkz. `tests/compat/c_ext/mathutil.c`) AYIRT EDİLEMEZ —
//! AYNI `extern def` mekanizmasıyla bağlanır ("tek bir mekanizma" iddiasının
//! kanıtı).

export fn triple(x: i64) callconv(.c) i64 {
    return x * 3;
}

const std = @import("std");

/// `noxrt.o`nun `nox_rc_alloc`ı (bkz. `runtime/alloc/arc.zig`) — AYRI
/// derlenmiş bu nesne dosyası, DAHA SONRA `noxrt.o` İLE AYNI ikiliye
/// bağlandığından (bkz. `extern_ffi_test.zig`'in `compileAndRun`ı) bunu
/// sıradan bir harici C sembolü olarak GÖREBİLİR — `nox.http`in (D.1)
/// GERÇEK kabuğunun `rt` üzerinden ARC tahsisi yapacağı YÖNTEMİN AYNISI.
extern fn nox_rc_alloc(rt: ?*anyopaque, payload_size: usize) callconv(.c) ?*anyopaque;

/// `with_rt` (bkz. nox-teknik-spesifikasyon.md, stdlib fazı §D.1, Keşif 3)
/// doğrulama testi: `rt` üzerinden GERÇEKTEN bir ARC-yönetimli `str` tahsis
/// edip döner — Nox tarafının bunu (özellikle `nox_str_release` ile) doğru
/// serbest bırakabildiğini (sızıntı yok, DebugAllocator doğrular) kanıtlar.
export fn nox_test_make_greeting(rt: ?*anyopaque, name: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const n = name orelse return null;
    const prefix = "merhaba, ";
    const name_len = std.mem.len(n);
    const total = prefix.len + name_len;
    const raw = nox_rc_alloc(rt, total + 1) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @memcpy(bytes[0..prefix.len], prefix);
    @memcpy(bytes[prefix.len..][0..name_len], n[0..name_len]);
    bytes[total] = 0;
    return @ptrCast(bytes);
}

/// `noxrt.o`nun `nox_dict_get`i (bkz. `runtime/collections/dict.zig`) —
/// `pub export fn` olduğundan (stdlib fazı §D.1, Keşif 4) buradan da
/// sıradan bir harici C sembolü olarak çağrılabilir.
extern fn nox_dict_get(rt: ?*anyopaque, dp: ?*anyopaque, key_is_str: i32, key: i64) callconv(.c) i64;
extern fn nox_rc_retain(ptr: ?*anyopaque) callconv(.c) void;

/// `dict[str, str]` FFI-güvenli hale getirmesinin (bkz. nox-teknik-
/// spesifikasyon.md, stdlib fazı §D.1, Keşif 4) doğrulama testi: bir
/// dict handle'ını (opak `ptr`, Nox tarafından `extern def`e DOĞRUDAN
/// argüman olarak geçirilir) alıp bir anahtarın değerini okur. `nox_dict_get`in
/// dönüşü BORROWED'dır (dict kendi referansını korur) — burada Nox'a YENİ
/// bir sahiplik devretmek için `nox_rc_retain` ile AÇIKÇA retain edilir
/// (aksi halde `print`in bu sonucu serbest bırakması dict'in KENDİ
/// referansını da geçersiz kılardı — çift serbest bırakma).
export fn nox_test_dict_lookup(rt: ?*anyopaque, d: ?*anyopaque, key: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const k = key orelse return null;
    const payload: i64 = @bitCast(@as(isize, @intCast(@intFromPtr(k))));
    const value_payload = nox_dict_get(rt, d, 1, payload);
    if (value_payload == 0) return null;
    const ptr: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(value_payload)));
    nox_rc_retain(ptr);
    return @ptrCast(ptr);
}

/// Stdlib fazı §F: `list[str]` DÖNÜŞ tipi FFI-güvenli sayılmasının (bkz.
/// `checker.zig`'in `isFfiSafeListReturnType`ı) doğrulama testi — `n`
/// elemanlı ("item_0".."item_{n-1}") ARC'lı bir `list[str]` payload'ını
/// EL İLE, `genListLit`in QBE ÇIKTISIYLA AYNI bayt düzeninde (Faz U.1'den
/// beri: 8 bayt uzunluk + 8 bayt kapasite başlığı + `n` adet 8 baytlık
/// `str` işaretçisi, `nox_rc_alloc` üzerinden — bkz. codegen_qbe/codegen.zig
/// `LIST_HEADER_SIZE`in belge notu) inşa edip döner — Nox tarafının bunu
/// (özellikle `len`/indeksleme/ARC serbest bırakma) DOĞRU işleyebildiğini
/// kanıtlar. Kapasite HER ZAMAN uzunluğa eşittir (tam-oturan).
export fn nox_test_make_list(rt: ?*anyopaque, n: i64) callconv(.c) ?*anyopaque {
    if (n < 0) return null;
    const count: usize = @intCast(n);
    const elem_size: usize = 8;
    const header_size: usize = 16;
    const payload_size = header_size + elem_size * count;
    const raw = nox_rc_alloc(rt, payload_size) orelse return null;
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(count);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(count);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "item_{d}", .{i}) catch return null;
        const item_raw = nox_rc_alloc(rt, s.len + 1) orelse return null;
        const item_bytes: [*]u8 = @ptrCast(item_raw);
        @memcpy(item_bytes[0..s.len], s);
        item_bytes[s.len] = 0;
        const slot_addr = bytes + header_size + elem_size * i;
        @as(*align(1) i64, @ptrCast(slot_addr)).* = @intCast(@intFromPtr(item_bytes));
    }
    return @ptrCast(bytes);
}
