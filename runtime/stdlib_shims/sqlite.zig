//! `nox.sqlite` Zig kabuğu — bkz. plan dosyası "nox.sqlite — libsqlite3'e
//! `extern def` ile bağlanan bir SQLite sürücüsü".
//!
//! **Bulundu (GERÇEK bir regresyon, testler SIRASINDA yakalandı) — bu
//! dosyanın ARTIK dinamik yükleme (`std.DynLib`, `dlopen`/`dlsym`)
//! KULLANMASININ NEDENİ:** İLK sürüm `sqlite3_*` C fonksiyonlarını
//! `extern "c" fn` İLE STATİK olarak bildiriyordu — bu, `noxrt.o`nun
//! (HER Nox programına KOŞULSUZ bağlanan TEK runtime nesnesi) İÇİNDE
//! ÇÖZÜLMEMİŞ `sqlite3_*` sembolleri BIRAKTI. Sonuç: `libsqlite3`
//! KULLANMAYAN (ör. `print("merhaba")`den İBARET) HERHANGİ bir Nox
//! programı `cc` bağlama AŞAMASINDA "symbol(s) not found" İLE
//! BAŞARISIZ olmaya BAŞLADI (GERÇEKTEN gözlemlendi) — bu, planın KENDİ
//! "sqlite KULLANMAYAN hiçbir Nox programı YENİ bir sistem bağımlılığı
//! KAZANMAZ" ilkesini AÇIKÇA BOZDU. Çözüm: `libsqlite3`yi (İLK
//! `nox.sqlite` çağrısında, TEMBEL/lazy) `std.DynLib.open` İLE ÇALIŞMA
//! ZAMANINDA yükleyip HER fonksiyonu `dlsym` (`DynLib.lookup`) İLE
//! ÇÖZMEK — `noxrt.o`nun KENDİSİ ARTIK `sqlite3_*`e dair HİÇBİR bağlama-
//! zamanı referansı TAŞIMAZ, bu YÜZDEN `stdlib/nox/sqlite.nox`nin KENDİSİ
//! de ARTIK `from "sqlite3"` extern def'i İÇERMEZ (TÜM sqlite erişimi
//! BU dosyanın `nox_sqlite_*_raw` sarmalayıcılarından geçer) — `-lsqlite3`
//! ARTIK HİÇBİR Nox programının `cc` bağlama komutuna EKLENMEZ, `libsqlite3`
//! yalnızca `nox.sqlite`yi GERÇEKTEN KULLANAN bir programın ÇALIŞMA
//! ZAMANINDA (İLK çağrıda) yüklenir — kütüphane KURULU DEĞİLSE, o programın
//! `nox.sqlite.open()`ı temiz bir `SqliteError` fırlatır (çökme YOK),
//! sqlite KULLANMAYAN HERHANGİ bir program ETKİLENMEZ.

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");

fn libraryFileName() [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => "libsqlite3.dylib",
        .windows => "sqlite3.dll",
        else => "libsqlite3.so.0",
    };
}

/// Bulundu (GERÇEK bir platform hatası, `windows-x64` release CI'sinde
/// YAKALANDI — bkz. nox-teknik-spesifikasyon.md): Zig 0.16'nın `std.
/// DynLib`i Windows İçin HİÇBİR implementasyon TAŞIMAZ (bkz. std kaynağı
/// `dynamic_library.zig`, `switch (native_os)`in `else` dalı BİLİNÇLİ bir
/// `@compileError("unsupported platform")`dır — geçici bir eksiklik
/// DEĞİL, bu Zig sürümünün KENDİ tasarım kararı). Bu, `noxrt.o`nun
/// (HER Nox programına koşulsuz bağlı) Windows'ta HİÇ DERLENEMEMESİNE
/// yol açan bir regresyondu — `crypto.zig`nin `SystemFunction036`/
/// `advapi32` özel-durumuyla AYNI desen İZLENİR: Windows'ta `std.DynLib`
/// YERİNE `kernel32.dll`nin KENDİ `LoadLibraryA`/`GetProcAddress`si
/// DOĞRUDAN kullanılır (ASCII kütüphane/sembol adları YETERLİ, geniş
/// karakter dönüşümüne GEREK YOK).
const Kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {};

