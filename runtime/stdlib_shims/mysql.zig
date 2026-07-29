//! `nox.mysql` Zig kabuğu — `sqlite.zig`/`postgres.zig`nin BİREBİR AYNI
//! şablonu (bkz. proje belleği "4 yeni stdlib modülü" planı): `libmysqlclient`
//! (ya da ikili-uyumlu MariaDB connector'ü) İLK `nox.mysql` çağrısında
//! TEMBEL yüklenir — `noxrt.o` HİÇBİR `mysql_*` bağlama-zamanı referansı
//! TAŞIMAZ, kütüphane KURULU DEĞİLSE `nox.mysql` KULLANMAYAN bir program
//! ETKİLENMEZ.
//!
//! `mysql_real_connect`, Postgres'in `PQconnectdb`sinin AKSİNE bir URI
//! DEĞİL, AYRI parametreler (host/user/passwd/db/port) İSTER — bu YÜZDEN
//! `nox.mysql.open_url`, `mysql://user:pass@host:port/db` biçimini
//! `nox.url.parse` İLE ayrıştırıp BU parçaları ÇIKARIR (bkz. `stdlib/nox/
//! mysql.nox`), ham dizeyi DOĞRUDAN iletemez.
//!
//! **MYSQL_FIELD struct erişimi hakkında not**: `.name` alanı (sütun adı),
//! `MYSQL_FIELD` struct'ının TAM Zig karşılığını tanımlamak YERİNE, İLK
//! ÜYESİ olarak (ham bir işaretçi-boyu OFSET İLE) okunur — bu, MySQL C
//! API'sinin `mysql.h`sinde ONLARCA YILDIR (3.x'ten beri) DEĞİŞMEYEN,
//! iyi-bilinen bir ABI düzenidir (birçok dil bağlayıcısının KULLANDIĞI
//! AYNI teknik) — TAM struct'ı tanımlamaktan DAHA AZ kırılgan, çünkü
//! yalnızca TEK bir alanın (İLK üye) konumuna bağımlıdır.

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");

fn libraryFileName() [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => "libmysqlclient.dylib",
        .windows => "libmysql.dll",
        else => "libmysqlclient.so.21",
    };
}

const Kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
} else struct {};

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

const InitFn = *const fn (mysql: ?*anyopaque) callconv(.c) ?*anyopaque;
const RealConnectFn = *const fn (
    mysql: ?*anyopaque,
    host: ?[*:0]const u8,
    user: ?[*:0]const u8,
    passwd: ?[*:0]const u8,
    db: ?[*:0]const u8,
    port: c_uint,
    unix_socket: ?[*:0]const u8,
    client_flag: c_ulong,
) callconv(.c) ?*anyopaque;
const CloseFn = *const fn (mysql: ?*anyopaque) callconv(.c) void;
const ErrorFn = *const fn (mysql: ?*anyopaque) callconv(.c) ?[*:0]const u8;
const QueryFn = *const fn (mysql: ?*anyopaque, stmt_str: [*:0]const u8) callconv(.c) c_int;
const FieldCountFn = *const fn (mysql: ?*anyopaque) callconv(.c) c_uint;
const AffectedRowsFn = *const fn (mysql: ?*anyopaque) callconv(.c) u64;
const StoreResultFn = *const fn (mysql: ?*anyopaque) callconv(.c) ?*anyopaque;
const NumRowsFn = *const fn (res: ?*anyopaque) callconv(.c) u64;
const NumFieldsFn = *const fn (res: ?*anyopaque) callconv(.c) c_uint;
const FetchRowFn = *const fn (res: ?*anyopaque) callconv(.c) ?[*]const ?[*:0]const u8;
const FetchFieldDirectFn = *const fn (res: ?*anyopaque, fieldnr: c_uint) callconv(.c) ?*anyopaque;
const FreeResultFn = *const fn (res: ?*anyopaque) callconv(.c) void;
const InsertIdFn = *const fn (mysql: ?*anyopaque) callconv(.c) u64;
/// `unsigned long mysql_real_escape_string(MYSQL*, char *to, const char
/// *from, unsigned long length)` — `to` en az `length*2+1` bayt OLMALI
/// (libmysqlclient'ın KENDİ sözleşmesi, HER bayt en KÖTÜ durumda 2 bayta
/// kaçabilir + sonlandırıcı NUL).
const RealEscapeStringFn = *const fn (mysql: ?*anyopaque, to: [*]u8, from: [*]const u8, length: c_ulong) callconv(.c) c_ulong;

const Funcs = struct {
    init: InitFn,
    real_connect: RealConnectFn,
    close: CloseFn,
    err: ErrorFn,
    query: QueryFn,
    field_count: FieldCountFn,
    affected_rows: AffectedRowsFn,
    store_result: StoreResultFn,
    num_rows: NumRowsFn,
    num_fields: NumFieldsFn,
    fetch_row: FetchRowFn,
    fetch_field_direct: FetchFieldDirectFn,
    free_result: FreeResultFn,
    insert_id: InsertIdFn,
    real_escape_string: RealEscapeStringFn,
};

