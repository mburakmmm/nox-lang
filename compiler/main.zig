//! noxc — Nox derleyicisi giriş noktası.
//! Faz 4 itibarıyla lexer + parser + zorunlu statik tip denetimi + sahiplik
//! analizi + QBE codegen (yalnızca değer tipleri) bağlıdır; qbe ve sistem
//! `cc`'si çağrılarak gerçek bir native binary üretilir.
//!
//! **Faz O §P.2/§P.3 (bkz. plan dosyası "Faz O" bölümü, nox-teknik-
//! spesifikasyon.md §3.6):** `noxc` artık Cargo/Go tarzı alt komutlar
//! tanır — `build`/`run`/`test`/`fmt`/`fetch`/`update` (bkz. Faz CC.2,
//! §3.54 — `fetch`/`update` ARTIK GERÇEK implementasyona SAHİP, REZERVE
//! DEĞİL). Çıplak `noxc <dosya.nox>` (alt komut OLMADAN) **geriye dönük
//! uyumluluk İÇİN `build`in bir takma adı olarak KORUNUR** — çıktı/mesaj/
//! çıkış kodu BİREBİR aynı (bkz. `cmdBuild`'e geçirilen `usage`
//! argümanının legacy/yeni-CLI için AYRI tutulması). İlk bayrak-olmayan
//! argüman bilinen bir alt komut anahtar kelimesiyle EŞLEŞMİYORSA (ör.
//! bir `.nox` yolu ya da `--dump`) eski tekil-dosya yoluna DÜŞÜLÜR.
//! `fmt`in GERÇEK implementasyonu Faz T.4a/T.4b'dir (bkz. `cmdFmt`/
//! `fmt/formatter.zig`).

const std = @import("std");
const builtin = @import("builtin");
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
const pkg_index = @import("pkg/index.zig");
const formatter = @import("fmt/formatter.zig");
const build_options = @import("build_options");

// Faz CC.2.3 (bkz. nox-teknik-spesifikasyon.md §3.58): renkli/daha
// okunabilir CLI çıktısı. `main()`de BİR KEZ hesaplanır (`NO_COLOR`
// ortam değişkeni SAYGI görür — bkz. no-color.org; İSATTY DEĞİLSE, ör.
// çıktı bir dosyaya/pipe'a YÖNLENDİRİLMİŞSE, KOŞULSUZ devre dışı kalır)
// — TÜM `printErr`/`printOk` çağrıları BU tek, süreç-geneli bayrağı
// okur. `std.debug.print`in KENDİSİ HER ZAMAN stderr'e yazdığından (bkz.
// modül üstü not, "TÜM mesajlar HER ZAMAN stderr'e") tespit de stderr
// ÜZERİNDEN yapılır.
var g_use_color: bool = false;

/// `g_use_color` İLE AYNI "main() başında BİR KEZ hesapla, süreç-geneli
/// oku" deseni — bkz. `detectTurkishLocale`nin belge notu. `buildOne`nin
/// dosya-bulunamadı İPUCU mesajı (bkz. onun belge notu) GİBİ, sinyali
/// HER çağıran fonksiyonun imzasına AYRI AYRI eklemek yerine BURADAN okur.
var g_is_tr: bool = false;

fn detectUseColor(io: std.Io, environ_map: *const std.process.Environ.Map) bool {
    if (environ_map.get("NO_COLOR")) |v| {
        if (v.len > 0) return false;
    }
    return std.Io.File.stderr().supportsAnsiEscapeCodes(io) catch false;
}

/// Bulundu (kullanıcı geri bildirimi, 2026-07-24): `noxc` çıplak
/// çalıştırıldığında modern dillerin (cargo/go/npm) CLI'ları gibi bir
/// yardım ekranı GÖSTERMİYORDU, yalnızca tek satırlık bir "kullanim: noxc
/// [--dump|-v] <dosya.nox>" mesajı veriyordu — bkz. `printHelp`. Bu, o
/// yardım ekranının HANGİ dilde (Türkçe/İngilizce) gösterileceğini,
/// `detectUseColor`in `NO_COLOR`/isatty tespitiyle AYNI "BİR KEZ, main()
/// başında hesapla" deseniyle belirler. POSIX (`LC_ALL`/`LC_MESSAGES`/
/// `LANG`, TAM OLARAK bu öncelik SIRASIYLA — `gettext`in KENDİ, standart
/// çözümleme kuralı) öncelikli KAYNAK; Windows'ta bu değişkenler genelde
/// AYARLANMADIĞINDAN (PowerShell/cmd varsayılanı), hiçbiri BULUNAMAZSA
/// `GetUserDefaultUILanguage`in (kernel32) döndürdüğü LANGID'in birincil
/// dil kodu Türkçe (`0x1F`) İLE karşılaştırılarak YEDEK olarak kullanılır.
fn detectTurkishLocale(environ_map: *const std.process.Environ.Map) bool {
    inline for (.{ "LC_ALL", "LC_MESSAGES", "LANG" }) |key| {
        if (environ_map.get(key)) |v| {
            if (v.len > 0) return std.ascii.startsWithIgnoreCase(v, "tr");
        }
    }
    if (builtin.os.tag == .windows) {
        const Win32 = struct {
            extern "kernel32" fn GetUserDefaultUILanguage() callconv(.c) u16;
        };
        const langid = Win32.GetUserDefaultUILanguage();
        const primary_lang_id = langid & 0x3FF;
        const lang_turkish = 0x1F;
        return primary_lang_id == lang_turkish;
    }
    return false;
}

