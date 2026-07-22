//! `import nox.http` gibi bir deyimin çözümlenmesi — stdlib fazı §A (bkz.
//! nox-teknik-spesifikasyon.md). Nox'ta HENÜZ ayrı derleme birimi/nesne
//! dosyası bağlama YOK (AGENTS.md'nin "tek derleme birimi" whole-program
//! modeliyle TUTARLI) — bunun yerine, `import` edilen HER stdlib `.nox`
//! dosyası (kendi `import`larını da ÖZYİNELEMELİ olarak çözerek) ayrıştırılıp
//! kullanıcının modülüyle AYNI `ast.Module`a BİRLEŞTİRİLİR.
//!
//! **Ad çakışması önleme (mangling):** stdlib modülünün KENDİ üst-düzey
//! `func_def`/`class_def` adları (yalnızca bunlar — metodlar/parametreler
//! DEĞİL), noktalı içe aktarma yoluyla nitelikli erişimde kullanılacak
//! sembol adına (`nox.http.get` → `nox_http_get`) YENİDEN ADLANDIRILIR —
//! hem TANIM sitesinde hem stdlib dosyasının KENDİ İÇİNDEKİ tüm başvuru
//! sitelerinde (çağrılar, tip ifadeleri — `self: ClassName` DAHİL). Bu,
//! kullanıcının kendi (aynı kısa adlı) bir fonksiyon/sınıf tanımlamasıyla
//! ÇAKIŞMAYI önler (`self.functions`/`self.classes` tek, düz bir ad alanı
//! kullandığından). Çağrı SİTELERİNİN (`nox.http.get(...)`) mangled isme
//! çözümlenmesi BURADA DEĞİL, `checker.zig`'in `tryResolveQualifiedCall`ında
//! yapılır (bkz. onun belge notu) — bu dosya yalnızca stdlib dosyasının
//! KENDİ gövdesini, kendi (kısa) adlarına göre tutarlı kılar.
//!
//! `extern def` YENİDEN ADLANDIRILMAZ (bilinçli): bir `extern def`in adı
//! GERÇEK bir C ABI sembolüne bağlanır (bkz. checker.zig'in `registerExternFunc`
//! belge notu) — mangling bunu bağlantı zamanında ÇÖZÜLEMEZ hale getirirdi.
//! stdlib yazarları extern def'leri ZATEN çakışmasız (ör. `nox_http_shim_get`
//! gibi önekli) adlandırmalıdır — bu bir dil garantisi değil, bir kural.

const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const ast = @import("parser/ast.zig");

pub const LoadError = error{ ModuleNotFound, UnknownImportAlias } || lexer.LexError || parser.ParseError || std.Io.Dir.ReadFileAllocError;

/// `user_module`ün (KENDİSİ hiç değiştirilmez/yeniden adlandırılmaz) `import`
/// deyimlerini (özyinelemeli olarak) çözer; sonuç, çözülen TÜM stdlib
/// bildirimlerinin (yeniden adlandırılmış) `user_module.body`den ÖNCE
/// eklendiği YENİ bir `ast.Module`dır.
///
/// **Stdlib fazı §E:** `stdlib/nox/core.nox` (ör. `ValueError`) HİÇBİR
/// `import` deyimi GEREKMEDEN, HER modüle KOŞULSUZ olarak (MANGLE EDİLMEDEN
/// — `print`/`len` gibi çekirdek yerleşiklerle AYNI "her yerde hazır"
/// statüsü) önce eklenir. Bu yüzden, önceki sürümün AKSİNE, `extra` ARTIK
/// HİÇBİR `import` yokken bile BOŞ DEĞİLDİR — bu fonksiyon eskisi gibi
/// `user_module`ü DEĞİŞTİRMEDEN döndürmez, HER ZAMAN en az `core.nox`u
/// içeren YENİ bir modül döner.
pub fn resolveImports(a: std.mem.Allocator, io: std.Io, user_module: ast.Module) LoadError!ast.Module {
    return resolveImportsImpl(a, io, user_module, null, "stdlib", null);
}

