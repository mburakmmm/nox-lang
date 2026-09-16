//! Faz F.1 (bkz. plan dosyası "Cross-compile İSKELETİ"): bu turun KENDİ,
//! doğrudan-deneysel (scratchpad'de yapılan) bulgusunu KALICI, tekrarlanabilir
//! bir teste ÇEVİRİR — QBE'nin x86_64 SysV (`amd64_sysv`) çıktısı GERÇEKTEN,
//! statik-bağlı, freestanding bir ELF ikilisi olarak linklenebiliyor MU
//! sorusunun (F.1'in KENDİ, önceden tanımlı falsifiable deneyi) CEVABI.
//!
//! Bu turda BULUNAN kritik ayrım: DÜZ sistem `cc`si (Apple clang, macOS'ta)
//! ELF nesne dosyalarını HİÇ İŞLEYEMİYOR (`ld: unknown file type`) — SADECE
//! `zig cc` (Zig'in KENDİ, evrensel LLD linker'ını KULLANARAK) BUNU BAŞARIYLA
//! yapabiliyor. Bu YÜZDEN bu test `cc`/`clang` DEĞİL, `zig cc`yi (`build.zig`
//! tarafından `build_options.zig_exe_path` ÜZERİNDEN geçirilen, `b.graph.
//! zig_exe` — `wasm_build_options`nin AYNI deseni) linker sürücüsü OLARAK
//! kullanır.
//!
//! `qbe` PATH'te YOKSA (bu HİÇ olmamalı — `ci.yml`nin HER işi "qbe kur"
//! adımını taşır — AMA yerel bir geliştirme makinesinde eksik olabilir)
//! test SESSİZCE `SkipZigTest` ile atlanır (`compile_helpers.zig`nin AYNI
//! "harici araç eksikse ana takımı KIRMA" ilkesi).

const std = @import("std");
const build_options = @import("build_options");

/// QBE IL — bir veri bölümü (`$msg`) VE bir DOĞRUDAN (non-`.globl`,
/// dolayısıyla PLT'siz) fonksiyon çağrısı (`$helper`) İçerir — SADECE
/// çağrı-içermeyen bir örnek DEĞİL, F.1'in araştırmasının "min2.ssa"sıyla
/// BİREBİR AYNI, GERÇEKÇİ bir desen.
const min2_ssa =
    \\data $msg = { b "AB", b 0 }
    \\function $helper(l %addr, w %val) {
    \\@start
    \\    storeb %val, %addr
    \\    ret
    \\}
    \\export function $_start() {
    \\@start
    \\    %p =l copy $msg
    \\    %v =w copy 67
    \\    call $helper(l %p, w %v)
    \\    ret
    \\}
    \\
;

test "Faz F.1: QBE'nin x86_64 SysV çıktısı freestanding, statik bir ELF olarak (zig cc aracılığıyla) linklenebiliyor" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..len];

    const ssa_path = try std.fmt.allocPrint(allocator, "{s}/min2.ssa", .{dir_path});
    defer allocator.free(ssa_path);
    const asm_path = try std.fmt.allocPrint(allocator, "{s}/min2.s", .{dir_path});
    defer allocator.free(asm_path);
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/min2_bin", .{dir_path});
    defer allocator.free(bin_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "min2.ssa", .data = min2_ssa });

    const qbe_result = std.process.run(allocator, io, .{
        .argv = &.{ "qbe", "-t", "amd64_sysv", "-o", asm_path, ssa_path },
    }) catch return error.SkipZigTest;
    defer allocator.free(qbe_result.stdout);
    defer allocator.free(qbe_result.stderr);
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz: {s}\n", .{qbe_result.stderr});
        return error.QbeFailed;
    }

    const cc_result = std.process.run(allocator, io, .{
        .argv = &.{
            build_options.zig_exe_path,
            "cc",
            "-target",
            "x86_64-freestanding-none",
            "-ffreestanding",
            "-nostdlib",
            "-static",
            "-o",
            bin_path,
            asm_path,
        },
    }) catch return error.SkipZigTest;
    defer allocator.free(cc_result.stdout);
    defer allocator.free(cc_result.stderr);
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("zig cc basarisiz: {s}\n", .{cc_result.stderr});
        return error.ZigCcFailed;
    }

    // `readelf`/`nm` GİBİ harici bir araca BAĞIMLI OLMADAN (CI'de MEVCUT
    // OLMAYABİLİR) — ELF header'ı DOĞRUDAN, ELLE doğrular: magic bytes
    // (`\x7fELF`) + `e_type` alanı (offset 16, 2 bayt, little-endian)
    // `ET_EXEC` (2) OLMALI — statik, çalıştırılabilir bir ikili, PIE/paylaşımlı
    // nesne DEĞİL.
    const bin_bytes = try tmp.dir.readFileAlloc(io, "min2_bin", allocator, .limited(1024 * 1024));
    defer allocator.free(bin_bytes);
    try std.testing.expect(bin_bytes.len >= 18);
    try std.testing.expectEqualSlices(u8, "\x7fELF", bin_bytes[0..4]);
    const e_type = std.mem.readInt(u16, bin_bytes[16..18], .little);
    try std.testing.expectEqual(@as(u16, 2), e_type); // ET_EXEC
}