/// Bare `noxc` (alt komutsuz) VE `noxc --help`/`-h`/`help` İÇİN modern,
/// kategorize edilmiş bir CLI yardım ekranı — cargo/go/npm gibi araçların
/// KENDİ `--help` çıktılarıyla AYNI ruhta (kısa açıklama + "Kullanım" +
/// kategorize alt komut listesi + örnekler). Renksiz de OKUNAKLI kalacak
/// şekilde tasarlandı (`g_use_color` bu ekranda KASITLI olarak
/// KULLANILMAZ — bir yardım ekranı, bir hata/başarı durumu DEĞİLDİR).
fn printHelp(is_tr: bool) void {
    if (is_tr) {
        std.debug.print(
            \\noxc {s} — Nox dili derleyicisi ve proje aracı
            \\
            \\Kullanım:
            \\  noxc <dosya.nox>              dosyayı derler + çalıştırır (build'in kısayolu)
            \\  noxc <alt-komut> [seçenekler]
            \\
            \\Alt komutlar:
            \\  build <dosya.nox>     derler, çalıştırılabilir bir ikili üretir
            \\  run <dosya.nox>       derler + hemen çalıştırır (-- ile argv iletilir)
            \\  test                  CWD altındaki tüm *_test.nox dosyalarını keşfedip çalıştırır
            \\  check <dosya.nox>     yalnızca tip denetimi yapar (codegen/qbe/cc yok, hızlı)
            \\  fmt <dosya.nox>       dosyayı standart biçimde yeniden yazar
            \\  init [ad]             yeni bir proje iskeleti oluşturur (nox.json + main.nox)
            \\  fetch                 nox.json'daki bağımlılıkları önbelleğe doldurur
            \\  update                bağımlılıkları en son ref'lerine yeniden çözer, nox.lock'u günceller
            \\  search <indeks> [q]   bir paket indeksini (dosya veya URL) sorgular
            \\  version               sürüm bilgisini yazdırır (--version/-V ile aynı)
            \\
            \\Ortak seçenekler:
            \\  --dump, -v             ayrıntılı/AST dökümü (build/run/check ile)
            \\  -o <çıktı>             çıktı ikilisinin adı (yalnızca build ile)
            \\
            \\Örnekler:
            \\  noxc run main.nox -- a b c
            \\  noxc build -o app main.nox
            \\  noxc search https://example.com/index.json http
            \\
            \\Daha fazla bilgi: https://github.com/mburakmmm/nox-lang
            \\
        , .{build_options.version});
    } else {
        std.debug.print(
            \\noxc {s} — the Nox language compiler and project tool
            \\
            \\Usage:
            \\  noxc <file.nox>              compile + run the file (shortcut for build)
            \\  noxc <subcommand> [options]
            \\
            \\Subcommands:
            \\  build <file.nox>      compile, producing an executable binary
            \\  run <file.nox>        compile + run immediately (argv after --)
            \\  test                  discover and run all *_test.nox files under the CWD
            \\  check <file.nox>      type-check only (no codegen/qbe/cc, fast feedback)
            \\  fmt <file.nox>        rewrite the file in the standard format
            \\  init [name]           scaffold a new project (nox.json + main.nox)
            \\  fetch                 populate the dependency cache from nox.json
            \\  update                re-resolve dependencies to their latest refs, update nox.lock
            \\  search <index> [q]    query a package index (file or URL)
            \\  version               print version info (same as --version/-V)
            \\
            \\Common options:
            \\  --dump, -v             verbose/AST dump (with build/run/check)
            \\  -o <output>            output binary name (build only)
            \\
            \\Examples:
            \\  noxc run main.nox -- a b c
            \\  noxc build -o app main.nox
            \\  noxc search https://example.com/index.json http
            \\
            \\More info: https://github.com/mburakmmm/nox-lang
            \\
        , .{build_options.version});
    }
}

/// `std.debug.print`in AYNISI, `g_use_color` İSE `fmt`i KIRMIZI ANSI
/// kaçış dizileriyle SARAR — GERÇEK bir hata/başarısızlık durumu İÇİN.
fn printErr(comptime fmt: []const u8, args: anytype) void {
    if (g_use_color) {
        std.debug.print("\x1b[31m" ++ fmt ++ "\x1b[0m", args);
    } else {
        std.debug.print(fmt, args);
    }
}

/// `printErr` İLE AYNI, YEŞİL — bir BAŞARI/tamamlanma durumu İÇİN.
fn printOk(comptime fmt: []const u8, args: anytype) void {
    if (g_use_color) {
        std.debug.print("\x1b[32m" ++ fmt ++ "\x1b[0m", args);
    } else {
        std.debug.print(fmt, args);
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    g_use_color = detectUseColor(io, init.environ_map);

    var all_args: std.ArrayListUnmanaged([]const u8) = .empty;
    // Faz LL.1 (bkz. nox-teknik-spesifikasyon.md §3.71): `.iterate()`
    // Windows'ta `@compileError` veriyor ("use initAllocator instead") —
    // `iterateAllocator` macOS/Linux'ta (Zig std'nin KENDİ `Args.zig`sının
    // `Posix` dalı) TAMAMEN AYNI, allocation'sız iç yolu izler (davranış
    // DEĞİŞMEZ), Windows'ta İSE GEREKEN allocator-tabanlı yolu kullanır —
    // GERÇEK bir `windows-latest` CI çalıştırmasında BULUNDU (bkz. §3.71
    // LL.1'in belge notu).
    var arg_it = try init.minimal.args.iterateAllocator(gpa);
    defer arg_it.deinit();
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

    // Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi"
    // planı): `NOX_HOME`/`NOX_RESOURCE_DIR` İLE AYNI desen — BİR KEZ
    // okunur, `fetch.zig`ye HİÇBİR ZAMAN doğrudan ortam değişkeni
    // OKUTULMAZ (bkz. `fetch.FetchPolicy`nin belge notu). AÇIKÇA (BOŞ
    // OLMAYAN bir DEĞERLE) verilmedikçe `false` (düz-metin şemalar
    // VARSAYILAN olarak REDDEDİLİR).
    const allow_insecure_transport = if (init.environ_map.get("NOX_ALLOW_INSECURE_TRANSPORT")) |v| v.len > 0 else false;
    const fetch_policy: fetch.FetchPolicy = .{
        .allow_insecure_transport = allow_insecure_transport,
        .parent_environ_map = init.environ_map,
    };

    const is_tr = detectTurkishLocale(init.environ_map);
    g_is_tr = is_tr;

    const Subcommand = enum { build, run, test_cmd, fmt, fetch, update, search, init, check, version, help, legacy };
    const sub: Subcommand = blk: {
        // Bulundu (kullanıcı geri bildirimi): çıplak `noxc` ÖNCEDEN `.legacy`ye
        // düşüp `cmdBuild`i argümansız çağırıyordu — tek satırlık bir
        // "kullanim" mesajı VERİYORDU ama modern bir yardım ekranı DEĞİLDİ.
        // Artık `.help`e gider (bkz. `printHelp`) — bu, "argümansız çalıştırma"
        // hiçbir GEÇERLİ dosya derlemesi ANLAMINA GELMEDİĞİNDEN, `.legacy`nin
        // "geriye dönük uyumlu tekil-dosya" sözleşmesini BOZMAZ.
        if (all_args.items.len == 0) break :blk .help;
        const first = all_args.items[0];
        if (std.mem.eql(u8, first, "build")) break :blk .build;
        if (std.mem.eql(u8, first, "run")) break :blk .run;
        if (std.mem.eql(u8, first, "test")) break :blk .test_cmd;
        if (std.mem.eql(u8, first, "fmt")) break :blk .fmt;
        if (std.mem.eql(u8, first, "fetch")) break :blk .fetch;
        if (std.mem.eql(u8, first, "update")) break :blk .update;
        if (std.mem.eql(u8, first, "search")) break :blk .search;
        if (std.mem.eql(u8, first, "init")) break :blk .init;
        if (std.mem.eql(u8, first, "check")) break :blk .check;
        // `-v`/`--dump` ZATEN `build`in AYRINTILI-döküm bayrağı olduğundan
        // (bkz. modül üstü not), sürüm İÇİN `-V` (büyük harf, `-v` İLE
        // ÇAKIŞMAZ) VE `--version`/`version` KULLANILIR — `rustc`/`go`/`node`
        // İLE TUTARLI bir dizi eşanlamlı.
        if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) break :blk .version;
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) break :blk .help;
        break :blk .legacy;
    };
    const rest: []const []const u8 = if (sub == .legacy or all_args.items.len == 0) all_args.items else all_args.items[1..];

    switch (sub) {
        .build => try cmdBuild(gpa, io, a, rest, "kullanim: noxc build [--dump|-v] [-o <cikti>] <dosya.nox>\n", nox_home, resource_dirs, fetch_policy),
        .legacy => try cmdBuild(gpa, io, a, rest, "kullanim: noxc [--dump|-v] <dosya.nox>  (komutlar icin: noxc --help)\n", nox_home, resource_dirs, fetch_policy),
        .help => printHelp(is_tr),
        .run => try cmdRun(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
        .test_cmd => try cmdTest(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
        .fmt => try cmdFmt(gpa, io, a, rest),
        .search => try cmdSearch(io, a, rest, fetch_policy),
        .version => std.debug.print("noxc {s}\n", .{build_options.version}),
        .fetch => try cmdFetch(io, a, rest, nox_home, fetch_policy),
        .update => try cmdUpdate(io, a, rest, nox_home, fetch_policy),
        .init => try cmdInit(io, a, rest),
        .check => try cmdCheck(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
    }
}

/// Faz Y.1: `noxc search <indeks-dosyasi.json> [sorgu]` — hafif, statik
/// paket dizinini (bkz. `pkg/index.zig`nin modül üstü notu) sorgular.
/// `sorgu` VERİLMEZSE TÜM katalog LİSTELENİR. Bu KOMUT, `fetch`/`update`in
/// AKSİNE (henüz REZERVE), TAM olarak ÇALIŞIR — herhangi bir AĞ erişimi
/// GEREKMEZ (yalnızca YEREL bir JSON dosyası okur, bkz. modül üstü not
/// "gelecekte eklenebilir" tasarım kararı).
fn cmdSearch(io: std.Io, a: std.mem.Allocator, args: []const []const u8, fetch_policy: fetch.FetchPolicy) !void {
    const index_arg = if (args.len > 0) args[0] else {
        std.debug.print("kullanim: noxc search <indeks-dosyasi.json|https://...> [sorgu]\n", .{});
        std.process.exit(1);
    };
    const query = if (args.len > 1) args[1] else "";

    // Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
    // `pkg_index.loadIndexFromUrl` (YENİ) — `index.zig`nin KENDİ belge
    // notunun ÖNGÖRDÜĞÜ uzantı. Bir URL mi yerel yol mu olduğu, düz bir
    // önek kontrolüyle ayırt edilir (`fetch.zig`nin `resolveCloneUrl`iyle
    // AYNI basit ayrım).
    const is_url = std.mem.startsWith(u8, index_arg, "http://") or std.mem.startsWith(u8, index_arg, "https://");
    const idx = if (is_url)
        pkg_index.loadIndexFromUrl(a, io, index_arg, fetch_policy) catch |e| {
            printErr("search: indeks getirilemedi/ayristirilamadi ({t}): {s}\n", .{ e, index_arg });
            std.process.exit(1);
        }
    else
        pkg_index.loadIndexFromFile(a, io, index_arg) catch |e| {
            printErr("search: indeks okunamadi/ayristirilamadi ({t}): {s}\n", .{ e, index_arg });
            std.process.exit(1);
        };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    var found: usize = 0;
    for (idx.packages) |pkg| {
        if (!pkg_index.matches(pkg, query)) continue;
        found += 1;
        try w.print("{s} — {s}\n", .{ pkg.name, pkg.repo });
        if (pkg.description.len > 0) try w.print("    {s}\n", .{pkg.description});
        if (pkg.tags.len > 0) {
            try w.writeAll("    etiketler: ");
            for (pkg.tags, 0..) |t, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(t);
            }
            try w.writeAll("\n");
        }
    }
    if (found == 0) try w.writeAll("eslesen paket bulunamadi\n");
    try w.flush();
}

const BuildOpts = struct {
    path: ?[]const u8 = null,
    verbose: bool = false,
    output: ?[]const u8 = null,
    /// Faz T.3: `-g` — QBE IR'a `dbgfile`/`dbgloc` yönergeleri (bkz.
    /// `codegen_qbe/codegen.zig`nin modül üstü notu) yayınlanmasını
    /// TETİKLER. Varsayılan `false` — M.2'nin "sessiz varsayılan" ilkesiyle
    /// TUTARLI (opt-in, çıktı boyutunu/derleme süresini gereksiz büyütmez).
    debug_info: bool = false,
};

fn parseBuildOpts(args: []const []const u8) BuildOpts {
    var opts: BuildOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-g")) {
            opts.debug_info = true;
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

fn cmdBuild(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, usage: []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const opts = parseBuildOpts(args);
    const path_arg = opts.path orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };
    const out = try buildOne(gpa, io, a, path_arg, opts.verbose, opts.output, nox_home, resource_dirs, opts.debug_info, fetch_policy);
    printOk("derlendi: {s}\n", .{out});
}

/// `noxc run`/`noxc test` (Faz O §P.2 — `test`in GERÇEK `*_test.nox` keşif/
/// toplama kuralı §P.3'te bu fonksiyonun YERİNİ alacak; şimdilik TEK bir
/// dosyayı derleyip çalıştırmak, `nox.test`in `raise`-ile-başarısız-olma
/// modeliyle zaten TUTARLI bir ilk adımdır): `buildOne`ı proje-yerel bir
/// önbelleğe (`<proje_kökü_veya_dosya_dizini>/.nox/cache/bin/<isim>`,
/// KAYNAĞIN YANINA DEĞİL) derler, çalıştırılabilir dosyayı stdio'yu
/// MİRAS ALARAK çalıştırır, çocuğun çıkış kodunu AYNEN yansıtır.
fn cmdRun(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const split = splitOnDoubleDash(args);
    const opts = parseBuildOpts(split.before);
    const path_arg = opts.path orelse {
        std.debug.print("kullanim: noxc run [--dump|-v] <dosya.nox> [-- argv...]\n", .{});
        std.process.exit(1);
    };

    const cache_bin_path = try cacheBinPath(io, a, path_arg);
    const bin_path = try buildOne(gpa, io, a, path_arg, opts.verbose, cache_bin_path, nox_home, resource_dirs, opts.debug_info, fetch_policy);

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
fn cmdTest(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const opts = parseBuildOpts(args);

    if (opts.path) |t| {
        if (std.mem.endsWith(u8, t, ".nox")) {
            const cache_bin_path = try cacheBinPath(io, a, t);
            const bin_path = try buildOne(gpa, io, a, t, opts.verbose, cache_bin_path, nox_home, resource_dirs, opts.debug_info, fetch_policy);
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
        const bin_path = try buildOne(gpa, io, fa, file, opts.verbose, cache_bin_path, nox_home, resource_dirs, opts.debug_info, fetch_policy);
        const code = runAndWait(io, fa, bin_path, &.{}) catch 1;
        if (code == 0) {
            printOk("GECTI: {s}\n", .{file});
            pass_count += 1;
        } else {
            printErr("BASARISIZ: {s}\n", .{file});
            fail_count += 1;
        }
    }

    if (fail_count > 0) {
        printErr("\n{d} gecti, {d} basarisiz ({d} toplam)\n", .{ pass_count, fail_count, files.len });
        std.process.exit(1);
    }
    printOk("\n{d} gecti, {d} basarisiz ({d} toplam)\n", .{ pass_count, fail_count, files.len });
}

/// Faz T.4b: `noxc fmt <dosya.nox>` — kaynağı `lexer.tokenizeWithTrivia` +
/// `parser.parseModule` ile ayrıştırır, `formatter.formatModule`e verir,
/// SONUCU DOSYANIN YERİNE (in-place) YAZAR (`gofmt`/`rustfmt`in varsayılan
/// davranışıyla TUTARLI). **Tip denetimi ÇALIŞTIRILMAZ** — sözdizimsel
/// olarak geçerli ama tipçe HATALI bir program (gofmt'ın DAVRANIŞIYLA AYNI)
/// YİNE DE formatlanabilir olmalıdır; yalnızca lex/parse hatası BAŞARISIZLIK
/// sayılır. `module_loader.resolveImports` KASITLI olarak ÇAĞRILMAZ —
/// KULLANICININ KENDİ dosyası formatlanır, stdlib'in TÜM merge edilmiş
/// içeriği DEĞİL (bkz. `formatter.zig`nin modül üstü notu).
fn cmdFmt(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("kullanim: noxc fmt <dosya.nox>\n", .{});
        std.process.exit(1);
    }
    const path_arg = args[0];
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024));
    defer gpa.free(source);

    const result = lexer.tokenizeWithTrivia(a, source) catch |e| {
        printErr("fmt: lex hatasi ({t})\n", .{e});
        std.process.exit(1);
    };
    const module = parser.parseModule(a, result.tokens) catch |e| {
        printErr("fmt: ayristirma hatasi ({t})\n", .{e});
        std.process.exit(1);
    };
    const formatted = try formatter.formatModule(a, module, result.trivia);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path_arg, .data = formatted });
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
    fetch_policy: fetch.FetchPolicy,
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
                printErr("import: stdlib modülü bulunamadı ({s} altında aranır)\n", .{resource_dirs.stdlib_dir});
                std.process.exit(1);
            },
            else => |err| return err,
        };
    };

    const manifest = project.loadManifest(a, io, root) catch |e| {
        printErr("nox.json okunamadi/gecersiz ({s}): {t}\n", .{ root, e });
        std.process.exit(1);
    };
    const lock = project.loadLockfile(a, io, root) catch |e| {
        printErr("nox.lock okunamadi/gecersiz ({s}): {t}\n", .{ root, e });
        std.process.exit(1);
    };

    var roots: std.StringHashMapUnmanaged([]const u8) = .empty;
    var new_packages: std.ArrayListUnmanaged(project.LockedPackage) = .empty;
    try new_packages.appendSlice(a, lock.packages);
    var lock_changed = false;

    for (manifest.requires) |req| {
        cached: {
            var fetch_ref = req.ref;
            if (project.findLocked(lock, req.alias)) |locked| {
                const cache_dir = try fetch.cachedDirFor(a, nox_home, locked.repo, locked.resolved);
                if (std.Io.Dir.accessAbsolute(io, cache_dir, .{})) |_| {
                    try roots.put(a, req.alias, cache_dir);
                    break :cached;
                } else |_| {}
                // Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme
                // listesi" planı — GERÇEK, önceden keşfedilmemiş bir hata):
                // önbellek dizini KAYBOLMUŞ AMA `nox.lock`ta ZATEN kilitli
                // bir SHA VARSA, `req.ref`i (bir dal/etiket adı, HAREKETLİ
                // olabilir) DEĞİL, kilitli SHA'nın KENDİSİNİ getir — AKSİ
                // HALDE bir dal ref'i kilitlemeden SONRA ilerlemişse, SADECE
                // önbelleği temizlemek (`~/.nox` silmek, YENİ bir makine,
                // CI önbellek KAÇIRMASI) `nox.lock`ın VAR OLMA amacını
                // (`Lockfile`in belge notu: "TEKRARLANABİLİR derlemenin
                // bütün amacı BU") SESSİZCE BOZARDI. `req.repo != locked.
                // repo` İSE (manifest'te repo'nun KENDİSİ DEĞİŞTİYSE) eski
                // SHA BAŞKA bir depoya AİT olduğundan bu YOLA GİRİLMEZ,
                // `req.ref` (ilk-çözümleme benzeri) KULLANILMAYA DEVAM eder.
                if (std.mem.eql(u8, locked.repo, req.repo)) fetch_ref = locked.resolved;
            }
            // İlk kez GÖRÜLÜYOR YA DA önbellek dizini KAYBOLMUŞ — GERÇEKTEN
            // getir (bkz. `fetch.fetchToCache`'in belge notu — bu fonksiyon
            // `git`i HER ZAMAN çağırır, "zaten kilitliyse hiç dokunma"
            // kısayolu TAM OLARAK BURADA, bu bloğun ÜZERİNDE uygulanır).
            var sig_diag: ?[]const u8 = null;
            const result = fetch.fetchToCache(a, io, nox_home, req.repo, fetch_ref, req.require_signed_commit, &sig_diag, fetch_policy) catch |e| {
                if (e == error.CommitSignatureRejected) {
                    printErr("paket getirilemedi (alias={s}, repo={s}): commit imza dogrulamasi basarisiz:\n{s}\n", .{ req.alias, req.repo, sig_diag orelse "(git aciklama vermedi)" });
                } else {
                    printErr("paket getirilemedi (alias={s}, repo={s}): {t}\n", .{ req.alias, req.repo, e });
                }
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

    return module_loader.resolveProjectImports(a, io, user_module, roots, resource_dirs.stdlib_dir, root) catch |e| switch (e) {
        error.ModuleNotFound => {
            printErr("import: modül bulunamadı (ne 'stdlib/' altında ne bir bağımlılık dizininde)\n", .{});
            std.process.exit(1);
        },
        error.UnknownImportAlias => {
            printErr("import: bilinmeyen alias veya proje-içi dosya bulunamadı ({s}/nox.json'daki 'requires' listesine bakın ya da '{s}' altında ilgili .nox dosyasının var olduğundan emin olun)\n", .{ root, root });
            std.process.exit(1);
        },
        else => |err| return err,
    };
}

/// CWD'den yukarı doğru `nox.json`ı arar — bulamazsa `cmd_name`e özgü bir
/// hata basıp `exit(1)` çağırır (bir `.nox` dosyası argümanı ALMAYAN
/// `fetch`/`update` İÇİN — `resolveImportsForBuild`in aksine, bir dosya
/// yolunun dizininden DEĞİL, doğrudan CWD'den arar).
fn findProjectRootOrExit(io: std.Io, a: std.mem.Allocator, cmd_name: []const u8) ![]const u8 {
    const cwd_abs = try std.process.currentPathAlloc(io, a);
    return (try project.findProjectRoot(a, io, cwd_abs)) orelse {
        printErr("{s}: nox.json bulunamadi (proje kokunde ya da bir alt dizininde olmalisiniz)\n", .{cmd_name});
        std.process.exit(1);
    };
}

fn loadManifestOrExit(a: std.mem.Allocator, io: std.Io, root: []const u8) project.Manifest {
    return project.loadManifest(a, io, root) catch |e| {
        printErr("nox.json okunamadi/gecersiz ({s}): {t}\n", .{ root, e });
        std.process.exit(1);
    };
}

fn loadLockfileOrExit(a: std.mem.Allocator, io: std.Io, root: []const u8) project.Lockfile {
    return project.loadLockfile(a, io, root) catch |e| {
        printErr("nox.lock okunamadi/gecersiz ({s}): {t}\n", .{ root, e });
        std.process.exit(1);
    };
}

/// `resolveDependencies`in bir bağımlılık İÇİN ürettiği SONUÇ — `fetch`/
/// `update`in KENDİ özet çıktısını basmak İÇİN kullanılır.
const DepAction = enum {
    cached,
    fetched,
    updated,
    unchanged,
    /// Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi"
    /// planı): önbellek dizini KAYBOLMUŞTU AMA `nox.lock`ta ZATEN kilitli
    /// bir SHA VARDI — `req.ref` (hareketli olabilir) DEĞİL, O SHA'nın
    /// KENDİSİ yeniden getirildi (`resolveDependencies`in SHA-kayması
    /// düzeltmesi). Bu, `force_refetch=false` İKEN de git'in ÇAĞRILDIĞI
    /// TEK durumdur — `.cached`DEN farklıdır (git ÇAĞRILDI), `.fetched`/
    /// `.updated`DAN farklıdır (kilitli SHA DEĞİŞMEDİ, sadece YENİDEN
    /// önbelleklendi).
    recached,
};
const DepOutcome = struct {
    alias: []const u8,
    repo: []const u8,
    action: DepAction,
    resolved: []const u8,
    previous_resolved: ?[]const u8,
};

/// `manifest.requires[]`in HER birini çözer — `resolveImportsForBuild`in
/// AYNI iç döngüsünün (bkz. onun belge notu) `fetch`/`update` İLE
/// PAYLAŞILAN bağımsız bir çekirdeğidir. **BİLİNÇLİ olarak
/// `resolveImportsForBuild`a DOKUNULMADI** — o ZATEN test edilmiş/load-
/// bearing bir yol, bu YENİ, AYRI bir fonksiyondur (riski AZALTMAK İçin,
/// `nox.thread`/`ThreadChannel` fazlarının AYNI "mevcut load-bearing
/// koda dokunmadan yanına ekle" disiplinini SÜRDÜRÜR).
///
/// `force_refetch` `false` İSE (`fetch`in davranışı) ZATEN kilitli+
/// önbellekte mevcut bir bağımlılığa HİÇ DOKUNULMAZ (`.cached` sonucu).
/// `true` İSE (`update`) HER bağımlılık `req.ref`den YENİDEN çözülür (bir
/// dal/tag'in İLERLEMİŞ OLABİLECEĞİ varsayımıyla, Go'nun `go get -u`suyla
/// AYNI kavram) — `git` HER durumda ÇAĞRILIR, ama SONUÇ AYNI SHA'ya
/// çözülürse (`ref` ZATEN bir SHA'ysa ya da dal HİÇ ilerlemediyse)
/// `.unchanged` olarak işaretlenir (`.updated` DEĞİL — çağıranın "kaç
/// tanesi GERÇEKTEN değişti" özetini DOĞRU basabilmesi İÇİN).
fn resolveDependencies(
    a: std.mem.Allocator,
    io: std.Io,
    nox_home: []const u8,
    manifest: project.Manifest,
    lock: project.Lockfile,
    force_refetch: bool,
    fetch_policy: fetch.FetchPolicy,
) !struct { packages: []project.LockedPackage, outcomes: []DepOutcome, changed: bool } {
    var new_packages: std.ArrayListUnmanaged(project.LockedPackage) = .empty;
    try new_packages.appendSlice(a, lock.packages);
    var outcomes: std.ArrayListUnmanaged(DepOutcome) = .empty;
    var changed = false;

    for (manifest.requires) |req| {
        const locked_opt = project.findLocked(lock, req.alias);
        if (!force_refetch) {
            if (locked_opt) |locked| {
                const cache_dir = try fetch.cachedDirFor(a, nox_home, locked.repo, locked.resolved);
                if (std.Io.Dir.accessAbsolute(io, cache_dir, .{})) |_| {
                    try outcomes.append(a, .{ .alias = req.alias, .repo = req.repo, .action = .cached, .resolved = locked.resolved, .previous_resolved = null });
                    continue;
                } else |_| {}
            }
        }

        // Faz P2.4 (bkz. proje belleği "P0/P1/P2 inceleme düzeltme listesi"
        // planı — GERÇEK, önceden keşfedilmemiş bir hata, `resolveImportsForBuild`
        // İLE AYNI gerekçe): `force_refetch=false` İKEN (yani `fetch`),
        // önbellek dizini KAYBOLMUŞTU AMA ZATEN kilitli bir SHA VARSA (VE
        // `repo` DEĞİŞMEDİYSE), `req.ref`i (hareketli olabilir) DEĞİL,
        // kilitli SHA'nın KENDİSİNİ getir — `force_refetch=true` İKEN
        // (`update`) BU YOLA HİÇ GİRİLMEZ, `req.ref` HER ZAMAN yeniden
        // çözülür (bu, "update"in TAM OLARAK YAPMASI GEREKEN şey).
        const cache_was_missing_for_locked = !force_refetch and locked_opt != null and std.mem.eql(u8, locked_opt.?.repo, req.repo);
        const fetch_ref = if (cache_was_missing_for_locked) locked_opt.?.resolved else req.ref;

        const previous = if (locked_opt) |locked| locked.resolved else null;
        var sig_diag: ?[]const u8 = null;
        const result = fetch.fetchToCache(a, io, nox_home, req.repo, fetch_ref, req.require_signed_commit, &sig_diag, fetch_policy) catch |e| {
            if (e == error.CommitSignatureRejected) {
                printErr("paket getirilemedi (alias={s}, repo={s}): commit imza dogrulamasi basarisiz:\n{s}\n", .{ req.alias, req.repo, sig_diag orelse "(git aciklama vermedi)" });
            } else {
                printErr("paket getirilemedi (alias={s}, repo={s}): {t}\n", .{ req.alias, req.repo, e });
            }
            std.process.exit(1);
        };

        var found_idx: ?usize = null;
        for (new_packages.items, 0..) |p, i| {
            if (std.mem.eql(u8, p.alias, req.alias)) {
                found_idx = i;
                break;
            }
        }
        const new_entry: project.LockedPackage = .{ .alias = req.alias, .repo = req.repo, .ref = req.ref, .resolved = result.resolved_sha };
        if (found_idx) |i| new_packages.items[i] = new_entry else try new_packages.append(a, new_entry);

        const same_as_before = if (previous) |p| std.mem.eql(u8, p, result.resolved_sha) else false;
        if (!same_as_before) changed = true;

        const action: DepAction = if (cache_was_missing_for_locked) .recached else if (previous == null) .fetched else if (same_as_before) .unchanged else .updated;
        try outcomes.append(a, .{ .alias = req.alias, .repo = req.repo, .action = action, .resolved = result.resolved_sha, .previous_resolved = previous });
    }

    return .{ .packages = new_packages.items, .outcomes = outcomes.items, .changed = changed };
}

fn shortSha(sha: []const u8) []const u8 {
    return if (sha.len > 7) sha[0..7] else sha;
}

/// `noxc fetch` — Faz CC.2 (bkz. nox-teknik-spesifikasyon.md §3.54):
/// mevcut projenin `nox.json`daki `requires[]`ini, `build`/`run`/`test`in
/// ZATEN uyguladığı "otomatik, gerektiğinde getir" akışının AYNISIYLA —
/// ama BİR `.nox` dosyası derlemeden — önbelleğe DOLDURUR. ZATEN kilitli+
/// önbellekte olan bağımlılıklara DOKUNULMAZ.
fn cmdFetch(io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, fetch_policy: fetch.FetchPolicy) !void {
    _ = args;
    const root = try findProjectRootOrExit(io, a, "fetch");
    const manifest = loadManifestOrExit(a, io, root);
    const lock = loadLockfileOrExit(a, io, root);

    if (manifest.requires.len == 0) {
        std.debug.print("fetch: nox.json'da hic bagimlilik yok ('requires' bos)\n", .{});
        return;
    }

    const result = try resolveDependencies(a, io, nox_home, manifest, lock, false, fetch_policy);
    if (result.changed) {
        try project.saveLockfile(a, io, root, .{ .packages = result.packages });
    }

    var fetched: usize = 0;
    var cached: usize = 0;
    var recached: usize = 0;
    for (result.outcomes) |o| {
        switch (o.action) {
            .fetched => {
                fetched += 1;
                std.debug.print("getirildi: {s} ({s}@{s})\n", .{ o.alias, o.repo, shortSha(o.resolved) });
            },
            .cached => {
                cached += 1;
                std.debug.print("zaten guncel: {s} ({s})\n", .{ o.alias, shortSha(o.resolved) });
            },
            .recached => {
                recached += 1;
                std.debug.print("onbellek yeniden olusturuldu (kilitli SHA'dan): {s} ({s})\n", .{ o.alias, shortSha(o.resolved) });
            },
            .updated, .unchanged => unreachable, // force_refetch=false bunlari asla uretmez
        }
    }
    std.debug.print("fetch tamamlandi: {d} getirildi, {d} zaten guncel, {d} yeniden onbelleklendi\n", .{ fetched, cached, recached });
}

/// `noxc update` — `fetch`in AKSİNE, HER bağımlılığı `req.ref`den
/// KOŞULSUZ yeniden çözer (bkz. `resolveDependencies`in
/// `force_refetch=true`ı) — `nox.lock`taki kilitli SHA'ları GÜNCELLER.
fn cmdUpdate(io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, fetch_policy: fetch.FetchPolicy) !void {
    _ = args;
    const root = try findProjectRootOrExit(io, a, "update");
    const manifest = loadManifestOrExit(a, io, root);
    const lock = loadLockfileOrExit(a, io, root);

    if (manifest.requires.len == 0) {
        std.debug.print("update: nox.json'da hic bagimlilik yok ('requires' bos)\n", .{});
        return;
    }

    const result = try resolveDependencies(a, io, nox_home, manifest, lock, true, fetch_policy);
    try project.saveLockfile(a, io, root, .{ .packages = result.packages });

    var updated: usize = 0;
    var unchanged: usize = 0;
    for (result.outcomes) |o| {
        switch (o.action) {
            .updated => {
                updated += 1;
                std.debug.print("guncellendi: {s} {s} -> {s}\n", .{ o.alias, shortSha(o.previous_resolved.?), shortSha(o.resolved) });
            },
            .unchanged => {
                unchanged += 1;
                std.debug.print("degismedi: {s} ({s})\n", .{ o.alias, shortSha(o.resolved) });
            },
            .fetched => {
                updated += 1;
                std.debug.print("yeni kilitlendi: {s} ({s}@{s})\n", .{ o.alias, o.repo, shortSha(o.resolved) });
            },
            .cached => unreachable, // force_refetch=true asla .cached uretmez
            .recached => unreachable, // force_refetch=true asla .recached uretmez (bkz. DepAction.recached'in belge notu)
        }
    }
    std.debug.print("update tamamlandi: {d} guncellendi, {d} degismedi\n", .{ updated, unchanged });
}

/// `dir`/`name`i birleştirir — `dir == "."` İSE (varsayılan, `noxc init`in
/// argümansız çağrısı) YALIN `name`i döner (kullanıcıya "./nox.json"
/// yerine "nox.json" GİBİ temiz mesajlar/yollar basmak İÇİN).
fn joinIfNeeded(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, dir, ".")) return name;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

/// `noxc init [proje-adi]` — Faz CC.2.2 (bkz. nox-teknik-spesifikasyon.md
/// §3.56): Cargo/Go tarzı proje iskeleti oluşturucu. Argüman VERİLMEZSE
/// (`cargo init` deseni) CWD'nin KENDİSİNDE, CWD'nin taban adını proje
/// adı olarak KULLANARAK; VERİLİRSE (`cargo new` deseni) O adla YENİ bir
/// alt dizin OLUŞTURUP İÇİNDE başlatır. `nox.json`/`main.nox` ZATEN
/// VARSA ÜZERİNE YAZILMAZ (net bir hatayla exit 1) — var olan bir
/// projeyi YANLIŞLIKLA silmemek İçin.
fn cmdInit(io: std.Io, a: std.mem.Allocator, args: []const []const u8) !void {
    const has_name_arg = args.len > 0 and args[0].len > 0;
    const target_dir: []const u8 = if (has_name_arg) args[0] else ".";
    const project_name: []const u8 = if (has_name_arg) args[0] else blk: {
        const cwd = try std.process.currentPathAlloc(io, a);
        break :blk std.fs.path.basename(cwd);
    };

    if (has_name_arg) {
        std.Io.Dir.cwd().createDirPath(io, target_dir) catch |e| {
            printErr("init: dizin olusturulamadi ({s}): {t}\n", .{ target_dir, e });
            std.process.exit(1);
        };
    }

    const manifest_path = try joinIfNeeded(a, target_dir, "nox.json");
    if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
        printErr("init: '{s}' zaten var, uzerine yazilmiyor\n", .{manifest_path});
        std.process.exit(1);
    } else |_| {}

    const manifest_json = try std.fmt.allocPrint(a,
        \\{{
        \\  "name": "{s}",
        \\  "entry": "main.nox"
        \\}}
        \\
    , .{project_name});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = manifest_json });

    const main_path = try joinIfNeeded(a, target_dir, "main.nox");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = main_path, .data = "print(\"merhaba, nox!\")\n" });

    // `.gitignore` ZATEN VARSA (ör. `noxc init`, GİT DEPOSU olan bir
    // dizinde çalıştırıldığında) DOKUNULMAZ — SADECE YENİ bir proje İÇİN
    // makul bir varsayılan sağlanır.
    const gitignore_path = try joinIfNeeded(a, target_dir, ".gitignore");
    if (std.Io.Dir.cwd().access(io, gitignore_path, .{})) |_| {} else |_| {
        // `.nox/` — üçüncü-taraf paket önbelleği/derlenmiş-ikili önbelleği
        // (bkz. `compiler/main.zig`nin `.nox/cache/bin` notu); `main` —
        // `noxc build`in varsayılan `entry`den (`main.nox`) ürettiği
        // ikilinin adı. `nox.lock` KASITLI olarak İGNORE EDİLMEZ (VCS'e
        // commit EDİLMESİ GEREKİR — bkz. `project.zig`nin belge notu).
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gitignore_path, .data = ".nox/\nmain\n" });
    }

    printOk("olusturuldu: {s}, {s}\n", .{ manifest_path, main_path });
}

