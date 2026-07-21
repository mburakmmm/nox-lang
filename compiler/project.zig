//! Faz O §P.1 (bkz. plan dosyası "Faz O" bölümü, nox-teknik-spesifikasyon.md
//! §3.6): `noxc`nin proje kökü keşfi (`nox.json` arayarak yukarı yürüyüş) +
//! `noxc`nin KENDİ stdlib/runtime kaynak dizini keşfi (self-exe göreli,
//! `NOX_HOME` override'lı). Bu dosya, main.zig:135-138'in "v0.1
//! basitleştirmesi" olarak işaretlediği (`stdlib/`/`zig-out/lib/noxrt.o`nun
//! CWD-göreli SABİT yol olması, `noxc`nin yalnızca proje kökünden
//! çalıştırılabilmesi) kısıtın çözümünün ALTYAPISIdır.
//!
//! **Bilinçli olarak SALT EKLEYİCİ:** bu dosya, golden testlerin (3 ayrı
//! dosya) DOĞRUDAN çağırdığı `module_loader.resolveImports`ın imzasına HİÇ
//! DOKUNMAZ. `main.zig` (Faz Q.3'ten beri) `resolveResourceDirs`i GERÇEKTEN
//! kullanır — `buildOne`in `cc` bağlama argümanı VE `resolveImportsForBuild`in
//! stdlib arama kökü, artık BU fonksiyonun döndürdüğü `ResourceDirs`e dayanır
//! (bkz. main.zig'in `main()`i, `resource_dirs` değişkeni).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Bir bağımlılık bildirimi (`nox.json`'ın `requires[]` dizisinin bir
/// elemanı) — Faz O §P.4. `alias`, KAYNAK KODDA kullanılacak TEK noktalı
/// kök (ör. `import somepkg.util` → `alias = "somepkg"`); `repo` bir
/// GitHub koordinatı (ör. `"github.com/someuser/somepkg"`); `ref` bir
/// tag/branch/commit SHA'sı (Go'nun `require`iyle AYNI kavram).
pub const Requirement = struct {
    alias: []const u8,
    repo: []const u8,
    ref: []const u8,
};

/// Proje manifesti (`nox.json`, proje kökünde). `.ignore_unknown_fields`
/// (bkz. `loadManifest`) sayesinde P.1'de ZATEN `requires`lı bir manifesti
/// ayrıştırmak (o alanı yok sayarak) başarısız OLMUYORDU — §P.4 bu alanı
/// GERÇEK bir `[]Requirement`e bağlıyor.
pub const Manifest = struct {
    name: []const u8 = "",
    entry: []const u8 = "main.nox",
    requires: []const Requirement = &.{},
};

pub const ManifestError = error{ InvalidManifest, DuplicateAlias, ReservedAlias } ||
    std.Io.Dir.ReadFileAllocError ||
    Allocator.Error;

/// `requires[]`in KENDİ İÇİNDE İKİ kuralı doğrular (Faz O §P.4): (1) her
/// `alias` BENZERSİZ olmalı (aksi halde `import` çözümlemesi HANGİ
/// bağımlılığın kastedildiğini AYIRT edemez); (2) `"nox"` alias'ı REZERVE
/// (bkz. stdlib'in KENDİ noktalı kökü) — bir üçüncü-taraf bağımlılık BUNU
/// ele geçiremez. `requires` genelde KÜÇÜK (onlarca değil, birkaç eleman)
/// olduğundan basit O(n²) doğrusal tarama TERCİH edildi — bir allocator
/// (ör. bir `StringHashMap`) GEREKMEDEN saf bellek-içi çalışır.
pub fn validateManifest(m: Manifest) error{ DuplicateAlias, ReservedAlias }!void {
    for (m.requires, 0..) |req, i| {
        if (std.mem.eql(u8, req.alias, "nox")) return error.ReservedAlias;
        for (m.requires[0..i]) |prev| {
            if (std.mem.eql(u8, prev.alias, req.alias)) return error.DuplicateAlias;
        }
    }
}

