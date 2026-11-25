//! Nox WASM köprüsü — tek import yüzeyi (AGENTS.md §11): ayrıştırıcı (`module`) + yorumlayıcı (`interp`). `wasm_call` yerleşiği ve `nox.wasm` bunun üzerine kuruludur.

pub const module = @import("module.zig");
pub const compile = @import("compile.zig");
pub const interp = @import("interp.zig");

comptime {
    _ = module;
    _ = compile;
    _ = interp;
}