/// Faz Q.3 (bkz. docs/uretim-hazirlik-analizi.md, main.zig'in
/// `resolveResourceDirs`e bağlanması): `resolveImports`in stdlib KÖK
/// DİZİNİ parametreli hali — `noxc`nin KENDİSİ (`main.zig`) `project.
/// resolveResourceDirs`in çözdüğü MUTLAK `stdlib_dir`i geçirir (proje
/// kökünden/CWD'den BAĞIMSIZ çalışabilmek için, ör. sistem geneli bir
/// kurulumdan). `resolveImports`ın KENDİSİ (İMZASI ASLA DEĞİŞTİRİLMEYEN,
/// bkz. modül üstü not — golden testler CWD'si HER ZAMAN proje kökü
/// olduğundan sabit `"stdlib"` göreli kökünü kullanmaya DEVAM eder)
/// DEĞİŞMEDEN bu fonksiyonun `stdlib_root = "stdlib"` özel durumudur.
pub fn resolveImportsFrom(a: std.mem.Allocator, io: std.Io, user_module: ast.Module, stdlib_root: []const u8) LoadError!ast.Module {
    return resolveImportsImpl(a, io, user_module, null, stdlib_root, null);
}

/// Faz O §P.6 (bkz. plan dosyası "Faz O" bölümü, nox-teknik-spesifikasyon.md
/// §3.6): `resolveImports`in EK (imzası ASLA DEĞİŞTİRİLMEYEN, bkz. modül
/// üstü not) bir GENİŞLEMESİ — `alias_roots` (bir üçüncü-taraf `requires[]`
/// alias'ının KENDİ ÇÖZÜLMÜŞ önbellek dizinine eşlenmesi, main.zig'in
/// `resolveImportsForBuild`i TARAFINDAN `nox.json` bulunduğunda inşa edilir)
/// VERİLDİĞİNDE, `import somepkg.util` gibi bir deyimin İLK segmenti
/// (`"somepkg"`) `"nox"` OLMAYIP `alias_roots`ta eşleşiyorsa, dosya
/// `<stdlib_root>/{yol}.nox` YERİNE `<alias_roots["somepkg"]>/{kalan-yol}.nox`dan
/// okunur — GERİ KALAN HER ŞEY (özyineleme, mangling, `core.nox` önceliği)
/// `resolveImports` İLE BİREBİR AYNI kalır. İlk segment `"nox"` DEĞİLSE VE
/// `alias_roots`ta da YOKSA `error.UnknownImportAlias` döner (`resolveImports`ın
/// KENDİSİ hiçbir zaman bu hatayı üretmez — `alias_roots == null` olduğunda
/// HER ZAMAN eski `error.ModuleNotFound` yoluna düşülür, bkz. `loadImportsRecursive`).
/// **`stdlib_root` (Faz Q.3'te eklendi):** `resolveImportsFrom` İLE AYNI
/// gerekçeyle — `noxc`nin KENDİ çözülmüş stdlib dizinini geçirmesi için.
/// Faz U.1'in `alias_roots`ından SONRA eklenen ÜÇÜNCÜ (isteğe bağlı) çözümleme
/// katmanı: `project_root` (main.zig'in `resolveImportsForBuild`ı TARAFINDAN
/// `nox.json` bulunduğunda geçirilen, MUTLAK proje kökü) VERİLDİĞİNDE, İLK
/// segmenti `"nox"` OLMAYAN VE HİÇBİR `alias_roots` GİRDİSİYLE eşleşmeyen bir
/// import, `<project_root>/{yol}.nox`da ARANIR — bu, KULLANICININ KENDİ
/// projesini `requires[]`e HİÇ İHTİYAÇ DUYMADAN birden çok dosyaya
/// bölebilmesini sağlar (`import helpers` → `<proje kökü>/helpers.nox`,
/// `import utils.strings` → `<proje kökü>/utils/strings.nox`). Öncelik SIRASI
/// BİLİNÇLİDİR: `"nox"` (stdlib, HER ZAMAN rezerve) → `requires[]` alias'ı
/// (AÇIKÇA `nox.json`da BİLDİRİLMİŞ, "açık örtükten iyidir") → proje-içi
/// dosya (ÖRTÜK, yalnızca YUKARIDAKİ İKİSİ eşleşmezse denenir). `alias_roots
/// == null` OLAN (`resolveImports`/`resolveImportsFrom`, İMZALARI DONDURULMUŞ)
/// çağrılarda bu katman HİÇ DEVREYE GİRMEZ (manifestsiz kullanım TEK dosyalı
/// KALIR — proje-içi çoklu-dosya importu bir `nox.json` GEREKTİRİR, Cargo/
/// Go modüllerinin AYNI ön koşuluyla TUTARLI).
pub fn resolveProjectImports(
    a: std.mem.Allocator,
    io: std.Io,
    user_module: ast.Module,
    alias_roots: std.StringHashMapUnmanaged([]const u8),
    stdlib_root: []const u8,
    project_root: ?[]const u8,
) LoadError!ast.Module {
    return resolveImportsImpl(a, io, user_module, &alias_roots, stdlib_root, project_root);
}