/// `dir_path` (mutlak ya da CWD-göreli, `nox.json`ın YAŞADIĞI dizin)
/// altındaki `nox.json`ı okuyup ayrıştırır VE `validateManifest`i uygular.
/// Dosya yoksa/bozuksa/geçersizse hata döner (çağıran, "manifest yok"
/// durumunu `findProjectRoot`ın `null` dönüşüyle AYIRT eder — bu fonksiyon
/// yalnızca "manifest VARSA doğru mu" sorusuna bakar).
pub fn loadManifest(a: Allocator, io: Io, dir_path: []const u8) ManifestError!Manifest {
    const manifest_path = try std.fmt.allocPrint(a, "{s}/nox.json", .{dir_path});
    const source = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, a, .limited(1024 * 1024));
    const parsed = std.json.parseFromSlice(Manifest, a, source, .{ .ignore_unknown_fields = true }) catch {
        return error.InvalidManifest;
    };
    try validateManifest(parsed.value);
    return parsed.value;
}

/// `start_dir`den (**mutlak yol OLMALI** — çağıran, ör. `Dir.realPath` ile
/// önce mutlak hale getirmeli) YUKARI doğru `nox.json` arar (Cargo/`go.mod`
/// keşfiyle AYNI desen); bulursa onu İÇEREN dizinin yolunu döner, dosya
/// sistemi köküne kadar bulamazsa `null` (hata DEĞİL — manifestsiz bir
/// `.nox` dosyasını derlemek GEÇERLİ bir v1 kullanım biçimidir, bkz. plan
/// dosyası "1.5(b)").
pub fn findProjectRoot(a: Allocator, io: Io, start_dir: []const u8) Allocator.Error!?[]const u8 {
    var current: []const u8 = try a.dupe(u8, start_dir);
    while (true) {
        const candidate = try std.fmt.allocPrint(a, "{s}/nox.json", .{current});
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return current;
        } else |_| {}
        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;
        current = parent;
    }
}

/// `noxc`nin KENDİ `stdlib/` ağacı VE `noxrt.o`sunun çözülmüş mutlak yolları.
pub const ResourceDirs = struct {
    stdlib_dir: []const u8,
    noxrt_path: []const u8,
    /// Faz LL.6 (bkz. nox-teknik-spesifikasyon.md §3.71): YALNIZCA Windows'ta
    /// ANLAMLI — `build.zig`nin AYRI kurduğu `swap_asm.o` (fiber bağlam
    /// değişimi assembly'si), `zig build-obj`in COFF'ta `addObjectFile` İLE
    /// birleştirilen HAM nesne dosyalarını SESSİZCE Zig'in KENDİ derlediği
    /// içeriğin YERİNE geçirdiği bir hatadan (GERÇEK, yalıtılıp doğrulanmış)
    /// KAÇINMAK İçin `noxrt.o`nun DIŞINDA, AYRI kurulur — `main.zig`nin `cc_
    /// argv`ı BU YÜZDEN Windows'ta bunu AYRI bir bağlama girdisi olarak
    /// ekler (macOS/Linux'ta `noxrt.o` fiber assembly'sini ZATEN İÇERİR,
    /// bu alan KULLANILMAZ).
    swap_asm_path: []const u8,
};

/// `resource_dir_override` VERİLMİŞSE (`main.zig`de `NOX_RESOURCE_DIR`
/// ortam değişkeni ya da bir testin geçici dizini — **DİKKAT:** bu, paket
/// önbelleği kökü olan `NOX_HOME` İLE AYNI ŞEY DEĞİLDİR, bkz. `main.zig`nin
/// `resource_dirs` hesaplamasının belge notu) doğrudan bu KÖK kullanılır;
/// VERİLMEMİŞSE çalıştırılabilir dosyanın KENDİ dizininden (`<exe_dir>/..`)
/// hesaplanır. Kurulum düzeni `build.zig`nin `b.addInstallFile`/
/// `b.addInstallDirectory` çağrılarıyla EŞLEŞİR: `<kök>/lib/noxrt.o` ve
/// `<kök>/lib/nox/stdlib/`.
pub fn resolveResourceDirs(a: Allocator, io: Io, resource_dir_override: ?[]const u8) !ResourceDirs {
    const base = if (resource_dir_override) |h|
        try a.dupe(u8, h)
    else blk: {
        const exe_dir = try std.process.executableDirPathAlloc(io, a);
        break :blk try std.fmt.allocPrint(a, "{s}/..", .{exe_dir});
    };
    return .{
        .stdlib_dir = try std.fmt.allocPrint(a, "{s}/lib/nox/stdlib", .{base}),
        .noxrt_path = try std.fmt.allocPrint(a, "{s}/lib/noxrt.o", .{base}),
        .swap_asm_path = try std.fmt.allocPrint(a, "{s}/lib/swap_asm.o", .{base}),
    };
}

