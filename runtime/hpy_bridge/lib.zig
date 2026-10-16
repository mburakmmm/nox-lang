//! Nox HPy köprüsü (Tier 0) — tek import yüzeyi. Bu modül, derlenmiş Nox
//! programlarına (`noxc` çıktısı) DEĞİL, `tests/compat`teki uçtan uca
//! doğrulamaya ve gelecekteki derleyici entegrasyonuna hizmet eder (bkz.
//! context.zig'in modül üstü notu, "bilinen sınırlamalar").

pub const context = @import("context.zig");
pub const loader = @import("loader.zig");
pub const host_contract = @import("hpy_contract");

comptime {
    _ = context;
    _ = loader;
    _ = host_contract;
    _ = @import("abi_dump.zig");
}