/// `noxc check <dosya.nox>` — Faz CC.2.2: SADECE lex→parse→import
/// çözümü→tip denetimi çalıştırır — ownership analizi/codegen/`qbe`/`cc`
/// (`buildOne`in AKSİNE) HİÇ TETİKLENMEZ. Editör entegrasyonu/hızlı geri
/// bildirim İÇİN — `noxc build`in TAM derleme MALİYETİNE (bir native
/// binary ÜRETMEK) katlanmadan "bu dosya GEÇERLİ mi?" sorusunu YANITLAR.
/// `buildOne`in AYNI ÖN EKİNİ (lex/parse/import-çözümü/checker) BİLİNÇLİ
/// olarak YİNELER (AYRI bir fonksiyon — `buildOne`a `codegen'e kadar mı
/// gidilsin` bayrağı EKLEMEK yerine, o ZATEN karmaşık fonksiyonu daha da
/// dallandırmamak İçin).
fn cmdCheck(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const path_arg = if (args.len > 0) args[0] else {
        std.debug.print("kullanim: noxc check <dosya.nox>\n", .{});
        std.process.exit(1);
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024));
    defer gpa.free(source);

    const tokens = try lexer.tokenize(a, source);
    const user_module = try parser.parseModule(a, tokens);
    const module = try resolveImportsForBuild(io, a, user_module, path_arg, nox_home, resource_dirs, fetch_policy);

    var checker_state = checker.Checker.init(a);
    checker_state.checkModule(module) catch |e| {
        printErr("tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        std.process.exit(1);
    };
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            printErr("tip hatasi ({t}): {s}\n", .{ d.code, d.message });
        }
        std.process.exit(1);
    }

    printOk("tip hatasi yok: {s}\n", .{path_arg});
}