fn resolveImportsImpl(
    a: std.mem.Allocator,
    io: std.Io,
    user_module: ast.Module,
    alias_roots: ?*const std.StringHashMapUnmanaged([]const u8),
    stdlib_root: []const u8,
    project_root: ?[]const u8,
) LoadError!ast.Module {
    var loaded: std.StringHashMapUnmanaged(void) = .empty;
    var extra: std.ArrayListUnmanaged(ast.Stmt) = .empty;

    const core_path = try std.fmt.allocPrint(a, "{s}/nox/core.nox", .{stdlib_root});
    const core_source = try std.Io.Dir.cwd().readFileAlloc(io, core_path, a, .limited(1024 * 1024));
    const core_tokens = try lexer.tokenize(a, core_source);
    const core_module = try parser.parseModule(a, core_tokens);
    try extra.appendSlice(a, core_module.body);

    try loadImportsRecursive(a, io, user_module.body, &loaded, &extra, alias_roots, stdlib_root, project_root);

    const combined = try a.alloc(ast.Stmt, extra.items.len + user_module.body.len);
    @memcpy(combined[0..extra.items.len], extra.items);
    @memcpy(combined[extra.items.len..], user_module.body);
    return .{ .body = combined };
}

fn fileExistsAbsolute(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| return true else |_| return false;
}

