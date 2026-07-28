//! `nox.postgres` Zig kabuğu — `sqlite.zig`nin BİREBİR AYNI şablonu (bkz.
//! proje belleği "4 yeni stdlib modülü" planı): `libpq`yu (İLK `nox.
//! postgres` çağrısında, TEMBEL) `std.DynLib`/`kernel32.LoadLibraryA`
//! İLE ÇALIŞMA ZAMANINDA yükler — `noxrt.o`nun KENDİSİ `PQ*`e dair
//! HİÇBİR bağlama-zamanı referansı TAŞIMAZ (`libpq` KURULU DEĞİLSE
//! `nox.postgres` KULLANMAYAN bir program HİÇ ETKİLENMEZ — sqlite.zig'in
//! TERK ETTİĞİ statik `-lsqlite3` deseninin AYNI GEREKÇESİ burada da
//! geçerlidir).
//!
//! `PQconnectdb` HEM keyword-value (`"host=... user=..."`) HEM URI
//! (`"postgres://user:pass@host:port/db"`) bağlantı dizesini NATİF kabul
//! eder — bu YÜZDEN `nox.postgres.open`in KENDİSİ bir DSN ayrıştırıcısına
//! İHTİYAÇ DUYMAZ, ham dizeyi DOĞRUDAN iletir.
//!
//! **Bilinçli v1 kapsamı**: Postgres'in `sqlite3_last_insert_rowid`
//! KARŞILIĞI YOK (kullanıcı `INSERT ... RETURNING id` YAZIP sonucu
//! `query()`den OKUMALIDIR — bu, Postgres'in KENDİ idiyomatik deseni) —
//! bu YÜZDEN `Connection`da `last_insert_rowid()` YOK, `changes()` İSE
//! `PQcmdTuples`in (etkilenen satır sayısı, ondalık METİN) ayrıştırılmasıyla
//! sağlanır.

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");
const abi_layout = @import("abi_layout");

const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