const LoadState = enum(u8) { uninit, initializing, ready, failed };
var g_state: std.atomic.Value(LoadState) = .init(.uninit);
var g_lib: LibHandle = undefined;
var g_funcs: Funcs = undefined;

fn loadAll() bool {
    var lib = openLib() orelse return false;
    const init_fn = lookupSym(&lib, InitFn, "mysql_init") orelse return false;
    const real_connect_fn = lookupSym(&lib, RealConnectFn, "mysql_real_connect") orelse return false;
    const close_fn = lookupSym(&lib, CloseFn, "mysql_close") orelse return false;
    const err_fn = lookupSym(&lib, ErrorFn, "mysql_error") orelse return false;
    const query_fn = lookupSym(&lib, QueryFn, "mysql_query") orelse return false;
    const field_count_fn = lookupSym(&lib, FieldCountFn, "mysql_field_count") orelse return false;
    const affected_rows_fn = lookupSym(&lib, AffectedRowsFn, "mysql_affected_rows") orelse return false;
    const store_result_fn = lookupSym(&lib, StoreResultFn, "mysql_store_result") orelse return false;
    const num_rows_fn = lookupSym(&lib, NumRowsFn, "mysql_num_rows") orelse return false;
    const num_fields_fn = lookupSym(&lib, NumFieldsFn, "mysql_num_fields") orelse return false;
    const fetch_row_fn = lookupSym(&lib, FetchRowFn, "mysql_fetch_row") orelse return false;
    const fetch_field_direct_fn = lookupSym(&lib, FetchFieldDirectFn, "mysql_fetch_field_direct") orelse return false;
    const free_result_fn = lookupSym(&lib, FreeResultFn, "mysql_free_result") orelse return false;
    const insert_id_fn = lookupSym(&lib, InsertIdFn, "mysql_insert_id") orelse return false;
    const real_escape_string_fn = lookupSym(&lib, RealEscapeStringFn, "mysql_real_escape_string") orelse return false;

    g_lib = lib;
    g_funcs = .{
        .init = init_fn,
        .real_connect = real_connect_fn,
        .close = close_fn,
        .err = err_fn,
        .query = query_fn,
        .field_count = field_count_fn,
        .affected_rows = affected_rows_fn,
        .store_result = store_result_fn,
        .num_rows = num_rows_fn,
        .num_fields = num_fields_fn,
        .fetch_row = fetch_row_fn,
        .fetch_field_direct = fetch_field_direct_fn,
        .free_result = free_result_fn,
        .insert_id = insert_id_fn,
        .real_escape_string = real_escape_string_fn,
    };
    return true;
}

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
    return str_mod.nox_str_from_bytes(rt, bytes);
}

fn dupeEmpty(rt: ?*anyopaque) ?[*:0]u8 {
    return dupeToNoxStr(rt, "");
}

/// `MYSQL_FIELD.name` — bkz. dosya başlığının belge notu (İLK üye,
/// ham işaretçi-boyu ofset İLE OKUNUR).
fn fieldName(field_ptr: ?*anyopaque) ?[*:0]const u8 {
    const p = field_ptr orelse return null;
    const name_ptr: *align(1) const ?[*:0]const u8 = @ptrCast(p);
    return name_ptr.*;
}

pub export fn nox_mysql_connect_raw(
    host: ?[*:0]const u8,
    user: ?[*:0]const u8,
    passwd: ?[*:0]const u8,
    db: ?[*:0]const u8,
    port: i64,
) callconv(.c) ?*anyopaque {
    if (!ensureLoaded()) return null;
    const conn = g_funcs.init(null) orelse return null;
    const result = g_funcs.real_connect(conn, host, user, passwd, db, @intCast(port), null, 0);
    if (result == null) {
        // Bağlantı BAŞARISIZ — `.nox` tarafı `status_ok_raw`/`errmsg_raw`i
        // OKUYUP SONRA `close()`u ÇAĞIRIR (sqlite/postgres'in AYNI "başarısız
        // handle'ı yine de temizle" deseni).
        return conn;
    }
    return conn;
}

pub export fn nox_mysql_status_ok_raw(conn: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    const msg = g_funcs.err(conn) orelse return 1;
    return if (std.mem.len(msg) == 0) 1 else 0;
}

pub export fn nox_mysql_errmsg_raw(rt: ?*anyopaque, conn: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeToNoxStr(rt, "libmysqlclient yuklenemedi (sistemde kurulu degil olabilir)");
    const msg = g_funcs.err(conn) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(msg));
}

pub export fn nox_mysql_close_raw(conn: ?*anyopaque) callconv(.c) void {
    if (!ensureLoaded()) return;
    g_funcs.close(conn);
}

pub export fn nox_mysql_query_raw(conn: ?*anyopaque, stmt_str: ?[*:0]const u8) callconv(.c) i64 {
    const s = stmt_str orelse return 1;
    if (!ensureLoaded()) return 1;
    return g_funcs.query(conn, s);
}

