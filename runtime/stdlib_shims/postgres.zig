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
const str_mod = @import("../str.zig");
const abi_layout = @import("abi_layout");
const fiber_net = @import("fiber_net.zig");

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
const ResultErrorFieldFn = *const fn (res: ?*anyopaque, fieldcode: c_int) callconv(.c) ?[*:0]const u8;
const SetNonblockingFn = *const fn (conn: ?*anyopaque, arg: c_int) callconv(.c) c_int;
const SendQueryFn = *const fn (conn: ?*anyopaque, query: [*:0]const u8) callconv(.c) c_int;
const SendQueryParamsFn = *const fn (
    conn: ?*anyopaque,
    command: [*:0]const u8,
    n_params: c_int,
    param_types: ?[*]const c_uint,
    param_values: ?[*]const ?[*:0]const u8,
    param_lengths: ?[*]const c_int,
    param_formats: ?[*]const c_int,
    result_format: c_int,
) callconv(.c) c_int;
const ConnFlagFn = *const fn (conn: ?*anyopaque) callconv(.c) c_int;
const GetResultFn = *const fn (conn: ?*anyopaque) callconv(.c) ?*anyopaque;
const GetCancelFn = *const fn (conn: ?*anyopaque) callconv(.c) ?*anyopaque;
const CancelFn = *const fn (cancel: ?*anyopaque, errbuf: [*]u8, errbufsize: c_int) callconv(.c) c_int;
const FreeCancelFn = *const fn (cancel: ?*anyopaque) callconv(.c) void;

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
    result_error_field: ResultErrorFieldFn,
    set_nonblocking: SetNonblockingFn,
    send_query: SendQueryFn,
    send_query_params: SendQueryParamsFn,
    consume_input: ConnFlagFn,
    is_busy: ConnFlagFn,
    flush: ConnFlagFn,
    socket: ConnFlagFn,
    get_result: GetResultFn,
    get_cancel: GetCancelFn,
    cancel: CancelFn,
    free_cancel: FreeCancelFn,
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
    const result_error_field_fn = lookupSym(&lib, ResultErrorFieldFn, "PQresultErrorField") orelse return false;
    const set_nonblocking_fn = lookupSym(&lib, SetNonblockingFn, "PQsetnonblocking") orelse return false;
    const send_query_fn = lookupSym(&lib, SendQueryFn, "PQsendQuery") orelse return false;
    const send_query_params_fn = lookupSym(&lib, SendQueryParamsFn, "PQsendQueryParams") orelse return false;
    const consume_input_fn = lookupSym(&lib, ConnFlagFn, "PQconsumeInput") orelse return false;
    const is_busy_fn = lookupSym(&lib, ConnFlagFn, "PQisBusy") orelse return false;
    const flush_fn = lookupSym(&lib, ConnFlagFn, "PQflush") orelse return false;
    const socket_fn = lookupSym(&lib, ConnFlagFn, "PQsocket") orelse return false;
    const get_result_fn = lookupSym(&lib, GetResultFn, "PQgetResult") orelse return false;
    const get_cancel_fn = lookupSym(&lib, GetCancelFn, "PQgetCancel") orelse return false;
    const cancel_fn = lookupSym(&lib, CancelFn, "PQcancel") orelse return false;
    const free_cancel_fn = lookupSym(&lib, FreeCancelFn, "PQfreeCancel") orelse return false;

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
        .result_error_field = result_error_field_fn,
        .set_nonblocking = set_nonblocking_fn,
        .send_query = send_query_fn,
        .send_query_params = send_query_params_fn,
        .consume_input = consume_input_fn,
        .is_busy = is_busy_fn,
        .flush = flush_fn,
        .socket = socket_fn,
        .get_result = get_result_fn,
        .get_cancel = get_cancel_fn,
        .cancel = cancel_fn,
        .free_cancel = free_cancel_fn,
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

/// `CONNECTION_OK` (libpq'nun `ConnStatusType` enum'unun 0'ıncı üyesi).
const CONNECTION_OK: c_int = 0;
/// `PGRES_COMMAND_OK`/`PGRES_TUPLES_OK` (libpq'nun `ExecStatusType`
/// enum'unun 1/2'nci üyeleri) — `execute()`/`query()`nin BAŞARI kontrolü.
const PGRES_COMMAND_OK: c_int = 1;
const PGRES_TUPLES_OK: c_int = 2;

/// Tutamak: libpq `PGconn`u + bu bağlantıya özgü sorgu zaman aşımı (tutamak başına durum; global yok). Nox'a opak işaretçi olarak verilir.
const PgConn = struct {
    conn: ?*anyopaque,
    /// İstemci tarafı sorgu zaman aşımı (ms); 0 = sınırsız. Aşılırsa sorgu `PQcancel` ile iptal edilir (sunucu 57014 `query_canceled` döner).
    timeout_ms: i64 = 0,
};

const pg_gpa = std.heap.page_allocator;

fn asPg(h: ?*anyopaque) ?*PgConn {
    return @ptrCast(@alignCast(h orelse return null));
}

