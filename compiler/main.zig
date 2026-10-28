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
const sandbox = @import("sandbox.zig");
const signing = @import("pkg/signing.zig");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const syntax_report = @import("syntax_report.zig");
const ast = @import("parser/ast.zig");
const ast_dump = @import("parser/ast_dump.zig");
const checker = @import("typecheck/checker.zig");
const ownership = @import("ownership/analysis.zig");
const codegen = @import("codegen_qbe/codegen.zig");
const local_escape = @import("codegen_qbe/local_escape.zig");
const inlining_mod = @import("codegen_qbe/inlining.zig");
const module_loader = @import("module_loader.zig");
const project = @import("project.zig");
const qbe_target = @import("qbe_target.zig");
const test_runner = @import("pkg/test_runner.zig");
const fetch = @import("pkg/fetch.zig");
const hpy_host_mod = @import("pkg/hpy_host.zig");
const pkg_index = @import("pkg/index.zig");
const upgrade_mod = @import("pkg/upgrade.zig");
const registry = @import("pkg/registry.zig");
const install_mod = @import("pkg/install.zig");
const cache_prune = @import("pkg/cache_prune.zig");
const run_cache = @import("pkg/run_cache.zig");
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
            \\  noxc <dosya.nox>              dosyayı çalıştırılabilir bir ikiliye derler (build'in kısayolu)
            \\  noxc <alt-komut> [seçenekler]
            \\
            \\Alt komutlar:
            \\  build <dosya.nox>     derler, çalıştırılabilir bir ikili üretir
            \\  run <dosya.nox>       derler + hemen çalıştırır (-- ile argv iletilir)
            \\  test [isim|yol ...]   *_test.nox dosyalarını çalıştırır; isim dosya adında aranır
            \\  check <dosya.nox>     yalnızca tip denetimi yapar (codegen/qbe/cc yok, hızlı)
            \\  expand <dosya.nox>    decorator metadata'sını (isim/argümanlar) yazdırır
            \\  explain [--release] <dosya.nox>  yerel değişkenlerin stack/arena/ARC tahsis kararını ve nedenini yazdırır
            \\  fmt <dosya.nox>       dosyayı standart biçimde yeniden yazar
            \\  init [ad]             yeni bir proje iskeleti oluşturur (nox.json + main.nox)
            \\  fetch                 nox.json'daki bağımlılıkları önbelleğe doldurur
            \\  update                bağımlılıkları en son ref'lerine yeniden çözer, nox.lock'u günceller
            \\  search <q>            merkezi indekste (varsayilan: noxpkg.noxlang.com) sorgular
            \\  search <indeks> <q>   belirtilen bir paket indeksini (dosya veya URL) sorgular
            \\  add <alias> [repo]    bagimliligi nox.json'a ekler (repo verilmezse indeksten cozer)
            \\  delete <alias>        bagimliligi nox.json'dan (ve nox.lock'tan) cikarir
            \\  publish <repo>        paket metadatasini merkezi indekse gonderir (admin onayi bekler)
            \\  upgrade [--check] [s] noxc'nin kendisini en son (ya da belirtilen) surume gunceller
            \\  install <ad|repo>     bir paketi GLOBAL olarak kurar (paketin kendi 'bin' giris noktasi gerekir)
            \\  uninstall <komut>     global kurulu bir paketi kaldirir
            \\  list                  global kurulu paketleri listeler
            \\  refresh [paket]       global kurulu paket(ler)i en son surume gunceller (paket verilmezse TUMUNU gunceller)
            \\  cache prune [--dry-run] [--all]  paket onbelleginin eski SHA dizinlerini siler (install/refresh/upgrade de otomatik yapar)
            \\  version               sürüm bilgisini yazdırır (--version/-V ile aynı)
            \\
            \\Ortak seçenekler:
            \\  --dump, -v             ayrıntılı/AST dökümü (build/run/check ile)
            \\  -o <çıktı>             çıktı ikilisinin adı (yalnızca build ile)
            \\  --profile <hosted|freestanding>  stdlib import allowlist'i (build/check ile, varsayılan: hosted)
            \\  --backend <llvm|qbe>   kod üretim backend'i (varsayılan: llvm; freestanding/--target/--emit-asm/-g yada clang ve zig yoksa qbe)
            \\
            \\Örnekler:
            \\  noxc run main.nox -- a b c
            \\  noxc build -o app main.nox
            \\  noxc search http
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
            \\  noxc <file.nox>              compile the file to an executable (shortcut for build)
            \\  noxc <subcommand> [options]
            \\
            \\Subcommands:
            \\  build <file.nox>      compile, producing an executable binary
            \\  run <file.nox>        compile + run immediately (argv after --)
            \\  test [name|path ...]  run *_test.nox files; a name matches the file name
            \\  check <file.nox>      type-check only (no codegen/qbe/cc, fast feedback)
            \\  expand <file.nox>     print decorator metadata (name/args) extracted from the file
            \\  explain [--release] <file.nox>  print each local variable's stack/arena/ARC allocation decision and why
            \\  fmt <file.nox>        rewrite the file in the standard format
            \\  init [name]           scaffold a new project (nox.json + main.nox)
            \\  fetch                 populate the dependency cache from nox.json
            \\  update                re-resolve dependencies to their latest refs, update nox.lock
            \\  search <q>            query the central index (default: noxpkg.noxlang.com)
            \\  search <index> <q>    query a specific package index (file or URL)
            \\  add <alias> [repo]    add a dependency to nox.json (resolves repo from the index if omitted)
            \\  delete <alias>        remove a dependency from nox.json (and nox.lock)
            \\  publish <repo>        submit package metadata to the central index (awaits admin approval)
            \\  upgrade [--check] [v] self-update noxc to the latest (or a given) version
            \\  install <name|repo>   GLOBALLY install a package (needs its own 'bin' entry point)
            \\  uninstall <command>   remove a globally installed package
            \\  list                  list globally installed packages
            \\  cache prune [--dry-run] [--all]  delete stale package-cache SHA dirs (install/refresh/upgrade also do this automatically)
            \\  version               print version info (same as --version/-V)
            \\
            \\Common options:
            \\  --dump, -v             verbose/AST dump (with build/run/check)
            \\  -o <output>            output binary name (build only)
            \\  --profile <hosted|freestanding>  stdlib import allowlist (with build/check, default: hosted)
            \\  --backend <llvm|qbe>   code generation backend (default: llvm; qbe for freestanding/--target/--emit-asm/-g or when neither clang nor zig is found)
            \\
            \\Examples:
            \\  noxc run main.nox -- a b c
            \\  noxc build -o app main.nox
            \\  noxc search http
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

/// Kullanıcı kaynağını ayrıştırır; sözdizimi hatasında okunaklı tanılamayı basıp süreci sonlandırır.
fn parseUserSource(a: std.mem.Allocator, source: []const u8, path: []const u8) !ast.Module {
    return syntax_report.parseSource(a, source, path) catch |e| switch (e) {
        error.SyntaxError => return error.SyntaxError,
        error.OutOfMemory => return e,
    };
}

pub fn main(init: std.process.Init) !void {
    return realMain(init) catch |e| {
        // `syntax_report` hatayı ZATEN okunaklı biçimde yazdı (örn. bir içe aktarılan modülde).
        const name = @errorName(e);
        if (std.mem.eql(u8, name, "SyntaxError") or std.mem.eql(u8, name, "BuildFailed")) std.process.exit(1);
        return e;
    };
}

fn realMain(init: std.process.Init) !void {
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

    // `noxc upgrade` (bkz. `pkg/upgrade.zig`nin modül üstü notu) — YALNIZCA-
    // TEST override'ları, `NOX_HOME`/`NOX_RESOURCE_DIR` İLE AYNI "BİR KEZ
    // oku, açıkça ilet" disiplini (GERÇEK kullanımda İKİSİ de VERİLMEZ,
    // varsayılan GERÇEK GitHub URL'leri kullanılır).
    var upgrade_policy: upgrade_mod.UpgradePolicy = .{};
    if (init.environ_map.get("NOX_UPGRADE_API_BASE")) |v| upgrade_policy.api_base = try a.dupe(u8, v);
    if (init.environ_map.get("NOX_UPGRADE_DOWNLOAD_BASE")) |v| upgrade_policy.download_base = try a.dupe(u8, v);

    // `noxc add`/`noxc publish` (bkz. `pkg/registry.zig`nin modül üstü
    // notu) — `upgrade_policy` İLE AYNI desen: varsayılan GERÇEK `noxpkg`
    // URL'leri, testler/yerel geliştirme İçin env override'ları.
    var registry_policy: registry.RegistryPolicy = .{};
    if (init.environ_map.get("NOX_INDEX_URL")) |v| registry_policy.index_url = try a.dupe(u8, v);
    if (init.environ_map.get("NOX_PUBLISH_API_BASE")) |v| registry_policy.publish_api_base = try a.dupe(u8, v);

    const Subcommand = enum { sign, build, run, test_cmd, fmt, fetch, update, search, add, delete, publish, init, check, expand, explain, version, help, upgrade, install, uninstall, list_installed, refresh, cache, legacy };
    const sub: Subcommand = blk: {
        // Bulundu (kullanıcı geri bildirimi): çıplak `noxc` ÖNCEDEN `.legacy`ye
        // düşüp `cmdBuild`i argümansız çağırıyordu — tek satırlık bir
        // "kullanim" mesajı VERİYORDU ama modern bir yardım ekranı DEĞİLDİ.
        // Artık `.help`e gider (bkz. `printHelp`) — bu, "argümansız çalıştırma"
        // hiçbir GEÇERLİ dosya derlemesi ANLAMINA GELMEDİĞİNDEN, `.legacy`nin
        // "geriye dönük uyumlu tekil-dosya" sözleşmesini BOZMAZ.
        if (all_args.items.len == 0) break :blk .help;
        const first = all_args.items[0];
        if (std.mem.eql(u8, first, "sign")) break :blk .sign;
        if (std.mem.eql(u8, first, "build")) break :blk .build;
        if (std.mem.eql(u8, first, "run")) break :blk .run;
        if (std.mem.eql(u8, first, "test")) break :blk .test_cmd;
        if (std.mem.eql(u8, first, "fmt")) break :blk .fmt;
        if (std.mem.eql(u8, first, "fetch")) break :blk .fetch;
        if (std.mem.eql(u8, first, "update")) break :blk .update;
        if (std.mem.eql(u8, first, "search")) break :blk .search;
        if (std.mem.eql(u8, first, "add")) break :blk .add;
        if (std.mem.eql(u8, first, "delete")) break :blk .delete;
        if (std.mem.eql(u8, first, "publish")) break :blk .publish;
        if (std.mem.eql(u8, first, "init")) break :blk .init;
        if (std.mem.eql(u8, first, "check")) break :blk .check;
        if (std.mem.eql(u8, first, "expand")) break :blk .expand;
        if (std.mem.eql(u8, first, "explain")) break :blk .explain;
        // `-v`/`--dump` ZATEN `build`in AYRINTILI-döküm bayrağı olduğundan
        // (bkz. modül üstü not), sürüm İÇİN `-V` (büyük harf, `-v` İLE
        // ÇAKIŞMAZ) VE `--version`/`version` KULLANILIR — `rustc`/`go`/`node`
        // İLE TUTARLI bir dizi eşanlamlı.
        if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) break :blk .version;
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) break :blk .help;
        if (std.mem.eql(u8, first, "upgrade")) break :blk .upgrade;
        if (std.mem.eql(u8, first, "install")) break :blk .install;
        if (std.mem.eql(u8, first, "uninstall")) break :blk .uninstall;
        if (std.mem.eql(u8, first, "list")) break :blk .list_installed;
        if (std.mem.eql(u8, first, "refresh")) break :blk .refresh;
        if (std.mem.eql(u8, first, "cache")) break :blk .cache;
        break :blk .legacy;
    };
    const rest: []const []const u8 = if (sub == .legacy or all_args.items.len == 0) all_args.items else all_args.items[1..];

    switch (sub) {
        .build => try cmdBuild(gpa, io, a, rest, "usage: noxc build [--dump|-v] [-o <output>] <file.nox>\n", nox_home, resource_dirs, fetch_policy),
        .legacy => try cmdBuild(gpa, io, a, rest, "usage: noxc [--dump|-v] <file.nox>  (for commands: noxc --help)\n", nox_home, resource_dirs, fetch_policy),
        .help => printHelp(is_tr),
        .sign => try cmdSign(io, a, rest, nox_home),
        .run => try cmdRun(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
        .test_cmd => try cmdTest(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
        .fmt => try cmdFmt(gpa, io, a, rest),
        .search => try cmdSearch(io, a, rest, registry_policy, fetch_policy),
        .add => try cmdAdd(io, a, rest, registry_policy, fetch_policy),
        .delete => try cmdDelete(io, a, rest),
        .publish => try cmdPublish(io, a, rest, registry_policy, fetch_policy),
        .version => std.debug.print("noxc {s}\n", .{build_options.version}),
        .fetch => try cmdFetch(io, a, rest, nox_home, fetch_policy),
        .update => try cmdUpdate(io, a, rest, nox_home, fetch_policy),
        .init => try cmdInit(io, a, rest),
        .check => try cmdCheck(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
        .expand => try cmdExpand(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
        .explain => try cmdExplain(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy),
        .upgrade => try cmdUpgrade(a, io, rest, resource_dir_override, upgrade_policy, fetch_policy, nox_home),
        .install => try cmdInstall(gpa, io, a, rest, nox_home, resource_dirs, registry_policy, fetch_policy, init.environ_map),
        .uninstall => try cmdUninstall(io, a, rest, nox_home),
        .list_installed => try cmdListInstalled(io, a, nox_home),
        .refresh => try cmdRefresh(gpa, io, a, rest, nox_home, resource_dirs, fetch_policy, init.environ_map),
        .cache => try cmdCache(io, a, rest, nox_home),
    }
}

/// `noxc upgrade [--check] [<sürüm>]` — bkz. `pkg/upgrade.zig`nin modül
/// üstü notu (tasarım/güvenlik modeli). `<sürüm>` (ör. `v1.3.0`) VERİLİRSE
/// ağ çağrısı OLMADAN o sürüme sabitlenir (düşürme DAHİL); VERİLMEZSE
/// GitHub'ın "latest release"i çözülür. `--check`, kurulum/indirmeyi
/// ATLAYIP yalnızca mevcut/en-son sürümü KARŞILAŞTIRIP raporlar (script'ler
/// İçin: güncelse çıkış 0, YENİ bir sürüm VARSA çıkış 1).
fn cmdUpgrade(a: std.mem.Allocator, io: std.Io, args: []const []const u8, resource_dir_override: ?[]const u8, policy: upgrade_mod.UpgradePolicy, fetch_policy: fetch.FetchPolicy, nox_home: []const u8) !void {
    var check_only = false;
    var explicit_version: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (explicit_version == null) {
            explicit_version = arg;
        }
    }

    const target_tag = upgrade_mod.resolveTargetVersion(a, io, explicit_version, policy, fetch_policy) catch |err| {
        printErr("failed to resolve version ({t})\n", .{err});
        std.process.exit(1);
    };

    const up_to_date = upgrade_mod.isAlreadyUpToDate(a, target_tag) catch false;

    // `--check`: KURULUM/İNDİRME hiç TETİKLENMEZ, yalnızca `target_tag`
    // (açık sürüm VERİLDİYSE OYSA, aksi halde "latest release") mevcut
    // sürümle KARŞILAŞTIRILIP raporlanır. Bu, AŞAĞIDAKİ "explicit_version
    // VERİLMİŞSE zorla yeniden kur" DAVRANIŞINDAN AYRIDIR (bkz. o dalın
    // belge notu) — `--check` HİÇBİR ZAMAN kurulum YAPMADIĞINDAN, açık bir
    // sürüm PIN'i BİLE mevcutla EŞİTSE "zaten güncel" (çıkış 0) raporlamak
    // DOĞRU davranıştır.
    if (check_only) {
        const current = upgrade_mod.currentVersionTag(a) catch "?";
        if (up_to_date) {
            printOk("already up to date: {s}\n", .{current});
            std.process.exit(0);
        }
        std.debug.print("current version: {s}\nlatest version: {s}\n", .{ current, target_tag });
        std.process.exit(1);
    }

    // Açık bir sürüm VERİLMEDİYSE VE zaten güncelse, kurulum/indirmeye HİÇ
    // GEREK YOK. Açık bir sürüm VERİLDİYSE (`noxc upgrade v1.2.0`), bu AYNI
    // sürüme BİLE olsa BİLİNÇLİ bir yeniden-kurulum İSTEĞİ sayılır — devam
    // edilir (`rustup`/`brew`nin "reinstall" semantiğiyle TUTARLI).
    if (up_to_date and explicit_version == null) {
        const current = upgrade_mod.currentVersionTag(a) catch target_tag;
        printOk("already up to date: {s}\n", .{current});
        return;
    }

    const asset = upgrade_mod.currentPlatformAsset() orelse {
        printErr("no prebuilt release for this platform -- build from source: see https://noxlang.com/docs/internals/contributing/\n", .{});
        std.process.exit(1);
    };

    const install_root = try project.resolveInstallRoot(a, io, resource_dir_override);
    upgrade_mod.performUpgrade(a, io, target_tag, asset, install_root, policy, fetch_policy) catch |err| {
        printErr("upgrade failed ({t})\n", .{err});
        std.process.exit(1);
    };
    printOk("upgraded to: {s}\n", .{target_tag});
    // Eski paket-önbelleği SHA'larını süpür (en iyi çaba — hata sessizce yutulur).
    autoPruneCache(io, a, nox_home, null);
}

/// Faz Y.1: `noxc search <indeks-dosyasi.json> [sorgu]` — hafif, statik
/// paket dizinini (bkz. `pkg/index.zig`nin modül üstü notu) sorgular.
/// `sorgu` VERİLMEZSE TÜM katalog LİSTELENİR. Bu KOMUT, `fetch`/`update`in
/// AKSİNE (henüz REZERVE), TAM olarak ÇALIŞIR — herhangi bir AĞ erişimi
/// GEREKMEZ (yalnızca YEREL bir JSON dosyası okur, bkz. modül üstü not
/// "gelecekte eklenebilir" tasarım kararı).
///
/// **Bulundu, kullanıcı isteği (services/noxpkg/'in GERÇEK bir merkezi
/// dizin OLARAK canlıya alınmasından SONRA):** `noxc add`nin `repo`
/// atlandığında `registry_policy.index_url`e (varsayılan: `noxpkg.
/// 2mtechnology.org`) DÜŞMESİYLE AYNI desen `search`e de eklendi — TEK
/// bir pozisyonel argüman VERİLDİĞİNDE (`noxc search <isim>`) o argüman
/// artık `<indeks>` DEĞİL `<sorgu>` olarak yorumlanır, indeks HER ZAMAN
/// varsayılan merkezi kayda düşer. Açık indeksli İKİ argümanlı form
/// (`noxc search <indeks> <sorgu>`) DEĞİŞMEDEN kalır — TEK argümanlı
/// eski "bir dosyayı sorgusuz listele" kullanımı (bu komut BU oturumda
/// YENİ eklendiği İçin GERÇEK bir kullanıcıya henüz ULAŞMADI) `noxc
/// search <indeks> ""` İLE İFADE edilebilir.
fn cmdSearch(io: std.Io, a: std.mem.Allocator, args: []const []const u8, registry_policy: registry.RegistryPolicy, fetch_policy: fetch.FetchPolicy) !void {
    if (args.len == 0) {
        std.debug.print("usage: noxc search <query> | noxc search <index-file.json|https://...> <query>\n", .{});
        std.process.exit(1);
    }
    const index_arg, const query = if (args.len == 1) .{ registry_policy.index_url, args[0] } else .{ args[0], args[1] };

    // Bulundu (bkz. proje belleği "f-string + augmented atama" görevi):
    // `pkg_index.loadIndexFromUrl` (YENİ) — `index.zig`nin KENDİ belge
    // notunun ÖNGÖRDÜĞÜ uzantı. Bir URL mi yerel yol mu olduğu, düz bir
    // önek kontrolüyle ayırt edilir (`fetch.zig`nin `resolveCloneUrl`iyle
    // AYNI basit ayrım).
    const is_url = std.mem.startsWith(u8, index_arg, "http://") or std.mem.startsWith(u8, index_arg, "https://");
    const idx = if (is_url)
        pkg_index.loadIndexFromUrl(a, io, index_arg, fetch_policy) catch |e| {
            printErr("search: could not fetch/parse the index ({t}): {s}\n", .{ e, index_arg });
            std.process.exit(1);
        }
    else
        pkg_index.loadIndexFromFile(a, io, index_arg) catch |e| {
            printErr("search: could not read/parse the index ({t}): {s}\n", .{ e, index_arg });
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
            try w.writeAll("    tags: ");
            for (pkg.tags, 0..) |t, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(t);
            }
            try w.writeAll("\n");
        }
    }
    if (found == 0) try w.writeAll("no matching packages found\n");
    try w.flush();
}