fn loadImportsRecursive(
    a: std.mem.Allocator,
    io: std.Io,
    stmts: []const ast.Stmt,
    loaded: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(ast.Stmt),
    alias_roots: ?*const std.StringHashMapUnmanaged([]const u8),
    stdlib_root: []const u8,
    project_root: ?[]const u8,
) LoadError!void {
    for (stmts) |stmt| {
        // Faz U.3: `from X.Y import foo` DA `import X.Y`İLE AYNI dosya
        // çözümlemesini tetikler — YALNIZCA `segments` (modül YOLU) İLGİLİDİR,
        // `.from_import_stmt`in `names`i (YEREL takma adlar) checker'ın
        // ilgisidir, bu dosyanın DEĞİL.
        const segments: []const []const u8 = switch (stmt.kind) {
            .import_stmt => |imp| imp.segments,
            .from_import_stmt => |fi| fi.segments,
            else => continue,
        };

        const joined_dot = try joinWith(a, segments, '.');
        if (loaded.contains(joined_dot)) continue;
        try loaded.put(a, joined_dot, {});

        // **Kritik davranış korunumu:** `alias_roots == null` OLDUĞUNDA
        // (yani `resolveImports`ın KENDİSİ çağrıldığında) bu dal HİÇ
        // ÇALIŞMAZ — davranış, imzası DONDURULMUŞ `resolveImports`ın ESKİ
        // (P.6'dan ÖNCEKİ) haliyle BİREBİR aynı kalır: İLK segment ne
        // OLURSA olsun HER ZAMAN `stdlib/{yol}.nox` denenir, bulunamazsa
        // (eskisi gibi) `error.ModuleNotFound`. `alias_roots` VERİLDİĞİNDE
        // (yalnızca `resolveProjectImports`) VE ilk segment `"nox"`
        // DEĞİLSE, ÖNCE alias haritasına, SONRA (Faz U.2) `project_root`a
        // bakılır — bkz. `resolveProjectImports`in belge notu.
        const is_nox_stdlib = segments.len == 0 or std.mem.eql(u8, segments[0], "nox");
        const file_path = blk: {
            if (alias_roots) |roots| {
                if (!is_nox_stdlib) {
                    if (roots.get(segments[0])) |root| {
                        const rest = try joinWith(a, segments[1..], '/');
                        break :blk try std.fmt.allocPrint(a, "{s}/{s}.nox", .{ root, rest });
                    }
                    if (project_root) |proot| {
                        const rel_path = try joinWith(a, segments, '/');
                        const candidate = try std.fmt.allocPrint(a, "{s}/{s}.nox", .{ proot, rel_path });
                        if (fileExistsAbsolute(io, candidate)) break :blk candidate;
                    }
                    return error.UnknownImportAlias;
                }
            }
            const rel_path = try joinWith(a, segments, '/');
            break :blk try std.fmt.allocPrint(a, "{s}/{s}.nox", .{ stdlib_root, rel_path });
        };

        // ÖNEMLİ: `source` ARENA (`a`) üzerinden tahsis edilir ve HİÇBİR ZAMAN
        // erken serbest bırakılmaz — ayrıştırılan AST'nin tanımlayıcı/dizge
        // dilimleri (lexeme'ler) DOĞRUDAN bu arabelleğin İÇİNE işaret eder
        // (bkz. lexer.zig'in token temsili). `gpa` gibi ayrı bir kısa ömürlü
        // allocator'la okuyup erken `free` etmek, AST tüm derleme boyunca
        // KULLANILMAYA DEVAM EDERKEN bu belleği serbest bırakır — sallanan
        // işaretçi (use-after-free) ile sonuçlanır (ör. `registerFunc`de
        // "bilinmeyen tip: <çöp baytlar>" gibi bozuk hatalar).
        const source = std.Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(1024 * 1024)) catch |e| switch (e) {
            error.FileNotFound => return error.ModuleNotFound,
            else => return e,
        };

        const tokens = try lexer.tokenize(a, source);
        const stdlib_module = try parser.parseModule(a, tokens);

        // ÖNCE bu stdlib modülünün KENDİ import'larını özyinelemeli çöz
        // (transitif — bir stdlib modülü başka bir stdlib modülünü import
        // edebilir).
        try loadImportsRecursive(a, io, stdlib_module.body, loaded, out, alias_roots, stdlib_root, project_root);

        // Bu modülün KENDİ üst-düzey `func_def`/`class_def` adlarını topla.
        var rename_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (stdlib_module.body) |s| {
            switch (s.kind) {
                .func_def => |fd| try rename_map.put(a, fd.name, try mangleWith(a, segments, fd.name)),
                .class_def => |cd| try rename_map.put(a, cd.name, try mangleWith(a, segments, cd.name)),
                else => {},
            }
        }

        // Şimdi TÜM üst-düzey deyimlerini (kendi `import`ları DAHİL — bu
        // deyimlerin `checker.zig`nin `imported_modules` kümesine girmesi
        // GEREKİR ki bu modülün İÇİNDEKİ nitelikli çağrılar da çözülebilsin)
        // yeniden adlandırarak `out`a ekle.
        for (stdlib_module.body) |s| {
            try out.append(a, try renameStmt(a, s, &rename_map));
        }
    }
}

