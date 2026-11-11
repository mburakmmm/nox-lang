//! Nox Zig runtime — noxc tarafından üretilen native binary'lere statik
//! bağlanır. `export fn` ile işaretli semboller C-ABI üzerinden QBE'nin
//! ürettiği makine kodundan çağrılabilir.

const std = @import("std");
const builtin = @import("builtin");

/// iOS, `_dyld_get_image_header_containing_address` sembolünü vermez
/// (`__API_UNAVAILABLE(ios)`). Zig'in Mach-O öz-bilgisi bu sembole bağlıdır.
/// iOS'ta yığın izi sembolize edilmez; panik yine de çalışır.
pub const debug = if (builtin.os.tag == .ios) struct {
    pub const SelfInfo = void;
} else struct {};

/// Reddedilen bir TCP bağlantısı Zig'in Debug izini stderr'e basar.
/// Nox bu hatayı kendi istisnasına çevirir; iz, programın stderr'ini
/// kirletmesin.
///
/// `signal_stack_size = null`: Zig std her iş parçacığı için 256 KiB'lik
/// `threadlocal` bir sinyal yığını (`Thread.maybeAttachSignalStack`) ayırır.
/// Bu statik TLS'i 256 KiB şişirir; Android API < 29 (eski Bionic) buyuk
/// PT_TLS bölümünü olan bir yürütülebilirde ilk TLS erişiminde SIGSEGV verir
/// (gecelik API 26 emülatörü: 468 fixture'ın 400'ü). Runtime bir kütüphanedir;
/// std'nin segfault işleyicisini kurmaz ve Nox kendi sigaltstack'ini kullanmaz,
/// yani bu yığın hiçbir zaman işe yaramıyordu.
pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
    .signal_stack_size = null,
};

pub const asap = @import("alloc/asap.zig");
pub const embed = @import("embed.zig");
/// TODO 1.5: çoklu-runtime izolasyon korpusu (yalnızca test keşfi için kayıtlı).
pub const multi_runtime_test = @import("multi_runtime_test.zig");
pub const arc = @import("alloc/arc.zig");
pub const dispatch_registry = @import("alloc/dispatch_registry.zig");
pub const diag_sink = @import("diag_sink");
pub const lowlevel = @import("alloc/lowlevel.zig");
pub const cycle_detector = @import("alloc/cycle_detector.zig");
pub const defer_stack = @import("alloc/defer_stack.zig");
pub const errors = @import("errors/handle.zig");
pub const foreign_bridge = @import("foreign_bridge.zig");
pub const async_bridge = @import("async_rt/bridge.zig");
pub const thread_bridge = @import("async_rt/thread_bridge.zig");
pub const thread_channel = @import("async_rt/thread_channel.zig");
pub const task_local = @import("async_rt/task_local.zig");
pub const task_local_entry = @import("async_rt/task_local_entry.zig");
pub const task_wait = @import("stdlib_shims/task_wait.zig");
pub const signal_shim = @import("stdlib_shims/signal.zig");
pub const terminal_shim = @import("stdlib_shims/terminal.zig");
pub const redis_shim = @import("stdlib_shims/redis.zig");
pub const grpc_shim = @import("stdlib_shims/grpc.zig");
pub const client_cert_shim = @import("stdlib_shims/client_cert.zig");
pub const tz_shim = @import("stdlib_shims/tz.zig");
pub const udp_shim = @import("stdlib_shims/udp.zig");
/// Faz MN.3a: BAĞIMSIZ, henüz HİÇBİR yere BAĞLANMAMIŞ (bkz. onun modül
/// üstü notu) — SADECE `zig build test`nin `noxrt_test`inin (bu dosyayı
/// KÖK modül olarak kullanan) KENDİ testlerini KEŞFEDEBİLMESİ İçİn burada
/// isim-üzerinden yeniden dışa aktarılıyor.
pub const chase_lev_deque = @import("async_rt/chase_lev_deque.zig");
/// v2.1.54: freestanding varsayılan heap'inin saf dağıtıcısı (kernel.zig kullanır); birim testleri hosted'ta çalışır.
pub const size_class_heap = @import("freestanding/size_class_heap.zig");
/// Faz MN.3b: MN.3a İLE AYNI "bağımsız, sadece test-keşfi İçİn KAYITLI"
/// deseni — bkz. onun modül üstü notu.
pub const worker_pool = @import("async_rt/worker_pool.zig");
/// Faz MN.7a: `nox.thread.pool_run`ın C-ABI yüzeyi — `thread_bridge`/
/// `thread_channel` İLE AYNI, GERÇEK Nox codegen'inden çağrılan bir
/// modül (`chase_lev_deque`/`worker_pool`nin "bağımsız, sadece test-
/// keşfi İçİN" notu BURAYA UYGULANMAZ).
pub const pool_bridge = @import("async_rt/pool_bridge.zig");
pub const str = @import("str.zig");
pub const format = @import("format.zig");
pub const dict = @import("collections/dict.zig");
pub const list_sort = @import("collections/list_sort.zig");
pub const list_ops = @import("collections/list_ops.zig");
pub const http_client = @import("stdlib_shims/http_client.zig");
pub const http_stream = @import("stdlib_shims/http_stream.zig");
pub const http_server = @import("stdlib_shims/http_server.zig");
pub const strings_shim = @import("stdlib_shims/strings.zig");
pub const math_shim = @import("stdlib_shims/math.zig");
pub const os_shim = @import("stdlib_shims/os.zig");
pub const fs_shim = @import("stdlib_shims/fs.zig");
pub const wasm_vfs = @import("wasm_vfs.zig");
pub const path_shim = @import("stdlib_shims/path.zig");
pub const time_shim = @import("stdlib_shims/time.zig");
pub const json_shim = @import("stdlib_shims/json.zig");
pub const random_shim = @import("stdlib_shims/random.zig");
pub const crypto_shim = @import("stdlib_shims/crypto.zig");
pub const regex_shim = @import("stdlib_shims/regex.zig");
pub const unicode_shim = @import("stdlib_shims/unicode.zig");
pub const io_shim = @import("stdlib_shims/io.zig");
pub const sqlite_shim = @import("stdlib_shims/sqlite.zig");
pub const process_shim = @import("stdlib_shims/process.zig");
// Mobil hedeflerde (iOS/Android) ana makine kütüphanesi (`libpq`/`libmysqlclient`) yüklenemez; bunun yerine saf Zig protokol istemcileri yerel soketler (`tcp_native.zig`) üzerinde kullanılır (v2.0.189).
// Aynı `nox_pg_*`/`nox_mysql_*` sembollerini dışa aktarırlar, yani `.nox` tarafı değişmez.
const mobile_db = builtin.os.tag == .ios or builtin.abi.isAndroid();
pub const postgres_shim = if (mobile_db) @import("stdlib_shims/pg_wasm.zig") else @import("stdlib_shims/postgres.zig");
pub const native_shim = @import("stdlib_shims/native.zig");
pub const mysql_shim = if (mobile_db) @import("stdlib_shims/mysql_wasm.zig") else @import("stdlib_shims/mysql.zig");
pub const tls_shim = @import("stdlib_shims/tls.zig");
pub const tls_server_shim = @import("stdlib_shims/tls_server.zig");
pub const websocket_shim = @import("stdlib_shims/websocket.zig");
pub const websocket_server_shim = @import("stdlib_shims/websocket_server.zig");
pub const shared_mem_shim = @import("stdlib_shims/shared_mem.zig");
pub const atomic_shim = @import("stdlib_shims/atomic.zig");
pub const gzip_shim = @import("stdlib_shims/gzip.zig");
pub const smtp_shim = @import("stdlib_shims/smtp.zig");