/// `noxc add <alias> [repo] [--ref <ref>]` — `repo` VERİLMEDİYSE
/// `registry_policy.index_url`den (URL ya da yerel dosya yolu —
/// `cmdSearch`in AYNI `is_url` ayrımı) çözülür. Alias ZATEN `requires[]`de
/// VARSA üzerine yazar (upsert — İKİNCİ bir `add` çağrısı hata VERMEZ,
/// `repo`/`ref`i günceller), YOKSA ekler.
fn cmdAdd(io: std.Io, a: std.mem.Allocator, args: []const []const u8, registry_policy: registry.RegistryPolicy, fetch_policy: fetch.FetchPolicy) !void {
    var positionals: std.ArrayListUnmanaged([]const u8) = .empty;
    var ref: []const u8 = "main";
    var ref_explicit = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            i += 1;
            if (i >= args.len) {
                printErr("add: --ref expects a value\n", .{});
                std.process.exit(1);
            }
            ref = args[i];
            ref_explicit = true;
        } else {
            try positionals.append(a, args[i]);
        }
    }
    if (positionals.items.len == 0) {
        std.debug.print("usage: noxc add <alias> [repo] [--ref <ref>]\n", .{});
        std.process.exit(1);
    }
    const alias = positionals.items[0];

    const repo: []const u8 = if (positionals.items.len > 1) positionals.items[1] else blk: {
        const index_arg = registry_policy.index_url;
        const is_url = std.mem.startsWith(u8, index_arg, "http://") or std.mem.startsWith(u8, index_arg, "https://");
        const idx = if (is_url)
            pkg_index.loadIndexFromUrl(a, io, index_arg, fetch_policy) catch |e| {
                printErr("add: could not fetch/parse the index ({t}): {s}\n", .{ e, index_arg });
                std.process.exit(1);
            }
        else
            pkg_index.loadIndexFromFile(a, io, index_arg) catch |e| {
                printErr("add: could not read/parse the index ({t}): {s}\n", .{ e, index_arg });
                std.process.exit(1);
            };
        const entry = registry.findByAlias(idx, alias) orelse {
            printErr("add: '{s}' not found in the index ({s}) — give the repo explicitly: noxc add {s} <repo>\n", .{ alias, index_arg, alias });
            std.process.exit(1);
        };
        break :blk entry.repo;
    };

    // Bkz. `cmdInstall`nin AYNI düzeltmesi/belge notu — `--ref` AÇIKÇA
    // verilmediyse sabit "main" varsayımı YERİNE repo'nun GERÇEK varsayılan
    // dalı sorgulanır, başarısız olursa sessizce eski davranışa DÜŞÜLÜR.
    if (!ref_explicit) {
        ref = fetch.resolveDefaultRef(a, io, repo, fetch_policy) catch ref;
    }

    const root = try findProjectRootOrExit(io, a, "add");
    const manifest = loadManifestOrExit(a, io, root);

    var new_requires: std.ArrayListUnmanaged(project.Requirement) = .empty;
    try new_requires.appendSlice(a, manifest.requires);
    var existing_idx: ?usize = null;
    for (new_requires.items, 0..) |req, idx| {
        if (std.mem.eql(u8, req.alias, alias)) {
            existing_idx = idx;
            break;
        }
    }
    const new_req: project.Requirement = .{ .alias = alias, .repo = repo, .ref = ref };
    if (existing_idx) |idx| {
        new_requires.items[idx] = new_req;
    } else {
        try new_requires.append(a, new_req);
    }

    const new_manifest: project.Manifest = .{ .name = manifest.name, .entry = manifest.entry, .bin = manifest.bin, .requires = new_requires.items };
    project.validateManifest(new_manifest) catch |e| {
        printErr("add: invalid alias '{s}' ({t})\n", .{ alias, e });
        std.process.exit(1);
    };
    try project.saveManifest(a, io, root, new_manifest);

    if (existing_idx != null) {
        printOk("updated: {s} -> {s}@{s}\n", .{ alias, repo, ref });
    } else {
        printOk("added: {s} -> {s}@{s}\n", .{ alias, repo, ref });
    }
    std.debug.print("next step: run 'noxc fetch'\n", .{});
}

/// `noxc delete <alias>` — `requires[]`den çıkarır VE `nox.lock`taki
/// eşleşen (VARSA) girdiyi de budar (bayat, referanssız bir kilit
/// girdisi KALMASIN).
fn cmdDelete(io: std.Io, a: std.mem.Allocator, args: []const []const u8) !void {
    const alias = if (args.len > 0) args[0] else {
        std.debug.print("usage: noxc delete <alias>\n", .{});
        std.process.exit(1);
    };

    const root = try findProjectRootOrExit(io, a, "delete");
    const manifest = loadManifestOrExit(a, io, root);

    var new_requires: std.ArrayListUnmanaged(project.Requirement) = .empty;
    var found = false;
    for (manifest.requires) |req| {
        if (std.mem.eql(u8, req.alias, alias)) {
            found = true;
            continue;
        }
        try new_requires.append(a, req);
    }
    if (!found) {
        printErr("delete: '{s}' not found in requires[]\n", .{alias});
        std.process.exit(1);
    }

    const new_manifest: project.Manifest = .{ .name = manifest.name, .entry = manifest.entry, .bin = manifest.bin, .requires = new_requires.items };
    try project.saveManifest(a, io, root, new_manifest);

    const lock = project.loadLockfile(a, io, root) catch project.Lockfile{};
    var new_packages: std.ArrayListUnmanaged(project.LockedPackage) = .empty;
    var lock_changed = false;
    for (lock.packages) |pkg| {
        if (std.mem.eql(u8, pkg.alias, alias)) {
            lock_changed = true;
            hpy_host_mod.forgetStaged(a, io, root, pkg.hpy_module);
            continue;
        }
        try new_packages.append(a, pkg);
    }
    if (lock_changed) {
        try project.saveLockfile(a, io, root, .{ .packages = new_packages.items });
    }

    printOk("removed: {s}\n", .{alias});
}

/// `noxc publish <repo> [--ref <ref>] [--description <metin>] [--tags a,b,c]`
/// — YALNIZCA METADATA gönderir (kod/tarball YOK). `noxpkg` sunucusunun
/// gönderi-kutusuna EKLENİR; onay kullanıcının KENDİSİ tarafından admin
/// panelinden yapılır (bu komut onay-BEKLEMEZ/poll ETMEZ).
fn cmdPublish(io: std.Io, a: std.mem.Allocator, args: []const []const u8, registry_policy: registry.RegistryPolicy, fetch_policy: fetch.FetchPolicy) !void {
    var repo_opt: ?[]const u8 = null;
    var ref: []const u8 = "main";
    var description: []const u8 = "";
    var tags: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            i += 1;
            if (i < args.len) ref = args[i];
        } else if (std.mem.eql(u8, args[i], "--description")) {
            i += 1;
            if (i < args.len) description = args[i];
        } else if (std.mem.eql(u8, args[i], "--tags")) {
            i += 1;
            if (i < args.len) {
                var tag_list: std.ArrayListUnmanaged([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, args[i], ',');
                while (it.next()) |t| try tag_list.append(a, t);
                tags = tag_list.items;
            }
        } else if (repo_opt == null) {
            repo_opt = args[i];
        }
    }
    const repo = repo_opt orelse {
        std.debug.print("usage: noxc publish <repo> [--ref <ref>] [--description <text>] [--tags a,b,c]\n", .{});
        std.process.exit(1);
    };

    const root = try findProjectRootOrExit(io, a, "publish");
    const manifest = loadManifestOrExit(a, io, root);
    if (manifest.name.len == 0) {
        printErr("publish: 'name' in nox.json is empty, but it is required to publish\n", .{});
        std.process.exit(1);
    }

    const payload: registry.PublishPayload = .{ .name = manifest.name, .repo = repo, .ref = ref, .description = description, .tags = tags };
    const result = registry.submitPublish(a, io, registry_policy.publish_api_base, payload, fetch_policy.allow_insecure_transport) catch |e| {
        printErr("publish: could not submit ({t}): {s}\n", .{ e, registry_policy.publish_api_base });
        std.process.exit(1);
    };
    if (!result.ok) {
        printErr("publish: rejected: {s}\n", .{result.@"error"});
        std.process.exit(1);
    }
    printOk("submitted: {s} (id={s}) — awaiting approval\n", .{ manifest.name, result.id });
}

/// `noxc install <paket-adi|repo> [--ref <ref>]` — bkz. `pkg/install.zig`nin
/// modül üstü notu (GLOBAL paket kurulumu tasarımı). `noxc add`in AYNI
/// "bare isimse registry'den coz, aksi halde DOGRUDAN kullan" deseni —
/// TEK fark: `add`in iki AYRI pozisyonel argümanı (alias + opsiyonel repo)
/// yerine burada TEK argüman var, çünkü komut ADI `add`in aksine kullanıcı
/// tarafından SEÇİLMEZ — paketin KENDİ `nox.json`sindeki `bin.name`den
/// GELİR.
fn cmdInstall(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, registry_policy: registry.RegistryPolicy, fetch_policy: fetch.FetchPolicy, environ_map: *const std.process.Environ.Map) !void {
    var ref: []const u8 = "main";
    var ref_explicit = false;
    var pkg_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--ref")) {
            i += 1;
            if (i >= args.len) {
                printErr("install: --ref expects a value\n", .{});
                std.process.exit(1);
            }
            ref = args[i];
            ref_explicit = true;
        } else if (pkg_arg == null) {
            pkg_arg = args[i];
        }
    }
    const pkg = pkg_arg orelse {
        std.debug.print("usage: noxc install <package-name|repo[@ref]> [--ref <ref>]\n", .{});
        std.process.exit(1);
    };

    // `repo@ref` (`github.com/org/name@v1.2.3`). `--ref` verilmişse o kazanır
    // ve gömülü etiket yok sayılır; aksi halde varsayılan dal sorgusu atlanır.
    const embedded = fetch.splitEmbeddedRef(pkg);
    const pkg_repo = embedded.repo;
    if (!ref_explicit) {
        if (embedded.ref) |embedded_ref| {
            ref = embedded_ref;
            ref_explicit = true;
        }
    }

    // Bare bir kayit-defteri ismi mi (`/` ve `\` ICERMIYOR, surucu
    // harfi de yok — "nyx" gibi) yoksa dogrudan bir repo/yerel yol mu
    // (`add`in "iki pozisyonel argüman" yerine tek argümanın İÇERİĞİNE
    // bakan, daha basit bir ayrım — bkz. bu fonksiyonun belge notu).
    // Windows yerel yolu `D:\...` biçimindedir: `/` yoktur, `\` ya da
    // sürücü harfi vardır. Bunlar da kayıt defteri adı değildir.
    const looks_like_repo = std.mem.indexOfScalar(u8, pkg_repo, '/') != null or
        std.mem.indexOfScalar(u8, pkg_repo, '\\') != null or
        std.mem.startsWith(u8, pkg_repo, "git@") or
        (pkg_repo.len >= 3 and pkg_repo[1] == ':');
    const repo: []const u8 = if (looks_like_repo) pkg_repo else blk: {
        const index_arg = registry_policy.index_url;
        const is_url = std.mem.startsWith(u8, index_arg, "http://") or std.mem.startsWith(u8, index_arg, "https://");
        const idx = if (is_url)
            pkg_index.loadIndexFromUrl(a, io, index_arg, fetch_policy) catch |e| {
                printErr("install: could not fetch/parse the index ({t}): {s}\n", .{ e, index_arg });
                std.process.exit(1);
            }
        else
            pkg_index.loadIndexFromFile(a, io, index_arg) catch |e| {
                printErr("install: could not read/parse the index ({t}): {s}\n", .{ e, index_arg });
                std.process.exit(1);
            };
        const entry = registry.findByAlias(idx, pkg) orelse {
            printErr("install: '{s}' not found in the index ({s}) — give the repo explicitly: noxc install <repo>\n", .{ pkg, index_arg });
            std.process.exit(1);
        };
        break :blk entry.repo;
    };

    // `--ref` AÇIKÇA verilmediyse sabit "main" varsayımına GÜVENMEK YERİNE
    // (bkz. `fetch.resolveDefaultRef`nin belge notu — repo'nun varsayılan
    // dalı `master`/başka bir isim OLABİLİR) GERÇEK varsayılan dal
    // SORGULANIR; sorgu HERHANGİ bir nedenle başarısız OLURSA sessizce
    // eski "main" varsayımına DÜŞÜLÜR (asla eskiye göre DAHA KIRILGAN hale
    // GELMEZ).
    if (!ref_explicit) {
        ref = fetch.resolveDefaultRef(a, io, repo, fetch_policy) catch ref;
    }

    installOrUpdatePackage(gpa, io, a, nox_home, resource_dirs, fetch_policy, environ_map, repo, ref) catch std.process.exit(1);
}

