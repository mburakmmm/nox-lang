//! Faz IR.0 (bkz. plan dosyası "QBE metin-emisyonu için bir 'instruction
//! emission' katmanı çıkarma"): `compiler/codegen_qbe/`nin 15 dosyasını
//! `qbe_emit.zig`nin ARKASINA taşıyan 14 migrasyon dilimi BOYUNCA
//! kullanılan MEKANİK bir bekçi — davranışsal testler (`codegen_golden_
//! test.zig`) SADECE "program hâlâ doğru çalışıyor" kanıtlar, "üretilen
//! QBE metni TAM OLARAK aynı kaldı" KANITLAMAZ (ör. `csltl`nin sessizce
//! `cultl`ye DÖNÜŞMESİ GİBİ bir hata, golden fixture'ı OLMAYAN bir yolda
//! YAKALANMAYABİLİR).
//!
//! `tests/golden/codegen_cases/` + `tests/golden/ownership_cases/`
//! altındaki HER `.nox` fixture İçin `nox.codegen.generateModule`in
//! ÜRETTİĞİ HAM metni (`qbe`/`cc`ye HİÇ GEÇMEDEN) `tests/golden/
//! ir_snapshots/<aynı-dizin>/<isim>.ssa`deki ÇEKİLİ (checked-in) anlık
//! görüntüyle byte-birebir karşılaştırır. Bir fixture'ın anlık görüntüsü
//! YOKSA (ör. İLK çalıştırma, YA DA yeni eklenen bir fixture) OTOMATİK
//! OLUŞTURULUR — bu YÜZDEN "anlık görüntü kasıtlı olarak GÜNCELLENMEK"
//! isteniyorsa (GERÇEK bir codegen değişikliği, bu migrasyon fazının
//! KAPSAMI DIŞINDA), İLGİLİ `.ssa` dosyaları ELLE silinip test YENİDEN
//! çalıştırılmalıdır.
//!
//! Checker'ın (kasıtlı olarak) reddettiği fixture'lar (ör. `rejected_
//! lowlevel_escape.nox`) SESSİZCE ATLANIR — bu dosya SADECE metin-
//! kararlılığını sınar, tip denetimi davranışını DEĞİL (bu, `codegen_
//! golden_test.zig`/`typecheck_golden_test.zig`nin İŞİ).

const std = @import("std");
const nox = @import("nox");

const FIXTURE_DIRS = [_][]const u8{
    "tests/golden/codegen_cases",
    "tests/golden/ownership_cases",
};
const SNAPSHOT_ROOT = "tests/golden/ir_snapshots";

/// `compileAndRun`in (`codegen_golden_test.zig`) ön-uç zincirinin AYNISI
/// — `qbe`/`cc`ye GEÇMEDEN, SADECE in-memory `ir` metnini döner.
/// Lexer/parser HİÇBİR fixture'da BAŞARISIZ OLMAMALI (hepsi sözdizimsel
/// olarak GEÇERLİ Nox kaynağı) — bu YÜZDEN `try` İLE PROPAGATE edilir.
/// Checker/codegen İSE bilerek REDDEDEN fixture'lar OLABİLİR — bu ikisi
/// `null` (atla) döner.
fn generateIr(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !?[]const u8 {
    const tokens = try nox.lexer.tokenize(allocator, source);
    const user_module = try nox.parser.parseModule(allocator, tokens);
    const module = try nox.module_loader.resolveImports(allocator, io, user_module);

    var checker_state = nox.checker.Checker.init(allocator);
    checker_state.checkModule(module) catch return null;
    if (checker_state.diagnostics.items.len > 0) return null;

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(allocator, k.*);

    var generic_class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_class_it = checker_state.generic_classes.keyIterator();
    while (generic_class_it.next()) |k| try generic_class_names.append(allocator, k.*);

    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try allocator.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(allocator, entry.key_ptr.*, names);
    }

    var functions_used_as_value: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = checker_state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try functions_used_as_value.append(allocator, k.*);

    const ir = nox.codegen.generateModule(
        allocator,
        module,
        checker_state.instantiations.items,
        generic_names.items,
        checker_state.class_instantiations.items,
        generic_class_names.items,
        null,
        closure_infos,
        checker_state.defer_synthetic_names,
        checker_state.from_imports,
        functions_used_as_value.items,
        checker_state.module_aliases,
        checker_state.decorated_functions.items,
        .qbe,
        null,
    ) catch return null;

    return ir;
}

test "codegen IR metni: fixture başına çekili anlık görüntüyle byte-birebir aynı" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var mismatches: std.ArrayListUnmanaged([]const u8) = .empty;
    var created: usize = 0;
    var compared: usize = 0;
    var skipped: usize = 0;

    for (FIXTURE_DIRS) |fixture_dir| {
        var dir = try std.Io.Dir.cwd().openDir(io, fixture_dir, .{ .iterate = true });
        defer dir.close(io);

        const snapshot_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ SNAPSHOT_ROOT, std.fs.path.basename(fixture_dir) });
        try std.Io.Dir.cwd().createDirPath(io, snapshot_dir_path);
        var snapshot_dir = try std.Io.Dir.cwd().openDir(io, snapshot_dir_path, .{});
        defer snapshot_dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".nox")) continue;

            const source = try dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024));
            const maybe_ir = try generateIr(allocator, io, source);
            const ir = maybe_ir orelse {
                skipped += 1;
                continue;
            };

            const snapshot_name = try std.fmt.allocPrint(allocator, "{s}.ssa", .{entry.name[0 .. entry.name.len - ".nox".len]});
            const existing = snapshot_dir.readFileAlloc(io, snapshot_name, allocator, .limited(8 * 1024 * 1024)) catch |e| switch (e) {
                error.FileNotFound => {
                    try snapshot_dir.writeFile(io, .{ .sub_path = snapshot_name, .data = ir });
                    created += 1;
                    continue;
                },
                else => return e,
            };
            compared += 1;
            if (!std.mem.eql(u8, existing, ir)) {
                try mismatches.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ fixture_dir, entry.name }));
            }
        }
    }

    std.debug.print("IR-diff: {d} karşılaştırıldı, {d} yeni anlık görüntü oluşturuldu, {d} atlandı (derlenmedi)\n", .{ compared, created, skipped });

    if (mismatches.items.len > 0) {
        std.debug.print("IR metni DEĞİŞTİ ({d} fixture) — kasıtlı bir codegen değişikliğiyse İLGİLİ .ssa anlık görüntüsünü sil ve testi yeniden çalıştır:\n", .{mismatches.items.len});
        for (mismatches.items) |m| std.debug.print("  {s}\n", .{m});
        return error.IrTextChanged;
    }
}