fn joinWith(a: std.mem.Allocator, segments: []const []const u8, sep: u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (segments, 0..) |seg, i| {
        if (i != 0) try buf.append(a, sep);
        try buf.appendSlice(a, seg);
    }
    return buf.toOwnedSlice(a);
}

fn mangleWith(a: std.mem.Allocator, segments: []const []const u8, name: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (segments) |seg| {
        try buf.appendSlice(a, seg);
        try buf.append(a, '_');
    }
    try buf.appendSlice(a, name);
    return buf.toOwnedSlice(a);
}

const RenameMap = std.StringHashMapUnmanaged([]const u8);

fn renameTypeExpr(a: std.mem.Allocator, te: ast.TypeExpr, map: *const RenameMap) std.mem.Allocator.Error!ast.TypeExpr {
    return switch (te) {
        .simple => |name| if (map.get(name)) |mangled| .{ .simple = mangled } else te,
        .generic => |g| blk: {
            const args = try a.alloc(ast.TypeExpr, g.args.len);
            for (g.args, 0..) |arg, i| args[i] = try renameTypeExpr(a, arg, map);
            break :blk .{ .generic = .{ .name = g.name, .args = args } };
        },
        // Faz U.4: içindeki tip ifadelerinde (parametreler/dönüş) sınıf adı
        // yeniden adlandırması GEREKEBİLİR (`.simple`/`.generic` İLE AYNI
        // gerekçe) — bir stdlib modülünün fonksiyon tipi imzasında KENDİ
        // sınıflarından birine başvurması olası bir senaryodur.
        .func_type => |ft| blk: {
            const params = try a.alloc(ast.TypeExpr, ft.params.len);
            for (ft.params, 0..) |p, i| params[i] = try renameTypeExpr(a, p, map);
            const ret = try a.create(ast.TypeExpr);
            ret.* = try renameTypeExpr(a, ft.return_type.*, map);
            break :blk .{ .func_type = .{ .params = params, .return_type = ret } };
        },
        // Faz FF.6: `T | None` — içindeki taban tipte de sınıf adı
        // yeniden adlandırması GEREKEBİLİR (`.func_type` İLE AYNI gerekçe).
        .optional => |inner| blk: {
            const boxed = try a.create(ast.TypeExpr);
            boxed.* = try renameTypeExpr(a, inner.*, map);
            break :blk .{ .optional = boxed };
        },
    };
}

fn renameExprBox(a: std.mem.Allocator, e: ast.Expr, map: *const RenameMap) std.mem.Allocator.Error!*ast.Expr {
    const p = try a.create(ast.Expr);
    p.* = try renameExpr(a, e, map);
    return p;
}