/// v1.33.0 (bkz. nox-teknik-spesifikasyon.md §3.100): `cmdInstall`nin (repo/
/// ref ZATEN çözüldükten SONRAKİ) fetch+derle+yerleştir+kayıt gövdesi —
/// `cmdRefresh` (AŞAĞIDA) tarafından da PAYLAŞILIR, ÇÜNKÜ `noxc install
/// <paket>`i TEKRAR çalıştırmak ZATEN bir "güncelleme" (fetchToCache HER
/// ZAMAN gerçek bir `git clone` yapar, önbellek SADECE çözümlenen SHA
/// ZATEN yerelse devreye girer) — `refresh` sadece BUNU keşfedilebilir/
/// toplu hale getirir. HER başarısızlık noktası KENDİ `printErr` mesajını
/// YAZAR VE hatayı ÇAĞIRANA `return` eder (`std.process.exit` ÇAĞIRMAZ)
/// — TEK-paket çağıranlar (`cmdInstall`, `cmdRefresh`nin tekli modu) bunu
/// KENDİLERİ `exit(1)`e çevirir, `cmdRefresh`nin TOPLU modu İSE yakalayıp
/// SONRAKİ pakete DEVAM eder (bkz. onun belge notu).
fn installOrUpdatePackage(
    gpa: std.mem.Allocator,
    io: std.Io,
    a: std.mem.Allocator,
    nox_home: []const u8,
    resource_dirs: project.ResourceDirs,
    fetch_policy: fetch.FetchPolicy,
    environ_map: *const std.process.Environ.Map,
    repo: []const u8,
    ref: []const u8,
) !void {
    var sig_diag: ?[]const u8 = null;
    const fetch_result = fetch.fetchToCache(a, io, nox_home, repo, ref, false, &sig_diag, fetch_policy) catch |e| {
        printErr("install: could not fetch ({t}): {s}@{s}\n", .{ e, repo, ref });
        return e;
    };

    const pkg_manifest = project.loadManifest(a, io, fetch_result.cache_dir) catch |e| {
        printErr("install: the package's nox.json could not be read or is invalid ({s}): {t}\n", .{ fetch_result.cache_dir, e });
        return e;
    };
    const bin_spec = pkg_manifest.bin orelse {
        printErr("install: '{s}' does not define a 'bin' entry point for global installation\n", .{repo});
        return error.NoBinEntryPoint;
    };
    const bin_source_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ fetch_result.cache_dir, bin_spec.path });

    // Derleme SCRATCH bir dizine yapılır — `noxc upgrade`nin "HERHANGİ bir
    // aşama BAŞARISIZ olursa GERÇEK kuruluma HİÇ dokunulmaz" ilkesiyle
    // TUTARLI (buradaki "gerçek kurulum", ZATEN VAR olan BAŞKA bir global
    // ikilidir — yarım kalmış bir derleme ONU asla ETKİLEMEZ).
    var suffix_bytes: [8]u8 = undefined;
    io.random(&suffix_bytes);
    const suffix = std.mem.readInt(u64, &suffix_bytes, .little);
    const scratch_dir_path = try std.fmt.allocPrint(a, "{s}/pkg/tmp/install-scratch-{x}", .{ nox_home, suffix });
    try std.Io.Dir.cwd().createDirPath(io, scratch_dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, scratch_dir_path) catch {};
    const scratch_bin_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ scratch_dir_path, bin_spec.name });

    const compiled_path = try buildOne(gpa, io, a, bin_source_path, false, scratch_bin_path, nox_home, resource_dirs, false, .auto, .hosted, fetch_policy, null, false, .exe);

    const bin_dir_path = try project.resolveGlobalBinDir(a, nox_home);
    try std.Io.Dir.cwd().createDirPath(io, bin_dir_path);
    var bin_dir = try std.Io.Dir.openDirAbsolute(io, bin_dir_path, .{});
    defer bin_dir.close(io);

    const dest_name = try install_mod.exeFileName(a, bin_spec.name);
    try install_mod.placeBinary(a, io, compiled_path, bin_dir, dest_name);

    const registry_state = project.loadInstalledRegistry(a, io, nox_home) catch project.InstalledRegistry{};
    // v1.33.0: `refresh`in "kuruldu"/"guncellendi" ayrımı İçİn — kayıt
    // BU upsert'TEN ÖNCE zaten `command_name`i İÇERİYORSA bu bir
    // güncellemedir, DEĞİLSE İLK kurulumdur.
    const was_already_installed = project.findInstalled(registry_state, bin_spec.name) != null;
    const installed_at = try install_mod.nowAsEpochSecondsString(a, io);
    const new_packages = try project.upsertInstalled(a, registry_state, .{
        .command_name = bin_spec.name,
        .repo = repo,
        .ref = ref,
        .resolved_sha = fetch_result.resolved_sha,
        .bin_path = bin_spec.path,
        .installed_at = installed_at,
    });
    try project.saveInstalledRegistry(a, io, nox_home, .{ .packages = new_packages });

    const short_sha = fetch_result.resolved_sha[0..@min(8, fetch_result.resolved_sha.len)];
    if (was_already_installed) {
        printOk("updated: {s} ({s}@{s})\n", .{ bin_spec.name, repo, short_sha });
    } else {
        printOk("installed: {s} ({s}@{s})\n", .{ bin_spec.name, repo, short_sha });
    }

    // Bu repo'nun eski (artık kurulu olmayan) SHA dizinlerini sil.
    autoPruneCache(io, a, nox_home, repo);

    const path_env = environ_map.get("PATH") orelse "";
    if (!install_mod.isDirOnPath(path_env, bin_dir_path)) {
        install_mod.printPathHint(bin_dir_path);
    }
}

/// v1.33.0 (bkz. nox-teknik-spesifikasyon.md §3.100): `noxc install
/// <paket>`i TEKRAR çalıştırmanın ZATEN yaptığı (yeniden fetch+derle+
/// yerleştir, bkz. `installOrUpdatePackage`nin belge notu) işlemi
/// keşfedilebilir/toplu hale getiren AYRI bir fiil — `update`/`upgrade`
/// isimleri ZATEN BAŞKA, İLİŞKİSİZ özellikler tarafından kullanıldığından
/// (`cmdUpdate`: proje-seviyesi `nox.lock` güncellemesi; `cmdUpgrade`:
/// `noxc`nin KENDİ ikilisi) KULLANILAMADI — bkz. plan dosyası "Context".
/// Paket adı VERİLİRSE SADECE onu, VERİLMEZSE `installed.json`daki TÜM
/// paketleri günceller — toplu modda TEK bir paketin başarısızlığı
/// DİĞERLERİNİ ENGELLEMEZ (pip/cargo/apt'nin "toplu güncelleme"
/// konvansiyonuyla TUTARLI), sadece SONUNDA (en az bir başarısızlık
/// VARSA) `exit(1)` yapılır.
fn cmdRefresh(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy, environ_map: *const std.process.Environ.Map) !void {
    const registry_state = project.loadInstalledRegistry(a, io, nox_home) catch |e| {
        printErr("refresh: could not read the installed-package record: {t}\n", .{e});
        std.process.exit(1);
    };

    if (args.len > 0) {
        const command_name = args[0];
        const entry = project.findInstalled(registry_state, command_name) orelse {
            printErr("refresh: '{s}' is not installed globally\n", .{command_name});
            std.process.exit(1);
        };
        installOrUpdatePackage(gpa, io, a, nox_home, resource_dirs, fetch_policy, environ_map, entry.repo, entry.ref) catch std.process.exit(1);
        return;
    }

    if (registry_state.packages.len == 0) {
        std.debug.print("refresh: no package is installed globally\n", .{});
        return;
    }
    var fail_count: usize = 0;
    for (registry_state.packages) |entry| {
        installOrUpdatePackage(gpa, io, a, nox_home, resource_dirs, fetch_policy, environ_map, entry.repo, entry.ref) catch {
            fail_count += 1;
        };
    }
    if (fail_count > 0) std.process.exit(1);
}

/// `installed.json`daki kayıtları `cache_prune.KeepEntry` listesine çevirir.
fn installedKeepEntries(io: std.Io, a: std.mem.Allocator, nox_home: []const u8) ![]const cache_prune.KeepEntry {
    const registry_state = try project.loadInstalledRegistry(a, io, nox_home);
    const keep = try a.alloc(cache_prune.KeepEntry, registry_state.packages.len);
    for (registry_state.packages, 0..) |pkg, i| keep[i] = .{ .repo = pkg.repo, .resolved_sha = pkg.resolved_sha };
    return keep;
}

/// `install`/`refresh`/`upgrade` sonrası en-iyi-çaba önbellek temizliği:
/// `only_repo` doluysa YALNIZCA o repo'nun eski SHA'ları (en-yeni-koruma
/// KAPALI — yeni kurulan SHA zaten `installed.json`da), `null` ise tüm
/// önbellek (en-yeni-koruma AÇIK — projelerin güncel `nox.lock` sürümleri
/// yeniden indirilmesin). Her hata sessizce yutulur: temizlik asla
/// asıl komutu başarısız KILMAZ.
fn autoPruneCache(io: std.Io, a: std.mem.Allocator, nox_home: []const u8, only_repo: ?[]const u8) void {
    const keep = installedKeepEntries(io, a, nox_home) catch return;
    const report = cache_prune.prune(a, io, nox_home, keep, .{
        .only_repo = only_repo,
        .keep_newest_per_repo = only_repo == null,
    }) catch return;
    const n = report.removed_paths.len + report.removed_tmp_entries;
    if (n == 0) return;
    const size = cache_prune.formatBytes(a, report.freed_bytes) catch return;
    printOk("pruned old cache entries: {d}, {s}\n", .{ n, size });
}

/// `noxc cache prune [--dry-run] [--all]` — paket önbelleğindeki (`pkg/mod`)
/// artık SHA dizinlerini siler (bkz. `pkg/cache_prune.zig`nin modül üstü
/// notu). Varsayılan: `installed.json`daki SHA'lar + her repo'nun en yeni
/// girdisi korunur; `--all` yalnızca kurulu SHA'ları korur; `--dry-run`
/// hiçbir şey silmeden ne silineceğini ve ne kadar yer açılacağını yazar.
fn cmdCache(io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8) !void {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "prune")) {
        std.debug.print("usage: noxc cache prune [--dry-run] [--all]\n", .{});
        std.process.exit(1);
    }
    var opts: cache_prune.PruneOptions = .{};
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            opts.keep_newest_per_repo = false;
        } else {
            printErr("cache prune: unknown option: {s}\n", .{arg});
            std.process.exit(1);
        }
    }
    const keep = installedKeepEntries(io, a, nox_home) catch |e| {
        printErr("cache prune: could not read the installed-package record: {t}\n", .{e});
        std.process.exit(1);
    };
    const report = cache_prune.prune(a, io, nox_home, keep, opts) catch |e| {
        printErr("cache prune: failed: {t}\n", .{e});
        std.process.exit(1);
    };
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    for (report.removed_paths) |p| try w.print("{s}{s}\n", .{ if (opts.dry_run) "would remove: " else "removed: ", p });
    const size = try cache_prune.formatBytes(a, report.freed_bytes);
    try w.print("{s}: {d} cache entries + {d} temporary leftovers, {s}; kept: {d}\n", .{
        if (opts.dry_run) "dry-run" else "pruned",
        report.removed_paths.len,
        report.removed_tmp_entries,
        size,
        report.kept_entries,
    });
    try w.flush();
}

/// `noxc uninstall <komut-adi>` — `{nox_home}/bin/{komut-adi}[.exe]`i
/// SİLER VE `installed.json`dan ÇIKARIR. Paylaşılan (içerik-adresli)
/// paket önbelleğine (`pkg/mod/...`) DOKUNMAZ — bkz. `project.
/// removeInstalled`in belge notu.
fn cmdUninstall(io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8) !void {
    const command_name = if (args.len > 0) args[0] else {
        std.debug.print("usage: noxc uninstall <command-name>\n", .{});
        std.process.exit(1);
    };

    const registry_state = project.loadInstalledRegistry(a, io, nox_home) catch |e| {
        printErr("uninstall: could not read the installed-package record: {t}\n", .{e});
        std.process.exit(1);
    };
    const new_packages = try project.removeInstalled(a, registry_state, command_name) orelse {
        printErr("uninstall: '{s}' is not installed globally\n", .{command_name});
        std.process.exit(1);
    };

    const bin_dir_path = try project.resolveGlobalBinDir(a, nox_home);
    const dest_name = try install_mod.exeFileName(a, command_name);
    const bin_file_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ bin_dir_path, dest_name });
    std.Io.Dir.cwd().deleteFile(io, bin_file_path) catch {};

    try project.saveInstalledRegistry(a, io, nox_home, .{ .packages = new_packages });
    printOk("uninstalled: {s}\n", .{command_name});
}

/// `noxc list` — global kurulu paketlerin insan-okunur bir tablosunu
/// yazdırır (bkz. `project.InstalledRegistry`).
fn cmdListInstalled(io: std.Io, a: std.mem.Allocator, nox_home: []const u8) !void {
    const registry_state = project.loadInstalledRegistry(a, io, nox_home) catch |e| {
        printErr("list: could not read the installed-package record: {t}\n", .{e});
        std.process.exit(1);
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    if (registry_state.packages.len == 0) {
        try w.writeAll("no package is installed globally (see 'noxc install --help')\n");
        try w.flush();
        return;
    }
    for (registry_state.packages) |pkg| {
        try w.print("{s}\t{s}@{s} ({s})\n", .{ pkg.command_name, pkg.repo, pkg.ref, pkg.resolved_sha[0..@min(8, pkg.resolved_sha.len)] });
    }
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
    /// v1.143.0: backend seçimi. `.auto` (varsayılan) `resolveRelease`e bırakılır: hosted +
    /// macOS/Linux + `clang` varsa LLVM (`.ll`/`clang -O2`), aksi halde QBE (freestanding,
    /// `--target`, `--emit-asm`, Windows, clang yok). `--backend qbe|llvm` ve (eski ad) `--release`
    /// seçimi açıkça sabitler.
    backend: BackendChoice = .auto,
    /// Faz F.2 (bkz. plan dosyası "capability sistemi"): `--profile
    /// <hosted|freestanding>` — `checker_state.profile`e AKTARILIR
    /// (bkz. `buildOne`). VARSAYILAN `.hosted` — mevcut TÜM davranış
    /// DEĞİŞMEDEN kalır.
    profile: codegen.Profile = .hosted,
    /// v2.0 madde 8 (bkz. nox-teknik-spesifikasyon.md §3.196): `--target
    /// <isim>` — `profile == .freestanding` İKEN `qbe_target.nameForArch`in
    /// (x86_64/aarch64/riscv64) çıplak mimari adlarından biri; `profile ==
    /// .hosted` İKEN `qbe_target.hostedTargetInfo`nin (macos-arm64/linux-
    /// x64/linux-arm64/windows-x64) platform isimlerinden biri. VARSAYILAN
    /// `null` — SIFIR davranış değişikliği (HOST'un KENDİ mimarisi/OS'u).
    target: ?[]const u8 = null,
    /// v2.0 madde 8: `--emit-asm` — `qbe -t ...` çalıştırıldıktan HEMEN
    /// SONRA linkleme TAMAMEN ATLANIR, ham `.s` yolu döner. Eski, dâhilî
    /// `NOX_FREESTANDING_KERNEL_ARCH`in "hangi mimari" + "linklemeyi atla"
    /// İKİ SORUMLULUĞUNUN İKİNCİSİ — ARTIK profile/target-nötr, AÇIKÇA
    /// adlandırılmış BAĞIMSIZ bir bayrak.
    emit_asm: bool = false,
    /// Mobil kütüphane biçimi. `.exe` masaüstü yoludur.
    emit: EmitKind = .exe,
};

const EmitKind = enum { exe, obj, static_lib, shared_lib };

const BackendChoice = enum { auto, qbe, llvm };

/// v2.0 madde 2: LLVM yolunun C sürücüsü. Sıra: PATH'te `clang` -> PATH'te `zig` (`zig cc`, Zig'in kendi
/// clang'ı + LLD'si; `.ll` girdisini de derler) -> yok (QBE'ye düşülür). `zig cc` Windows'ta da çalışır; bu yüzden
/// Windows LLVM yolunun tercih edilen sürücüsüdür (MinGW hedefi `-target x86_64-windows-gnu` ile seçilir).
const CcDriver = enum { clang, zig_cc, none };

var g_cc_driver: ?CcDriver = null;

fn probeOk(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn ccDriver(gpa: std.mem.Allocator, io: std.Io) CcDriver {
    if (g_cc_driver) |v| return v;
    const found: CcDriver = if (builtin.os.tag == .windows) blk: {
        // Windows: Zig'in MinGW hedefi bilinen-iyi yoldur; `clang` (genelde MSVC hedefli) yalnızca yedek.
        if (probeOk(gpa, io, &.{ "zig", "version" })) break :blk .zig_cc;
        if (probeOk(gpa, io, &.{ "clang", "--version" })) break :blk .clang;
        break :blk .none;
    } else blk: {
        if (probeOk(gpa, io, &.{ "clang", "--version" })) break :blk .clang;
        if (probeOk(gpa, io, &.{ "zig", "version" })) break :blk .zig_cc;
        break :blk .none;
    };
    g_cc_driver = found;
    return found;
}

fn clangAvailable(gpa: std.mem.Allocator, io: std.Io) bool {
    return ccDriver(gpa, io) != .none;
}

/// v1.143.0: `BackendChoice.auto`yu somut bir backend'e (`true` = LLVM) çözer. LLVM varsayılandır
/// (QBE'ye göre ~1.0-1.5x daha hızlı kod, derleme süresi aynı); QBE'ye düşülen durumlar: freestanding
/// profili (LLVM'in OS iş parçacığı havuzu yok), `--target`/`--emit-asm` (yalnızca QBE yolu hedef/asm
/// çıktısını destekler), Windows ana makinesi (yalnızca `zig` varsa LLVM; aksi halde QBE) ve `clang`/`zig`in
/// PATH'te bulunmaması (bu son durumda tek satırlık bir not basılır — checker'ın `spawn` tip kuralları
/// backend'e göre farklıdır, sessiz düşüş şaşırtıcı olurdu).
fn resolveRelease(gpa: std.mem.Allocator, io: std.Io, choice: BackendChoice, profile: codegen.Profile, target: ?[]const u8, emit_asm: bool, debug_info: bool) bool {
    if (target) |t| {
        if (qbe_target.hostedTargetInfo(t)) |info| {
            if (info.isMobile()) {
                if (choice == .qbe) {
                    printErr("--backend qbe does not support mobile target '{s}' (this ABI is LLVM-only until the same fixtures pass on QBE)\n", .{t});
                    std.process.exit(1);
                }
                if (emit_asm or debug_info) {
                    printErr("mobile target '{s}' uses the LLVM backend; --emit-asm and -g are not supported\n", .{t});
                    std.process.exit(1);
                }
                if (!clangAvailable(gpa, io)) {
                    printErr("mobile target '{s}' needs clang or zig on PATH\n", .{t});
                    std.process.exit(1);
                }
                return true;
            }
        }
    }
    switch (choice) {
        .qbe => return false,
        .llvm => {
            // v2.0: `-g` (DWARF satır tablosu) yalnızca QBE yolunda üretilir; LLVM'de açıkça istenirse net bir hata ver.
            if (debug_info) {
                printErr("-g (debug info) is only supported by the QBE backend: use --backend qbe -g\n", .{});
                std.process.exit(1);
            }
            return true;
        },
        .auto => {},
    }
    // v2.0: `-g` ile varsayilan backend QBE'ye duser (DWARF yalnizca orada uretilir).
    if (debug_info) return false;
    if (profile == .freestanding) return false;
    if (target != null or emit_asm) return false;
    // v2.0 madde 1: Windows'ta LLVM yolu YALNIZCA `zig cc` (MinGW hedefi, CI'da doğrulandı) varken otomatik seçilir;
    // yalnızca `clang` (genelde MSVC hedefli) olan makinede QBE + MinGW `cc` yolu korunur. `--backend llvm` her zaman zorlar.
    if (builtin.os.tag == .windows) return ccDriver(gpa, io) == .zig_cc;
    if (!clangAvailable(gpa, io)) {
        printErr("note: neither clang nor zig found, using the QBE backend (the default LLVM backend needs clang or zig on PATH; pass --backend qbe to silence this)\n", .{});
        return false;
    }
    return true;
}

fn parseBuildOpts(args: []const []const u8) BuildOpts {
    var opts: BuildOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dump") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "-g")) {
            opts.debug_info = true;
        } else if (std.mem.eql(u8, arg, "--release")) {
            opts.backend = .llvm;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "qbe")) {
                    opts.backend = .qbe;
                } else if (std.mem.eql(u8, args[i], "llvm")) {
                    opts.backend = .llvm;
                } else {
                    printErr("unknown backend: '{s}' (valid values: qbe, llvm)\n", .{args[i]});
                    std.process.exit(1);
                }
            }
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) opts.output = args[i];
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i < args.len) {
                if (std.mem.eql(u8, args[i], "hosted")) {
                    opts.profile = .hosted;
                } else if (std.mem.eql(u8, args[i], "freestanding")) {
                    opts.profile = .freestanding;
                } else {
                    printErr("unknown profile: '{s}' (valid values: hosted, freestanding)\n", .{args[i]});
                    std.process.exit(1);
                }
            }
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i < args.len) opts.target = args[i];
        } else if (std.mem.eql(u8, arg, "--emit-asm")) {
            opts.emit_asm = true;
        } else if (std.mem.eql(u8, arg, "--emit-obj")) {
            setEmit(&opts, .obj);
        } else if (std.mem.eql(u8, arg, "--emit-static-lib")) {
            setEmit(&opts, .static_lib);
        } else if (std.mem.eql(u8, arg, "--emit-shared-lib")) {
            setEmit(&opts, .shared_lib);
        } else if (opts.path == null) {
            opts.path = arg;
        }
    }
    return opts;
}