/// Windows'ta ham bir kütüphane handle'ı (`kernel32.LoadLibraryA`nın
/// döndürdüğü); diğer TÜM platformlarda (`std.DynLib`nin GERÇEKTEN
/// desteklediği macOS/Linux/BSD) olağan `std.DynLib`. `ensureLoaded`/
/// `loadAll` bu ikisini TEK bir kod yolunda BİRLEŞTİRİR (`openLib`/
/// `lookupSym` yardımcıları ÜZERİNDEN) — geri kalan TÜM `nox_sqlite_*_raw`
/// dışa aktarımları bu platform farkından TAMAMEN İZOLE KALIR.
const LibHandle = if (builtin.os.tag == .windows) ?*anyopaque else std.DynLib;

fn openLib() ?LibHandle {
    if (builtin.os.tag == .windows) {
        return Kernel32.LoadLibraryA(libraryFileName());
    }
    return std.DynLib.open(libraryFileName()) catch null;
}

fn lookupSym(lib: *LibHandle, comptime T: type, name: [:0]const u8) ?T {
    if (builtin.os.tag == .windows) {
        const handle = lib.* orelse return null;
        const addr = Kernel32.GetProcAddress(handle, name) orelse return null;
        return @ptrCast(addr);
    }
    return lib.lookup(T, name);
}

const OpenFn = *const fn (filename: [*:0]const u8, ppDb: *?*anyopaque) callconv(.c) c_int;
const CloseFn = *const fn (db: ?*anyopaque) callconv(.c) c_int;
const ErrmsgFn = *const fn (db: ?*anyopaque) callconv(.c) ?[*:0]const u8;
const PrepareFn = *const fn (db: ?*anyopaque, sql: [*:0]const u8, nbyte: c_int, ppStmt: *?*anyopaque, pzTail: ?*?[*:0]const u8) callconv(.c) c_int;
const StepFn = *const fn (stmt: ?*anyopaque) callconv(.c) c_int;
const FinalizeFn = *const fn (stmt: ?*anyopaque) callconv(.c) c_int;
const ColumnCountFn = *const fn (stmt: ?*anyopaque) callconv(.c) c_int;
const ColumnTypeFn = *const fn (stmt: ?*anyopaque, i: c_int) callconv(.c) c_int;
const ColumnTextFn = *const fn (stmt: ?*anyopaque, i: c_int) callconv(.c) ?[*:0]const u8;
const ColumnNameFn = *const fn (stmt: ?*anyopaque, i: c_int) callconv(.c) ?[*:0]const u8;
const BindInt64Fn = *const fn (stmt: ?*anyopaque, idx: c_int, val: i64) callconv(.c) c_int;
const BindDoubleFn = *const fn (stmt: ?*anyopaque, idx: c_int, val: f64) callconv(.c) c_int;
const BindTextFn = *const fn (stmt: ?*anyopaque, idx: c_int, text: [*:0]const u8, nbyte: c_int, destructor: ?*const anyopaque) callconv(.c) c_int;
const BindNullFn = *const fn (stmt: ?*anyopaque, idx: c_int) callconv(.c) c_int;
const ChangesFn = *const fn (db: ?*anyopaque) callconv(.c) c_int;
const LastInsertRowidFn = *const fn (db: ?*anyopaque) callconv(.c) i64;

const Funcs = struct {
    open: OpenFn,
    close: CloseFn,
    errmsg: ErrmsgFn,
    prepare_v2: PrepareFn,
    step: StepFn,
    finalize: FinalizeFn,
    column_count: ColumnCountFn,
    column_type: ColumnTypeFn,
    column_text: ColumnTextFn,
    column_name: ColumnNameFn,
    bind_int64: BindInt64Fn,
    bind_double: BindDoubleFn,
    bind_text: BindTextFn,
    bind_null: BindNullFn,
    changes: ChangesFn,
    last_insert_rowid: LastInsertRowidFn,
};

