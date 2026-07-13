//! Nox HPy köprüsü — modül yükleyici (AGENTS.md §10, Tier 0'ın "modül init"
//! parçası). Gerçek, `HPY_ABI_UNIVERSAL` modunda derlenmiş bir paylaşımlı
//! kütüphaneyi (`.so`/`.dylib`) `dlopen` ile yükler, giriş noktasını
//! (`HPyInit_<ad>`) çağırıp döndürülen `HPyModuleDef`i yorumlar ve
//! `HPyDef_Kind_Meth` (yalnızca `HPyFunc_O` imzası) girdilerini
//! çağrılabilir hale getirir.
//!
//! **Kapsam:** yalnızca `HPyFunc_O` (tek argümanlı, `fn(ctx, self, arg) ->
//! HPy`) imzalı metodlar desteklenir — Tier 0'ın "temel tip objesi
//! protokolü" için yeterli, minimal bir dilim. Diğer imzalar
//! (`HPyFunc_VARARGS`/`KEYWORDS`/...), slot'lar (`HPyDef_Kind_Slot` — özel
//! tip davranışları), üye/getset tanımları ve `HPyType_FromSpec` yoluyla
//! özel tip tanımlama henüz desteklenmiyor (bkz. nox-teknik-
//! spesifikasyon.md §3.12, bilinen sınırlamalar).
//!
//! Yapılar (`HPyModuleDef`/`HPyDef`/`HPyMeth`), gerçek HPy header'larından
//! (`hpy/devel/include/hpy/hpydef.h`, `hpy/devel/include/hpy/hpymodule.h`)
//! bayt-uyumlu olacak şekilde elle transkribe edilmiştir — bkz.
//! `context.zig`nin modül üstü notundaki aynı ABI-uyumluluk gerekçesi.
//! Doğrulama: `scripts/gen_hpy_ctx.py`nin yanında elle yazılan bir C
//! `offsetof` betiğiyle (bkz. Faz 12 oturum notları) her alanın ofseti
//! gerçek derleyici çıktısıyla bire bir karşılaştırıldı.

const std = @import("std");
const context = @import("context.zig");
pub const HPyContext = context.HPyContext;
pub const HPy = context.HPy;

pub const HPyMeth = extern struct {
    name: ?[*:0]const u8 = null,
    impl: ?*const anyopaque = null,
    cpy_trampoline: ?*const anyopaque = null,
    signature: c_int = 0,
    doc: ?[*:0]const u8 = null,
};

pub const HPyDefKind = enum(c_int) {
    slot = 1,
    meth = 2,
    member = 3,
    getset = 4,
};

pub const HPyFuncSignature = enum(c_int) {
    varargs = 1,
    keywords = 2,
    noargs = 3,
    o = 4,
    _,
};

/// C tarafındaki `union { HPySlot slot; HPyMeth meth; HPyMember member;
/// HPyGetSet getset; }`in bayt-uyumlu bir temsili — yalnızca `.meth` kolu
/// gerçekten yorumlanır (Tier 0 kapsamı), ama birliğin GERÇEK boyutuna
/// (64 bayt, `kind` dahil) uyması için sonda dolgu bulunur.
pub const HPyDef = extern struct {
    kind: c_int = 0,
    meth: HPyMeth = .{},
    _pad_tail: [16]u8 = undefined,
};

pub const HPyModuleDef = extern struct {
    doc: ?[*:0]const u8 = null,
    size: isize = 0,
    legacy_methods: ?*anyopaque = null,
    defines: ?[*:null]const ?*const HPyDef = null,
    globals: ?*anyopaque = null,
};

const InitFn = *const fn () callconv(.c) ?*const HPyModuleDef;
const MethO = *const fn (ctx: *HPyContext, self: HPy, arg: HPy) callconv(.c) HPy;

pub const LoadedModule = struct {
    lib: std.DynLib,
    def: *const HPyModuleDef,

    pub fn deinit(self: *LoadedModule) void {
        self.lib.close();
    }

    /// `HPyDef_Kind_Meth` VE `HPyFunc_O` imzalı, adı `name` olan ilk metodu
    /// bulur. Bulunamazsa ya da imza `HPyFunc_O` değilse `null` döner.
    pub fn findMethodO(self: *const LoadedModule, name: []const u8) ?MethO {
        const defines = self.def.defines orelse return null;
        var i: usize = 0;
        while (defines[i]) |d| : (i += 1) {
            if (d.kind != @intFromEnum(HPyDefKind.meth)) continue;
            const meth_name = d.meth.name orelse continue;
            if (!std.mem.eql(u8, std.mem.sliceTo(meth_name, 0), name)) continue;
            if (d.meth.signature != @intFromEnum(HPyFuncSignature.o)) return null;
            const impl = d.meth.impl orelse return null;
            return @ptrCast(@alignCast(impl));
        }
        return null;
    }
};

/// `so_path`teki paylaşımlı kütüphaneyi yükler ve `HPyInit_<ext_name>`
/// giriş noktasını çağırır. Döndürülen `LoadedModule.deinit()` ile
/// kapatılmalıdır.
pub fn load(so_path: []const u8, ext_name: []const u8) !LoadedModule {
    var lib = try std.DynLib.open(so_path);
    errdefer lib.close();

    var symbol_buf: [256]u8 = undefined;
    const symbol_name = try std.fmt.bufPrintZ(&symbol_buf, "HPyInit_{s}", .{ext_name});

    const init_fn = lib.lookup(InitFn, symbol_name) orelse return error.EntryPointNotFound;
    const def = init_fn() orelse return error.ModuleInitFailed;
    return .{ .lib = lib, .def = def };
}