fn setEmit(opts: *BuildOpts, kind: EmitKind) void {
    if (opts.emit != .exe) {
        printErr("only one of --emit-obj, --emit-static-lib, --emit-shared-lib may be set\n", .{});
        std.process.exit(1);
    }
    opts.emit = kind;
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
    const out = try buildOne(gpa, io, a, path_arg, opts.verbose, opts.output, nox_home, resource_dirs, opts.debug_info, opts.backend, opts.profile, fetch_policy, opts.target, opts.emit_asm, opts.emit);
    printOk("built: {s}\n", .{out});
}

/// v2.0 madde 8: `opts.target` HOST'un KENDİ mimarisine/platformuna karşılık
/// GELİYOR MU — `cmdRun`nin çapraz-derlenmiş bir ikiliyi ÇALIŞTIRMA
/// GİRİŞİMİNİ AÇIK bir hatayla reddetmesi İçİn.
fn isRunnableOnHost(profile: codegen.Profile, target: []const u8) bool {
    if (profile == .freestanding) return std.mem.eql(u8, target, @tagName(builtin.cpu.arch));
    const host_name: []const u8 = switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            else => "macos-x64",
        },
        .windows => "windows-x64",
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "linux-arm64",
            else => "linux-x64",
        },
        else => "",
    };
    return std.mem.eql(u8, target, host_name);
}

/// `noxc run`: `buildOne`ı `$NOX_HOME/cache/run/` altına, kaynak yolu ve
/// içerik özetiyle derler. Özet tutuyorsa yeniden derlemez. Çalıştırılabilir
/// dosyayı stdio'yu
/// MİRAS ALARAK çalıştırır, çocuğun çıkış kodunu AYNEN yansıtır.
fn cmdRun(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const split = splitOnDoubleDash(args);
    // `--sandbox` ailesi (ADR-010): bayraklar derleme seçeneklerinden AYRILIR, yalnızca ikilinin çalıştırılmasına uygulanır.
    var sandboxed = false;
    var policy: sandbox.Policy = .{};
    var kept: std.ArrayListUnmanaged([]const u8) = .empty;
    var writes: std.ArrayListUnmanaged([]const u8) = .empty;
    var reads: std.ArrayListUnmanaged([]const u8) = .empty;
    for (split.before) |arg| {
        if (std.mem.eql(u8, arg, "--sandbox")) {
            sandboxed = true;
        } else if (std.mem.eql(u8, arg, "--allow-net")) {
            policy.allow_net = true;
        } else if (std.mem.startsWith(u8, arg, "--allow-write=")) {
            try writes.append(a, arg["--allow-write=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--allow-read=")) {
            try reads.append(a, arg["--allow-read=".len..]);
        } else {
            try kept.append(a, arg);
        }
    }
    if (!sandboxed and (policy.allow_net or writes.items.len > 0 or reads.items.len > 0)) {
        printErr("noxc run: --allow-net/--allow-write/--allow-read only apply together with --sandbox\n", .{});
        std.process.exit(1);
    }
    policy.allow_write = writes.items;
    policy.allow_read = reads.items;
    const opts = parseBuildOpts(kept.items);
    const path_arg = opts.path orelse {
        std.debug.print("usage: noxc run [--dump|-v] <file.nox> [-- argv...]\n", .{});
        std.process.exit(1);
    };
    // v2.0 madde 8: `--emit-asm` linklenmemiş BİR `.s` dosyası döner,
    // `runAndWait` BUNU ÇALIŞTIRAMAZ; çapraz-derlenmiş bir `--target`
    // (HOST'tan FARKLI) İSE üretilen ikili BU makinede ÇALIŞTIRILAMAZ —
    // eski `NOX_FREESTANDING_KERNEL_ARCH`in `cmdRun` reddiyle AYNI ruh,
    // ARTIK genel.
    if (opts.emit_asm or opts.emit != .exe) {
        printErr("noxc run: cannot run with --emit-asm or a library emit (use 'noxc build')\n", .{});
        std.process.exit(1);
    }
    if (opts.target) |t| {
        if (!isRunnableOnHost(opts.profile, t)) {
            printErr("noxc run: --target {s} cannot run on this machine (it is a cross-compiled binary) - use 'noxc build'\n", .{t});
            std.process.exit(1);
        }
    }

    const tool_stamp = try toolchainStamp(io, a, resource_dirs);
    const slot = try prepareRunCache(io, a, nox_home, path_arg, opts, null, tool_stamp);
    const bin_path = if (slot.hit) slot.bin_path else blk: {
        const built = try buildOne(gpa, io, a, path_arg, opts.verbose, slot.bin_path, nox_home, resource_dirs, opts.debug_info, opts.backend, opts.profile, fetch_policy, opts.target, opts.emit_asm, opts.emit);
        try commitRunCache(io, a, slot);
        break :blk built;
    };

    if (sandboxed) {
        const code = try runSandboxed(io, a, bin_path, split.after, policy);
        std.process.exit(code);
    }
    const code = try runAndWait(io, a, bin_path, split.after);
    std.process.exit(code);
}

/// `bin_path`i işletim sistemi sandbox'ı içinde çalıştırır (bkz. `sandbox.zig`, ADR-010). Araç yoksa ya da platform desteklenmiyorsa
/// çalıştırmaz, açık bir hata verir: "sandbox istendi ama uygulanamadı" durumunda kısıtsız çalıştırmak güvenli DEĞİLDİR.
fn runSandboxed(io: std.Io, a: std.mem.Allocator, bin_path: []const u8, argv_tail: []const []const u8, policy: sandbox.Policy) !u8 {
    const cwd = try std.process.currentPathAlloc(io, a);
    const tmp_raw = std.c.getenv("TMPDIR");
    const tmp_env: []const u8 = if (tmp_raw) |t| std.mem.span(t) else "/tmp";
    var tmp_buf: [std.posix.PATH_MAX]u8 = undefined;
    var tmp_path: []const u8 = std.mem.trimEnd(u8, tmp_env, "/");
    if (tmp_path.len == 0) tmp_path = "/tmp";
    // `/tmp` ve `$TMPDIR` macOS'ta sembolik bağlardır; profil kanonik yolu ister. (Windows'ta sandbox yok: `buildArgv` zaten `Unsupported` döner.)
    if (comptime builtin.os.tag != .windows) {
        var z: [std.posix.PATH_MAX:0]u8 = undefined;
        if (tmp_path.len < z.len) {
            @memcpy(z[0..tmp_path.len], tmp_path);
            z[tmp_path.len] = 0;
            if (std.c.realpath(&z, &tmp_buf)) |p| tmp_path = std.mem.span(p);
        }
    }
    const argv = sandbox.buildArgv(a, builtin.os.tag, bin_path, argv_tail, cwd, tmp_path, policy) catch |e| switch (e) {
        error.Unsupported => {
            printErr("noxc run --sandbox: not supported on this operating system (macOS and Linux with bubblewrap only)\n", .{});
            std.process.exit(1);
        },
        error.InvalidPath => {
            printErr("noxc run --sandbox: --allow-read/--allow-write paths must be absolute and contain no quotes, parentheses or backslashes\n", .{});
            std.process.exit(1);
        },
        else => return e,
    };
    var child = std.process.spawn(io, .{ .argv = argv }) catch {
        printErr("noxc run --sandbox: could not start '{s}' (install it: macOS has sandbox-exec built in, Linux needs bubblewrap)\n", .{argv[0]});
        std.process.exit(1);
    };
    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
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

/// `noxc test [isim|yol ...]`. Argüman yoksa CWD altındaki her `*_test.nox`.
/// Dizin verilirse o ağaç. `.nox` dosyası TEK başına verilirse çıkış kodu
/// programın kodudur. Başka bir kelime dosya adında aranır (`smtp` →
/// `v18_smtp_test.nox`). Derleme hatası turu kesmez; dosya FAILED sayılır
/// ve kalan dosyalar çalışır.
fn cmdTest(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const opts = parseBuildOpts(args);
    const selectors = try testSelectors(a, args);
    const cwd_abs = try std.process.currentPathAlloc(io, a);

    if (selectors.len == 1 and std.mem.endsWith(u8, selectors[0], ".nox")) {
        const tool_stamp = try toolchainStamp(io, a, resource_dirs);
        const slot = try prepareRunCache(io, a, nox_home, selectors[0], opts, null, tool_stamp);
        const bin_path = if (slot.hit) slot.bin_path else blk: {
            const built = try buildOne(gpa, io, a, selectors[0], opts.verbose, slot.bin_path, nox_home, resource_dirs, opts.debug_info, opts.backend, opts.profile, fetch_policy, opts.target, opts.emit_asm, opts.emit);
            try commitRunCache(io, a, slot);
            break :blk built;
        };
        const code = try runAndWait(io, a, bin_path, &.{});
        std.process.exit(code);
    }

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var name_filters: std.ArrayListUnmanaged([]const u8) = .empty;
    var walked = false;
    for (selectors) |sel| {
        const abs = if (std.fs.path.isAbsolute(sel)) try a.dupe(u8, sel) else try std.fs.path.resolve(a, &.{ cwd_abs, sel });
        if (pathIsDir(io, abs)) {
            const found = try test_runner.discoverTestFiles(a, io, abs);
            try files.appendSlice(a, found);
            walked = true;
        } else if (std.mem.endsWith(u8, sel, ".nox")) {
            try files.append(a, abs);
        } else {
            try name_filters.append(a, sel);
        }
    }
    if (selectors.len == 0 or (name_filters.items.len > 0 and !walked and files.items.len == 0)) {
        const found = try test_runner.discoverTestFiles(a, io, cwd_abs);
        try files.appendSlice(a, found);
    }
    if (name_filters.items.len > 0) {
        var matched: std.ArrayListUnmanaged([]const u8) = .empty;
        for (files.items) |file| {
            for (name_filters.items) |query| {
                if (run_cache.matchesTestName(file, query)) {
                    try matched.append(a, file);
                    break;
                }
            }
        }
        files = matched;
    }

    if (files.items.len == 0) {
        if (name_filters.items.len == 0) {
            std.debug.print("found 0 test files (looking for *_test.nox under {s})\n", .{cwd_abs});
            return;
        }
        printErr("no test files matched\n", .{});
        std.process.exit(1);
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);

    var pass_count: usize = 0;
    var fail_count: usize = 0;
    var stamps: std.StringHashMapUnmanaged([]const u8) = .empty;
    const tool_stamp = toolchainStamp(io, a, resource_dirs) catch "-";
    for (files.items) |file| {
        var file_arena = std.heap.ArenaAllocator.init(gpa);
        defer file_arena.deinit();
        const fa = file_arena.allocator();

        const stamp = sourceStamp(io, a, &stamps, file) catch null;
        const slot = prepareRunCache(io, fa, nox_home, file, opts, stamp, tool_stamp) catch {
            printErr("FAILED: {s}\n", .{file});
            fail_count += 1;
            continue;
        };
        const bin_path = if (slot.hit) slot.bin_path else buildOne(gpa, io, fa, file, opts.verbose, slot.bin_path, nox_home, resource_dirs, opts.debug_info, opts.backend, opts.profile, fetch_policy, opts.target, opts.emit_asm, opts.emit) catch {
            printErr("FAILED: {s}\n", .{file});
            fail_count += 1;
            continue;
        };
        if (!slot.hit) commitRunCache(io, fa, slot) catch {};
        const code = runAndWait(io, fa, bin_path, &.{}) catch 1;
        if (code == 0) {
            printOk("PASSED: {s}\n", .{file});
            pass_count += 1;
        } else {
            printErr("FAILED: {s}\n", .{file});
            fail_count += 1;
        }
    }

    if (fail_count > 0) {
        printErr("\n{d} passed, {d} failed ({d} total)\n", .{ pass_count, fail_count, files.items.len });
        std.process.exit(1);
    }
    printOk("\n{d} passed, {d} failed ({d} total)\n", .{ pass_count, fail_count, files.items.len });
}

fn testSelectors(a: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--backend") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "--target")) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) continue;
        try out.append(a, arg);
    }
    return out.items;
}

fn pathIsDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
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
        std.debug.print("usage: noxc fmt <file.nox>\n", .{});
        std.process.exit(1);
    }
    const path_arg = args[0];
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024));
    defer gpa.free(source);

    const result = lexer.tokenizeWithTrivia(a, source) catch |e| {
        printErr("fmt: lexer error ({t})\n", .{e});
        std.process.exit(1);
    };
    const module = parser.parseModule(a, result.tokens) catch |e| {
        printErr("fmt: parse error ({t})\n", .{e});
        std.process.exit(1);
    };
    const formatted = try formatter.formatModule(a, module, result.trivia);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path_arg, .data = formatted });
}

const RunSlot = struct {
    bin_path: []const u8,
    hit: bool,
    index_path: []const u8,
    content_hex: []const u8,
    stale_dir: ?[]const u8,
};

/// İkili `$NOX_HOME/cache/run/obj/<özet>/bin` altına yazılır. Özet; sürüm,
/// backend, profil, hedef, `-g`, kaynak yolu, proje içeriği ve
/// `tool_stamp` (noxc ikilisi, `noxrt.o`, stdlib) dir. Kaynak değişince
/// önceki özet dizini `commitRunCache` ile silinir.
fn prepareRunCache(io: std.Io, a: std.mem.Allocator, nox_home: []const u8, path_arg: []const u8, opts: BuildOpts, source_stamp: ?[]const u8, tool_stamp: []const u8) !RunSlot {
    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const abs_path = if (std.fs.path.isAbsolute(path_arg)) try a.dupe(u8, path_arg) else try std.fs.path.resolve(a, &.{ cwd_abs, path_arg });
    const path_dir = std.fs.path.dirname(abs_path) orelse abs_path;
    const project_root = try project.findProjectRoot(a, io, path_dir);

    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    try parts.append(a, build_options.version);
    try parts.append(a, @tagName(opts.backend));
    try parts.append(a, @tagName(opts.profile));
    try parts.append(a, opts.target orelse "-");
    try parts.append(a, if (opts.debug_info) "g" else "-");
    try parts.append(a, abs_path);
    try parts.append(a, tool_stamp);
    if (source_stamp) |stamp| {
        try parts.append(a, stamp);
    } else if (project_root) |root| {
        try appendProjectSources(io, a, root, &parts);
    } else {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, abs_path, a, .limited(8 * 1024 * 1024));
        try parts.append(a, bytes);
    }
    try std.Io.Dir.cwd().createDirPath(io, nox_home);

    const content = run_cache.hex16(run_cache.digest(parts.items));
    const content_hex = try a.dupe(u8, &content);
    const path_key = run_cache.hex16(run_cache.digest(&.{abs_path}));
    const path_hex = try a.dupe(u8, &path_key);

    const obj_dir = try std.fmt.allocPrint(a, "{s}/cache/run/obj/{s}", .{ nox_home, content_hex });
    var home_dir = try std.Io.Dir.openDirAbsolute(io, nox_home, .{});
    defer home_dir.close(io);
    try home_dir.createDirPath(io, try std.fmt.allocPrint(a, "cache/run/obj/{s}", .{content_hex}));
    try home_dir.createDirPath(io, "cache/run/paths");

    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const bin_path = try std.fmt.allocPrint(a, "{s}/bin{s}", .{ obj_dir, suffix });
    const index_path = try std.fmt.allocPrint(a, "{s}/cache/run/paths/{s}", .{ nox_home, path_hex });
    const hit = if (std.Io.Dir.accessAbsolute(io, bin_path, .{})) |_| true else |_| false;

    var stale_dir: ?[]const u8 = null;
    if (std.Io.Dir.cwd().readFileAlloc(io, index_path, a, .limited(64))) |prev| {
        const prev_hex = std.mem.trim(u8, prev, " \t\r\n");
        if (!std.mem.eql(u8, prev_hex, content_hex)) {
            stale_dir = try std.fmt.allocPrint(a, "{s}/cache/run/obj/{s}", .{ nox_home, prev_hex });
        }
    } else |_| {}

    return .{
        .bin_path = bin_path,
        .hit = hit,
        .index_path = index_path,
        .content_hex = content_hex,
        .stale_dir = stale_dir,
    };
}

