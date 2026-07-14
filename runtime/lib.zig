//! Nox Zig runtime — noxc tarafından üretilen native binary'lere statik
//! bağlanır. `export fn` ile işaretli semboller C-ABI üzerinden QBE'nin
//! ürettiği makine kodundan çağrılabilir.

pub const asap = @import("alloc/asap.zig");
pub const arc = @import("alloc/arc.zig");
pub const lowlevel = @import("alloc/lowlevel.zig");
pub const cycle_detector = @import("alloc/cycle_detector.zig");
pub const errors = @import("errors/handle.zig");
pub const foreign_bridge = @import("foreign_bridge.zig");
pub const async_bridge = @import("async_rt/bridge.zig");
pub const str = @import("str.zig");
pub const dict = @import("collections/dict.zig");
pub const http_client = @import("stdlib_shims/http_client.zig");
pub const http_server = @import("stdlib_shims/http_server.zig");
pub const strings_shim = @import("stdlib_shims/strings.zig");
pub const os_shim = @import("stdlib_shims/os.zig");
pub const fs_shim = @import("stdlib_shims/fs.zig");
pub const time_shim = @import("stdlib_shims/time.zig");
pub const json_shim = @import("stdlib_shims/json.zig");
pub const random_shim = @import("stdlib_shims/random.zig");
pub const crypto_shim = @import("stdlib_shims/crypto.zig");

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
    _ = errors;
    _ = foreign_bridge;
    _ = async_bridge;
    _ = str;
    _ = dict;
    _ = http_client;
    _ = http_server;
    _ = strings_shim;
    _ = os_shim;
    _ = fs_shim;
    _ = time_shim;
    _ = json_shim;
    _ = random_shim;
    _ = crypto_shim;
}