/// Tek bir `.nox` dosyasını uçtan uca derler (lex→parse→import çözümü→tip
/// denetimi→[isteğe bağlı döküm]→codegen→qbe→cc) ve üretilen binary'nin
/// yolunu döner. Hata durumlarında (mevcut davranışla BİREBİR aynı mesaj/
/// çıkış kodu) doğrudan `std.process.exit(1)` çağırır — `cmdBuild`/`cmdRun`
/// bu davranışı DEĞİŞTİRMEDEN miras alır.
fn buildOne(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, path_arg: []const u8, verbose: bool, output_override: ?[]const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, debug_info: bool, fetch_policy: fetch.FetchPolicy) ![]const u8 {
    // Bulundu (kullanıcı geri bildirimi): `noxc upgrade` gibi mistyped/
    // bilinmeyen bir alt komut, tanınan HİÇBİR anahtar kelimeyle
    // eşleşmediğinden `.legacy`ye (bkz. `main`'in belge notu) düşüp
    // BURAYA "upgrade" isimli bir DOSYA olarak geliyordu — ham "error:
    // FileNotFound" mesajı KAFA KARIŞTIRICIYDI. `.nox` İLE BİTMEYEN bir
    // yol İçin (GERÇEK bir `.nox` dosyası YANLIŞLIKLA silinmiş/taşınmış
    // olma İHTİMALİNİ hâlâ AYRI tutarak) bilinmeyen-komut İPUCU eklenir.
    const source = std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            if (std.mem.endsWith(u8, path_arg, ".nox")) {
                if (g_is_tr) {
                    printErr("dosya bulunamadi: {s}\n", .{path_arg});
                } else {
                    printErr("file not found: {s}\n", .{path_arg});
                }
            } else if (g_is_tr) {
                printErr("bilinmeyen komut ya da dosya: '{s}' — komutlar icin: noxc --help\n", .{path_arg});
            } else {
                printErr("unknown command or file: '{s}' — for commands, run: noxc --help\n", .{path_arg});
            }
            std.process.exit(1);
        }
        return err;
    };
    defer gpa.free(source);

    const tokens = try lexer.tokenize(a, source);
    const user_module = try parser.parseModule(a, tokens);

    // Faz O §P.6: proje kökü (`nox.json`) BULUNAMAZSA `resolveImports`in
    // ESKİ, DEĞİŞMEMİŞ davranışına (yalnızca `nox.*` stdlib) DÜŞER;
    // BULUNURSA `requires[]`i ÇÖZÜP `resolveProjectImports`i ÇAĞIRIR (bkz.
    // `resolveImportsForBuild`'in belge notu). Her iki yol da (Faz Q.3)
    // `resource_dirs.stdlib_dir`i (CWD-göreli `"stdlib"` DEĞİL, `noxc`nin
    // KENDİ çözülmüş kaynak dizinini) kullanır.
    const module = try resolveImportsForBuild(io, a, user_module, path_arg, nox_home, resource_dirs, fetch_policy);

    // `checker.check`'in kullanışlı ok/err sarmalayıcısı yerine `Checker`
    // doğrudan kullanılır: Faz 10 generics'i somut örneklemeleri
    // (`checker_state.instantiations`) burada, ownership analizi ve codegen'e
    // iletmek için gereklidir (bkz. checker.zig, "Faz 10: generics" notu).
    var checker_state = checker.Checker.init(a);
    checker_state.checkModule(module) catch |e| {
        printErr("tip hatasi ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(mesaj yok)" });
        std.process.exit(1);
    };
    // Faz T.2: `checkModule` artık fonksiyon/sınıf/metod/gevşek-deyim
    // SINIRINDAKİ hatalarda FIRLATMAZ, `checker_state.diagnostics`e
    // KAYDEDER (bkz. checker.zig, `recordDiagnostic`) — bu yüzden BAŞARILI
    // dönüş TEK BAŞINA "tip hatasız" anlamına GELMEZ, AYRICA kontrol edilir.
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            printErr("tip hatasi ({t}): {s}\n", .{ d.code, d.message });
        }
        std.process.exit(1);
    }
    const instantiations = checker_state.instantiations.items;

    // Codegen'in `module.body`deki generic ŞABLONLARINI (açık `[T]` VEYA
    // Faz 11'in örtük protokol parametresi yoluyla) atlayabilmesi için
    // isimlerini iletiyoruz (bkz. codegen.zig, `generateModule` belge notu).
    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(a, k.*);

    // Faz P2.1 (bkz. proje belleği "generic sınıflar" planı): `instantiations`/
    // `generic_names`in AYNISI ama SINIFLAR İçin.
    const class_instantiations = checker_state.class_instantiations.items;
    var generic_class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_class_it = checker_state.generic_classes.keyIterator();
    while (generic_class_it.next()) |k| try generic_class_names.append(a, k.*);

    // Faz U.4.3: checker'ın closure yakalama (capture) listelerini
    // (`checker.ClosureInfo`, isim + SEMANTIK `Type`) codegen'in beklediği
    // basitleştirilmiş şekle (yol → yalnızca yakalanan İSİMLER) çevirir —
    // codegen, HER yakalanan ismin TAM `TypeInfo`sini KENDİSİ, dış
    // fonksiyonun O ANKİ `self.vars`ından türetir (bkz. `genNestedFuncDef`in
    // belge notu) — bu yüzden `Type`↔`TypeInfo` dönüştürücüsüne GEREK YOK.
    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try a.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(a, entry.key_ptr.*, names);
    }

    if (verbose) {
        // `report` yalnızca BU dökümün İÇİN hesaplanır (codegen KENDİ
        // sahiplik kararlarını AYRICA/dahili olarak üretir, `report`ı asla
        // parametre olarak ALMAZ) — `verbose` DEĞİLSE `ownership.analyze`
        // çağrısının KENDİSİ de atlanır, yalnızca I/O DEĞİL, hesaplama da
        // tasarruf edilir.
        const report = try ownership.analyze(a, module, instantiations, generic_names.items, class_instantiations, generic_class_names.items);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
        try stdout_writer.interface.writeAll("--- sahiplik analizi ---\n");
        try ownership.dumpReport(&stdout_writer.interface, report);
        try stdout_writer.interface.writeAll("--- AST ---\n");
        try ast_dump.dumpModule(&stdout_writer.interface, module);
        try stdout_writer.interface.flush();
    }

    // Faz T.3: `-g` VERİLDİYSE `path_arg` `dbgfile` olarak gömülür — bkz.
    // codegen.zig'in modül üstü notu (TEK dosya, stdlib-merge yanlış-atıf
    // sınırlaması bilinçli olarak KABUL EDİLDİ).
    const debug_source_path: ?[]const u8 = if (debug_info) path_arg else null;
    const ir = codegen.generateModule(a, module, instantiations, generic_names.items, class_instantiations, generic_class_names.items, debug_source_path, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports) catch |err| switch (err) {
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
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): MinGW'in `cc`si,
    // `-o` AÇIKÇA verilmiş olsa BİLE, PE (Windows) çıktı dosyasına HER ZAMAN
    // `.exe` uzantısı EKLER (`stem` zaten `.exe` İLE BİTMİYORSA) — `noxc`
    // BUNU BİLMEZSE, diskteki GERÇEK dosya `stem.exe` iken `noxc run`ın
    // ÇALIŞTIRMAYA ÇALIŞTIĞI yol UZANTISIZ `stem` OLURDU (bulunamaz hatası).
    const bin_path = if (builtin.os.tag == .windows and !std.mem.endsWith(u8, stem, ".exe"))
        try std.fmt.allocPrint(a, "{s}.exe", .{stem})
    else
        stem;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ssa_path, .data = ir });

    const qbe_result = try std.process.run(gpa, io, .{
        .argv = &.{ "qbe", "-t", qbe_target.name(), "-o", asm_path, ssa_path },
    });
    defer gpa.free(qbe_result.stdout);
    defer gpa.free(qbe_result.stderr);
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        printErr("qbe basarisiz:\n{s}\n", .{qbe_result.stderr});
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
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): MinGW'in `cc`si
    // `-rdynamic`yi TANIMAZ (`cc: error: unrecognized command-line option
    // '-rdynamic'` — GERÇEK Windows CI'de doğrulandı) — PE bağlayıcısının
    // "TÜM genel sembolleri dışa aç" karşılığı `-Wl,--export-all-symbols`dir.
    const dynamic_export_flag = if (builtin.os.tag == .windows) "-Wl,--export-all-symbols" else "-rdynamic";
    var cc_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try cc_argv.appendSlice(a, &.{ "cc", dynamic_export_flag, "-o", bin_path, asm_path, resource_dirs.noxrt_path });
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): Windows'ta fiber
    // bağlam değişimi assembly'si `noxrt.o`nun DIŞINDA, AYRI kurulur (bkz.
    // `ResourceDirs.swap_asm_path`ın belge notu) — bu YÜZDEN NİHAİ bağlamaya
    // AYRI bir girdi olarak eklenmesi GEREKİR.
    if (builtin.os.tag == .windows) try cc_argv.append(a, resource_dirs.swap_asm_path);
    try cc_argv.append(a, "-lm");
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): Zig'in KENDİ std
    // kütüphanesi (Windows dosya/iş parçacığı/zamanlayıcı ilkelleri İçin
    // `ntdll.dll`nin `Nt*`/`Rtl*`/`Ldr*` sembollerini, `std.http.Client`in
    // TLS sertifika DOĞRULAMASI İçin `crypt32.dll`nin `Cert*` sembollerini,
    // `runtime/async_rt/io.zig`nin `WinSock`u İSE `ws2_32.dll`nin
    // `WSAGetLastError`/`accept`/... sembollerini KULLANIR) MinGW'in
    // VARSAYILAN bağlama kütüphaneleri ARASINDA DEĞİLDİR — AÇIKÇA
    // eklenmesi GEREKİR (GERÇEK Windows CI'de `undefined reference to
    // 'WSAGetLastError'`/`'NtCreateFile'`/`'CertOpenSystemStoreW'`/... İLE
    // doğrulandı).
    if (builtin.os.tag == .windows) try cc_argv.appendSlice(a, &.{ "-lntdll", "-lws2_32", "-lcrypt32" });
    try appendExternLinkArgs(a, &cc_argv, module);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = cc_argv.items,
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        printErr("cc basarisiz:\n{s}\n", .{cc_result.stderr});
        std.process.exit(1);
    }

    return bin_path;
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
        if (stmt.kind != .extern_def) continue;
        const from_lib = stmt.kind.extern_def.from_lib;
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