fn commitRunCache(io: std.Io, a: std.mem.Allocator, slot: RunSlot) !void {
    if (slot.stale_dir) |dir| {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = slot.index_path, .data = slot.content_hex });
    _ = a;
}

fn appendProjectSources(io: std.Io, a: std.mem.Allocator, root: []const u8, parts: *std.ArrayListUnmanaged([]const u8)) !void {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".nox")) continue;
        if (pathHasSkippedComponent(entry.path)) continue;
        try files.append(a, try a.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    for (files.items) |rel| {
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, full, a, .limited(8 * 1024 * 1024)) catch continue;
        try parts.append(a, rel);
        try parts.append(a, bytes);
    }
}

fn toolchainStamp(io: std.Io, a: std.mem.Allocator, resource_dirs: project.ResourceDirs) ![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    const exe = std.process.executablePathAlloc(io, a) catch "-";
    try appendFileStamp(io, a, &parts, exe);
    try appendFileStamp(io, a, &parts, resource_dirs.noxrt_path);
    if (builtin.os.tag == .windows) try appendFileStamp(io, a, &parts, resource_dirs.swap_asm_path);
    appendProjectSources(io, a, resource_dirs.stdlib_dir, &parts) catch try parts.append(a, "-");
    const hex = run_cache.hex16(run_cache.digest(parts.items));
    return try a.dupe(u8, &hex);
}

fn appendFileStamp(io: std.Io, a: std.mem.Allocator, parts: *std.ArrayListUnmanaged([]const u8), path: []const u8) !void {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch {
        try parts.append(a, path);
        try parts.append(a, "-");
        return;
    };
    defer file.close(io);
    const st = file.stat(io) catch {
        try parts.append(a, path);
        try parts.append(a, "-");
        return;
    };
    try parts.append(a, path);
    try parts.append(a, try std.fmt.allocPrint(a, "{d}:{d}", .{ st.size, st.mtime.nanoseconds }));
}

fn sourceStamp(io: std.Io, a: std.mem.Allocator, stamps: *std.StringHashMapUnmanaged([]const u8), path_arg: []const u8) !?[]const u8 {
    const cwd_abs = try std.process.currentPathAlloc(io, a);
    const abs_path = if (std.fs.path.isAbsolute(path_arg)) path_arg else try std.fs.path.resolve(a, &.{ cwd_abs, path_arg });
    const path_dir = std.fs.path.dirname(abs_path) orelse abs_path;
    const root = (try project.findProjectRoot(a, io, path_dir)) orelse return null;
    if (stamps.get(root)) |stamp| return stamp;
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    try appendProjectSources(io, a, root, &parts);
    const hex = run_cache.hex16(run_cache.digest(parts.items));
    const stamp = try a.dupe(u8, &hex);
    try stamps.put(a, root, stamp);
    return stamp;
}

fn pathHasSkippedComponent(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (run_cache.shouldSkipDir(part)) return true;
    }
    return false;
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
                printErr("import: stdlib module not found (searched under {s})\n", .{resource_dirs.stdlib_dir});
                return error.BuildFailed;
            },
            else => |err| return err,
        };
    };

    const manifest = project.loadManifest(a, io, root) catch |e| {
        printErr("nox.json could not be read or is invalid ({s}): {t}\n", .{ root, e });
        return error.BuildFailed;
    };
    const lock = project.loadLockfile(a, io, root) catch |e| {
        printErr("nox.lock could not be read or is invalid ({s}): {t}\n", .{ root, e });
        return error.BuildFailed;
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
            // getir. Kilitli tam SHA önbellekte duruyorsa `fetchToCache`
            // `git` çağırmaz. Dal adı SHA'yı çözmek için klon ister.
            var sig_diag: ?[]const u8 = null;
            const result = fetch.fetchToCache(a, io, nox_home, req.repo, fetch_ref, req.require_signed_commit, &sig_diag, fetch_policy) catch |e| {
                if (e == error.CommitSignatureRejected) {
                    printErr("could not fetch the package (alias={s}, repo={s}): commit signature verification failed:\n{s}\n", .{ req.alias, req.repo, sig_diag orelse "(git gave no explanation)" });
                } else {
                    printErr("could not fetch the package (alias={s}, repo={s}): {t}\n", .{ req.alias, req.repo, e });
                }
                return error.BuildFailed;
            };
            try roots.put(a, req.alias, result.cache_dir);

            var found_idx: ?usize = null;
            for (new_packages.items, 0..) |p, i| {
                if (std.mem.eql(u8, p.alias, req.alias)) {
                    found_idx = i;
                    break;
                }
            }
            var new_entry: project.LockedPackage = .{ .alias = req.alias, .repo = req.repo, .ref = req.ref, .resolved = result.resolved_sha };
            hpy_host_mod.annotateLock(a, io, result.cache_dir, &new_entry) catch |e| {
                printErr("HPy package rejected before install (alias={s}): {t}\n", .{ req.alias, e });
                return error.BuildFailed;
            };
            if (found_idx) |i| new_packages.items[i] = new_entry else try new_packages.append(a, new_entry);
            lock_changed = true;
        }
    }

    if (lock_changed) {
        try project.saveLockfile(a, io, root, .{ .packages = new_packages.items });
    }

    return module_loader.resolveProjectImports(a, io, user_module, roots, resource_dirs.stdlib_dir, root) catch |e| switch (e) {
        error.ModuleNotFound => {
            printErr("import: module not found (neither under 'stdlib/' nor in a dependency directory)\n", .{});
            return error.BuildFailed;
        },
        error.UnknownImportAlias => {
            printErr("import: unknown alias, or project file not found (check the 'requires' list in {s}/nox.json, or make sure the .nox file exists under '{s}')\n", .{ root, root });
            return error.BuildFailed;
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
        printErr("{s}: nox.json not found (you must be in the project root or one of its subdirectories)\n", .{cmd_name});
        std.process.exit(1);
    };
}

fn loadManifestOrExit(a: std.mem.Allocator, io: std.Io, root: []const u8) project.Manifest {
    return project.loadManifest(a, io, root) catch |e| {
        printErr("nox.json could not be read or is invalid ({s}): {t}\n", .{ root, e });
        std.process.exit(1);
    };
}

fn loadLockfileOrExit(a: std.mem.Allocator, io: std.Io, root: []const u8) project.Lockfile {
    return project.loadLockfile(a, io, root) catch |e| {
        printErr("nox.lock could not be read or is invalid ({s}): {t}\n", .{ root, e });
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
                    var check = locked;
                    hpy_host_mod.annotateLock(a, io, cache_dir, &check) catch |e| {
                        printErr("HPy package rejected before use (alias={s}): {t}\n", .{ req.alias, e });
                        return e;
                    };
                    if (check.hpy_module.len != 0 and !hpy_host_mod.requireComplete(locked, true)) {
                        printErr("HPy package is locked without a digest (alias={s})\n", .{req.alias});
                        return error.HpyRejected;
                    }
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
                printErr("could not fetch the package (alias={s}, repo={s}): commit signature verification failed:\n{s}\n", .{ req.alias, req.repo, sig_diag orelse "(git gave no explanation)" });
            } else {
                printErr("could not fetch the package (alias={s}, repo={s}): {t}\n", .{ req.alias, req.repo, e });
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
        var new_entry: project.LockedPackage = .{ .alias = req.alias, .repo = req.repo, .ref = req.ref, .resolved = result.resolved_sha };
        hpy_host_mod.annotateLock(a, io, result.cache_dir, &new_entry) catch |e| {
            printErr("HPy package rejected before install (alias={s}): {t}\n", .{ req.alias, e });
            return e;
        };
        if (found_idx) |i| new_packages.items[i] = new_entry else try new_packages.append(a, new_entry);

        const same_as_before = if (previous) |p| std.mem.eql(u8, p, result.resolved_sha) else false;
        if (!same_as_before) changed = true;

        const action: DepAction = if (cache_was_missing_for_locked) .recached else if (previous == null) .fetched else if (same_as_before) .unchanged else .updated;
        try outcomes.append(a, .{ .alias = req.alias, .repo = req.repo, .action = action, .resolved = result.resolved_sha, .previous_resolved = previous });
    }

    if (hpy_host_mod.findConflict(new_packages.items)) {
        printErr("HPy module name is locked to two different artifacts\n", .{});
        return error.HpyRejected;
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
        std.debug.print("fetch: nox.json has no dependencies ('requires' is empty)\n", .{});
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
                std.debug.print("fetched: {s} ({s}@{s})\n", .{ o.alias, o.repo, shortSha(o.resolved) });
            },
            .cached => {
                cached += 1;
                std.debug.print("already up to date: {s} ({s})\n", .{ o.alias, shortSha(o.resolved) });
            },
            .recached => {
                recached += 1;
                std.debug.print("cache rebuilt (from the locked SHA): {s} ({s})\n", .{ o.alias, shortSha(o.resolved) });
            },
            .updated, .unchanged => unreachable, // force_refetch=false bunlari asla uretmez
        }
    }
    std.debug.print("fetch complete: {d} fetched, {d} already up to date, {d} re-cached\n", .{ fetched, cached, recached });
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
        std.debug.print("update: nox.json has no dependencies ('requires' is empty)\n", .{});
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
                std.debug.print("updated: {s} {s} -> {s}\n", .{ o.alias, shortSha(o.previous_resolved.?), shortSha(o.resolved) });
            },
            .unchanged => {
                unchanged += 1;
                std.debug.print("unchanged: {s} ({s})\n", .{ o.alias, shortSha(o.resolved) });
            },
            .fetched => {
                updated += 1;
                std.debug.print("newly locked: {s} ({s}@{s})\n", .{ o.alias, o.repo, shortSha(o.resolved) });
            },
            .cached => unreachable, // force_refetch=true asla .cached uretmez
            .recached => unreachable, // force_refetch=true asla .recached uretmez (bkz. DepAction.recached'in belge notu)
        }
    }
    std.debug.print("update complete: {d} updated, {d} unchanged\n", .{ updated, unchanged });
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
            printErr("init: could not create the directory ({s}): {t}\n", .{ target_dir, e });
            std.process.exit(1);
        };
    }

    const manifest_path = try joinIfNeeded(a, target_dir, "nox.json");
    if (std.Io.Dir.cwd().access(io, manifest_path, .{})) |_| {
        printErr("init: '{s}' already exists, not overwriting\n", .{manifest_path});
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

    printOk("created: {s}, {s}\n", .{ manifest_path, main_path });
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
    const opts = parseBuildOpts(args);
    const path_arg = opts.path orelse {
        std.debug.print("usage: noxc check [--profile <hosted|freestanding>] <file.nox>\n", .{});
        std.process.exit(1);
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024));
    defer gpa.free(source);

    const user_module = try parseUserSource(a, source, path_arg);
    const module = try resolveImportsForBuild(io, a, user_module, path_arg, nox_home, resource_dirs, fetch_policy);

    var checker_state = checker.Checker.init(a);
    checker_state.profile = opts.profile;
    checker_state.mobile_mask = mobileMaskOf(if (opts.profile == .hosted and opts.target != null) qbe_target.hostedTargetInfo(opts.target.?) else null);
    // `build` ile aynı backend'e göre denetle (checker'ın `spawn` tip kuralları backend'e bağlıdır).
    checker_state.backend = if (resolveRelease(gpa, io, opts.backend, opts.profile, opts.target, opts.emit_asm, opts.debug_info)) .llvm else .qbe;
    checker_state.checkModule(module) catch |e| {
        printErr("type error ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(no message)" });
        std.process.exit(1);
    };
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            printErr("type error ({t}): {s}\n", .{ d.code, d.message });
        }
        std.process.exit(1);
    }

    printOk("no type errors: {s}\n", .{path_arg});
}

/// `noxc expand <dosya.nox>` — Faz 1 decorator (bkz. plan dosyası
/// "Decorator sözdizimi + metadata-tabanlı metaprogramming" §6): derleyicinin
/// decorator'lardan ÇIKARDIĞI metadata'yı insan-okunur biçimde YAZDIRIR.
/// Metadata-only tasarım GEREĞİ GERÇEK bir kod dönüşümü YOKTUR — bu YÜZDEN
/// "üretilen kod" GÖSTERİLMEZ, yalnızca `checker.zig`nin `registerDecorators`
/// ının topladığı `decorated_functions` listesi (`cmdCheck` İLE AYNI
/// derleme adımlarından SONRA) DÖKÜLÜR. Kullanıcının decorator'larının
/// DOĞRU ayrıştırıldığını/geçerli argümanlar TAŞIDIĞINI DOĞRULAMASI İçİndir.
fn cmdExpand(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const path_arg = if (args.len > 0) args[0] else {
        std.debug.print("usage: noxc expand <file.nox>\n", .{});
        std.process.exit(1);
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024));
    defer gpa.free(source);

    const user_module = try parseUserSource(a, source, path_arg);
    const module = try resolveImportsForBuild(io, a, user_module, path_arg, nox_home, resource_dirs, fetch_policy);

    var checker_state = checker.Checker.init(a);
    checker_state.checkModule(module) catch |e| {
        printErr("type error ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(no message)" });
        std.process.exit(1);
    };
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            printErr("type error ({t}): {s}\n", .{ d.code, d.message });
        }
        std.process.exit(1);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    const decorated = checker_state.decorated_functions.items;
    if (decorated.len == 0) {
        try w.print("decorator not found: {s}\n", .{path_arg});
    } else {
        try w.print("{d} decorator(s) found:\n", .{decorated.len});
        for (decorated) |d| {
            try w.print("  @{s}(", .{d.decorator_name});
            for (d.args, 0..) |arg, i| {
                if (i > 0) try w.writeAll(", ");
                switch (arg) {
                    .string => |s| try w.print("\"{s}\"", .{s}),
                    .int => |n| try w.print("{d}", .{n}),
                    .boolean => |b| try w.print("{}", .{b}),
                    .list_str => |items| {
                        try w.writeAll("[");
                        for (items, 0..) |it, k| {
                            if (k > 0) try w.writeAll(", ");
                            try w.print("\"{s}\"", .{it});
                        }
                        try w.writeAll("]");
                    },
                }
            }
            try w.print(") -> {s}", .{d.func_name});
            if (d.is_handler_shaped) {
                try w.writeAll("  [handler: (Context) -> HttpResponse]\n");
            } else {
                try w.writeAll("\n");
            }
        }
    }
    try w.flush();
}

