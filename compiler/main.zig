//! noxc — Nox derleyicisi giriş noktası.
//! Faz 4 itibarıyla lexer + parser + zorunlu statik tip denetimi + sahiplik
//! analizi + QBE codegen (yalnızca değer tipleri) bağlıdır; qbe ve sistem
//! `cc`'si çağrılarak gerçek bir native binary üretilir.
//!
//! **Faz O §P.2/§P.3 (bkz. plan dosyası "Faz O" bölümü, nox-teknik-
//! spesifikasyon.md §3.6):** `noxc` artık Cargo/Go tarzı alt komutlar
//! tanır — `build`/`run`/`test` (+ henüz REZERVE edilmiş `fmt`/`fetch`/
//! `update`, bkz. P.5/P.7/P.8). Çıplak `noxc <dosya.nox>` (alt komut
//! OLMADAN) **geriye dönük uyumluluk İÇİN `build`in bir takma adı olarak
//! KORUNUR** — çıktı/mesaj/çıkış kodu BİREBİR aynı (bkz. `cmdBuild`'e
//! geçirilen `usage` argümanının legacy/yeni-CLI için AYRI tutulması).
//! İlk bayrak-olmayan argüman bilinen bir alt komut anahtar kelimesiyle
//! EŞLEŞMİYORSA (ör. bir `.nox` yolu ya da `--dump`) eski tekil-dosya
//! yoluna DÜŞÜLÜR.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const ast = @import("parser/ast.zig");
const ast_dump = @import("parser/ast_dump.zig");
const checker = @import("typecheck/checker.zig");
const ownership = @import("ownership/analysis.zig");
const codegen = @import("codegen_qbe/codegen.zig");
const module_loader = @import("module_loader.zig");
const project = @import("project.zig");
const qbe_target = @import("qbe_target.zig");
const test_runner = @import("pkg/test_runner.zig");
const fetch = @import("pkg/fetch.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var all_args: std.ArrayListUnmanaged([]const u8) = .empty;
    var arg_it = init.minimal.args.iterate();
    _ = arg_it.next(); // program adı
    while (arg_it.next()) |arg| try all_args.append(gpa, arg);
    defer all_args.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Faz O §P.6: üçüncü-taraf paket önbelleğinin KÖKÜ — `NOX_HOME` ortam
    // değişkeni VERİLMİŞSE (testlerin GERÇEK `~/.nox`a dokunmaması İÇİN
    // KRİTİK override) doğrudan KULLANILIR, aksi halde `$HOME/.nox`
    // varsayılır (bkz. plan dosyası §3.3 — "$NOX_HOME varsayılan ~/.nox").
    const nox_home_env_override = if (init.environ_map.get("NOX_HOME")) |h| try a.dupe(u8, h) else null;
    const nox_home = nox_home_env_override orelse blk: {
        const home = init.environ_map.get("HOME") orelse "";
        break :blk try std.fmt.allocPrint(a, "{s}/.nox", .{home});
    };

    // Faz Q.3: `noxc`nin KENDİ stdlib/runtime kaynak dizinleri — `NOX_HOME`
    // İLE KARIŞTIRILMAMASI GEREKEN AYRI bir override: `NOX_HOME` üçüncü-
    // taraf paket ÖNBELLEĞİNİN köküdür (bkz. `nox_home`), stdlib/runtime
    // İSE `noxc` İKİLİSİNİN KENDİ kurulumunun bir PARÇASIdır — ikisi AYNI
    // dizine denk gelmesi GEREKMEZ (ör. `tests/cli/package_resolution_test.
    // zig`nin izole `$NOX_HOME`si SADECE paket önbelleğini izole eder, HİÇ
    // stdlib/runtime İÇERMEZ). `NOX_RESOURCE_DIR` AÇIKÇA verilmişse O KÖK
    // KULLANILIR; AKSİ HALDE `noxc`nin KENDİ çalıştırılabilir dosya
    // konumundan (`<exe_dir>/../lib/...`) hesaplanır — bkz. `project.
    // resolveResourceDirs`in belge notu. Bu, `noxc`nin proje kökü DIŞINDAN
    // (ör. sistem geneli bir kurulumdan) çalıştırılabilmesini SAĞLAR.
    const resource_dir_override = if (init.environ_map.get("NOX_RESOURCE_DIR")) |h| try a.dupe(u8, h) else null;
    const resource_dirs = try project.resolveResourceDirs(a, io, resource_dir_override);

    const Subcommand = enum { build, run, test_cmd, fmt, fetch, update, legacy };
    const sub: Subcommand = blk: {
        if (all_args.items.len == 0) break :blk .legacy;
        const first = all_args.items[0];
        if (std.mem.eql(u8, first, "build")) break :blk .build;
        if (std.mem.eql(u8, first, "run")) break :blk .run;
        if (std.mem.eql(u8, first, "test")) break :blk .test_cmd;
        if (std.mem.eql(u8, first, "fmt")) break :blk .fmt;
        if (std.mem.eql(u8, first, "fetch")) break :blk .fetch;
        if (std.mem.eql(u8, first, "update")) break :blk .update;
        break :blk .legacy;
    };
    const rest: []const []const u8 = if (sub == .legacy) all_args.items else all_args.items[1..];

    switch (sub) {
        .build => try cmdBuild(gpa, io, a, rest, "kullanim: noxc build [--dump|-v] [-o <cikti>] <dosya.nox>\n", nox_home, resource_dirs),
        .legacy => try cmdBuild(gpa, io, a, rest, "kullanim: noxc [--dump|-v] <dosya.nox>\n", nox_home, resource_dirs),
        .run => try cmdRun(gpa, io, a, rest, nox_home, resource_dirs),
        .test_cmd => try cmdTest(gpa, io, a, rest, nox_home, resource_dirs),
        .fmt, .fetch, .update => {
            std.debug.print("noxc {s}: henuz uygulanmadi (bkz. plan dosyasi, Faz O)\n", .{@tagName(sub)});
            std.process.exit(1);
        },
    }
}

