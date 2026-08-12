//! Nox Zig runtime — noxc tarafından üretilen native binary'lere statik
//! bağlanır. `export fn` ile işaretli semboller C-ABI üzerinden QBE'nin
//! ürettiği makine kodundan çağrılabilir.

pub const asap = @import("alloc/asap.zig");
pub const arc = @import("alloc/arc.zig");
pub const lowlevel = @import("alloc/lowlevel.zig");
pub const cycle_detector = @import("alloc/cycle_detector.zig");
pub const defer_stack = @import("alloc/defer_stack.zig");
pub const errors = @import("errors/handle.zig");
pub const foreign_bridge = @import("foreign_bridge.zig");
pub const async_bridge = @import("async_rt/bridge.zig");
pub const thread_bridge = @import("async_rt/thread_bridge.zig");
pub const thread_channel = @import("async_rt/thread_channel.zig");
pub const task_local = @import("async_rt/task_local.zig");
/// Faz MN.3a: BAĞIMSIZ, henüz HİÇBİR yere BAĞLANMAMIŞ (bkz. onun modül
/// üstü notu) — SADECE `zig build test`nin `noxrt_test`inin (bu dosyayı
/// KÖK modül olarak kullanan) KENDİ testlerini KEŞFEDEBİLMESİ İçİn burada
/// isim-üzerinden yeniden dışa aktarılıyor.
pub const chase_lev_deque = @import("async_rt/chase_lev_deque.zig");
/// Faz MN.3b: MN.3a İLE AYNI "bağımsız, sadece test-keşfi İçİn KAYITLI"
/// deseni — bkz. onun modül üstü notu.
pub const worker_pool = @import("async_rt/worker_pool.zig");
/// Faz MN.7a: `nox.thread.pool_run`ın C-ABI yüzeyi — `thread_bridge`/
/// `thread_channel` İLE AYNI, GERÇEK Nox codegen'inden çağrılan bir
/// modül (`chase_lev_deque`/`worker_pool`nin "bağımsız, sadece test-
/// keşfi İçİN" notu BURAYA UYGULANMAZ).
pub const pool_bridge = @import("async_rt/pool_bridge.zig");
pub const str = @import("str.zig");
pub const dict = @import("collections/dict.zig");
pub const list_sort = @import("collections/list_sort.zig");
pub const http_client = @import("stdlib_shims/http_client.zig");
pub const http_server = @import("stdlib_shims/http_server.zig");
pub const strings_shim = @import("stdlib_shims/strings.zig");
pub const os_shim = @import("stdlib_shims/os.zig");
pub const fs_shim = @import("stdlib_shims/fs.zig");
pub const path_shim = @import("stdlib_shims/path.zig");
pub const time_shim = @import("stdlib_shims/time.zig");
pub const json_shim = @import("stdlib_shims/json.zig");
pub const random_shim = @import("stdlib_shims/random.zig");
pub const crypto_shim = @import("stdlib_shims/crypto.zig");
pub const regex_shim = @import("stdlib_shims/regex.zig");
pub const io_shim = @import("stdlib_shims/io.zig");
pub const sqlite_shim = @import("stdlib_shims/sqlite.zig");
pub const process_shim = @import("stdlib_shims/process.zig");
pub const postgres_shim = @import("stdlib_shims/postgres.zig");
pub const mysql_shim = @import("stdlib_shims/mysql.zig");
pub const tls_shim = @import("stdlib_shims/tls.zig");
pub const tls_server_shim = @import("stdlib_shims/tls_server.zig");
pub const websocket_shim = @import("stdlib_shims/websocket.zig");
pub const websocket_server_shim = @import("stdlib_shims/websocket_server.zig");
pub const shared_mem_shim = @import("stdlib_shims/shared_mem.zig");

// Bu modüllerin yalnızca isim üzerinden yeniden dışa aktarılması, Zig'in
// tembel (lazy) analiz modelinde `export fn` bildirimlerinin nesne çıktısına
// alınmasını GARANTİ ETMEZ (hiçbir şey onları başvurmadıkça analiz edilmez).
// Bu, içindeki tüm bildirimleri zorla analiz ettirip `export` sözleşmesinin
// (her zaman emit edilir) devreye girmesini sağlar.
comptime {
    _ = asap;
    _ = arc;
    _ = lowlevel;
    _ = cycle_detector;
    _ = defer_stack;
    _ = errors;
    _ = foreign_bridge;
    _ = async_bridge;
    _ = thread_bridge;
    _ = pool_bridge;
    _ = thread_channel;
    _ = task_local;
    _ = chase_lev_deque;
    _ = worker_pool;
    _ = str;
    _ = dict;
    _ = list_sort;
    _ = http_client;
    _ = http_server;
    _ = strings_shim;
    _ = os_shim;
    _ = fs_shim;
    _ = path_shim;
    _ = time_shim;
    _ = json_shim;
    _ = random_shim;
    _ = crypto_shim;
    _ = regex_shim;
    _ = io_shim;
    _ = sqlite_shim;
    _ = process_shim;
    _ = postgres_shim;
    _ = mysql_shim;
    _ = tls_shim;
    _ = websocket_shim;
    _ = websocket_server_shim;
    _ = shared_mem_shim;
}