/// HH.3 (bkz. plan dosyası "`noxc explain`"): `cmdCheck`/`cmdExpand`nin
/// AYNI lexer→parser→resolveImports→checker İSKELETİNİ İZLER, AMA
/// `checkModule` BAŞARILI OLDUKTAN SONRA `buildOne`nin (satır ~1701-1775)
/// AYNI argüman-türetme mantığını TEKRARLAYIP `codegen.generateModule`i
/// `explain_sink` DOLU olarak çağırır — HİÇBİR `.ssa`/`.ll` YAZILMAZ,
/// `qbe`/`cc`/`clang` HİÇ ÇAĞRILMAZ (bu YÜZDEN `noxc explain` GERÇEK bir
/// `noxc build`DAN DAHA UCUZDUR). `--release` bayrağı, SADECE `list`/
/// `class`/`dict` spawn-parametreli bir programın TİP-KONTROLÜNDEN
/// GEÇEBİLMESİ İçİn isteğe bağlı olarak sağlanır — `classifyVarDecl`nin
/// KENDİSİ backend'DEN BAĞIMSIZDIR (tahsis kararı HER İKİ backend İçİn
/// de AYNIDIR).
fn cmdExplain(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, fetch_policy: fetch.FetchPolicy) !void {
    const opts = parseBuildOpts(args);
    const path_arg = opts.path orelse {
        std.debug.print("usage: noxc explain [--release] <file.nox>\n", .{});
        std.process.exit(1);
    };

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path_arg, gpa, .limited(1024 * 1024));
    defer gpa.free(source);

    const user_module = try parseUserSource(a, source, path_arg);
    const module = try resolveImportsForBuild(io, a, user_module, path_arg, nox_home, resource_dirs, fetch_policy);

    const backend: codegen.Backend = if (resolveRelease(gpa, io, opts.backend, opts.profile, opts.target, opts.emit_asm, opts.debug_info)) .llvm else .qbe;
    var checker_state = checker.Checker.init(a);
    checker_state.backend = backend;
    checker_state.checkModule(module) catch |e| {
        printErr("type error ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(no message)" });
        std.process.exit(1);
    };
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            printErr("type error ({t}): {s}\n", .{ d.code, d.message });
        }
        std.process.exit(1);
    }

    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(a, k.*);

    var functions_used_as_value: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = checker_state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try functions_used_as_value.append(a, k.*);

    var callback_targets: std.ArrayListUnmanaged([]const u8) = .empty;
    var cb_target_it = checker_state.callback_targets.keyIterator();
    while (cb_target_it.next()) |k| try callback_targets.append(a, k.*);

    var generic_class_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_class_it = checker_state.generic_classes.keyIterator();
    while (generic_class_it.next()) |k| try generic_class_names.append(a, k.*);

    var closure_infos: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var closure_it = checker_state.closure_infos.iterator();
    while (closure_it.next()) |entry| {
        const names = try a.alloc([]const u8, entry.value_ptr.captures.len);
        for (entry.value_ptr.captures, 0..) |c, i| names[i] = c.name;
        try closure_infos.put(a, entry.key_ptr.*, names);
    }

    // Bkz. `buildOne`nin AYNI `resolved_bases` belge notu (Aether
    // NOX_LIMITATIONS.md madde 13).
    var resolved_bases: std.StringHashMapUnmanaged([]const u8) = .empty;
    var class_base_it = checker_state.classes.iterator();
    while (class_base_it.next()) |e| {
        if (e.value_ptr.*.base) |b| try resolved_bases.put(a, e.key_ptr.*, b);
    }

    // `module`, `core.nox`/import edilen TÜM stdlib dosyalarını KULLANICININ
    // KENDİ `user_module.body`sinin ÖNÜNE EKLENMİŞ olarak taşır (bkz.
    // `codegen.ExplainOptions`nin belge notu) — kullanıcının KENDİ dosyasının
    // BAŞLADIĞI İNDEKS, sondaki `user_module.body.len` uzunluğundan geri
    // hesaplanır.
    const user_stmt_start = module.body.len - user_module.body.len;
    var explain_sink: std.ArrayListUnmanaged(local_escape.ExplainRecord) = .empty;
    _ = codegen.generateModuleWithMeta(a, module, checker_state.instantiations.items, generic_names.items, checker_state.class_instantiations.items, generic_class_names.items, null, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, functions_used_as_value.items, checker_state.module_aliases, checker_state.decorated_functions.items, backend, opts.profile, .{ .sink = &explain_sink, .user_stmt_start = user_stmt_start }, callback_targets.items, resolved_bases, checker_state.class_ctors.items, false, "") catch |err| {
        printErr("explain: code generation failed ({t})\n", .{err});
        std.process.exit(1);
    };

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;
    if (explain_sink.items.len == 0) {
        try w.print("no local variable needing an allocation decision was found: {s}\n", .{path_arg});
    } else {
        for (explain_sink.items) |r| {
            const verdict_label = switch (r.verdict) {
                .stack => "stack",
                .arena => "arena",
                .arc => "ARC (heap, reference-counted)",
            };
            try w.print("{s}:{d}  {s}\n", .{ path_arg, r.line, r.name });
            if (r.size) |sz| {
                try w.print("  allocation: {s} ({d} bytes)\n", .{ verdict_label, sz });
            } else {
                try w.print("  allocation: {s}\n", .{verdict_label});
            }
            try w.writeAll("  reasons:\n");
            for (r.reasons) |reason| try w.print("    - {s}\n", .{reason});
            if (r.verdict == .stack) {
                try w.print("  frame budget: {d} / {d} bytes (before: {d})\n", .{ r.budget_after, inlining_mod.MAX_PROMOTED_FRAME_SIZE, r.budget_before });
            }
        }
    }
    try w.flush();
}

/// Faz FFI.3 (bkz. nox-teknik-spesifikasyon.md §3.148) `-rdynamic` (POSIX/
/// ELF) / `-Wl,--export-all-symbols` (Windows/PE) TÜM global sembolleri
/// dinamik sembol tablosuna koyduğundan, linker'ın "hiçbir yerden
/// erişilemeyen kodu ele" (`--gc-sections`/`-dead_strip`) mantığını FİİLEN
/// devre dışı bırakıyordu (macOS'ta `-rdynamic` OLMADAN + `-dead_strip` İLE
/// aynı program 7.68 MB'tan 1.52 MB'a İNİYOR, ama `-rdynamic`+`-dead_strip`
/// BİRLİKTE HİÇBİR fark YARATMIYOR). O turda çözüm 5 SABİT sembolü (`nox_
/// json_make_json_value`/`nox_class_release_dispatch`/`nox_trace_dispatch`/
/// `nox_gc_free_dispatch`/`nox_class_name_dispatch`) dinamik sembol
/// tablosuna KOYUP GERİ KALANIN dead-strip edilmesine İZİN vermekti — bu 5
/// sembol `runtime/`nin KENDİ `dlopen(null,...)+dlsym`iyle ÇALIŞMA ZAMANINDA
/// ARANIYORDU. Faz F.0.1'DEN İTİBAREN (bkz. proje planı "Freestanding Nox —
/// dlopen/dlsym-tabanlı dispatch'i statik, 'push' modeli bir kayıt
/// mekanizmasına çevirme") BU 5 sembol ARTIK dlsym İLE ARANMIYOR —
/// `compiler/codegen_qbe/registration.zig`'in `emitDispatchTableRegistration`ı
/// bunları `$nox_register_dispatch_table`e DOĞRUDAN, GERÇEK bir çağrı
/// argümanı OLARAK REFERANS ALIYOR (statik linkleme) — bu YÜZDEN ARTIK
/// dinamik sembol tablosuna KOYULMALARINA HİÇ GEREK YOK (zaten kullanılan
/// bir sembolü `--gc-sections`/`-dead_strip` ASLA silmez). macOS/Linux'ta
/// `-exported_symbol`/`--export-dynamic-symbol` özel-durumu TAMAMEN
/// KALDIRILDI, SADECE genel dead-stripping bayrağı KALDI. Windows BİLİNÇLİ
/// olarak DOKUNULMADI (gerçek Windows CI erişimi/link-davranışı doğrulaması
/// OLMADAN `--export-all-symbols`i KALDIRMAK riskli — AYRI, gelecekteki bir
/// tur).
fn computeLinkerVisibilityArgs() []const []const u8 {
    if (builtin.os.tag == .windows) {
        return &.{"-Wl,--export-all-symbols"};
    }
    if (builtin.os.tag == .macos) {
        return &.{"-Wl,-dead_strip"};
    }
    // Linux (ELF/GNU ld).
    return &.{"-Wl,--gc-sections"};
}

/// Tek bir `.nox` dosyasını uçtan uca derler (lex→parse→import çözümü→tip
/// denetimi→[isteğe bağlı döküm]→codegen→qbe→cc) ve üretilen binary'nin
/// yolunu döner. Hata durumlarında (mevcut davranışla BİREBİR aynı mesaj/
/// çıkış kodu) doğrudan `std.process.exit(1)` çağırır — `cmdBuild`/`cmdRun`
/// bu davranışı DEĞİŞTİRMEDEN miras alır.
fn isScalarSlotType(te: ast.TypeExpr) bool {
    const name = switch (te) {
        .simple => |n| n,
        else => return false,
    };
    return std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "float") or
        std.mem.eql(u8, name, "i8") or std.mem.eql(u8, name, "i16") or std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "isize") or std.mem.eql(u8, name, "u8") or
        std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "usize");
}

fn collectFunctionScalars(a: std.mem.Allocator, body: []const ast.Stmt, out: *std.ArrayListUnmanaged([]const u8)) !void {
    for (body) |s| {
        if (s.kind != .var_decl) continue;
        const vd = s.kind.var_decl;
        if (!isScalarSlotType(vd.type_expr)) continue;
        var seen = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, vd.name)) seen = true;
        }
        if (!seen) try out.append(a, vd.name);
    }
}

fn collectScalarLocalNames(a: std.mem.Allocator, module: ast.Module, out: *std.ArrayListUnmanaged([]const u8)) !void {
    for (module.body) |s| {
        switch (s.kind) {
            .func_def => |fd| try collectFunctionScalars(a, fd.body, out),
            .class_def => |cd| {
                for (cd.methods) |m| try collectFunctionScalars(a, m.body, out);
            },
            else => {},
        }
    }
}

/// Kullanıcı dosyasındaki skaler yerel adlarını `.debug_str`e ekler.
/// Birleştirilmiş modül kullanılmaz: stdlib satırları kullanıcının
/// kaynak ofsetleriyle örtüşmez.
fn appendScalarLocalNames(io: std.Io, a: std.mem.Allocator, asm_path: []const u8, qbe_arch: []const u8, user_module: ast.Module) !void {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    try collectScalarLocalNames(a, user_module, &names);
    if (names.items.len == 0) return;

    const apple = std.mem.indexOf(u8, qbe_arch, "apple") != null;
    const win = std.mem.eql(u8, qbe_arch, "amd64_win");
    var extra: std.ArrayListUnmanaged(u8) = .empty;
    try extra.appendSlice(a, "\n");
    if (apple) {
        try extra.appendSlice(a, ".section __DWARF,__debug_str,regular,debug\n");
    } else if (win) {
        try extra.appendSlice(a, ".section .debug_str,\"dr\"\n");
    } else {
        try extra.appendSlice(a, ".section .debug_str,\"MS\",@progbits,1\n");
    }
    for (names.items) |name| {
        try extra.appendSlice(a, ".asciz \"");
        try extra.appendSlice(a, name);
        try extra.appendSlice(a, "\"\n");
    }

    const existing = try std.Io.Dir.cwd().readFileAlloc(io, asm_path, a, .limited(32 * 1024 * 1024));
    const combined = try std.mem.concat(a, u8, &.{ existing, extra.items });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = asm_path, .data = combined });
}

fn mobileMaskOf(info: ?qbe_target.HostedTargetInfo) checker.MobileMask {
    const ht = info orelse return .none;
    return switch (ht.mobile) {
        .none => .none,
        .ios_device, .ios_simulator => .ios,
        .android => .android,
    };
}

fn stripOneExt(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return path;
    if (slash) |s| {
        if (dot < s) return path;
    }
    return path[0..dot];
}

fn runTool(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
        if (err == error.FileNotFound) {
            printErr("command not found: {s}\n", .{argv[0]});
            return error.BuildFailed;
        }
        return err;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        printErr("{s} failed:\n{s}\n", .{ argv[0], result.stderr });
        return error.BuildFailed;
    }
}

fn appleSdkPath(gpa: std.mem.Allocator, io: std.Io, sdk: []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "xcrun", "--sdk", sdk, "--show-sdk-path" } }) catch {
        printErr("xcrun not found: an Apple SDK is required for {s}\n", .{sdk});
        return error.BuildFailed;
    };
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        printErr("xcrun --sdk {s} failed:\n{s}\n", .{ sdk, result.stderr });
        return error.BuildFailed;
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) {
        gpa.free(result.stdout);
        printErr("xcrun --sdk {s} returned an empty SDK path\n", .{sdk});
        return error.BuildFailed;
    }
    const owned = try gpa.dupe(u8, trimmed);
    gpa.free(result.stdout);
    return owned;
}

fn commandSucceeds(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn findNdkClang(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const hosts = [_][]const u8{ "darwin-arm64", "darwin-x86_64", "linux-aarch64", "linux-x86_64", "windows-x86_64" };
    var root_buf: [3]?[]const u8 = .{ null, null, null };
    var owned_parent: ?[]u8 = null;
    defer if (owned_parent) |p| gpa.free(p);
    if (std.c.getenv("ANDROID_NDK_HOME")) |p| root_buf[0] = std.mem.span(p);
    if (std.c.getenv("ANDROID_NDK_ROOT")) |p| root_buf[1] = std.mem.span(p);
    if (std.c.getenv("HOME")) |home| {
        owned_parent = std.fmt.allocPrint(gpa, "{s}/Library/Android/sdk/ndk", .{std.mem.span(home)}) catch null;
        if (owned_parent) |parent| {
            if (commandSucceeds(gpa, io, &.{ "test", "-d", parent })) {
                const listed = std.process.run(gpa, io, .{ .argv = &.{ "ls", "-1", parent } }) catch null;
                if (listed) |result| {
                    defer gpa.free(result.stdout);
                    defer gpa.free(result.stderr);
                    var last: ?[]const u8 = null;
                    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
                    while (lines.next()) |line| {
                        if (line.len > 0) last = line;
                    }
                    if (last) |name| {
                        root_buf[2] = std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent, name }) catch null;
                    }
                }
            }
        }
    }
    defer if (root_buf[2]) |p| gpa.free(p);
    for (root_buf) |maybe| {
        const root = maybe orelse continue;
        for (hosts) |host| {
            const path = std.fmt.allocPrint(gpa, "{s}/toolchains/llvm/prebuilt/{s}/bin/clang", .{ root, host }) catch continue;
            if (commandSucceeds(gpa, io, &.{ "test", "-x", path })) return path;
            gpa.free(path);
        }
    }
    return null;
}

fn linkMobile(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, stem: []const u8, ir: []const u8, info: qbe_target.HostedTargetInfo, emit: EmitKind, output_override: ?[]const u8, resource_dirs: project.ResourceDirs) ![]const u8 {
    const base = stripOneExt(output_override orelse stem);
    const ll_path = try std.fmt.allocPrint(a, "{s}.ll", .{base});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ll_path, .data = ir });
    const obj_path = if (emit == .obj and output_override != null) output_override.? else try std.fmt.allocPrint(a, "{s}.o", .{base});
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    var sdk_owned: ?[]u8 = null;
    defer if (sdk_owned) |s| gpa.free(s);
    var ndk_owned: ?[]u8 = null;
    defer if (ndk_owned) |p| gpa.free(p);
    if (info.apple_sdk.len > 0) {
        const sdk = try appleSdkPath(gpa, io, info.apple_sdk);
        sdk_owned = sdk;
        try argv.appendSlice(a, &.{ "clang", "-c", "-O2", "-Wno-override-module", "-fPIC", "-target", info.llvmTriple(), "-isysroot", sdk, "-o", obj_path, ll_path });
    } else {
        const ndk = findNdkClang(gpa, io) orelse {
            printErr("Android target '{s}' needs the NDK clang (set ANDROID_NDK_HOME)\n", .{info.llvmTriple()});
            return error.BuildFailed;
        };
        ndk_owned = ndk;
        try argv.appendSlice(a, &.{ ndk, "-c", "-O2", "-Wno-override-module", "-fPIC", "-target", info.llvmTriple(), "-o", obj_path, ll_path });
    }
    try runTool(gpa, io, argv.items);
    if (emit == .obj) return if (output_override) |p| p else obj_path;
    const rt_path = try std.fmt.allocPrint(a, "{s}/lib/{s}.o", .{ resource_dirs.install_root, info.runtime_object_name });
    if (std.Io.Dir.accessAbsolute(io, rt_path, .{})) |_| {} else |_| {
        printErr("mobile runtime '{s}' is missing; build it with: zig build mobile-rt\n", .{rt_path});
        return error.BuildFailed;
    }
    if (emit == .static_lib) {
        const archive = output_override orelse try std.fmt.allocPrint(a, "{s}.a", .{base});
        if (info.apple_sdk.len > 0) {
            try runTool(gpa, io, &.{ "libtool", "-static", "-o", archive, obj_path, rt_path });
        } else {
            try runTool(gpa, io, &.{ "ar", "rcs", archive, obj_path, rt_path });
        }
        return archive;
    }
    const shared = output_override orelse try std.fmt.allocPrint(a, "{s}.so", .{base});
    const ndk = ndk_owned orelse {
        printErr("Android shared library needs the NDK clang (set ANDROID_NDK_HOME)\n", .{});
        return error.BuildFailed;
    };
    const page = try std.fmt.allocPrint(a, "-Wl,-z,max-page-size={d}", .{info.min_page});
    const base_argv = [_][]const u8{ ndk, "-shared", "-fPIC", "-target", info.llvmTriple(), page, "-o", shared, obj_path, rt_path, "-lm", "-ldl", "-llog" };
    var strict: std.ArrayListUnmanaged([]const u8) = .empty;
    try strict.appendSlice(a, base_argv[0..6]);
    try strict.append(a, "-Wl,--no-undefined");
    try strict.appendSlice(a, base_argv[6..]);
    const strict_result = std.process.run(gpa, io, .{ .argv = strict.items }) catch return error.BuildFailed;
    defer gpa.free(strict_result.stdout);
    defer gpa.free(strict_result.stderr);
    if (strict_result.term == .exited and strict_result.term.exited == 0) return shared;
    // x86_64 Bionic, API 29'dan önce `__tls_get_addr`ı libc'de değil
    // dinamik bağlayıcıda tanımlar. Başka çözülmemiş sembol varsa bağ hata verir.
    if (onlyUndefinedSymbol(strict_result.stderr, "__tls_get_addr")) {
        try runTool(gpa, io, &base_argv);
        return shared;
    }
    printErr("{s} failed:\n{s}\n", .{ ndk, strict_result.stderr });
    return error.BuildFailed;
}

fn onlyUndefinedSymbol(stderr: []const u8, name: []const u8) bool {
    var seen = false;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        const marker = "undefined symbol: ";
        const at = std.mem.indexOf(u8, line, marker) orelse continue;
        const sym = std.mem.trim(u8, line[at + marker.len ..], " \r");
        if (!std.mem.eql(u8, sym, name)) return false;
        seen = true;
    }
    return seen;
}