const BuildOpts = struct {
    path: ?[]const u8 = null,
    verbose: bool = false,
    output: ?[]const u8 = null,
};

fn parseBuildOpts(args: []const []const u8) BuildOpts {
    var opts: BuildOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) opts.output = args[i];
        } else if (opts.path == null) {
            opts.path = arg;
        }
    }
    return opts;
}

/// `args`i İLK `--` argümanında ikiye böler (`run`in çocuk sürece iletilecek
/// argv'si İÇİN) — `--` bulunmazsa `after` boştur.
fn splitOnDoubleDash(args: []const []const u8) struct { before: []const []const u8, after: []const []const u8 } {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) {
            return .{ .before = args[0..i], .after = args[i + 1 ..] };
        }
    }
    return .{ .before = args, .after = &.{} };
}

fn cmdBuild(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, usage: []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs) !void {
    const opts = parseBuildOpts(args);
    const path_arg = opts.path orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    const out = try buildOne(gpa, io, a, path_arg, opts.verbose, opts.output, nox_home, resource_dirs);
    std.debug.print("derlendi: {s}\n", .{out});
}

/// `noxc run`/`noxc test` (Faz O §P.2 — `test`in GERÇEK `*_test.nox` keşif/
/// toplama kuralı §P.3'te bu fonksiyonun YERİNİ alacak; şimdilik TEK bir
/// dosyayı derleyip çalıştırmak, `nox.test`in `raise`-ile-başarısız-olma
/// modeliyle zaten TUTARLI bir ilk adımdır): `buildOne`ı proje-yerel bir
/// önbelleğe (`<proje_kökü_veya_dosya_dizini>/.nox/cache/bin/<isim>`,
/// KAYNAĞIN YANINA DEĞİL) derler, çalıştırılabilir dosyayı stdio'yu
/// MİRAS ALARAK çalıştırır, çocuğun çıkış kodunu AYNEN yansıtır.
fn cmdRun(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs) !void {
    const split = splitOnDoubleDash(args);
    const opts = parseBuildOpts(split.before);
    const path_arg = opts.path orelse {
        std.debug.print("kullanim: noxc run [--dump|-v] <dosya.nox> [-- argv...]\n", .{});
        std.process.exit(1);
    };

    const cache_bin_path = try cacheBinPath(io, a, path_arg);
    const bin_path = try buildOne(gpa, io, a, path_arg, opts.verbose, cache_bin_path, nox_home, resource_dirs);

    const code = try runAndWait(io, a, bin_path, split.after);
    std.process.exit(code);
}