fn libraryFileName() [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => "libpq.dylib",
        .windows => "libpq.dll",
        else => "libpq.so.5",
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

const ConnectdbFn = *const fn (conninfo: [*:0]const u8) callconv(.c) ?*anyopaque;
const FinishFn = *const fn (conn: ?*anyopaque) callconv(.c) void;
const StatusFn = *const fn (conn: ?*anyopaque) callconv(.c) c_int;
const ErrorMessageFn = *const fn (conn: ?*anyopaque) callconv(.c) ?[*:0]const u8;
const ExecFn = *const fn (conn: ?*anyopaque, query: [*:0]const u8) callconv(.c) ?*anyopaque;
const ExecParamsFn = *const fn (
    conn: ?*anyopaque,
    command: [*:0]const u8,
    n_params: c_int,
    param_types: ?[*]const c_uint,
    param_values: ?[*]const ?[*:0]const u8,
    param_lengths: ?[*]const c_int,
    param_formats: ?[*]const c_int,
    result_format: c_int,
) callconv(.c) ?*anyopaque;
const ResultStatusFn = *const fn (res: ?*anyopaque) callconv(.c) c_int;
const ResultErrorMessageFn = *const fn (res: ?*anyopaque) callconv(.c) ?[*:0]const u8;
const NtuplesFn = *const fn (res: ?*anyopaque) callconv(.c) c_int;
const NfieldsFn = *const fn (res: ?*anyopaque) callconv(.c) c_int;
const FnameFn = *const fn (res: ?*anyopaque, col: c_int) callconv(.c) ?[*:0]const u8;
const GetvalueFn = *const fn (res: ?*anyopaque, row: c_int, col: c_int) callconv(.c) ?[*:0]const u8;
const GetisnullFn = *const fn (res: ?*anyopaque, row: c_int, col: c_int) callconv(.c) c_int;
const CmdTuplesFn = *const fn (res: ?*anyopaque) callconv(.c) ?[*:0]const u8;
const ClearFn = *const fn (res: ?*anyopaque) callconv(.c) void;

const Funcs = struct {
    connectdb: ConnectdbFn,
    finish: FinishFn,
    status: StatusFn,
    error_message: ErrorMessageFn,
    exec: ExecFn,
    exec_params: ExecParamsFn,
    result_status: ResultStatusFn,
    result_error_message: ResultErrorMessageFn,
    ntuples: NtuplesFn,
    nfields: NfieldsFn,
    fname: FnameFn,
    getvalue: GetvalueFn,
    getisnull: GetisnullFn,
    cmd_tuples: CmdTuplesFn,
    clear: ClearFn,
};

const LoadState = enum(u8) { uninit, initializing, ready, failed };
var g_state: std.atomic.Value(LoadState) = .init(.uninit);
var g_lib: LibHandle = undefined;
var g_funcs: Funcs = undefined;

fn loadAll() bool {
    var lib = openLib() orelse return false;
    const connectdb_fn = lookupSym(&lib, ConnectdbFn, "PQconnectdb") orelse return false;
    const finish_fn = lookupSym(&lib, FinishFn, "PQfinish") orelse return false;
    const status_fn = lookupSym(&lib, StatusFn, "PQstatus") orelse return false;
    const error_message_fn = lookupSym(&lib, ErrorMessageFn, "PQerrorMessage") orelse return false;
    const exec_fn = lookupSym(&lib, ExecFn, "PQexec") orelse return false;
    const exec_params_fn = lookupSym(&lib, ExecParamsFn, "PQexecParams") orelse return false;
    const result_status_fn = lookupSym(&lib, ResultStatusFn, "PQresultStatus") orelse return false;
    const result_error_message_fn = lookupSym(&lib, ResultErrorMessageFn, "PQresultErrorMessage") orelse return false;
    const ntuples_fn = lookupSym(&lib, NtuplesFn, "PQntuples") orelse return false;
    const nfields_fn = lookupSym(&lib, NfieldsFn, "PQnfields") orelse return false;
    const fname_fn = lookupSym(&lib, FnameFn, "PQfname") orelse return false;
    const getvalue_fn = lookupSym(&lib, GetvalueFn, "PQgetvalue") orelse return false;
    const getisnull_fn = lookupSym(&lib, GetisnullFn, "PQgetisnull") orelse return false;
    const cmd_tuples_fn = lookupSym(&lib, CmdTuplesFn, "PQcmdTuples") orelse return false;
    const clear_fn = lookupSym(&lib, ClearFn, "PQclear") orelse return false;

    g_lib = lib;
    g_funcs = .{
        .connectdb = connectdb_fn,
        .finish = finish_fn,
        .status = status_fn,
        .error_message = error_message_fn,
        .exec = exec_fn,
        .exec_params = exec_params_fn,
        .result_status = result_status_fn,
        .result_error_message = result_error_message_fn,
        .ntuples = ntuples_fn,
        .nfields = nfields_fn,
        .fname = fname_fn,
        .getvalue = getvalue_fn,
        .getisnull = getisnull_fn,
        .cmd_tuples = cmd_tuples_fn,
        .clear = clear_fn,
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
    const raw = arc.nox_rc_alloc(rt, bytes.len + 1) orelse return null;
    const out: [*]u8 = @ptrCast(raw);
    @memcpy(out[0..bytes.len], bytes);
    out[bytes.len] = 0;
    return @ptrCast(out);
}

fn dupeEmpty(rt: ?*anyopaque) ?[*:0]u8 {
    return dupeToNoxStr(rt, "");
}

/// `CONNECTION_OK` (libpq'nun `ConnStatusType` enum'unun 0'ıncı üyesi).
const CONNECTION_OK: c_int = 0;
/// `PGRES_COMMAND_OK`/`PGRES_TUPLES_OK` (libpq'nun `ExecStatusType`
/// enum'unun 1/2'nci üyeleri) — `execute()`/`query()`nin BAŞARI kontrolü.
const PGRES_COMMAND_OK: c_int = 1;
const PGRES_TUPLES_OK: c_int = 2;

pub export fn nox_pg_connect_raw(conninfo: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s = conninfo orelse return null;
    if (!ensureLoaded()) return null;
    const conn = g_funcs.connectdb(s) orelse return null;
    if (g_funcs.status(conn) != CONNECTION_OK) {
        // Bağlantı BAŞARISIZ — `PQfinish` ÇAĞRILMAZ (libpq'nun KENDİ
        // sözleşmesi: başarısız bir `PQconnectdb` SONUCU YİNE DE
        // `PQfinish` İLE serbest bırakılmalıdır, AKSİ TAKDİRDE sızar) —
        // bu YÜZDEN handle'ı OLDUĞU GİBİ döneriz, `.nox` tarafı `status`/
        // `errmsg`i OKUYUP SONRA `close()`u ÇAĞIRIR (`SqliteError`in AYNI
        // "başarısız handle'ı yine de temizle" deseni).
        return conn;
    }
    return conn;
}

pub export fn nox_pg_status_ok_raw(conn: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return if (g_funcs.status(conn) == CONNECTION_OK) 1 else 0;
}

pub export fn nox_pg_errmsg_raw(rt: ?*anyopaque, conn: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeToNoxStr(rt, "libpq yuklenemedi (sistemde kurulu degil olabilir)");
    const msg = g_funcs.error_message(conn) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(msg));
}

pub export fn nox_pg_finish_raw(conn: ?*anyopaque) callconv(.c) void {
    if (!ensureLoaded()) return;
    g_funcs.finish(conn);
}

pub export fn nox_pg_exec_raw(conn: ?*anyopaque, query: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const q = query orelse return null;
    if (!ensureLoaded()) return null;
    return g_funcs.exec(conn, q);
}

/// `Statement.bind_*`nin BİRİKTİRDİĞİ metin-formatlı parametreleri (bir
/// `list[str]` + PARALEL bir `list[str]` NULL bayrağı — checker'ın FFI
/// sınırı `list[str]` DIŞINDA HİÇBİR `list[T]`ye (ör. `list[bool]`e)
/// PARAMETRE olarak İZİN VERMEDİĞİNDEN, `is_null` bayrağı "1"/"0" metin
/// dizeleri OLARAK kodlanır — `Statement.nox`'un KENDİ İÇ tamponları)
/// `PQexecParams`e iletir — sqlite'ın GERÇEK artımlı bind'inin AKSİNE,
/// libpq'nun `PQexecParams` API'si TEK bir çağrıda TÜM parametreleri alır
/// ("biriktir-sonra-ateşle", bkz. `stdlib/nox/postgres.nox`nin `Statement`
/// sınıfının belge notu). `null_flags`te "1" OLAN bir indeks İçin
/// `paramValues[i]` C `NULL` olarak geçirilir (libpq'nun SQL `NULL`
/// sözleşmesi) — `params_list`teki KARŞILIK gelen dize (BOŞ bir yer
/// tutucu) YOK SAYILIR. `paramTypes`/`paramLengths`/`paramFormats` HEPSİ
/// `null` (metin formatı — libpq TÜM değerleri metin olarak yorumlar,
/// sunucu tipi KENDİSİ ÇIKARIR), `resultFormat = 0` (metin) —
/// `nox_pg_getvalue_raw`in mevcut metin-tabanlı okuma yoluyla TUTARLI.
pub export fn nox_pg_exec_params_raw(conn: ?*anyopaque, query: ?[*:0]const u8, params_list: ?*anyopaque, null_flags_list: ?*anyopaque) callconv(.c) ?*anyopaque {
    const q = query orelse return null;
    if (!ensureLoaded()) return null;
    const bytes: [*]u8 = @ptrCast(params_list orelse return g_funcs.exec_params(conn, q, 0, null, null, null, null, 0));
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
    if (count == 0) return g_funcs.exec_params(conn, q, 0, null, null, null, null, 0);
    const null_bytes: ?[*]u8 = if (null_flags_list) |p| @ptrCast(p) else null;
    const gpa = std.heap.page_allocator;
    const values = gpa.alloc(?[*:0]const u8, count) catch return null;
    defer gpa.free(values);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const is_null = if (null_bytes) |nb| blk: {
            const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(nb + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
            const flag_str: [*:0]const u8 = @ptrFromInt(addr);
            break :blk flag_str[0] == '1';
        } else false;
        if (is_null) {
            values[i] = null;
        } else {
            const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
            values[i] = @ptrFromInt(addr);
        }
    }
    return g_funcs.exec_params(conn, q, @intCast(count), null, values.ptr, null, null, 0);
}

pub export fn nox_pg_result_ok_raw(res: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    const st = g_funcs.result_status(res);
    return if (st == PGRES_COMMAND_OK or st == PGRES_TUPLES_OK) 1 else 0;
}

pub export fn nox_pg_result_errmsg_raw(rt: ?*anyopaque, res: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeEmpty(rt);
    const msg = g_funcs.result_error_message(res) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(msg));
}