fn buildOne(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, path_arg: []const u8, verbose: bool, output_override: ?[]const u8, nox_home: []const u8, resource_dirs: project.ResourceDirs, debug_info: bool, backend_choice: BackendChoice, profile: codegen.Profile, fetch_policy: fetch.FetchPolicy, target: ?[]const u8, emit_asm: bool, emit: EmitKind) ![]const u8 {
    const release = resolveRelease(gpa, io, backend_choice, profile, target, emit_asm, debug_info);
    const hosted_info: ?qbe_target.HostedTargetInfo = if (profile == .hosted and target != null) qbe_target.hostedTargetInfo(target.?) else null;
    if (hosted_info) |ht| {
        if (ht.isMobile()) {
            if (emit == .exe) {
                printErr("mobile target '{s}' does not emit an executable; pass --emit-obj, --emit-static-lib, or --emit-shared-lib\n", .{target.?});
                return error.BuildFailed;
            }
            if (ht.mobile != .android and emit == .shared_lib) {
                printErr("mobile target '{s}' emits a static library; --emit-shared-lib is for Android\n", .{target.?});
                return error.BuildFailed;
            }
        }
    }
    if (emit != .exe and (hosted_info == null or !hosted_info.?.isMobile())) {
        printErr("--emit-obj, --emit-static-lib and --emit-shared-lib require a mobile --target\n", .{});
        return error.BuildFailed;
    }
    // Faz R.3+F.1 tamamlama (bkz. plan dosyası): `--release` (LLVM) yolu
    // GERÇEK OS iş parçacıklarına dayanan paylaşılan bir `WorkerPool`
    // kurar (Task[T]/Channel[T] DAHİL, TÜM `spawn`lar İçİn) — freestanding
    // profilinde (F.0.7'nin `lib_freestanding.zig`si worker_pool.zig'i
    // BİLİNÇLİ olarak HARİÇ TUTUYOR) BU HENÜZ ÇÖZÜLMEMİŞ bir etkileşimdir,
    // bu YÜZDEN v1 KOŞULSUZ olarak reddeder — TEK, ÜST-DÜZEY kontrol
    // NOKTASI (`buildOne`nin KENDİSİ) `cmdBuild`/`cmdRun`/`cmdTest`nin TÜM
    // çağrı sitelerini otomatik/ücretsiz kapsar.
    if (release and profile == .freestanding) {
        printErr("the freestanding profile currently supports ONLY the QBE backend (it cannot be combined with --release: LLVM's own WorkerPool needs real OS threads, which do not exist in freestanding)\n", .{});
        return error.BuildFailed;
    }
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
                printErr("file not found: {s}\n", .{path_arg});
            } else {
                printErr("unknown command or file: '{s}' — for commands, run: noxc --help\n", .{path_arg});
            }
            return error.BuildFailed;
        }
        return err;
    };
    defer gpa.free(source);

    const user_module = try parseUserSource(a, source, path_arg);

    // Faz O §P.6: proje kökü (`nox.json`) BULUNAMAZSA `resolveImports`in
    // ESKİ, DEĞİŞMEMİŞ davranışına (yalnızca `nox.*` stdlib) DÜŞER;
    // BULUNURSA `requires[]`i ÇÖZÜP `resolveProjectImports`i ÇAĞIRIR (bkz.
    // `resolveImportsForBuild`'in belge notu). Her iki yol da (Faz Q.3)
    // `resource_dirs.stdlib_dir`i (CWD-göreli `"stdlib"` DEĞİL, `noxc`nin
    // KENDİ çözülmüş kaynak dizinini) kullanır.
    const module = try resolveImportsForBuild(io, a, user_module, path_arg, nox_home, resource_dirs, fetch_policy);

    // DENEYSEL (bkz. plan dosyası "`noxc build --release` için deneysel
    // bir LLVM backend'i"): `--release` `.ll`/`clang -O2` yoluna, bayraksız
    // `build` (varsayılan) DEĞİŞMEDEN `.ssa`/`qbe`/`cc` yoluna gider —
    // aşağıda `release`e göre dallanır (bkz. Faz LLVM.5). Faz MN.9.4:
    // `checkModule` ÇAĞRILMADAN ÖNCE hesaplanır — `Checker.backend`
    // (`isThreadTransferSafeType`/`isSpawnParamSafeType`nin backend-
    // farkındalı gevşetmesi İçİn, bkz. checker.zig) BUNU İHTİYAÇ DUYAR.
    const backend: codegen.Backend = if (release) .llvm else .qbe;

    // `checker.check`'in kullanışlı ok/err sarmalayıcısı yerine `Checker`
    // doğrudan kullanılır: Faz 10 generics'i somut örneklemeleri
    // (`checker_state.instantiations`) burada, ownership analizi ve codegen'e
    // iletmek için gereklidir (bkz. checker.zig, "Faz 10: generics" notu).
    var checker_state = checker.Checker.init(a);
    checker_state.backend = backend;
    checker_state.profile = profile;
    checker_state.mobile_mask = mobileMaskOf(hosted_info);
    checker_state.checkModule(module) catch |e| {
        printErr("type error ({t}): {s}\n", .{ e, checker_state.diagnostic orelse "(no message)" });
        return error.BuildFailed;
    };
    // Faz T.2: `checkModule` artık fonksiyon/sınıf/metod/gevşek-deyim
    // SINIRINDAKİ hatalarda FIRLATMAZ, `checker_state.diagnostics`e
    // KAYDEDER (bkz. checker.zig, `recordDiagnostic`) — bu yüzden BAŞARILI
    // dönüş TEK BAŞINA "tip hatasız" anlamına GELMEZ, AYRICA kontrol edilir.
    if (checker_state.diagnostics.items.len > 0) {
        for (checker_state.diagnostics.items) |d| {
            printErr("type error ({t}): {s}\n", .{ d.code, d.message });
        }
        return error.BuildFailed;
    }
    const instantiations = checker_state.instantiations.items;

    // Codegen'in `module.body`deki generic ŞABLONLARINI (açık `[T]` VEYA
    // Faz 11'in örtük protokol parametresi yoluyla) atlayabilmesi için
    // isimlerini iletiyoruz (bkz. codegen.zig, `generateModule` belge notu).
    var generic_names: std.ArrayListUnmanaged([]const u8) = .empty;
    var generic_it = checker_state.generic_functions.keyIterator();
    while (generic_it.next()) |k| try generic_names.append(a, k.*);

    // Faz U.4.5 (bkz. `checker.zig`nin `functions_used_as_value`i VE
    // `codegen_qbe/closures.zig`nin `genFunctionValueTrampoline`ının belge
    // notu): `generic_names` İLE AYNI "keyIterator → slice" deseni.
    var functions_used_as_value: std.ArrayListUnmanaged([]const u8) = .empty;
    var fn_value_it = checker_state.functions_used_as_value.keyIterator();
    while (fn_value_it.next()) |k| try functions_used_as_value.append(a, k.*);

    // v2.0 madde 2.3: `functions_used_as_value` İLE AYNI "keyIterator →
    // slice" deseni — `@ffi.callback` hedefleri.
    var callback_targets: std.ArrayListUnmanaged([]const u8) = .empty;
    var cb_target_it = checker_state.callback_targets.keyIterator();
    while (cb_target_it.next()) |k| try callback_targets.append(a, k.*);

    // Bulundu (Aether NOX_LIMITATIONS.md madde 13 — çapraz-modül sınıf
    // kalıtımı, bkz. `codegen.zig`nin `Codegen.resolved_bases`inin belge
    // notu): `checker_state.classes`in HER girdisinin `.base`i (ZATEN
    // `registerClassSignatures`in `from_imports` geri-düşüşüyle DOĞRU
    // çözülmüş) `class_name → resolved_base_name` haritasına kopyalanıp
    // codegen'e aktarılır — codegen KENDİ başına bir çözümleme YENİDEN
    // UYGULAMAZ.
    var resolved_bases: std.StringHashMapUnmanaged([]const u8) = .empty;
    var class_base_it = checker_state.classes.iterator();
    while (class_base_it.next()) |e| {
        if (e.value_ptr.*.base) |b| try resolved_bases.put(a, e.key_ptr.*, b);
    }

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

    const library_mode = emit != .exe;
    const llvm_triple: []const u8 = if (hosted_info) |ht| (if (ht.isMobile()) ht.llvmTriple() else "") else "";
    const ir = codegen.generateModuleWithMeta(a, module, instantiations, generic_names.items, class_instantiations, generic_class_names.items, debug_source_path, closure_infos, checker_state.defer_synthetic_names, checker_state.from_imports, functions_used_as_value.items, checker_state.module_aliases, checker_state.decorated_functions.items, backend, profile, null, callback_targets.items, resolved_bases, checker_state.class_ctors.items, library_mode, llvm_triple) catch |err| switch (err) {
        error.Unsupported => {
            std.debug.print(
                "codegen: this program contains a construct that is not supported at the moment " ++
                    "(e.g. a nested function/class definition, an unsupported " ++
                    "type expression, or a for loop over an iterable other than " ++
                    "range()/list[T]) - see the language reference at " ++
                    "https://noxlang.com/docs/language/\n",
                .{},
            );
            return error.BuildFailed;
        },
        // Ayrıntılı ileti (hangi değişken hangisini okuyor) codegen'de basıldı.
        error.GlobalInitOrder => return error.BuildFailed,
        else => |e| return e,
    };

    const stem = output_override orelse stemOf(path_arg);
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): MinGW'in `cc`si,
    // `-o` AÇIKÇA verilmiş olsa BİLE, PE (Windows) çıktı dosyasına HER ZAMAN
    // `.exe` uzantısı EKLER (`stem` zaten `.exe` İLE BİTMİYORSA) — `noxc`
    // BUNU BİLMEZSE, diskteki GERÇEK dosya `stem.exe` iken `noxc run`ın
    // ÇALIŞTIRMAYA ÇALIŞTIĞI yol UZANTISIZ `stem` OLURDU (bulunamaz hatası).
    const bin_path = if (builtin.os.tag == .windows and !std.mem.endsWith(u8, stem, ".exe"))
        try std.fmt.allocPrint(a, "{s}.exe", .{stem})
    else
        stem;

    // Faz R.3/LL.6/FFI.3/F.0.1 (bkz. YUKARIDAKİ `computeLinkerVisibilityArgs`in
    // belge notu): `.qbe` VE `.llvm` yollarının İKİSİ de AYNI, genel dead-
    // stripping bayrağına İHTİYAÇ DUYAR — TEK yerde hesaplanır.
    const linker_visibility_args = computeLinkerVisibilityArgs();

    // Faz LLVM.5 (bkz. plan dosyası "`noxc build --release` için deneysel
    // bir LLVM backend'i"): `--release` İKEN `.ssa`/`qbe`/`cc` boru hattı
    // YERİNE TEK bir `.ll`/`clang -O2` çağrısı — geleneksel `opt|llc|cc`
    // boru hattı DEĞİL (bilinçli, bkz. plan). Kapsam BİLİNÇLİ olarak dar
    // (SADECE macOS/arm64, bkz. planın "Kapsam DIŞI" bölümü) — Windows'un
    // MinGW-özel bağlama argümanları (`swap_asm_path`/`-lntdll` vb.) bu
    // yola EKLENMEDİ.
    if (release) {
        if (hosted_info) |ht| {
            if (ht.isMobile()) {
                return linkMobile(gpa, io, a, stem, ir, ht, emit, output_override, resource_dirs);
            }
        }
        const ll_path = try std.fmt.allocPrint(a, "{s}.ll", .{stem});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ll_path, .data = ir });

        const driver = ccDriver(gpa, io);
        var clang_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        switch (driver) {
            .zig_cc => {
                try clang_argv.appendSlice(a, &.{ "zig", "cc", "-O2", "-Wno-override-module" });
                if (builtin.os.tag == .windows) try clang_argv.appendSlice(a, &.{ "-target", "x86_64-windows-gnu" });
            },
            .clang, .none => {
                try clang_argv.appendSlice(a, &.{ "clang", "-O2", "-Wno-override-module" });
                if (builtin.os.tag == .windows) try clang_argv.appendSlice(a, &.{ "-target", "x86_64-w64-windows-gnu" });
            },
        }
        try clang_argv.appendSlice(a, linker_visibility_args);
        try clang_argv.appendSlice(a, &.{ "-o", bin_path, ll_path, resource_dirs.noxrt_path });
        // Windows'ta fiber bağlam değişimi assembly'si `noxrt.o`nun dışında ayrı kurulur (QBE yolundaki ile aynı).
        if (builtin.os.tag == .windows) try clang_argv.append(a, resource_dirs.swap_asm_path);
        try clang_argv.append(a, "-lm");
        if (builtin.os.tag == .windows) try clang_argv.appendSlice(a, &.{ "-lntdll", "-lws2_32", "-lcrypt32" });
        try appendExternLinkArgs(a, &clang_argv, module);

        const clang_result = std.process.run(gpa, io, .{ .argv = clang_argv.items }) catch |err| {
            if (err == error.FileNotFound) {
                printErr("clang/zig not found: the LLVM backend needs 'clang' or 'zig' on PATH (for example: brew install llvm); alternative: --backend qbe\n", .{});
                return error.BuildFailed;
            }
            return err;
        };
        defer gpa.free(clang_result.stdout);
        defer gpa.free(clang_result.stderr);
        if (clang_result.term != .exited or clang_result.term.exited != 0) {
            printErr("{s} failed:\n{s}\n", .{ if (driver == .zig_cc) "zig cc" else "clang", clang_result.stderr });
            return error.BuildFailed;
        }
        stageProjectHpy(a, io, path_arg, bin_path, nox_home) catch |e| {
            printErr("HPy artifacts were not staged: {t}\n", .{e});
            return error.BuildFailed;
        };
        return bin_path;
    }

    const ssa_path = try std.fmt.allocPrint(a, "{s}.ssa", .{stem});
    const asm_path = try std.fmt.allocPrint(a, "{s}.s", .{stem});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ssa_path, .data = ir });

    // v2.0 madde 8 (bkz. nox-teknik-spesifikasyon.md §3.196): kamuya açık
    // `--target <isim>` — `profile`e göre YORUMLANIR: `.freestanding`
    // İKEN `nameForArch`in çıplak mimari adları (x86_64/aarch64/riscv64),
    // `.hosted` İKEN `hostedTargetInfo`nin platform isimleri (macos-arm64/
    // linux-x64/linux-arm64/linux-riscv64/windows-x64) — İKİ sözlük ASLA ÇAKIŞMAZ, bu
    // YÜZDEN YANLIŞ profil İçİn bir isim vermek DOĞAL olarak (AYRI bir
    // uyuşmazlık kontrolüne GEREK KALMADAN) "bilinmeyen hedef" hatasına
    // düşer. Eski, dâhilî `NOX_FREESTANDING_KERNEL_ARCH` TAMAMEN SİLİNDİ —
    // `--target`/`--emit-asm` YERİNİ ALDI.
    const hosted_target: ?qbe_target.HostedTargetInfo = if (profile == .hosted and target != null)
        (qbe_target.hostedTargetInfo(target.?) orelse {
            printErr("--target: unknown hosted target '{s}' (valid values: macos-arm64, macos-x64, linux-x64, linux-arm64, linux-riscv64, windows-x64, ios-arm64, ios-simulator-arm64, android-arm64, android-x64)\n", .{target.?});
            return error.BuildFailed;
        })
    else
        null;

    const qbe_arch_name: []const u8 = if (hosted_target) |ht|
        ht.qbe_target
    else if (profile == .freestanding and target != null)
        (qbe_target.nameForArch(target.?) orelse {
            printErr("--target: unknown freestanding architecture '{s}' (valid values: x86_64, aarch64, riscv64)\n", .{target.?});
            return error.BuildFailed;
        })
    else
        qbe_target.name(profile == .freestanding);

    // v2.0 madde 8: `runtime/async_rt/fiber.zig`nin mimari kapısı riscv64
    // İçİn HİÇBİR context-switch İMPLEMENTASYONU TAŞIMIYOR (bkz. plan
    // dosyasının araştırma notu) — `noxrt-freestanding-riscv64.o` BUGÜN
    // İNŞA EDİLEMEZ, bu YÜZDEN GERÇEK bir link denemesi (yani `--emit-asm`
    // OLMADAN) AÇIK bir hatayla reddedilir. `--emit-asm` İLE (SADECE ham
    // `.s`, linksiz) YİNE de çalışır.
    if (profile == .freestanding and target != null and std.mem.eql(u8, target.?, "riscv64") and !emit_asm) {
        printErr("--target riscv64: there is no freestanding runtime yet (no boot chain) - hosted riscv64 is 'noxc build --target linux-riscv64'; freestanding can only emit a raw .s file with --emit-asm\n", .{});
        return error.BuildFailed;
    }

    const qbe_result = try std.process.run(gpa, io, .{
        .argv = &.{ "qbe", "-t", qbe_arch_name, "-o", asm_path, ssa_path },
    });
    defer gpa.free(qbe_result.stdout);
    defer gpa.free(qbe_result.stderr);
    if (qbe_result.term != .exited or qbe_result.term.exited != 0) {
        printErr("qbe failed:\n{s}\n", .{qbe_result.stderr});
        return error.BuildFailed;
    }

    // `-g`: QBE değişken yönergesi bilmez. Fonksiyon gövdesinin en üstündeki
    // skaler yereller tek bir `alloc` yuvasında durur; adları hedefe uygun
    // `.debug_str` bölümüne yazılır. macOS `ld` bu bölümü bağlı ikiliden
    // düşürmeye devam eder (bkz. docs/tools/debugging.md).
    if (debug_info) try appendScalarLocalNames(io, a, asm_path, qbe_arch_name, user_module);

    // v2.0 madde 8: `--emit-asm` — `qbe -t ...` çalıştırıldıktan HEMEN
    // SONRA linkleme TAMAMEN ATLANIR, ham `.s` yolu döner (eski `kernel_
    // arch != null`in "return asm_path" davranışının BİREBİR AYNISI, AMA
    // ARTIK profile-nötr, AÇIKÇA adlandırılmış BAĞIMSIZ bir bayrak).
    if (emit_asm) {
        return asm_path;
    }

    // Faz R.3+F.1 tamamlama (bkz. plan dosyası): `--profile freestanding`
    // İKEN linker sürücüsü ARTIK host `cc` DEĞİL, `zig cc` (Zig'in KENDİ
    // evrensel LLD'si) — `tests/golden/freestanding_link_test.zig`nin
    // (Faz F.1) ZATEN KANITLADIĞI, TEK yol: macOS'un KENDİ NATİF `ld`si
    // ELF nesne dosyalarını HİÇ işleyemiyor. `linker_visibility_args`/`-lm`
    // BİLİNÇLİ olarak ATLANIR (dead-strip bayrakları macOS'un native
    // `ld`sine ÖZGÜ, `zig cc`nin İÇ LLD'si FARKLI bir sözdizimi
    // bekleyebilir — v1 basitliği İçİn, AYRI bir gelecekteki iyileştirme).
    if (profile == .freestanding) {
        // v2.0 madde 8: `target` VARSA (`--target x86_64`/`aarch64`) SABİT
        // hedefli `noxrt-freestanding-generic-{arch}.o`ya (bkz. build.zig'in
        // `addFreestandingRuntimeChain`ı) bağlanır — YOKSA (VARSAYILAN,
        // SIFIR davranış değişikliği) `builtin.cpu.arch`in HOST-arch'lı
        // `resource_dirs.noxrt_freestanding_path`ine.
        const freestanding_arch_name: []const u8 = target orelse @tagName(builtin.cpu.arch);
        const freestanding_triple = try std.fmt.allocPrint(a, "{s}-freestanding-none", .{freestanding_arch_name});
        const freestanding_runtime_path: []const u8 = if (target != null)
            try std.fmt.allocPrint(a, "{s}/lib/noxrt-freestanding-generic-{s}.o", .{ resource_dirs.install_root, freestanding_arch_name })
        else
            resource_dirs.noxrt_freestanding_path;
        var zig_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try zig_argv.appendSlice(a, &.{
            "zig", "cc",     "-target", freestanding_triple,       "-ffreestanding", "-nostdlib", "-static",
            "-o",  bin_path, asm_path,  freestanding_runtime_path,
        });
        try appendExternLinkArgs(a, &zig_argv, module);

        const zig_result = std.process.run(gpa, io, .{ .argv = zig_argv.items }) catch |err| {
            if (err == error.FileNotFound) {
                printErr("zig not found: --profile freestanding needs a 'zig' executable on PATH\n", .{});
                return error.BuildFailed;
            }
            return err;
        };
        defer gpa.free(zig_result.stdout);
        defer gpa.free(zig_result.stderr);
        if (zig_result.term != .exited or zig_result.term.exited != 0) {
            printErr("zig cc failed:\n{s}\n", .{zig_result.stderr});
            return error.BuildFailed;
        }
        return bin_path;
    }

    // v2.0 madde 8: `hosted_target` VARSA (`--target linux-x64`/vb.)
    // `zig cc -target <triple>` İLE ÇAPRAZ-derlenmiş linkleme; YOKSA
    // (VARSAYILAN, SIFIR davranış değişikliği) host `cc` + `resource_
    // dirs.noxrt_path`. `-lntdll`/`-lws2_32`/`-lcrypt32`/`swap_asm`
    // eklemeleri `builtin.os.tag == .windows` (HOST) YERİNE `target_is_
    // windows` (HEDEFİN OS'u) KOŞULUYLA yapılır.
    const target_is_windows = if (hosted_target) |ht| ht.is_windows else builtin.os.tag == .windows;
    // Faz Q.3: runtime nesne dosyasının yolu artık `resource_dirs.noxrt_path`
    // (bkz. `project.resolveResourceDirs`) — `noxc`nin KENDİ çalıştırılabilir
    // dosya konumuna göre çözülür, CWD'ye (proje köküne) BAĞIMLI DEĞİLDİR.
    //
    // Faz R.3/FFI.3/F.0.1 (bkz. `computeLinkerVisibilityArgs`in belge
    // notu): Faz F.0.1'DEN İTİBAREN `runtime/`de dlsym-tabanlı bir sembol
    // arama KALMADI (`nox_register_dispatch_table` statik linklemeyle
    // çözülüyor) — bu YÜZDEN ARTIK blanket `-rdynamic`nin YOL AÇTIĞI dead-
    // stripping sorununu ÇÖZMEK İçİn ÖZEL bir "5 sembolü dinamik tabloya
    // koy" işlemine GEREK YOK, SADECE genel dead-stripping bayrağı yeterli.
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): MinGW'in `cc`si
    // `-rdynamic`yi TANIMAZ (`cc: error: unrecognized command-line option
    // '-rdynamic'` — GERÇEK Windows CI'de doğrulandı) — PE bağlayıcısının
    // "TÜM genel sembolleri dışa aç" karşılığı `-Wl,--export-all-symbols`dir
    // (`linker_visibility_args`, YUKARIDA — LLVM yoluyla PAYLAŞILDI).
    var cc_argv: std.ArrayListUnmanaged([]const u8) = .empty;
    const runtime_object_path: []const u8 = if (hosted_target) |ht|
        try std.fmt.allocPrint(a, "{s}/lib/{s}.o", .{ resource_dirs.install_root, ht.runtime_object_name })
    else
        resource_dirs.noxrt_path;
    if (hosted_target) |ht| {
        try cc_argv.appendSlice(a, &.{ "zig", "cc", "-target", ht.zig_triple });
        // musl üçlüsü statik bağlanır: qemu-user sysroot olmadan çalıştırır.
        if (std.mem.endsWith(u8, ht.zig_triple, "musl")) try cc_argv.append(a, "-static");
    } else {
        try cc_argv.append(a, "cc");
    }
    try cc_argv.appendSlice(a, linker_visibility_args);
    try cc_argv.appendSlice(a, &.{ "-o", bin_path, asm_path, runtime_object_path });
    // Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): Windows'ta fiber
    // bağlam değişimi assembly'si `noxrt.o`nun DIŞINDA, AYRI kurulur (bkz.
    // `ResourceDirs.swap_asm_path`ın belge notu) — bu YÜZDEN NİHAİ bağlamaya
    // AYRI bir girdi olarak eklenmesi GEREKİR.
    if (target_is_windows) {
        const swap_asm_path: []const u8 = if (hosted_target) |ht|
            try std.fmt.allocPrint(a, "{s}/lib/swap_asm-{s}.o", .{ resource_dirs.install_root, ht.runtime_object_name })
        else
            resource_dirs.swap_asm_path;
        try cc_argv.append(a, swap_asm_path);
    }
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
    if (target_is_windows) try cc_argv.appendSlice(a, &.{ "-lntdll", "-lws2_32", "-lcrypt32" });
    try appendExternLinkArgs(a, &cc_argv, module);

    const cc_result = try std.process.run(gpa, io, .{
        .argv = cc_argv.items,
    });
    defer gpa.free(cc_result.stdout);
    defer gpa.free(cc_result.stderr);
    if (cc_result.term != .exited or cc_result.term.exited != 0) {
        printErr("cc failed:\n{s}\n", .{cc_result.stderr});
        return error.BuildFailed;
    }

    stageProjectHpy(a, io, path_arg, bin_path, nox_home) catch |e| {
        printErr("HPy artifacts were not staged: {t}\n", .{e});
        return error.BuildFailed;
    };
    return bin_path;
}