/// Kilitlenmiş (ÇÖZÜLMÜŞ) bir bağımlılık girdisi (`nox.lock`ın `packages[]`
/// dizisinin bir elemanı) — Faz O §P.4. `alias`/`repo`/`ref`, `Requirement`
/// İLE AYNI anlamı taşır; `resolved`, `ref`in GERÇEKTEN çözüldüğü commit
/// SHA'sıdır (bkz. plan dosyası §3 — önbellek bu SHA İLE anahtarlanır,
/// İNSAN tarafından verilen `ref` İLE DEĞİL, böylece hareketli bir branch
/// ref'i paylaşılan önbelleği BOZMAZ).
pub const LockedPackage = struct {
    alias: []const u8,
    repo: []const u8,
    ref: []const u8,
    resolved: []const u8,
};

/// Kilit dosyası (`nox.lock`, `nox.json`nin YANINDA, VCS'e commit EDİLİR
/// — bkz. plan dosyası §5). `build`/`run`/`test`, VARSA lock'taki
/// `resolved` SHA'sını KULLANMAK ZORUNDADIR (asla sessizce bir branch
/// ref'i HER derlemede yeniden çözmez) — TEKRARLANABİLİR derlemenin bütün
/// amacı BU. Bu dosya (P.4) yalnızca ŞEMAYI/ayrıştırmayı/serileştirmeyi
/// tanımlar — GERÇEK `git`-tabanlı çözümleme (lock'u GERÇEKTEN DOLDURAN
/// akış) Faz O §P.5'te gelecek.
pub const Lockfile = struct {
    packages: []const LockedPackage = &.{},
};

pub const LockfileError = error{InvalidLockfile} ||
    std.Io.Dir.ReadFileAllocError ||
    Allocator.Error;

/// Bir `nox.lock` JSON metnini (dosya sistemine HİÇ dokunmadan, saf
/// bellek-içi) ayrıştırır — birim testlerinin GERÇEK dosya sistemi
/// olmadan doğrudan fixture string'lerle çalışabilmesi İÇİN.
pub fn parseLockfile(a: Allocator, source: []const u8) LockfileError!Lockfile {
    const parsed = std.json.parseFromSlice(Lockfile, a, source, .{ .ignore_unknown_fields = true }) catch {
        return error.InvalidLockfile;
    };
    return parsed.value;
}

/// `dir_path` altındaki `nox.lock`ı okuyup ayrıştırır. Dosya HİÇ YOKSA
/// (ör. bir bağımlılık İLK KEZ `requires`e eklenmiş, henüz HİÇ `build`/
/// `fetch` çalıştırılmamış) bu bir HATA DEĞİLDİR — BOŞ bir `Lockfile`
/// döner (`findProjectRoot`ın "manifestsiz de geçerli" ilkesiyle AYNI
/// tutarlılıkta: "henüz kilitlenmemiş" GEÇERLİ bir başlangıç durumudur).
/// Dosya VARSA ama BOZUKSA `error.InvalidLockfile` döner.
pub fn loadLockfile(a: Allocator, io: Io, dir_path: []const u8) LockfileError!Lockfile {
    const lock_path = try std.fmt.allocPrint(a, "{s}/nox.lock", .{dir_path});
    const source = std.Io.Dir.cwd().readFileAlloc(io, lock_path, a, .limited(1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => return Lockfile{},
        else => |err| return err,
    };
    return parseLockfile(a, source);
}

/// `lock`u `dir_path/nox.lock`a (okunabilir, girintili JSON olarak) yazar
/// — Faz O §P.5'in GERÇEK `git`-tabanlı çözümleme akışı, HER başarılı
/// çözümlemeden SONRA bunu ÇAĞIRACAK.
pub fn saveLockfile(a: Allocator, io: Io, dir_path: []const u8, lock: Lockfile) !void {
    const lock_path = try std.fmt.allocPrint(a, "{s}/nox.lock", .{dir_path});
    const json_text = try std.json.Stringify.valueAlloc(a, lock, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = json_text });
}

/// `lock` İÇİNDE `alias`e karşılık gelen (ÇÖZÜLMÜŞ) girdiyi bulur — Faz O
/// §P.6'nın "bu bağımlılık ZATEN kilitlenmiş mi?" sorusu İÇİN.
pub fn findLocked(lock: Lockfile, alias: []const u8) ?LockedPackage {
    for (lock.packages) |pkg| {
        if (std.mem.eql(u8, pkg.alias, alias)) return pkg;
    }
    return null;
}