// Bu modüllerin yalnızca isim üzerinden yeniden dışa aktarılması, Zig'in
// tembel (lazy) analiz modelinde `export fn` bildirimlerinin nesne çıktısına
// alınmasını GARANTİ ETMEZ (hiçbir şey onları başvurmadıkça analiz edilmez).
// Bu, içindeki tüm bildirimleri zorla analiz ettirip `export` sözleşmesinin
// (her zaman emit edilir) devreye girmesini sağlar.
comptime {
    _ = asap;
    _ = multi_runtime_test;
    _ = arc;
    _ = dispatch_registry;
    _ = diag_sink;
    _ = lowlevel;
    _ = cycle_detector;
    _ = @import("alloc/ptr_map.zig");
    _ = defer_stack;
    _ = errors;
    _ = foreign_bridge;
    _ = async_bridge;
    _ = thread_bridge;
    _ = pool_bridge;
    _ = thread_channel;
    _ = task_local;
    _ = task_local_entry;
    _ = task_wait;
    _ = signal_shim;
    _ = terminal_shim;
    _ = redis_shim;
    _ = grpc_shim;
    _ = client_cert_shim;
    _ = tz_shim;
    _ = udp_shim;
    _ = chase_lev_deque;
    _ = size_class_heap;
    _ = worker_pool;
    _ = str;
    _ = @import("unicode.zig");
    _ = @import("unicode_norm.zig");
    _ = format;
    _ = dict;
    _ = list_sort;
    _ = list_ops;
    _ = embed;
    _ = http_client;
    _ = @import("stdlib_shims/net_dial.zig");
    _ = @import("stdlib_shims/tcp_native.zig");
    _ = http_stream;
    _ = http_server;
    _ = strings_shim;
    _ = math_shim;
    _ = os_shim;
    _ = fs_shim;
    _ = path_shim;
    _ = time_shim;
    _ = json_shim;
    _ = random_shim;
    _ = crypto_shim;
    _ = regex_shim;
    _ = unicode_shim;
    _ = io_shim;
    _ = sqlite_shim;
    _ = process_shim;
    _ = postgres_shim;
    _ = native_shim;
    _ = mysql_shim;
    _ = tls_shim;
    _ = websocket_shim;
    _ = websocket_server_shim;
    _ = shared_mem_shim;
    _ = atomic_shim;
    _ = gzip_shim;
    _ = smtp_shim;
}