fn renameExpr(a: std.mem.Allocator, e: ast.Expr, map: *const RenameMap) std.mem.Allocator.Error!ast.Expr {
    return switch (e) {
        .identifier => |name| if (map.get(name)) |mangled| .{ .identifier = mangled } else e,
        .unary => |u| .{ .unary = .{ .op = u.op, .operand = try renameExprBox(a, u.operand.*, map) } },
        .binary => |b| .{ .binary = .{ .op = b.op, .left = try renameExprBox(a, b.left.*, map), .right = try renameExprBox(a, b.right.*, map) } },
        .call => |c| blk: {
            const args = try a.alloc(ast.Expr, c.args.len);
            for (c.args, 0..) |arg, i| args[i] = try renameExpr(a, arg, map);
            break :blk .{ .call = .{ .callee = try renameExprBox(a, c.callee.*, map), .args = args } };
        },
        // `a.attr` (bir metod/alan ADI) hiçbir zaman yeniden adlandırılmaz —
        // yalnızca TABAN ifadesindeki (`a.obj`) olası bir üst-düzey isim
        // başvurusu yeniden adlandırılabilir.
        .attribute => |at| .{ .attribute = .{ .obj = try renameExprBox(a, at.obj.*, map), .attr = at.attr } },
        .index => |idx| .{ .index = .{ .obj = try renameExprBox(a, idx.obj.*, map), .index = try renameExprBox(a, idx.index.*, map) } },
        .list_lit => |elems| blk: {
            const out = try a.alloc(ast.Expr, elems.len);
            for (elems, 0..) |el, i| out[i] = try renameExpr(a, el, map);
            break :blk .{ .list_lit = out };
        },
        .dict_lit => |pairs| blk: {
            const out = try a.alloc(ast.DictPair, pairs.len);
            for (pairs, 0..) |p, i| out[i] = .{ .key = try renameExpr(a, p.key, map), .value = try renameExpr(a, p.value, map) };
            break :blk .{ .dict_lit = out };
        },
        .await_expr => |op| .{ .await_expr = try renameExprBox(a, op.*, map) },
        .spawn_expr => |op| .{ .spawn_expr = try renameExprBox(a, op.*, map) },
        .generic_construct => |g| blk: {
            const args = try a.alloc(ast.Expr, g.args.len);
            for (g.args, 0..) |arg, i| args[i] = try renameExpr(a, arg, map);
            const type_args = try a.alloc(ast.TypeExpr, g.type_args.len);
            for (g.type_args, 0..) |ta, i| type_args[i] = try renameTypeExpr(a, ta, map);
            break :blk .{ .generic_construct = .{ .name = g.name, .type_args = type_args, .args = args } };
        },
        .int_lit, .float_lit, .bool_lit, .string_lit, .none_lit => e,
    };
}

fn renameStmts(a: std.mem.Allocator, stmts: []const ast.Stmt, map: *const RenameMap) std.mem.Allocator.Error![]ast.Stmt {
    const out = try a.alloc(ast.Stmt, stmts.len);
    for (stmts, 0..) |s, i| out[i] = try renameStmt(a, s, map);
    return out;
}

/// Metod gövdeleri İÇİN: metodun KENDİ adı (`m.name`) hiçbir zaman yeniden
/// adlandırılmaz (metodlar `map`e hiç GİRMEZ — yalnızca üst-düzey `func_def`/
/// `class_def` adları girer) — ama `self: ClassName` DAHİL parametre/dönüş
/// tip ifadeleri VE gövde YENİDEN adlandırılır (bkz. modül üstü not).
fn renameMethodDef(a: std.mem.Allocator, m: ast.FuncDef, map: *const RenameMap) std.mem.Allocator.Error!ast.FuncDef {
    const params = try a.alloc(ast.Param, m.params.len);
    for (m.params, 0..) |p, i| params[i] = .{ .name = p.name, .type_expr = try renameTypeExpr(a, p.type_expr, map), .self_inferred = p.self_inferred };
    return .{
        .name = m.name,
        .type_params = m.type_params,
        .params = params,
        .return_type = try renameTypeExpr(a, m.return_type, map),
        .body = try renameStmts(a, m.body, map),
        .is_async = m.is_async,
    };
}

/// Üst-düzey `func_def`ler İÇİN: `fd.name`in KENDİSİ de `map`den mangled
/// isme çevrilir (bu fonksiyon yalnızca `map`de ZATEN kayıtlı olduğu bilinen
/// üst-düzey tanımlar için çağrılır — bkz. `loadImportsRecursive`).
fn renameTopLevelFuncDef(a: std.mem.Allocator, fd: ast.FuncDef, map: *const RenameMap) std.mem.Allocator.Error!ast.FuncDef {
    const params = try a.alloc(ast.Param, fd.params.len);
    for (fd.params, 0..) |p, i| params[i] = .{ .name = p.name, .type_expr = try renameTypeExpr(a, p.type_expr, map) };
    return .{
        .name = map.get(fd.name).?,
        .type_params = fd.type_params,
        .params = params,
        .return_type = try renameTypeExpr(a, fd.return_type, map),
        .body = try renameStmts(a, fd.body, map),
        .is_async = fd.is_async,
    };
}