/// `bin_path`i (`argv_tail` argümanları AYRICA iletilerek) çalıştırır,
/// stdio'yu MİRAS ALARAK (bkz. `cmdRun`'ın belge notu), çıkış kodunu döner.
fn runAndWait(io: std.Io, a: std.mem.Allocator, bin_path: []const u8, argv_tail: []const []const u8) !u8 {
    var child_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try child_argv.append(a, bin_path);
    try child_argv.appendSlice(a, argv_tail);

    var child = try std.process.spawn(io, .{ .argv = child_argv.items });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

/// Faz O §P.3: `noxc test [yol]`. `yol` bir `.nox` DOSYASIYSA (P.2'nin
/// eski davranışı — GERİYE DÖNÜK UYUMLU bırakıldı) TEK dosya derlenip
/// çalıştırılır, çıkış kodu AYNEN yansıtılır. AKSİ HALDE (`yol` bir DİZİNSE
/// ya da HİÇ verilmediyse — o zaman CWD kullanılır) `yol`(ya da CWD)
/// altında `*_test.nox` İLE BİTEN TÜM dosyalar (bkz. `test_runner.
/// discoverTestFiles`) KEŞFEDİLİR, HER biri BAĞIMSIZ derlenip çalıştırılır,
/// sonuçlar TOPLANIP bir özet basılır; HERHANGİ biri başarısızsa (çıkış
/// kodu != 0) `noxc test`in KENDİSİ de çıkış kodu `1` ile sonlanır.
///
/// **Bilinçli sınırlama:** bir test dosyasının DERLENMESİ başarısız olursa
/// (`buildOne` İÇİNDEKİ mevcut hata yollarının HER BİRİ hâlâ doğrudan
/// `std.process.exit(1)` çağırıyor, bkz. `buildOne`'ın belge notu) TÜM
/// `noxc test` çalışması ORADA durur — yalnızca ÇALIŞMA ZAMANI (derlenmiş
/// binary'nin çıkış kodu) başarısızlıkları dosya-dosya TOPLANIR. Bu, Go'nun
/// `go test`inin KENDİ paketi derlenemezse TÜM paketi başarısız SAYMASIYLA
/// AYNI kategoride bir davranış — bir test dosyasının derlenmemesi zaten
/// KENDİ BAŞINA acil düzeltilmesi gereken bir hata, "diğer testlere devam
/// et" mantığıyla GİZLENMEMELİ.
fn cmdTest(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs) !void {
    const opts = parseBuildOpts(args);

    if (opts.path) |t| {
        if (std.mem.endsWith(u8, t, ".nox")) {
            const cache_bin_path = try cacheBinPath(io, a, t);
            const bin_path = try buildOne(gpa, io, a, t, opts.verbose, cache_bin_path, nox_home, resource_dirs);
            const code = try runAndWait(io, a, bin_path, &.{});
            std.process.exit(code);
        }
    }

    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const walk_root = if (opts.path) |t|
        (if (std.fs.path.isAbsolute(t)) try a.dupe(u8, t) else try std.fs.path.resolve(a, &.{ cwd_abs, t }))
    else
        cwd_abs;

    const files = try test_runner.discoverTestFiles(a, io, walk_root);
    if (files.len == 0) {
        std.debug.print("0 test dosyasi bulundu ({s} altinda *_test.nox aranir)\n", .{walk_root});
        return;
    }

    var pass_count: usize = 0;
    var fail_count: usize = 0;
    for (files) |file| {
        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const cache_bin_path = try cacheBinPath(io, fa, file);
        const bin_path = try buildOne(gpa, io, fa, file, opts.verbose, cache_bin_path, nox_home, resource_dirs);
        const code = runAndWait(io, fa, bin_path, &.{}) catch 1;
        if (code == 0) {
            std.debug.print("GECTI: {s}\n", .{file});
            pass_count += 1;
        } else {
            std.debug.print("BASARISIZ: {s}\n", .{file});
            fail_count += 1;
        }
    }

    std.debug.print("\n{d} gecti, {d} basarisiz ({d} toplam)\n", .{ pass_count, fail_count, files.len });
    if (fail_count > 0) std.process.exit(1);
}

/// `path_arg`in (proje kökü BULUNURSA o kök, BULUNAMAZSA dosyanın KENDİ
/// dizini — bkz. `project.findProjectRoot`'un "manifestsiz de geçerli"
/// notu) altında `.nox/cache/bin/<uzantısız-ad>` mutlak yolunu HAZIRLAR
/// (dizinleri de oluşturarak).
fn cacheBinPath(io: std.Io, a: std.mem.Allocator, path_arg: []const u8) ![]const u8 {
    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const path_dir = std.fs.path.dirname(path_arg) orelse ".";
    const start_dir = if (std.fs.path.isAbsolute(path_dir))
        try a.dupe(u8, path_dir)
    else
        try std.fs.path.resolve(a, &.{ cwd_abs, path_dir });

    const root = (try project.findProjectRoot(a, io, start_dir)) orelse start_dir;

    const cache_dir_rel = ".nox/cache/bin";
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer root_dir.close(io);
    try root_dir.createDirPath(io, cache_dir_rel);

    const base_name = std.fs.path.stem(path_arg);
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ root, cache_dir_rel, base_name });
}