pub export fn nox_pg_connect_raw(conninfo: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const s = conninfo orelse return null;
    if (!ensureLoaded()) return null;
    const conn = g_funcs.connectdb(s) orelse return null;
    const h = pg_gpa.create(PgConn) catch {
        g_funcs.finish(conn);
        return null;
    };
    h.* = .{ .conn = conn };
    // Bağlantı BAŞARISIZ olsa da tutamak OLDUĞU GİBİ döner (libpq sözleşmesi: başarısız bir `PQconnectdb` sonucu yine `PQfinish` ile bırakılmalıdır); `.nox` tarafı
    // `status`/`errmsg`i okuyup sonra `close()`u çağırır (`SqliteError`in aynı deseni).
    return h;
}

pub export fn nox_pg_status_ok_raw(h: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    const pg = asPg(h) orelse return 0;
    return if (g_funcs.status(pg.conn) == CONNECTION_OK) 1 else 0;
}

pub export fn nox_pg_errmsg_raw(rt: ?*anyopaque, h: ?*anyopaque) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeToNoxStr(rt, "could not load libpq (it may not be installed on the system)");
    const pg = asPg(h) orelse return dupeEmpty(rt);
    const msg = g_funcs.error_message(pg.conn) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(msg));
}

pub export fn nox_pg_finish_raw(h: ?*anyopaque) callconv(.c) void {
    if (!ensureLoaded()) return;
    const pg = asPg(h) orelse return;
    g_funcs.finish(pg.conn);
    pg_gpa.destroy(pg);
}

/// Bağlantının istemci tarafı sorgu zaman aşımı (ms, 0 = sınırsız).
pub export fn nox_pg_set_timeout_raw(h: ?*anyopaque, ms: i64) callconv(.c) void {
    const pg = asPg(h) orelse return;
    pg.timeout_ms = if (ms < 0) 0 else ms;
}

/// Çalışan sorguyu istemci tarafından iptal eder (`PQcancel`: sunucuya AYRI, kısa ömürlü bir bağlantıyla iptal isteği gönderir; başka bir iş parçacığından/görevden güvenle çağrılabilir,
/// ama o küçük bağlantı kurulurken çağıranı kısa süre bloklar). Başarıda 1. Sorgu o sırada çalışmıyorsa etkisizdir.
pub export fn nox_pg_cancel_raw(h: ?*anyopaque) callconv(.c) i64 {
    if (!ensureLoaded()) return 0;
    const pg = asPg(h) orelse return 0;
    return cancelConn(pg.conn);
}

fn cancelConn(conn: ?*anyopaque) i64 {
    const c = g_funcs.get_cancel(conn) orelse return 0;
    defer g_funcs.free_cancel(c);
    var buf: [256]u8 = undefined;
    return if (g_funcs.cancel(c, &buf, buf.len) == 1) 1 else 0;
}

/// Bloklamayan sorgu yürütme (Windows dışında): `PQsendQuery*` gönderdikten sonra soketi bekler. Fiber içindeyken yalnızca çağıran görev reaktörde askıya alınır (zamanlayıcı
/// iş parçacığı diğer görevleri çalıştırır), fiber dışında `poll` ile beklenir. `timeout_ms` aşılırsa bir kez `PQcancel` çağrılır ve sunucunun iptal yanıtı (57014) beklenir.
const async_io = builtin.os.tag != .windows and !builtin.cpu.arch.isWasm();

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Soket hazır olana ya da `budget_ms` dolana dek bekler (`< 0` sınırsız). `false`: zaman aşımı.
fn waitSock(sock: c_int, write: bool, budget_ms: i64) bool {
    if (fiber_net.inFiber()) {
        const t: ?u32 = if (budget_ms < 0) null else @intCast(@min(@max(budget_ms, 1), std.math.maxInt(i32)));
        return fiber_net.waitFd(sock, write, t) == .ready;
    }
    var pfd = [1]std.c.pollfd{.{ .fd = sock, .events = if (write) std.c.POLL.OUT else std.c.POLL.IN, .revents = 0 }};
    const ms: c_int = if (budget_ms < 0) -1 else @intCast(@min(budget_ms, std.math.maxInt(i32)));
    return std.c.poll(&pfd, 1, ms) > 0;
}

/// İptal isteği gönderildikten sonra sunucunun yanıtını bekleme üst sınırı (ms).
const CANCEL_GRACE_MS: i64 = 5000;

