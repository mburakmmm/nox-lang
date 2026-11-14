//! `noxc sbom` (TODO 7.4 S1): CycloneDX 1.5 çıktısı geçerli, deterministik, native işaretleri doğru; saf Nox projesi native=false.

const std = @import("std");

fn runSbom(a: std.mem.Allocator, io: std.Io, dir: []const u8) ![]u8 {
    const r = try std.process.run(a, io, .{ .argv = &.{ "zig-out/bin/noxc", "sbom", dir } });
    defer a.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("noxc sbom basarisiz: {s}\n", .{r.stderr});
        a.free(r.stdout);
        return error.SbomFailed;
    }
    return r.stdout;
}

test "noxc sbom: deterministik CycloneDX 1.5, native proje işaretlenir, kilitli bağımlılık purl taşır" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "nox.json", .data = "{\"name\": \"demo\", \"entry\": \"main.nox\", \"requires\": []}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.nox", .data = "extern def sqrt(x: float) -> float from \"libm\"\nprint(sqrt(4.0))\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "nox.lock", .data = "{\"packages\": [{\"alias\": \"zeta\", \"repo\": \"github.com/o/zeta\", \"ref\": \"v1\", \"resolved\": \"0123456789abcdef0123456789abcdef01234567\"}, {\"alias\": \"alpha\", \"repo\": \"github.com/o/alpha\", \"ref\": \"v2\", \"resolved\": \"89abcdef0123456789abcdef0123456789abcdef\"}]}" });

    const one = try runSbom(a, io, dir);
    defer a.free(one);
    const two = try runSbom(a, io, dir);
    defer a.free(two);
    try std.testing.expectEqualStrings(one, two); // deterministik

    const parsed = try std.json.parseFromSlice(std.json.Value, a, one, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("CycloneDX", root.get("bomFormat").?.string);
    try std.testing.expectEqualStrings("1.5", root.get("specVersion").?.string);
    const comps = root.get("components").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), comps.len);
    // alias sırası: alpha, zeta
    try std.testing.expectEqualStrings("alpha", comps[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("pkg:github/o/zeta@0123456789abcdef0123456789abcdef01234567", comps[1].object.get("purl").?.string);
    // proje native (extern def + libm)
    try std.testing.expect(std.mem.indexOf(u8, one, "\"nox:extern-libs\", \"value\": \"libm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"nox:native\", \"value\": \"true\"") != null);
    // önbellekte olmayan bağımlılık "taranmadı" diye işaretlenir
    try std.testing.expect(std.mem.indexOf(u8, one, "\"nox:scanned\", \"value\": \"false\"") != null);
}