/// Faz O §P.6: `path_arg`in proje kökünü (`nox.json`) arar; BULAMAZSA
/// `module_loader.resolveImports`in ESKİ (P.6'dan ÖNCEKİ) davranışına
/// BİREBİR düşer (yalnızca `nox.*` stdlib, `error.ModuleNotFound` mesajı
/// DEĞİŞMEDEN) — bu, manifestsiz KULLANIMIN (ki HÂLÂ geçerlidir) hiçbir
/// şekilde ETKİLENMEMESİNİ garanti eder. BULURSA: manifesti + kilit
/// dosyasını okur, `requires[]`in HER elemanı İÇİN ÖNCE `nox.lock`ta
/// ZATEN kilitli bir SHA VARSA VE o SHA'nın önbellek dizini HÂLÂ diskte
/// İSE `git`e HİÇ dokunmadan O dizini kullanır; AKSİ HALDE (ilk kez ya da
/// önbellek silinmiş) `fetch.fetchToCache`i çağırıp kilidi GÜNCELLER
/// (tüm bağımlılıklar çözüldükten SONRA `nox.lock` TEK seferde YENİDEN
/// yazılır). Son olarak `module_loader.resolveProjectImports`i (alias→
/// önbellek-dizini haritasıyla) çağırır.
fn resolveImportsForBuild(
    io: std.Io,
    a: std.mem.Allocator,
    user_module: ast.Module,
    path_arg: []const u8,
    nox_home: []const u8,
    resource_dirs: project.ResourceDirs,
) !ast.Module {
    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const path_dir = std.fs.path.dirname(path_arg) orelse ".";
    const start_dir = if (std.fs.path.isAbsolute(path_dir))
        try a.dupe(u8, path_dir)
    else
        try std.fs.path.resolve(a, &.{ cwd_abs, path_dir });

    const root = (try project.findProjectRoot(a, io, start_dir)) orelse {
        return module_loader.resolveImportsFrom(a, io, user_module, resource_dirs.stdlib_dir) catch |e| switch (e) {
            error.ModuleNotFound => {
                std.debug.print("import: stdlib modülü bulunamadı ({s} altında aranır)\n", .{resource_dirs.stdlib_dir});
                std.process.exit(1);
            },
            else => |err| return err,
        };
    };

    const manifest = project.loadManifest(a, io, root) catch |e| {
        std.debug.print("nox.json okunamadi/gecersiz ({s}): {t}\n", .{ root, e });
        std.process.exit(1);
    };
    const lock = project.loadLockfile(a, io, root) catch |e| {
        std.debug.print("nox.lock okunamadi/gecersiz ({s}): {t}\n", .{ root, e });
        std.process.exit(1);
    };

    var roots: std.StringHashMapUnmanaged([]const u8) = .empty;
    var new_packages: std.ArrayListUnmanaged(project.LockedPackage) = .empty;
    try new_packages.appendSlice(a, lock.packages);
    var lock_changed = false;

    for (manifest.requires) |req| {
        cached: {
            if (project.findLocked(lock, req.alias)) |locked| {
                const cache_dir = try fetch.cachedDirFor(a, nox_home, locked.repo, locked.resolved);
                if (std.Io.Dir.accessAbsolute(io, cache_dir, .{})) |_| {
                    try roots.put(a, req.alias, cache_dir);
                    break :cached;
                } else |_| {}
            }
            // İlk kez GÖRÜLÜYOR YA DA önbellek dizini KAYBOLMUŞ — GERÇEKTEN
            // getir (bkz. `fetch.fetchToCache`'in belge notu — bu fonksiyon
            // `git`i HER ZAMAN çağırır, "zaten kilitliyse hiç dokunma"
            // kısayolu TAM OLARAK BURADA, bu bloğun ÜZERİNDE uygulanır).
            const result = fetch.fetchToCache(a, io, nox_home, req.repo, req.ref) catch |e| {
                std.debug.print("paket getirilemedi (alias={s}, repo={s}): {t}\n", .{ req.alias, req.repo, e });
                std.process.exit(1);
            };
            try roots.put(a, req.alias, result.cache_dir);

            var found_idx: ?usize = null;
            for (new_packages.items, 0..) |p, i| {
                if (std.mem.eql(u8, p.alias, req.alias)) {
                    found_idx = i;
                    break;
                }
            }
            const new_entry: project.LockedPackage = .{ .alias = req.alias, .repo = req.repo, .ref = req.ref, .resolved = result.resolved_sha };
            if (found_idx) |i| new_packages.items[i] = new_entry else try new_packages.append(a, new_entry);
            lock_changed = true;
        }
    }

    if (lock_changed) {
        try project.saveLockfile(a, io, root, .{ .packages = new_packages.items });
    }

    return module_loader.resolveProjectImports(a, io, user_module, roots, resource_dirs.stdlib_dir) catch |e| switch (e) {
        error.ModuleNotFound => {
            std.debug.print("import: modül bulunamadı (ne 'stdlib/' altında ne bir bağımlılık dizininde)\n", .{});
            std.process.exit(1);
        },
        error.UnknownImportAlias => {
            std.debug.print("import: bilinmeyen alias (nox.json'daki 'requires' listesine bakın: {s}/nox.json)\n", .{root});
            std.process.exit(1);
        },
        else => |err| return err,
    };
}