/// Gönderilmiş bir sorgunun sonuçlarını toplar; `PQexec` gibi SON sonucu döner (`null`: bağlantı hatası). Çağıran `PQclear` eder.
fn collectResults(pg: *PgConn) ?*anyopaque {
    const conn = pg.conn;
    const sock = g_funcs.socket(conn);
    if (sock < 0) return null;
    var deadline: i64 = if (pg.timeout_ms > 0) nowMs() + pg.timeout_ms else -1;
    var cancelled = false;
    while (true) {
        const f = g_funcs.flush(conn);
        if (f == 0) break;
        if (f < 0) return null;
        const rem: i64 = if (deadline < 0) -1 else @max(deadline - nowMs(), 1);
        _ = waitSock(sock, true, rem);
        if (deadline >= 0 and nowMs() >= deadline and !cancelled) {
            _ = cancelConn(conn);
            cancelled = true;
            deadline = nowMs() + CANCEL_GRACE_MS;
        }
    }
    var last: ?*anyopaque = null;
    while (true) {
        while (g_funcs.is_busy(conn) != 0) {
            const rem: i64 = if (deadline < 0) -1 else deadline - nowMs();
            if (deadline >= 0 and rem <= 0) {
                if (!cancelled) {
                    _ = cancelConn(conn);
                    cancelled = true;
                    deadline = nowMs() + CANCEL_GRACE_MS;
                    continue;
                }
                // Sunucu iptale yanıt vermedi: bağlantı kullanılamaz (çağıran `null` görür, bağlantıyı kapatmalıdır).
                if (last) |l| g_funcs.clear(l);
                return null;
            }
            _ = waitSock(sock, false, rem);
            if (g_funcs.consume_input(conn) == 0) {
                if (last) |l| g_funcs.clear(l);
                return null;
            }
        }
        const res = g_funcs.get_result(conn) orelse break;
        if (last) |l| g_funcs.clear(l);
        last = res;
    }
    return last;
}

fn runSimple(pg: *PgConn, q: [*:0]const u8) ?*anyopaque {
    if (comptime !async_io) return g_funcs.exec(pg.conn, q);
    if (g_funcs.set_nonblocking(pg.conn, 1) != 0) return g_funcs.exec(pg.conn, q);
    defer _ = g_funcs.set_nonblocking(pg.conn, 0);
    if (g_funcs.send_query(pg.conn, q) != 1) return null;
    return collectResults(pg);
}

fn runParams(pg: *PgConn, q: [*:0]const u8, n: c_int, values: ?[*]const ?[*:0]const u8) ?*anyopaque {
    if (comptime !async_io) return g_funcs.exec_params(pg.conn, q, n, null, values, null, null, 0);
    if (g_funcs.set_nonblocking(pg.conn, 1) != 0) return g_funcs.exec_params(pg.conn, q, n, null, values, null, null, 0);
    defer _ = g_funcs.set_nonblocking(pg.conn, 0);
    if (g_funcs.send_query_params(pg.conn, q, n, null, values, null, null, 0) != 1) return null;
    return collectResults(pg);
}

pub export fn nox_pg_exec_raw(h: ?*anyopaque, query: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const q = query orelse return null;
    if (!ensureLoaded()) return null;
    const pg = asPg(h) orelse return null;
    return runSimple(pg, q);
}

/// `Statement.bind_*`nin BİRİKTİRDİĞİ metin-formatlı parametreleri (bir `list[str]` + PARALEL bir `list[str]` NULL bayrağı — checker'ın FFI sınırı `list[str]` DIŞINDA
/// HİÇBİR `list[T]`ye PARAMETRE olarak İZİN VERMEDİĞİNDEN, `is_null` bayrağı "1"/"0" metin dizeleri OLARAK kodlanır) `PQsendQueryParams`e iletir — libpq TEK çağrıda TÜM
/// parametreleri alır ("biriktir-sonra-ateşle", bkz. `stdlib/nox/postgres.nox`nin `Statement` notu). `null_flags`te "1" olan indeks için `paramValues[i]` C `NULL` olarak
/// geçirilir (SQL `NULL`). `paramTypes`/`paramLengths`/`paramFormats` `null` (metin formatı), `resultFormat = 0`.
pub export fn nox_pg_exec_params_raw(h: ?*anyopaque, query: ?[*:0]const u8, params_list: ?*anyopaque, null_flags_list: ?*anyopaque) callconv(.c) ?*anyopaque {
    const q = query orelse return null;
    if (!ensureLoaded()) return null;
    const pg = asPg(h) orelse return null;
    const bytes: [*]u8 = @ptrCast(params_list orelse return runParams(pg, q, 0, null));
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
    if (count == 0) return runParams(pg, q, 0, null);
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
    return runParams(pg, q, @intCast(count), values.ptr);
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

/// Başarısız bir sonucun yapılandırılmış hata alanı (`PG_DIAG_*` kodu, tek karakter): 'S' önem, 'C' SQLSTATE, 'M' ileti, 'D' ayrıntı, 'H' ipucu,
/// 't' tablo, 'c' sütun, 'n' kısıt adı. Alan yoksa boş dize.
pub export fn nox_pg_result_field_raw(rt: ?*anyopaque, res: ?*anyopaque, code: i64) callconv(.c) ?[*:0]u8 {
    if (!ensureLoaded()) return dupeEmpty(rt);
    const v = g_funcs.result_error_field(res, @intCast(code)) orelse return dupeEmpty(rt);
    return dupeToNoxStr(rt, std.mem.span(v));
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