/// Faz U.4.2: İÇ İÇE (nested) `func_def`ler İÇİN — `renameTopLevelFuncDef`nin
/// AKSİNE, `fd.name`in KENDİSİ `map`de KAYITLI DEĞİLDİR (yalnızca üst-düzey
/// `func_def`/`class_def` adları kaydedilir, bkz. `loadImportsRecursive`)
/// VE olmamalıdır — iç içe bir fonksiyonun adı DIŞ kapsama YEREL bir
/// değişken bağlar (Faz U.4.2), qualified-call mangling'in KONUSU DEĞİLDİR.
/// `renameStmt`in `.func_def` dalı, `fd.name`in `map`de olup OLMADIĞINA
/// bakarak bu iki fonksiyon arasında dispatch eder.
fn renameNestedFuncDef(a: std.mem.Allocator, fd: ast.FuncDef, map: *const RenameMap) std.mem.Allocator.Error!ast.FuncDef {
    const params = try a.alloc(ast.Param, fd.params.len);
    for (fd.params, 0..) |p, i| params[i] = .{ .name = p.name, .type_expr = try renameTypeExpr(a, p.type_expr, map) };
    return .{
        .name = fd.name,
        .type_params = fd.type_params,
        .params = params,
        .return_type = try renameTypeExpr(a, fd.return_type, map),
        .body = try renameStmts(a, fd.body, map),
        .is_async = fd.is_async,
    };
}

/// Faz FF.5 (bkz. nox-teknik-spesifikasyon.md §3.64): `renameMethodDef`nin
/// AYNI "tip ifadesi DAHİL yeniden adlandır" deseni — AÇIKÇA bildirilen bir
/// sınıf alanının tipi BAŞKA (`import`la GELEN, mangled) bir sınıfa
/// başvurabilir, bu yüzden `renameTypeExpr` BURADA da ÇAĞRILMALIDIR.
/// GÜNCELLENMEZSE (bkz. modül üstü not, "self: ClassName DAHİL... YENİDEN
/// adlandırılır"), `import nox.X` üzerinden GELEN alan bildirimleri
/// SESSİZCE DÜŞERDİ (dosya HÂLÂ derlenirdi — yalnızca o alan çıkarım-only
/// semantiğe geri dönerdi).
fn renameFieldDecls(a: std.mem.Allocator, fields: []const ast.FieldDecl, map: *const RenameMap) std.mem.Allocator.Error![]ast.FieldDecl {
    const out = try a.alloc(ast.FieldDecl, fields.len);
    for (fields, 0..) |fd, i| out[i] = .{ .name = fd.name, .type_expr = try renameTypeExpr(a, fd.type_expr, map) };
    return out;
}