/// Tek bir `.nox` dosyasını uçtan uca derler (lex→parse→import çözümü→tip
/// denetimi→[isteğe bağlı döküm]→codegen→qbe→cc) ve üretilen binary'nin
/// yolunu döner. Hata durumlarında (mevcut davranışla BİREBİR aynı mesaj/
/// çıkış kodu) doğrudan `std.process.exit(1)` çağırır — `cmdBuild`/`cmdRun`
/// bu davranışı DEĞİŞTİRMEDEN miras alır.
fn buildOne(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, path_arg: []const u8, verbose: bool, output_override: ?[]const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs) ![]const u8 {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024));
    defer gpa.free(source);

    const tokens = try lexer.tokenize(a, source);
    const user_module = try parser.parseModule(a, tokens);

    // Faz O §P.6: proje kökü (`nox.json`) BULUNAMAZSA `resolveImports`in
    // ESKİ, DEĞİŞMEMİŞ davranışına (yalnızca `nox.*` stdlib) DÜŞER;
    // BULUNURSA `requires[]`i ÇÖZÜP `resolveProjectImports`i ÇAĞIRIR (bkz.
    // `resolveImportsForBuild`'in belge notu). Her iki yol da (Faz Q.3)
    // `resource_dirs.stdlib_dir`i (CWD-göreli `"stdlib"` DEĞİL, `noxc`nin
    // KENDİ çözülmüş kaynak dizinini) kullanır.
    const module = try resolveImportsForBuild(io, a, user_module, path_arg, nox_home, resource_dirs);

    // `checker.check`'in kullanışlı ok/err sarmalayıcısı yerine `Checker`
    // doğrudan kullanılır: Faz 10 generics'i somut örneklemeleri
    // (`checker_state.instantiations`) burada, ownership analizi ve codegen'e
    // iletmek için gereklidir (bkz. checker.zig, "Faz 10: generics" notu).
    var checker_state = checker.Checker.init(a);
    checker_state.checkModule(module) catch |e| {
        std.debug.print("tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        std.process.exit(1);
    };
    const instantiations = checker_state.instantiations.items;

    // Codegen'in `module.body`deki generic ŞABLONLARINI (açık `[T]` VEYA
    // Faz 11'in örtük protokol parametresi yoluyla) atlayabilmesi için
    // isimlerini iletiyoruz (bkz. codegen.zig, `generateModule` belge notu).
    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(a, k.*);

    if (verbose) {
        // `report` yalnızca BU dökümün İÇİN hesaplanır (codegen KENDİ
        // sahiplik kararlarını AYRICA/dahili olarak üretir, `report`ı asla
        // parametre olarak ALMAZ) — `verbose` DEĞİLSE `ownership.analyze`
        // çağrısının KENDİSİ de atlanır, yalnızca I/O DEĞİL, hesaplama da
        // tasarruf edilir.
        const report = try ownership.analyze(a, module, instantiations, generic_names.items);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
        try stdout_writer.interface.writeAll("--- sahiplik analizi ---\n");
        try ownership.dumpReport(&stdout_writer.interface, report);
        try stdout_writer.interface.writeAll("--- AST ---\n");
        try ast_dump.dumpModule(&stdout_writer.interface, module);
        try stdout_writer.interface.flush();
    }

    const ir = codegen.generateModule(a, module, instantiations, generic_names.items) catch |err| switch (err) {
        error.Unsupported => {
            std.debug.print(
                "codegen: bu program şu an desteklenmeyen bir yapı içeriyor " ++
                    "(ör. iç içe fonksiyon/sınıf tanımı, desteklenmeyen bir " ++
                    "tip ifadesi ya da bir for döngüsünde range()/list[T] " ++
                    "dışında bir iterable) - bkz. nox-teknik-spesifikasyon.md " ++
                    "§3.6 (bilinçli kapsam sınırlamaları)\n",
                .{},
            );
            std.process.exit(1);
        },
        else => |e| return e,
    };

    const stem = output_override orelse stemOf(path_arg);
    const ssa_path = try std.fmt.allocPrint(a, "{s}.ssa", .{stem});
    const asm_path = try std.fmt.allocPrint(a, "{s}.s", .{stem});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ssa_path, .data = ir });

    const qbe_result = try std.process.run(gpa, io, .{
        .argv = &.{ "qbe", "-t", qbe_target.name(), "-o", asm_path, ssa_path },
    });
    defer gpa.free(qbe_result.stdout);
    defer gpa.free(qbe_result.stderr);
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        std.debug.print("qbe basarisiz:\n{s}\n", .{qbe_result.stderr});
        std.process.exit(1);
    }

    // Faz Q.3: runtime nesne dosyasının yolu artık `resource_dirs.noxrt_path`
    // (bkz. `project.resolveResourceDirs`) — `noxc`nin KENDİ çalıştırılabilir
    // dosya konumuna göre çözülür, CWD'ye (proje köküne) BAĞIMLI DEĞİLDİR.
    //
    // Faz R.3 (KRİTİK, Linux'ta GERÇEK bir çökme/sızıntıya yol açan bir
    // hatanın KÖK NEDENİ): `-rdynamic` ZORUNLUDUR. `runtime/stdlib_shims/
    // json.zig`nin `dlopen(null, ...)` + `dlsym(..., "nox_json_make_json_
    // value")` deseni (bkz. o dosyanın belge notu — Zig kodu, QBE'nin
    // SONRADAN derleyeceği bir Nox sembolünü ÇALIŞMA ZAMANINDA arar), ana
    // programın KENDİ sembollerini `dlsym` İLE bulunabilir kılmak İÇİN
    // dinamik sembol tablosuna AÇIKÇA EXPORT edilmelerini gerektirir.
    // macOS'ta (Mach-O) bu ÖRTÜK olarak ÇALIŞIR — Linux'ta (ELF) İSE
    // `-rdynamic` OLMADAN `dlsym` SESSİZCE `null` döner (Docker'da GERÇEKTEN
    // yakalandı: `nox.json.decode` HER çağrıda `null` dönüyor, bu da hem
    // ÇÖKMEYE hem daha önce `nox_rc_alloc` İLE tahsis edilmiş, artık HİÇBİR
    // ŞEYE bağlanamayan parçaların SIZMASINA yol açıyordu).
    var cc_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try cc_argv.appendSlice(a, &.{ "cc", "-rdynamic", "-o", stem, asm_path, resource_dirs.noxrt_path, "-lm" });
    try appendExternLinkArgs(a, &cc_argv, module);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = cc_argv.items,
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        std.debug.print("cc basarisiz:\n{s}\n", .{cc_result.stderr});
        std.process.exit(1);
    }

    return stem;
}