/// `http_client.zig`nin `sharedClientIo`sıyla AYNI atomik durum-makinesi
/// deseni (bkz. onun belge notu) — çok sayıda fiber/iş parçacığı AYNI ANDA
/// İLK `nox.sqlite` çağrısını yaparsa, YALNIZCA biri GERÇEKTEN yüklesin,
/// diğerleri BEKLESİN.
const LoadState = enum(u8) { uninit, initializing, ready, failed };
var g_state: std.atomic.Value(LoadState) = .init(.uninit);
var g_lib: LibHandle = undefined;
var g_funcs: Funcs = undefined;

fn loadAll() bool {
    var lib = openLib() orelse return false;
    const open_fn = lookupSym(&lib, OpenFn, "sqlite3_open") orelse return false;
    const close_fn = lookupSym(&lib, CloseFn, "sqlite3_close") orelse return false;
    const errmsg_fn = lookupSym(&lib, ErrmsgFn, "sqlite3_errmsg") orelse return false;
    const prepare_fn = lookupSym(&lib, PrepareFn, "sqlite3_prepare_v2") orelse return false;
    const step_fn = lookupSym(&lib, StepFn, "sqlite3_step") orelse return false;
    const finalize_fn = lookupSym(&lib, FinalizeFn, "sqlite3_finalize") orelse return false;
    const column_count_fn = lookupSym(&lib, ColumnCountFn, "sqlite3_column_count") orelse return false;
    const column_type_fn = lookupSym(&lib, ColumnTypeFn, "sqlite3_column_type") orelse return false;
    const column_text_fn = lookupSym(&lib, ColumnTextFn, "sqlite3_column_text") orelse return false;
    const column_name_fn = lookupSym(&lib, ColumnNameFn, "sqlite3_column_name") orelse return false;
    const bind_int64_fn = lookupSym(&lib, BindInt64Fn, "sqlite3_bind_int64") orelse return false;
    const bind_double_fn = lookupSym(&lib, BindDoubleFn, "sqlite3_bind_double") orelse return false;
    const bind_text_fn = lookupSym(&lib, BindTextFn, "sqlite3_bind_text") orelse return false;
    const bind_null_fn = lookupSym(&lib, BindNullFn, "sqlite3_bind_null") orelse return false;
    const changes_fn = lookupSym(&lib, ChangesFn, "sqlite3_changes") orelse return false;
    const last_insert_rowid_fn = lookupSym(&lib, LastInsertRowidFn, "sqlite3_last_insert_rowid") orelse return false;

    g_lib = lib;
    g_funcs = .{
        .open = open_fn,
        .close = close_fn,
        .errmsg = errmsg_fn,
        .prepare_v2 = prepare_fn,
        .step = step_fn,
        .finalize = finalize_fn,
        .column_count = column_count_fn,
        .column_type = column_type_fn,
        .column_text = column_text_fn,
        .column_name = column_name_fn,
        .bind_int64 = bind_int64_fn,
        .bind_double = bind_double_fn,
        .bind_text = bind_text_fn,
        .bind_null = bind_null_fn,
        .changes = changes_fn,
        .last_insert_rowid = last_insert_rowid_fn,
    };
    return true;
}

/// `true` dönerse `g_funcs` KULLANIMA HAZIRDIR. `false` dönerse (kütüphane
/// KURULU DEĞİL VEYA beklenmeyen bir ABI'ye sahip) ÇAĞIRAN taraf (HER
/// `nox_sqlite_*_raw` fonksiyonu) `null`/`0` gibi bir başarısızlık
/// sentinel'i döner — `.nox` tarafı (`open()`) bunu `SqliteError` OLARAK
/// TEMİZ bir şekilde fırlatır, ÇÖKME YOK.
fn ensureLoaded() bool {
    if (g_state.cmpxchgStrong(.uninit, .initializing, .acquire, .monotonic) == null) {
        g_state.store(if (loadAll()) .ready else .failed, .release);
    } else {
        while (true) {
            const s = g_state.load(.acquire);
            if (s == .ready or s == .failed) break;
            std.Thread.yield() catch {};
        }
    }
    return g_state.load(.acquire) == .ready;
}

fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    const raw = arc.nox_rc_alloc(rt, bytes.len + 1) orelse return null;
    const out: [*]u8 = @ptrCast(raw);
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0;
    return @ptrCast(out);
}

fn dupeEmpty(rt: ?*anyopaque) ?[*:0]u8 {
    return dupeToNoxStr(rt, "");
}

/// `SQLITE_TRANSIENT` — bkz. ÖNCEKİ sürümün AYNI belge notu (`((sqlite3_
/// destructor_type)-1)`, SQLite'ın KENDİ "verdiğim metnin kopyasını çıkar"
/// makrosu).
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub export fn nox_sqlite_open_raw(path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const p = path orelse return null;
    if (!ensureLoaded()) return null;
    var db: ?*anyopaque = null;
    _ = g_funcs.open(p, &db);
    return db;
}

pub export fn nox_sqlite_errmsg_raw(rt: ?*anyopaque, db: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeToNoxStr(rt, "libsqlite3 yuklenemedi (sistemde kurulu degil olabilir)");
    const msg = g_funcs.errmsg(db) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(msg));
}

pub export fn nox_sqlite_prepare_raw(db: ?*anyopaque, sql: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s = sql orelse return null;
    if (!ensureLoaded()) return null;
    var stmt: ?*anyopaque = null;
    _ = g_funcs.prepare_v2(db, s, -1, &stmt, null);
    return stmt;
}

pub export fn nox_sqlite_step_raw(stmt: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 1; // SQLITE_ERROR
    return g_funcs.step(stmt);
}

pub export fn nox_sqlite_finalize_raw(stmt: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 1;
    return g_funcs.finalize(stmt);
}

pub export fn nox_sqlite_close_raw(db: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 1;
    return g_funcs.close(db);
}

pub export fn nox_sqlite_column_count_raw(stmt: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return g_funcs.column_count(stmt);
}

pub export fn nox_sqlite_column_type_raw(stmt: ?*anyopaque, i: i64) callconv(.c) i64 {
    if (!ensureLoaded()) return 5; // SQLITE_NULL
    return g_funcs.column_type(stmt, @intCast(i));
}

pub export fn nox_sqlite_bind_int_raw(stmt: ?*anyopaque, idx: i64, val: i64) callconv(.c) i64 {
    if (!ensureLoaded()) return 1;
    return g_funcs.bind_int64(stmt, @intCast(idx), val);
}

pub export fn nox_sqlite_bind_double_raw(stmt: ?*anyopaque, idx: i64, val: f64) callconv(.c) i64 {
    if (!ensureLoaded()) return 1;
    return g_funcs.bind_double(stmt, @intCast(idx), val);
}

pub export fn nox_sqlite_bind_text_raw(stmt: ?*anyopaque, idx: i64, value: ?[*:0]const u8) callconv(.c) i64 {
    if (!ensureLoaded()) return 1;
    const v = value orelse "";
    return g_funcs.bind_text(stmt, @intCast(idx), v, -1, SQLITE_TRANSIENT);
}

pub export fn nox_sqlite_bind_null_raw(stmt: ?*anyopaque, idx: i64) callconv(.c) i64 {
    if (!ensureLoaded()) return 1;
    return g_funcs.bind_null(stmt, @intCast(idx));
}

pub export fn nox_sqlite_changes_raw(db: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return g_funcs.changes(db);
}

pub export fn nox_sqlite_last_insert_rowid_raw(db: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return g_funcs.last_insert_rowid(db);
}

pub export fn nox_sqlite_column_text_raw(rt: ?*anyopaque, stmt: ?*anyopaque, i: i64) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeEmpty(rt);
    const txt = g_funcs.column_text(stmt, @intCast(i)) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(txt));
}

pub export fn nox_sqlite_column_name_raw(rt: ?*anyopaque, stmt: ?*anyopaque, i: i64) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeEmpty(rt);
    const name = g_funcs.column_name(stmt, @intCast(i)) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(name));
}

/// Bulundu (bkz. plan dosyası): `ptr` yalnızca AYNI tip VEYA sayısal
/// tiplerle karşılaştırılabilir — `handle == 0` TİP HATASI verir.
pub export fn nox_sqlite_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