pub export fn nox_pg_ntuples_raw(res: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return g_funcs.ntuples(res);
}

pub export fn nox_pg_nfields_raw(res: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    return g_funcs.nfields(res);
}

pub export fn nox_pg_fname_raw(rt: ?*anyopaque, res: ?*anyopaque, col: i64) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeEmpty(rt);
    const name = g_funcs.fname(res, @intCast(col)) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(name));
}

pub export fn nox_pg_getvalue_raw(rt: ?*anyopaque, res: ?*anyopaque, row: i64, col: i64) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeEmpty(rt);
    const v = g_funcs.getvalue(res, @intCast(row), @intCast(col)) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(v));
}

pub export fn nox_pg_getisnull_raw(res: ?*anyopaque, row: i64, col: i64) callconv(.c) i64 {
    if (!ensureLoaded()) return 1;
    return g_funcs.getisnull(res, @intCast(row), @intCast(col));
}

/// Etkilenen satır sayısı (`INSERT`/`UPDATE`/`DELETE`) — `PQcmdTuples`
/// ondalık BİR METİN döner (`SELECT` İçin BOŞ dize), burada `int`e
/// ayrıştırılır (ayrıştırma BAŞARISIZSA `0`).
pub export fn nox_pg_changes_raw(res: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    const s = g_funcs.cmd_tuples(res) orelse return 0;
    const span = std.mem.span(s);
    if (span.len == 0) return 0;
    return std.fmt.parseInt(i64, span, 10) catch 0;
}

pub export fn nox_pg_clear_raw(res: ?*anyopaque) callconv(.c) void {
    if (!ensureLoaded()) return;
    g_funcs.clear(res);
}

pub export fn nox_pg_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}