fn stemOf(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".nox")) return path[0 .. path.len - 4];
    return path;
}

/// Modüldeki her `extern def ... from "X"` için son `cc` bağlama komutuna
/// bir argüman ekler (bkz. nox-teknik-spesifikasyon.md §3.20, "Sözdizimi"):
/// `X` bir dosya yolu GÖRÜNÜYORSA (`/` içeriyor ya da `.o`/`.a` ile
/// bitiyorsa) DOĞRUDAN eklenir (Zig'le `zig build-obj` ile üretilmiş bir
/// `.o` DAHİL — ayrı bir "Zig FFI'si" yok, aynı yol); aksi halde bir SİSTEM
/// kütüphanesi ADI sayılıp `-l<ad>` olarak eklenir. Aynı `from_lib` birden
/// çok `extern def`de kullanılmışsa yalnızca BİR KEZ eklenir. **Düzeltme
/// (stdlib fazı §D.1.5):** `"zig-out/lib/noxrt.o"` `seen`e ÖNCEDEN eklenir
/// (çağıran ZATEN runtime nesne dosyasını — Faz Q.3'ten beri `resource_dirs.
/// noxrt_path`, ÇÖZÜLMÜŞ MUTLAK yol — koşulsuz argv'ye ekliyor, bkz. üstteki
/// çağrı sitesi) — `noxrt.o`nun İÇİNDEKİ bir sembole `extern def ... from
/// "zig-out/lib/noxrt.o" with_rt` İLE başvuran stdlib dosyaları (ör. `stdlib/
/// nox/http.nox`) İÇİN bu dosyayı `cc`ye İKİNCİ KEZ GEÇMEMEK için — macOS'un
/// `ld64`sü AYNI `.o` dosyası İKİ KEZ geçildiğinde "duplicate symbol" hatası
/// verir. **ÖNEMLİ:** `seen`e eklenen `"zig-out/lib/noxrt.o"` LİTERALİ,
/// runtime'ın GERÇEK (çözülmüş) yolu DEĞİL, stdlib yazarlarının KENDİ
/// `extern def`lerinde KULLANDIKLARI SABİT KURAL/SENTİNEL'dir (bkz. stdlib/
/// nox/*.nox — HEPSİ bu TAM literal dizgeyi `from_lib` olarak yazar) — bu
/// yüzden gerçek `noxrt_path` ne olursa olsun (sistem geneli bir kurulumda
/// CWD-göreli DEĞİL, mutlak bir yol) eşleşme DOĞRU çalışır.
fn appendExternLinkArgs(allocator: std.mem.Allocator, argv: *std.ArrayListUnmanaged([]const u8), module: ast.Module) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try seen.put(allocator, "zig-out/lib/noxrt.o", {});
    for (module.body) |stmt| {
        if (stmt != .extern_def) continue;
        const from_lib = stmt.extern_def.from_lib;
        if (seen.contains(from_lib)) continue;
        try seen.put(allocator, from_lib, {});

        const looks_like_path = std.mem.indexOfScalar(u8, from_lib, '/') != null or
            std.mem.endsWith(u8, from_lib, ".o") or
            std.mem.endsWith(u8, from_lib, ".a");
        if (looks_like_path) {
            try argv.append(allocator, from_lib);
        } else {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-l{s}", .{from_lib}));
        }
    }
}
