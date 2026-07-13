//! Nox WASM köprüsü — tek import yüzeyi (AGENTS.md §11). `hpy_bridge` gibi,
//! bu da henüz derlenmiş Nox programlarına DEĞİL, `tests/compat`teki uçtan
//! uca doğrulamaya hizmet eder.

pub const module = @import("module.zig");
pub const interp = @import("interp.zig");

comptime {
    _ = module;
    _ = interp;
}