fn renameStmt(a: std.mem.Allocator, s: ast.Stmt, map: *const RenameMap) std.mem.Allocator.Error!ast.Stmt {
    const kind: ast.StmtKind = switch (s.kind) {
        .expr_stmt => |e| .{ .expr_stmt = try renameExpr(a, e, map) },
        .var_decl => |v| .{ .var_decl = .{ .name = v.name, .type_expr = try renameTypeExpr(a, v.type_expr, map), .value = try renameExpr(a, v.value, map) } },
        .assign => |asg| .{ .assign = .{ .target = try renameExpr(a, asg.target, map), .value = try renameExpr(a, asg.value, map) } },
        .if_stmt => |f| blk: {
            const elifs = try a.alloc(ast.ElifClause, f.elif_clauses.len);
            for (f.elif_clauses, 0..) |ec, i| elifs[i] = .{ .cond = try renameExpr(a, ec.cond, map), .body = try renameStmts(a, ec.body, map) };
            break :blk .{ .if_stmt = .{
                .cond = try renameExpr(a, f.cond, map),
                .then_body = try renameStmts(a, f.then_body, map),
                .elif_clauses = elifs,
                .else_body = if (f.else_body) |eb| try renameStmts(a, eb, map) else null,
            } };
        },
        .while_stmt => |w| .{ .while_stmt = .{ .cond = try renameExpr(a, w.cond, map), .body = try renameStmts(a, w.body, map) } },
        .for_stmt => |f| .{ .for_stmt = .{ .var_name = f.var_name, .iterable = try renameExpr(a, f.iterable, map), .body = try renameStmts(a, f.body, map) } },
        // Faz U.4.2: `fd.name`in `map`de olup OLMAMASI, bu deyimin ÜST-DÜZEY
        // (mangled edilmeli) mi YOKSA İÇ İÇE/nested (mangled EDİLMEMELİ,
        // bkz. `renameNestedFuncDef`in belge notu) bir `func_def` mi
        // OLDUĞUNU AYIRT EDER.
        .func_def => |fd| if (map.contains(fd.name))
            .{ .func_def = try renameTopLevelFuncDef(a, fd, map) }
        else
            .{ .func_def = try renameNestedFuncDef(a, fd, map) },
        .class_def => |cd| blk: {
            const methods = try a.alloc(ast.FuncDef, cd.methods.len);
            for (cd.methods, 0..) |m, i| methods[i] = try renameMethodDef(a, m, map);
            const fields = try renameFieldDecls(a, cd.fields, map);
            break :blk .{ .class_def = .{ .name = map.get(cd.name).?, .methods = methods, .fields = fields } };
        },
        .protocol_def => |pd| blk: {
            const methods = try a.alloc(ast.FuncDef, pd.methods.len);
            for (pd.methods, 0..) |m, i| methods[i] = try renameMethodDef(a, m, map);
            break :blk .{ .protocol_def = .{ .name = pd.name, .methods = methods } };
        },
        // Bilinçli DEĞİŞMEZ — bkz. modül üstü not ("extern def YENİDEN
        // ADLANDIRILMAZ").
        .extern_def => return s,
        .return_stmt => |r| .{ .return_stmt = if (r) |e| try renameExpr(a, e, map) else null },
        .raise_stmt => |e| .{ .raise_stmt = try renameExpr(a, e, map) },
        .try_stmt => |t| blk: {
            const ecs = try a.alloc(ast.ExceptClause, t.except_clauses.len);
            for (t.except_clauses, 0..) |ec, i| ecs[i] = .{
                .class_name = map.get(ec.class_name) orelse ec.class_name,
                .bind_name = ec.bind_name,
                .body = try renameStmts(a, ec.body, map),
            };
            break :blk .{ .try_stmt = .{
                .try_body = try renameStmts(a, t.try_body, map),
                .except_clauses = ecs,
                .finally_body = if (t.finally_body) |fb| try renameStmts(a, fb, map) else null,
            } };
        },
        .lowlevel_stmt => |ll| .{ .lowlevel_stmt = .{ .body = try renameStmts(a, ll.body, map) } },
        // Bir stdlib modülünün KENDİ `import`u — segmentler stdlib DOSYA
        // YOLUdur, Nox bildirim adı DEĞİLDİR; yeniden adlandırmaya gerek yok.
        // (Zaten `loadImportsRecursive` tarafından AYRICA işlenir.)
        .import_stmt => return s,
        // Faz U.3: `.import_stmt` İLE AYNI gerekçe — `from ... import`ın
        // `segments`i de bir DOSYA YOLUdur, `names`teki üye adları YEREL
        // takma adlardır (Nox bildirim adları DEĞİL) — yeniden adlandırmaya
        // gerek yok.
        .from_import_stmt => return s,
        .pass_stmt => return s,
        .with_stmt => |w| .{ .with_stmt = .{
            .ctx_expr = try renameExpr(a, w.ctx_expr, map),
            .binding = w.binding,
            .body = try renameStmts(a, w.body, map),
        } },
        .defer_stmt => |d| blk: {
            const renamed = try renameExpr(a, .{ .call = d.call }, map);
            break :blk .{ .defer_stmt = .{ .call = renamed.call } };
        },
    };
    return .{ .kind = kind, .line = s.line };
}
