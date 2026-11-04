//! Derleme zamanı aracı: `stdlib/` ağacındaki `.nox` dosyalarını TEK bir paket dosyasına yazar (stdout). Tarayıcıdaki WASM derleyiciye (`compiler/wasm_compiler.zig`) gömülür, böylece
//! derleyici dosya sistemine ihtiyaç duymadan `import nox.*` çözebilir. Biçim (küçük-endian): tekrarlayan kayıtlar `u32 yol uzunluğu`, yol (`nox/http.nox` gibi, stdlib köküne göreli),
//! `u32 veri uzunluğu`, veri. Kayıtlar yola göre sıralıdır (yeniden üretilebilir çıktı).
//! Kullanım: bundle_stdlib <stdlib_dizini>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(a);
    _ = args.next();
    const root = args.next() orelse return error.Usage;

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".nox")) continue;
        try files.append(a, try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (files.items) |rel| {
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
        const data = try std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(8 * 1024 * 1024));
        // Windows'ta yol ayracı `\` olabilir; paket her zaman `/` kullanır.
        const norm = try a.dupe(u8, rel);
        std.mem.replaceScalar(u8, norm, '\\', '/');
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(norm.len))));
        try out.appendSlice(a, norm);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(data.len))));
        try out.appendSlice(a, data);
    }
    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    try w.interface.writeAll(out.items);
    try w.interface.flush();
}