fn stageProjectHpy(a: std.mem.Allocator, io: std.Io, path_arg: []const u8, bin_path: []const u8, nox_home: []const u8) !void {
    const start_rel = std.fs.path.dirname(path_arg) orelse ".";
    const start = if (std.fs.path.isAbsolute(start_rel))
        start_rel
    else if (std.mem.eql(u8, start_rel, "."))
        try std.process.currentPathAlloc(io, a)
    else
        try std.fs.path.join(a, &.{ try std.process.currentPathAlloc(io, a), start_rel });
    const root = try project.findProjectRoot(a, io, start) orelse return;
    const lock = project.loadLockfile(a, io, root) catch return;
    if (hpy_host_mod.findConflict(lock.packages)) return error.HpyRejected;
    const bin_dir = std.fs.path.dirname(bin_path) orelse ".";
    const staged_root = try std.fmt.allocPrint(a, "{s}/hpy", .{bin_dir});
    std.Io.Dir.cwd().deleteTree(io, staged_root) catch {};
    for (lock.packages) |pkg| {
        if (pkg.hpy_module.len == 0) continue;
        if (!hpy_host_mod.requireComplete(pkg, true)) return error.HpyRejected;
        const cache_dir = try fetch.cachedDirFor(a, nox_home, pkg.repo, pkg.resolved);
        try hpy_host_mod.stageBesideBinary(a, io, cache_dir, bin_path, pkg);
    }
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

// ---- `noxc sign` (ADR-011): nox.lock imzalama ---------------------------------------------------------------------------------------

fn readHexFile(io: std.Io, a: std.mem.Allocator, path: []const u8, out: []u8) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4096)) catch {
        printErr("noxc sign: cannot read {s}\n", .{path});
        std.process.exit(1);
    };
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    _ = std.fmt.hexToBytes(out, trimmed) catch {
        printErr("noxc sign: {s} is not valid hex of the expected length\n", .{path});
        std.process.exit(1);
    };
    if (trimmed.len != out.len * 2) {
        printErr("noxc sign: {s} is not valid hex of the expected length\n", .{path});
        std.process.exit(1);
    }
}

fn cmdSign(io: std.Io, a: std.mem.Allocator, args: []const []const u8, nox_home: []const u8) !void {
    const usage =
        "usage: noxc sign keygen <name>                create an Ed25519 key pair in $NOX_HOME/keys\n" ++
        "       noxc sign lock [--key <name|file>] [dir]  sign dir/nox.lock -> dir/nox.lock.sig\n" ++
        "       noxc sign trust <pubkey-file>          trust a publisher key (verification then accepts it)\n" ++
        "       noxc sign revoke <fingerprint>         never trust that key again\n" ++
        "       noxc sign verify [dir]                 verify dir/nox.lock.sig offline (exit 0 only when valid)\n";
    if (args.len == 0) {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
    const cwd = std.Io.Dir.cwd();
    const keys_dir = try std.fmt.allocPrint(a, "{s}/keys", .{nox_home});
    const trusted_dir = try std.fmt.allocPrint(a, "{s}/trusted", .{nox_home});
    const revoked_path = try std.fmt.allocPrint(a, "{s}/revoked.txt", .{nox_home});
    const sub = args[0];

    if (std.mem.eql(u8, sub, "keygen")) {
        if (args.len < 2) {
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
        const name = args[1];
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
            printErr("noxc sign keygen: the name may only contain letters, digits, '-' and '_'\n", .{});
            std.process.exit(1);
        };
        try cwd.createDirPath(io, keys_dir);
        const key_path = try std.fmt.allocPrint(a, "{s}/{s}.key", .{ keys_dir, name });
        const pub_path = try std.fmt.allocPrint(a, "{s}/{s}.pub", .{ keys_dir, name });
        if (cwd.access(io, key_path, .{})) |_| {
            printErr("noxc sign keygen: {s} already exists (it is never overwritten)\n", .{key_path});
            std.process.exit(1);
        } else |_| {}
        var seed: [32]u8 = undefined;
        try io.randomSecure(&seed);
        const kp = try signing.publicKeyOf(seed);
        const seed_hex = std.fmt.bytesToHex(seed, .lower);
        const pub_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
        try cwd.writeFile(io, .{ .sub_path = key_path, .data = &seed_hex, .flags = .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) } });
        try cwd.writeFile(io, .{ .sub_path = pub_path, .data = &pub_hex });
        std.debug.print("key: {s}\npublic key: {s}\nfingerprint: {s}\nKeep the .key file secret; share the .pub file with consumers.\n", .{ key_path, pub_path, signing.fingerprint(kp.public_key.toBytes()) });
        return;
    }

    if (std.mem.eql(u8, sub, "lock")) {
        var key_arg: ?[]const u8 = null;
        var dir: []const u8 = ".";
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--key") and i + 1 < args.len) {
                key_arg = args[i + 1];
                i += 1;
            } else dir = args[i];
        }
        const key_path = if (key_arg) |k| (if (std.mem.indexOfScalar(u8, k, '/') != null) k else try std.fmt.allocPrint(a, "{s}/{s}.key", .{ keys_dir, k })) else {
            printErr("noxc sign lock: pass --key <name|file> (create one with 'noxc sign keygen <name>')\n", .{});
            std.process.exit(1);
        };
        var seed: [32]u8 = undefined;
        try readHexFile(io, a, key_path, &seed);
        const lock_path = try std.fmt.allocPrint(a, "{s}/nox.lock", .{dir});
        const lock_bytes = cwd.readFileAlloc(io, lock_path, a, .limited(4 * 1024 * 1024)) catch {
            printErr("noxc sign lock: cannot read {s} (run 'noxc fetch' first)\n", .{lock_path});
            std.process.exit(1);
        };
        const sig_text = try signing.signLock(a, seed, lock_bytes);
        const sig_path = try std.fmt.allocPrint(a, "{s}/nox.lock.sig", .{dir});
        try cwd.writeFile(io, .{ .sub_path = sig_path, .data = sig_text });
        std.debug.print("signed {s} -> {s}\n", .{ lock_path, sig_path });
        return;
    }

    if (std.mem.eql(u8, sub, "trust")) {
        if (args.len < 2) {
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
        var pub_bytes: [32]u8 = undefined;
        try readHexFile(io, a, args[1], &pub_bytes);
        const fp = signing.fingerprint(pub_bytes);
        try cwd.createDirPath(io, trusted_dir);
        const dest = try std.fmt.allocPrint(a, "{s}/{s}.pub", .{ trusted_dir, fp });
        const hex = std.fmt.bytesToHex(pub_bytes, .lower);
        try cwd.writeFile(io, .{ .sub_path = dest, .data = &hex });
        std.debug.print("trusted key {s}\n", .{fp});
        return;
    }

    if (std.mem.eql(u8, sub, "revoke")) {
        if (args.len < 2 or args[1].len != 32) {
            printErr("noxc sign revoke: pass the 32-character fingerprint\n", .{});
            std.process.exit(1);
        }
        const existing = cwd.readFileAlloc(io, revoked_path, a, .limited(1024 * 1024)) catch "";
        const updated = try std.fmt.allocPrint(a, "{s}{s}\n", .{ existing, args[1] });
        try cwd.createDirPath(io, nox_home);
        try cwd.writeFile(io, .{ .sub_path = revoked_path, .data = updated });
        std.debug.print("revoked {s}\n", .{args[1]});
        return;
    }

    if (std.mem.eql(u8, sub, "verify")) {
        const dir: []const u8 = if (args.len > 1) args[1] else ".";
        const lock_path = try std.fmt.allocPrint(a, "{s}/nox.lock", .{dir});
        const sig_path = try std.fmt.allocPrint(a, "{s}/nox.lock.sig", .{dir});
        const lock_bytes = cwd.readFileAlloc(io, lock_path, a, .limited(4 * 1024 * 1024)) catch {
            printErr("noxc sign verify: cannot read {s}\n", .{lock_path});
            std.process.exit(1);
        };
        const sig_text = cwd.readFileAlloc(io, sig_path, a, .limited(4096)) catch {
            printErr("noxc sign verify: {s} is missing (the lock file is not signed)\n", .{sig_path});
            std.process.exit(1);
        };
        var trusted: std.ArrayListUnmanaged(signing.Trusted) = .empty;
        if (cwd.openDir(io, trusted_dir, .{ .iterate = true })) |td_const| {
            var td = td_const;
            defer td.close(io);
            var it = td.iterate();
            while (try it.next(io)) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".pub")) continue;
                const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ trusted_dir, entry.name });
                var kb: [32]u8 = undefined;
                try readHexFile(io, a, path, &kb);
                try trusted.append(a, .{ .fingerprint = signing.fingerprint(kb), .key = kb });
            }
        } else |_| {}
        var revoked: std.ArrayListUnmanaged([]const u8) = .empty;
        const revoked_text = cwd.readFileAlloc(io, revoked_path, a, .limited(1024 * 1024)) catch "";
        var lines = std.mem.splitScalar(u8, revoked_text, '\n');
        while (lines.next()) |l| if (l.len > 0) try revoked.append(a, l);
        const verdict = signing.verifyLock(sig_text, lock_bytes, trusted.items, revoked.items);
        switch (verdict) {
            .ok => std.debug.print("ok: {s} is signed by a trusted key\n", .{lock_path}),
            .malformed => {
                printErr("noxc sign verify: {s} is malformed\n", .{sig_path});
                std.process.exit(1);
            },
            .revoked => {
                printErr("noxc sign verify: the signing key has been revoked\n", .{});
                std.process.exit(1);
            },
            .untrusted_signer => {
                printErr("noxc sign verify: the signer is not trusted (use 'noxc sign trust <pubkey-file>' after checking the fingerprint with the publisher)\n", .{});
                std.process.exit(1);
            },
            .bad_signature => {
                printErr("noxc sign verify: the signature does not match nox.lock (the file changed after signing, or the key is wrong)\n", .{});
                std.process.exit(1);
            },
        }
        return;
    }

    std.debug.print("{s}", .{usage});
    std.process.exit(1);
}