pub export fn nox_mysql_field_count_raw(conn: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return g_funcs.field_count(conn);
}

pub export fn nox_mysql_affected_rows_raw(conn: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return @intCast(g_funcs.affected_rows(conn));
}

pub export fn nox_mysql_store_result_raw(conn: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (!ensureLoaded()) return null;
    return g_funcs.store_result(conn);
}

pub export fn nox_mysql_num_fields_raw(res: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return g_funcs.num_fields(res);
}

pub export fn nox_mysql_fname_raw(rt: ?*anyopaque, res: ?*anyopaque, col: i64) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeEmpty(rt);
    const field = g_funcs.fetch_field_direct(res, @intCast(col)) orelse return dupeEmpty(rt);
    const name = fieldName(field) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(name));
}

/// Sonraki satırı OKUR — bitince (daha fazla satır YOKSA) `null` döner.
/// `.nox` tarafı `nox_mysql_is_null_ptr` İLE bunu KONTROL eder (`ptr ==
/// 0` Nox'ta doğrudan YAZILAMADIĞINDAN).
pub export fn nox_mysql_fetch_row_raw(res: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (!ensureLoaded()) return null;
    const row = g_funcs.fetch_row(res) orelse return null;
    return @constCast(@ptrCast(row));
}

pub export fn nox_mysql_row_isnull_raw(row: ?*anyopaque, col: i64) callconv(.c) i64 {
    const r: [*]const ?[*:0]const u8 = @ptrCast(@alignCast(row orelse return 1));
    return if (r[@intCast(col)] == null) 1 else 0;
}

pub export fn nox_mysql_row_getvalue_raw(rt: ?*anyopaque, row: ?*anyopaque, col: i64) callconv(.c) ?[*:0]u8 {
    const r: [*]const ?[*:0]const u8 = @ptrCast(@alignCast(row orelse return dupeEmpty(rt)));
    const v = r[@intCast(col)] orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(v));
}

pub export fn nox_mysql_free_result_raw(res: ?*anyopaque) callconv(.c) void {
    if (!ensureLoaded()) return;
    g_funcs.free_result(res);
}

pub export fn nox_mysql_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}

/// Faz NN.4 (bkz. proje belleği "nyx v2 limitasyon listesi doğrulaması"):
/// `mysql_insert_id` — son `AUTO_INCREMENT` id'si (bağlantı-durumu, sqlite'ın
/// `sqlite3_last_insert_rowid`iyle AYNI KAVRAM — Postgres'in AKSİNE MySQL
/// bunu DOĞRUDAN destekler).
pub export fn nox_mysql_insert_id_raw(conn: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return @intCast(g_funcs.insert_id(conn));
}

/// Faz NN.4: **Bilinçli tasarım kararı** — `mysql_stmt_*` (GERÇEK sunucu-
/// taraflı hazırlanmış deyimler) `MYSQL_BIND` struct'ının TAM Zig
/// karşılığını (çok-tipli `buffer`/`buffer_length`/`is_null`/`length`
/// alanları, ABI-KIRILGAN) gerektirir — bunun yerine `mysql_real_escape_
/// string` (libmysqlclient'ın KENDİ, iyi-test-edilmiş SQL-enjeksiyon
/// kaçışlama fonksiyonu) İLE İSTEMCİ-TARAFLI parametre kaçışlaması
/// kullanılır: `Statement` (bkz. `stdlib/nox/mysql.nox`) her `bind_str`
/// değerini BURADAN kaçışlatıp SQL metnine `?` yerine DOĞRUDAN gömer,
/// SONRA MEVCUT `nox_mysql_query_raw`ı (düz metin) çağırır — kullanıcı
/// API'si (`bind_int`/`bind_str` sonra `execute()`) Postgres/sqlite İLE
/// AYNI görünür, ama sunucu tarafında isimli bir "prepared statement" YOK
/// (`nox.postgres`nin AYNI "biriktir-sonra-ateşle" felsefesiyle TUTARLI,
/// yalnızca ateşleme MEKANİZMASI FARKLI). Bu, GERÇEK SQL-enjeksiyon
/// korumasını (asıl pratik endişe) MYSQL_BIND'in ABI riskine GİRMEDEN
/// sağlar.
pub export fn nox_mysql_escape_raw(rt: ?*anyopaque, conn: ?*anyopaque, value: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const v = value orelse return dupeEmpty(rt);
    if (!ensureLoaded()) return dupeEmpty(rt);
    const src = str_mod.nox_str_slice(v);
    const gpa = std.heap.page_allocator;
    const buf = gpa.alloc(u8, src.len * 2 + 1) catch return dupeEmpty(rt);
    defer gpa.free(buf);
    const written = g_funcs.real_escape_string(conn, buf.ptr, src.ptr, @intCast(src.len));
    return dupeToNoxStr(rt, buf[0..written]);
}
