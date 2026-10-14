//! `noxc`nin host `cc`/`clang` kuyruğu. `tests/golden` ve `tests/compat`
//! ayrı modül kökleridir; relative import modül sınırını aşar. Bu dosya
//! named module olarak paylaşılır (`diag_sink` ile aynı gerekçe).

const std = @import("std");
const builtin = @import("builtin");

/// MinGW `-rdynamic` tanımaz.
pub fn hostLinkVisibility() []const u8 {
    return if (builtin.os.tag == .windows) "-Wl,--export-all-symbols" else "-rdynamic";
}

/// Windows'ta `swap_asm.o` `noxrt.o`nun dışındadır. `ntdll`/`ws2_32`/
/// `crypt32` MinGW'nin varsayılan kütüphaneleri değildir. `clang` MSVC
/// üçlüsüne düşmesin diye GNU hedefi verilir. Dönüş `allocator`a aittir.
pub fn hostLinkArgv(
    allocator: std.mem.Allocator,
    prefix: []const []const u8,
    out_path: []const u8,
    input_path: []const u8,
    extra_objects: []const []const u8,
) ![]const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.appendSlice(allocator, prefix);
    if (builtin.os.tag == .windows and prefix.len > 0 and std.mem.eql(u8, prefix[0], "clang")) {
        try argv.appendSlice(allocator, &.{ "-target", "x86_64-w64-windows-gnu", "-Wno-override-module" });
    }
    try argv.appendSlice(allocator, &.{ "-o", out_path, input_path, "zig-out/lib/noxrt.o" });
    if (builtin.os.tag == .windows) try argv.append(allocator, "zig-out/lib/swap_asm.o");
    try argv.appendSlice(allocator, extra_objects);
    try argv.append(allocator, "-lm");
    if (builtin.os.tag == .windows) try argv.appendSlice(allocator, &.{ "-lntdll", "-lws2_32", "-lcrypt32" });
    return try argv.toOwnedSlice(allocator);
}
