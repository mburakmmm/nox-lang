//! `nox.http.serve_tls` — sunucu-tarafı TLS terminasyonu, OpenSSL/BoringSSL
//! `libssl`ine ÇALIŞMA ZAMANINDA (`std.DynLib`, TEMBEL) BAĞLANARAK. Bkz.
//! plan dosyası "Sunucu-tarafı TLS terminasyonu (OpenSSL FFI) + WebSocket
//! Upgrade — nox.http.serve".
//!
//! **NEDEN OpenSSL (Zig'in KENDİ `std.crypto.tls`i DEĞİL):** `nox.tls`
//! (istemci, `tls.zig`) Zig'in KENDİ `std.crypto.tls.Client`ını kullanır —
//! ama bu Zig sürümünün (0.16.0) std kütüphanesinde `std.crypto.tls.Server`
//! (`std/crypto/tls/` altında yalnızca `Client.zig` VAR, `Server.zig` YOK)
//! HENÜZ YOK — bu `tls.zig`nin KENDİ modül üstü notunda ZATEN belgeli.
//! Kullanıcı BİLEREK sıfırdan bir TLS handshake YAZMAK yerine `sqlite.zig`/
//! `postgres.zig`/`mysql.zig` İLE AYNI dlopen-FFI desenini TERCİH etti.
//!
//! **Bellek-BIO tasarımı (`SSL_set_fd` DEĞİL):** OpenSSL'e ham fd'nin
//! KENDİSİ VERİLMEZ — bunun yerine `BIO_s_mem()` İLE İKİ bellek-BIO'su
//! (okuma/yazma) OpenSSL'e `SSL_set_bio` İLE bağlanır; GERÇEK soket G/Ç'si
//! HER ZAMAN `http_server.zig`nin KENDİ fiber-farkında `rawRead`/
//! `rawWriteAll`INE denk gelen (bu dosyada YİNELENEN, `http_server.zig`
//! İLE ÇAPRAZ-İMPORT OLMADAN, DİĞER shim dosyalarıyla AYNI "her dosya
//! kendi ham G/Ç yardımcısını taşır" kuralına UYAN) fonksiyonlardan geçer.
//! Bu SAYEDE OpenSSL, fiber zamanlama/timeout MANTIĞIMIZIN TAMAMEN
//! DIŞINDA, YALNIZCA kriptografik dönüşümü yapar.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const io_mod = @import("../async_rt/io.zig");
const scheduler_mod = @import("../async_rt/scheduler.zig");

/// **GERÇEK, ÇALIŞMA-ZAMANINDA bulunan hata (macOS):** ÖNCEDEN bu liste
/// BARE isimleri (`"libssl.3.dylib"`/`"libssl.dylib"`) İLK sırada
/// deniyordu — bu, macOS'un KENDİ dyld PAYLAŞILAN ÖNBELLEĞİNDEKİ (disk
/// üzerinde AYRI bir dosyası OLMAYAN) sahte bir "libssl" saplamasıyla
/// (Apple, sistemden OpenSSL'i KALDIRDIĞINDAN, bu isimlerle dlopen eden
/// UYGULAMALARI BİLEREK KIRMAK İçİn tuttuğu bir tuzak) EŞLEŞTİ:
/// `dlopen()`ın KENDİSİ BAŞARILI dönüyor AMA yüklenen kütüphanenin
/// KENDİ ObjC/C++ İLKLENDİRİCİSİ "... is loading libcrypto in an unsafe
/// way" YAZIP `abort()` ÇAĞIRIYORDU — TÜM sürecin ÇÖKMESİNE yol AÇAN,
/// `openLib`in KENDİ "sıradaki adayı dene" mantığının HİÇ YAKALAYAMADIĞI
/// bir SIGABRT (dlopen BAŞARISIZ dönmüyor, İÇERİDEKİ kütüphanenin KENDİSİ
/// süreci ÖLDÜRÜYOR). GERÇEK bir `serve_tls` çalıştırmasıyla (`lldb`
/// backtrace'i `libssl.dylib`__report_load`ı GÖSTERDİ) YAKALANDI. Düzeltme:
/// macOS'ta BARE isimler ARTIK HİÇ denenmiyor — YALNIZCA Homebrew'nin
/// (arm64/Intel) VE MacPorts'un MUTLAK yolları (`NOX_OPENSSL_LIB` YOKSA)
/// denenir; bunların HİÇBİRİ dyld'in sahte önbellek girdisiyle
/// ÇAKIŞMAZ (dlopen bir MUTLAK yol VERİLDİĞİNDE dyld'in "sistemin bare
/// isim arama" YOLUNU ASLA KULLANMAZ).
fn libraryCandidates() []const [:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{
            "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib",
            "/usr/local/opt/openssl@3/lib/libssl.3.dylib",
            "/opt/local/lib/libssl.dylib",
        },
        .windows => &.{
            "libssl-3-x64.dll",
            "libssl-1_1-x64.dll",
        },
        else => &.{ "libssl.so.3", "libssl.so.1.1" },
    };
}

const Kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetLastError() callconv(.c) u32;
} else struct {};

const LibHandle = if (builtin.os.tag == .windows) ?*anyopaque else std.DynLib;

/// `NOX_OPENSSL_LIB` — kullanıcının KENDİ libssl yolunu (ör. keg-only bir
/// Homebrew kurulumunda bare-isim adaylarının HİÇBİRİ bulunamazsa) BELİRTMESİ
/// İçİn bir kaçış kapısı. Bulunursa DİĞER TÜM adaylardan ÖNCE denenir.
///
/// **NOT (`v1.22.5`+):** her BAŞARISIZ deneme ARTIK stderr'e TEK satırlık
/// bir tanı BASAR (Windows'ta `GetLastError()` DAHİL) — bu, GERÇEK bir
/// Windows CI çalıştırmasında `libssl-3-x64.dll`/`libcrypto-3-x64.dll`
/// HER İKİSİ de DİSKTE doğrulanmış OLDUĞU HALDE `ensureLoaded()`nin YİNE
/// DE başarısız OLDUĞU bir durumu (HANGİ adımın – `LoadLibraryA`nın
/// KENDİSİ mi, yoksa SONRAKİ bir `GetProcAddress` sembol araması mı –
/// başarısız olduğunu ayırt EDEMEDİĞİMİZ) teşhis ETMEK İçİn EKLENDİ.
fn openLib() ?LibHandle {
    if (std.c.getenv("NOX_OPENSSL_LIB")) |override_path| {
        if (builtin.os.tag == .windows) {
            if (Kernel32.LoadLibraryA(override_path)) |h| return h;
            std.debug.print("nox_tls_server: NOX_OPENSSL_LIB LoadLibraryA basarisiz: {s} (GetLastError={d})\n", .{ override_path, Kernel32.GetLastError() });
        } else if (std.DynLib.open(std.mem.span(override_path))) |lib| {
            return lib;
        } else |err| {
            std.debug.print("nox_tls_server: NOX_OPENSSL_LIB dlopen basarisiz: {s} ({t})\n", .{ override_path, err });
        }
    }
    for (libraryCandidates()) |name| {
        if (builtin.os.tag == .windows) {
            if (Kernel32.LoadLibraryA(name)) |h| return h;
            std.debug.print("nox_tls_server: LoadLibraryA basarisiz: {s} (GetLastError={d})\n", .{ name, Kernel32.GetLastError() });
        } else if (std.DynLib.open(name)) |lib| {
            return lib;
        } else |err| {
            std.debug.print("nox_tls_server: dlopen basarisiz: {s} ({t})\n", .{ name, err });
        }
    }
    return null;
}

/// **GERÇEK, ÇALIŞMA-ZAMANINDA bulunan hata (Windows):** `BIO_new`/`BIO_
/// s_mem`/`BIO_read`/`BIO_write`/`BIO_ctrl` OpenSSL'in `libcrypto`SUNDA
/// tanımlıdır, `libssl`DE DEĞİL (`libssl`, `libcrypto`yu SADECE `SSL_*`
/// fonksiyonlarının İÇ UYGULAMASI İçİn ÇAĞIRIR — `libcrypto`nun KENDİ
/// exports tablosuna sahip fonksiyonları libssl'in EXPORTS tablosuna
/// YENİDEN İHRAÇ EDİLMEZ). POSIX'te (`dlsym`) bu SORUN OLMAZ — `dlsym`
/// bir handle ÜZERİNDE arama YAPARKEN o modülün BAĞIMLILIK grafiğini
/// (libssl'in KENDİ `DT_NEEDED libcrypto`SU DAHİL) TRANSİTİF olarak
/// TARAR — GERÇEK bir macOS/Linux CI çalıştırması BUNU zaten doğruladı.
/// AMA Windows'ta `GetProcAddress` YALNIZCA VERİLEN HMODULE'ün KENDİ
/// exports tablosuna BAKAR, bağımlılıklarına ASLA İNMEZ — bu YÜZDEN
/// `GetProcAddress(libssl_handle, "BIO_new")` HER ZAMAN BAŞARISIZ olur
/// (GERÇEK bir Windows CI çalıştırmasında `libssl-3-x64.dll`/`libcrypto-
/// 3-x64.dll` HER İKİSİ de DİSKTE doğrulanmış OLDUĞU HALDE `nox_tls_
/// server: sembol bulunamadi: BIO_new` HATASIYLA YAKALANDI). Düzeltme:
/// Windows'ta BIO_* sembolleri AYRI bir `libcrypto` handle'ından
/// aranır — bu handle'ı elde etmek İçİn AYRI bir arama/PATH GEREKMEZ:
/// `libcrypto`, `libssl` ZATEN yüklendiğinde (onun KENDİ import
/// tablosundaki bir bağımlılık olarak) işlem belleğine ÇOKTAN
/// YÜKLENMİŞTİR — bare-isimli bir `LoadLibraryA` çağrısı bu YÜZDEN
/// SADECE refcount'u artırıp AYNI, ZATEN-yüklü handle'ı DÖNER (YENİDEN
/// disk/PATH araması YAPMAZ).
fn openCryptoLibWindows() ?*anyopaque {
    if (Kernel32.LoadLibraryA("libcrypto-3-x64.dll")) |h| return h;
    if (Kernel32.LoadLibraryA("libcrypto-1_1-x64.dll")) |h| return h;
    std.debug.print("nox_tls_server: libcrypto-*.dll (BIO_* sembolleri icin) bulunamadi (GetLastError={d})\n", .{Kernel32.GetLastError()});
    return null;
}

fn lookupSym(lib: *LibHandle, comptime T: type, name: [:0]const u8) ?T {
    if (builtin.os.tag == .windows) {
        const handle = lib.* orelse return null;
        const addr = Kernel32.GetProcAddress(handle, name) orelse {
            std.debug.print("nox_tls_server: sembol bulunamadi: {s}\n", .{name});
            return null;
        };
        return @ptrCast(addr);
    }
    return lib.lookup(T, name) orelse {
        std.debug.print("nox_tls_server: sembol bulunamadi: {s}\n", .{name});
        return null;
    };
}

// ---- OpenSSL C ABI (tamamen opak işaretçiler + sabit manifest değerleri —
// `sqlite3*`/`sqlite3_stmt*` İLE AYNI ilke, bkz. `sqlite.zig`) -------------

const TlsMethodFn = *const fn () callconv(.c) ?*anyopaque;
const CtxNewFn = *const fn (method: ?*anyopaque) callconv(.c) ?*anyopaque;
const CtxFreeFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;
const CtxUpRefFn = *const fn (ctx: ?*anyopaque) callconv(.c) c_int;
const CtxUseCertFn = *const fn (ctx: ?*anyopaque, path: [*:0]const u8, file_type: c_int) callconv(.c) c_int;
const CtxUseKeyFn = *const fn (ctx: ?*anyopaque, path: [*:0]const u8, file_type: c_int) callconv(.c) c_int;
const CtxCheckKeyFn = *const fn (ctx: ?*anyopaque) callconv(.c) c_int;
const SslNewFn = *const fn (ctx: ?*anyopaque) callconv(.c) ?*anyopaque;
const SslFreeFn = *const fn (ssl: ?*anyopaque) callconv(.c) void;
const SslSetBioFn = *const fn (ssl: ?*anyopaque, rbio: ?*anyopaque, wbio: ?*anyopaque) callconv(.c) void;
const SslSetAcceptStateFn = *const fn (ssl: ?*anyopaque) callconv(.c) void;
const SslDoHandshakeFn = *const fn (ssl: ?*anyopaque) callconv(.c) c_int;
const SslReadFn = *const fn (ssl: ?*anyopaque, buf: [*]u8, num: c_int) callconv(.c) c_int;
const SslWriteFn = *const fn (ssl: ?*anyopaque, buf: [*]const u8, num: c_int) callconv(.c) c_int;
const SslShutdownFn = *const fn (ssl: ?*anyopaque) callconv(.c) c_int;
const SslGetErrorFn = *const fn (ssl: ?*anyopaque, ret: c_int) callconv(.c) c_int;
const BioNewFn = *const fn (method: ?*anyopaque) callconv(.c) ?*anyopaque;
const BioMethodFn = *const fn () callconv(.c) ?*anyopaque;
const BioReadFn = *const fn (bio: ?*anyopaque, buf: [*]u8, len: c_int) callconv(.c) c_int;
const BioWriteFn = *const fn (bio: ?*anyopaque, buf: [*]const u8, len: c_int) callconv(.c) c_int;
const BioCtrlFn = *const fn (bio: ?*anyopaque, cmd: c_int, larg: c_long, parg: ?*anyopaque) callconv(.c) c_long;

const Funcs = struct {
    tls_server_method: TlsMethodFn,
    ctx_new: CtxNewFn,
    ctx_free: CtxFreeFn,
    ctx_up_ref: CtxUpRefFn,
    ctx_use_cert: CtxUseCertFn,
    ctx_use_key: CtxUseKeyFn,
    ctx_check_key: CtxCheckKeyFn,
    ssl_new: SslNewFn,
    ssl_free: SslFreeFn,
    ssl_set_bio: SslSetBioFn,
    ssl_set_accept_state: SslSetAcceptStateFn,
    ssl_do_handshake: SslDoHandshakeFn,
    ssl_read: SslReadFn,
    ssl_write: SslWriteFn,
    ssl_shutdown: SslShutdownFn,
    ssl_get_error: SslGetErrorFn,
    bio_new: BioNewFn,
    bio_s_mem: BioMethodFn,
    bio_read: BioReadFn,
    bio_write: BioWriteFn,
    bio_ctrl: BioCtrlFn,
};

const SSL_FILETYPE_PEM: c_int = 1;
const SSL_ERROR_WANT_READ: c_int = 2;
const SSL_ERROR_WANT_WRITE: c_int = 3;
const SSL_ERROR_ZERO_RETURN: c_int = 6;
const BIO_CTRL_PENDING: c_int = 10;

const LoadState = enum(u8) { uninit, initializing, ready, failed };
var g_state: std.atomic.Value(LoadState) = .init(.uninit);
var g_lib: LibHandle = undefined;
var g_funcs: Funcs = undefined;

fn loadAll() bool {
    var lib = openLib() orelse return false;
    // BIO_* sembolleri Windows'ta AYRI bir `libcrypto` handle'INDAN aranır
    // (bkz. `openCryptoLibWindows`nin belge notu); DİĞER platformlarda
    // `dlsym`in KENDİSİ ZATEN transitif ÇÖZÜYOR, bu YÜZDEN AYNI `lib`
    // handle'ı YETERLİ.
    var bio_lib: LibHandle = if (builtin.os.tag == .windows)
        openCryptoLibWindows() orelse return false
    else
        lib;
    const tls_server_method = lookupSym(&lib, TlsMethodFn, "TLS_server_method") orelse return false;
    const ctx_new = lookupSym(&lib, CtxNewFn, "SSL_CTX_new") orelse return false;
    const ctx_free = lookupSym(&lib, CtxFreeFn, "SSL_CTX_free") orelse return false;
    const ctx_up_ref = lookupSym(&lib, CtxUpRefFn, "SSL_CTX_up_ref") orelse return false;
    const ctx_use_cert = lookupSym(&lib, CtxUseCertFn, "SSL_CTX_use_certificate_file") orelse return false;
    const ctx_use_key = lookupSym(&lib, CtxUseKeyFn, "SSL_CTX_use_PrivateKey_file") orelse return false;
    const ctx_check_key = lookupSym(&lib, CtxCheckKeyFn, "SSL_CTX_check_private_key") orelse return false;
    const ssl_new = lookupSym(&lib, SslNewFn, "SSL_new") orelse return false;
    const ssl_free = lookupSym(&lib, SslFreeFn, "SSL_free") orelse return false;
    const ssl_set_bio = lookupSym(&lib, SslSetBioFn, "SSL_set_bio") orelse return false;
    const ssl_set_accept_state = lookupSym(&lib, SslSetAcceptStateFn, "SSL_set_accept_state") orelse return false;
    const ssl_do_handshake = lookupSym(&lib, SslDoHandshakeFn, "SSL_do_handshake") orelse return false;
    const ssl_read = lookupSym(&lib, SslReadFn, "SSL_read") orelse return false;
    const ssl_write = lookupSym(&lib, SslWriteFn, "SSL_write") orelse return false;
    const ssl_shutdown = lookupSym(&lib, SslShutdownFn, "SSL_shutdown") orelse return false;
    const ssl_get_error = lookupSym(&lib, SslGetErrorFn, "SSL_get_error") orelse return false;
    const bio_new = lookupSym(&bio_lib, BioNewFn, "BIO_new") orelse return false;
    const bio_s_mem = lookupSym(&bio_lib, BioMethodFn, "BIO_s_mem") orelse return false;
    const bio_read = lookupSym(&bio_lib, BioReadFn, "BIO_read") orelse return false;
    const bio_write = lookupSym(&bio_lib, BioWriteFn, "BIO_write") orelse return false;
    const bio_ctrl = lookupSym(&bio_lib, BioCtrlFn, "BIO_ctrl") orelse return false;

    g_lib = lib;
    g_funcs = .{
        .tls_server_method = tls_server_method,
        .ctx_new = ctx_new,
        .ctx_free = ctx_free,
        .ctx_up_ref = ctx_up_ref,
        .ctx_use_cert = ctx_use_cert,
        .ctx_use_key = ctx_use_key,
        .ctx_check_key = ctx_check_key,
        .ssl_new = ssl_new,
        .ssl_free = ssl_free,
        .ssl_set_bio = ssl_set_bio,
        .ssl_set_accept_state = ssl_set_accept_state,
        .ssl_do_handshake = ssl_do_handshake,
        .ssl_read = ssl_read,
        .ssl_write = ssl_write,
        .ssl_shutdown = ssl_shutdown,
        .ssl_get_error = ssl_get_error,
        .bio_new = bio_new,
        .bio_s_mem = bio_s_mem,
        .bio_read = bio_read,
        .bio_write = bio_write,
        .bio_ctrl = bio_ctrl,
    };
    return true;
}

fn ensureLoaded() bool {
    if (g_state.cmpxchgStrong(.uninit, .initializing, .acquire, .monotonic) == null) {
        g_state.store(if (loadAll()) .ready else .failed, .release);
    } else {
        while (true) {
            const s = g_state.load(.acquire);
            if (s == .ready or s == .failed) break;
            std.Thread.yield() catch {};
        }
    }
    return g_state.load(.acquire) == .ready;
}

/// `newServerCtx`nin BAŞARISIZLIK nedeni — ÖNCEDEN (`v1.22.4`e KADAR)
/// TÜM bu dört farklı hata TEK bir belirsiz stderr mesajına ("libssl
/// kurulu degil olabilir, ya da cert/key yolu/eslesmesi yanlis")
/// düşüyordu; bu, GERÇEK bir Windows CI çalıştırmasında `libssl`/
/// `libcrypto` HER İKİSİ de doğrulanmış (bulunmuş) OLDUĞU HALDE sunucunun
/// yine de dinlemeye BAŞLAMADIĞI bir durumda hangi ADIMIN başarısız
/// OLDUĞUNU (kütüphane yükleme mi, cert dosyası mı, key dosyası mı, yoksa
/// eşleşme mi) TEŞHİS ETMEYİ İMKANSIZ kılıyordu. Artık HER ADIM kendi
/// nedenini bildirir.
pub const CtxError = enum {
    lib_load_failed,
    cert_file_failed,
    key_file_failed,
    key_mismatch,
};

/// `SSL_CTX*`. `cert_path`/`key_path` PEM biçiminde OLMALIDIR (Apache/nginx
/// İLE AYNI KONVANSİYON). HERHANGİ bir adımda BAŞARISIZ OLURSA (libssl
/// yüklenemedi, dosya bulunamadı, cert/key EŞLEŞMİYOR) `null` döner ve
/// (VERİLDİYSE) `err_out`a HANGİ adımın başarısız olduğunu YAZAR —
/// çağıran (`http_server.zig`) stderr'e TEK satırlık bir tanı BASAR.
pub fn newServerCtx(cert_path: [*:0]const u8, key_path: [*:0]const u8, err_out: ?*CtxError) ?*anyopaque {
    if (!ensureLoaded()) {
        if (err_out) |e| e.* = .lib_load_failed;
        return null;
    }
    const method = g_funcs.tls_server_method() orelse {
        if (err_out) |e| e.* = .lib_load_failed;
        return null;
    };
    const ctx = g_funcs.ctx_new(method) orelse {
        if (err_out) |e| e.* = .lib_load_failed;
        return null;
    };
    if (g_funcs.ctx_use_cert(ctx, cert_path, SSL_FILETYPE_PEM) != 1) {
        if (err_out) |e| e.* = .cert_file_failed;
        g_funcs.ctx_free(ctx);
        return null;
    }
    if (g_funcs.ctx_use_key(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        if (err_out) |e| e.* = .key_file_failed;
        g_funcs.ctx_free(ctx);
        return null;
    }
    if (g_funcs.ctx_check_key(ctx) != 1) {
        if (err_out) |e| e.* = .key_mismatch;
        g_funcs.ctx_free(ctx);
        return null;
    }
    return ctx;
}

pub fn freeServerCtx(ctx: *anyopaque) void {
    g_funcs.ctx_free(ctx);
}

/// **KÖK NEDEN düzeltmesi (kullanım-sonrası-serbest-bırakma, TLS + fiber
/// zamanlaması):** `serveImpl` (bkz. `http_server.zig`) bir bağlantıyı
/// `accept()` EDER ETMEZ onun fiber'ını `markReady` İLE hazır kuyruğuna
/// EKLER ve KENDİ döngüsüne DEVAM EDER — `max_connections` sınırına
/// ULAŞILDIYSA bu, `serveImpl`nin (dolayısıyla `nox_http_serve_raw`nin)
/// bu fiber HENÜZ BİR KEZ BİLE ÇALIŞTIRILMADAN DÖNMESİ anlamına gelir.
/// Codegen'in ÜRETTİĞİ sıra HER ZAMAN `nox_http_serve_raw` HEMEN ARDINDAN
/// `nox_http_server_close`dur (bkz. `emitServeAndClose`) — `owns_tls_ctx`
/// İSE bu, PAYLAŞILAN `SSL_CTX*`nin, YENİ spawn edilmiş bağlantı fiber'ı
/// KENDİ `SSL_new(ctx)` çağrısını YAPMADAN ÖNCE `SSL_CTX_free`lenmesi
/// demektir — bağlantı fiber'ı ZAMANLAYICI TARAFINDAN ÇALIŞTIRILDIĞINDA
/// `SSL_new`, ÇOKTAN SERBEST BIRAKILMIŞ (dangling) bir `ctx`i DEREFERANS
/// EDER (GERÇEK, tekrarlanabilir bir `EXC_BAD_ACCESS`, `SSL_new + 20`de,
/// `libssl.3.dylib` İçİNDE — `lldb`de `x0`nin (ctx) NUMERIK DEĞERİ HER
/// ZAMAN AYNI kalıyordu ama İÇERİĞİ freed-heap/yeniden-kullanılmış-bellek
/// deseniyle DEĞİŞİYORDU, bkz. proje belleği).
///
/// **Düzeltme, OpenSSL'in KENDİ (`ssl_ctx_st.references`, atomik) referans
/// SAYACINI kullanır** — YENİ bir senkronizasyon İLKELİ İCAT ETMEK YERİNE:
/// `serveImpl`, bir TLS bağlantısını spawn ETMEDEN HEMEN ÖNCE `SSL_CTX_
/// up_ref(ctx)` İLE "bu bağlantı ADINA" fazladan bir referans ALIR (bkz.
/// çağrı sitesi) — bu, `ServerHandle`nin KENDİ referansı `nox_http_server_
/// close` TARAFINDAN HEMEN bırakılsa BİLE `ctx`nin GERÇEKTEN yok EDİLMESİNİ
/// ERTELER. Bağlantı fiber'ı ÇALIŞTIĞINDA `acceptHandshake`, `SSL_new(ctx)`
/// çağrısından (BAŞARILI olsun ya da OLMASIN — OpenSSL `SSL_new`in KENDİSİ
/// BAŞARILIYSA ZATEN KENDİ bağımsız referansını alır, `s->ctx = ctx` İçİn)
/// HEMEN SONRA bu FAZLADAN referansı `ctxReleaseExtraRef` İLE geri verir —
/// böylece `ctx` yalnızca "GERÇEKTEN kimse İhtİYAÇ DUYMADIĞINDA" (sunucunun
/// KENDİ referansı + TÜM bekleyen bağlantıların fazladan referansları +
/// TÜM CANLI `SSL*`lerin KENDİ referansları HEPSİ bırakıldığında) yok
/// edilir — `SSL_new`in KENDİSİ bu YÜZDEN ASLA dangling bir `ctx` GÖRMEZ.
pub fn ctxTakeExtraRef(ctx: *anyopaque) void {
    _ = g_funcs.ctx_up_ref(ctx);
}

/// Bkz. `ctxTakeExtraRef`nin belge notu — `acceptHandshake`nin `SSL_new`
/// çağrısından HEMEN SONRA (başarı/hata FARK ETMEKSİZİN) çağrılır.
pub fn ctxReleaseExtraRef(ctx: *anyopaque) void {
    g_funcs.ctx_free(ctx);
}

/// `serve_multicore_tls`/`serve_multicore_ws_tls`nin PAYLAŞILAN `SSL_CTX*`si
/// İçİn DOĞRUDAN, `ServerHandle` SARMADAN çağrılan serbest bırakma —
/// `genHttpServeMulticoreCore`nin TÜM worker'lar JOIN EDİLDİKTEN SONRA
/// (bkz. `genHttpServeMulticore`nin AYNI join-sonrası temizlik deseni,
/// `handles_arr`in `nox_free`si) çağırdığı TEK sahiplik noktasıdır — HİÇBİR
/// worker'ın KENDİ `ServerHandle`ı bunu SAHİPLENMEZ (`owns_tls_ctx = false`,
/// bkz. `nox_http_server_from_fd_tls`), aksi halde bir worker ERKEN
/// döndüğünde DİĞERLERİ HÂLÂ `SSL_new(ctx)` ÇAĞIRIYORKEN bir kullanım-
/// sonrası-serbest-bırakma YARIŞI oluşurdu.
export fn nox_tls_ctx_free(ctx: ?*anyopaque) callconv(.c) void {
    if (ctx) |c| freeServerCtx(c);
}

// ---- Ham soket G/Ç (http_server.zig'in `rawRead`/`rawWriteAll`ıyla AYNI
// desen — ÇAPRAZ-import OLMADAN, bkz. modül üstü not) ----------------------

fn rawSockRead(scheduler: ?*scheduler_mod.Scheduler, fd: posix.fd_t, buf: []u8, read_timeout_ms: u32) !usize {
    if (scheduler) |s| return io_mod.nonBlockingReadWithTimeout(s, fd, buf, read_timeout_ms);
    if (builtin.os.tag == .windows) {
        const rc = io_mod.WinSock.recv(@intFromPtr(fd), buf.ptr, @intCast(buf.len), 0);
        if (rc >= 0) return @intCast(rc);
        return error.Unexpected;
    }
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .INTR => continue,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

fn rawSockWriteAll(scheduler: ?*scheduler_mod.Scheduler, fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = if (scheduler) |s|
            try io_mod.nonBlockingWrite(s, fd, bytes[off..])
        else if (builtin.os.tag == .windows) blk: {
            const rc = io_mod.WinSock.send(@intFromPtr(fd), bytes[off..].ptr, @intCast(bytes.len - off), 0);
            if (rc < 0) return error.Unexpected;
            break :blk @as(usize, @intCast(rc));
        } else blk: {
            while (true) {
                const rc = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
                if (rc >= 0) break :blk @as(usize, @intCast(rc));
                switch (posix.errno(rc)) {
                    .INTR => continue,
                    else => |e| return posix.unexpectedErrno(e),
                }
            }
        };
        off += n;
    }
}

// ---- Bellek-BIO pompa döngüsü --------------------------------------------

pub const TlsConn = struct {
    ssl: *anyopaque,
    rbio: *anyopaque,
    wbio: *anyopaque,
    fd: posix.fd_t,
    scheduler: ?*scheduler_mod.Scheduler,
    read_timeout_ms: u32,
};

/// Normal durumda döngü 1-3 yinelemede biter (bkz. plan dosyası) — bu
/// SAVUNMACI bir üst sınırdır, doğruluk KANITI DEĞİL.
const MAX_PUMP_ITERS: usize = 64;

/// `wbio`daki (varsa) TÜM bekleyen baytları GERÇEK soketE boşaltır — HER
/// `SSL_*` çağrısından ÖNCE VE SONRA çağrılır (ara-el sıkışma alert'leri/
/// NewSessionTicket, bir `WANT_READ` dönüşünde BİLE çıktı ÜRETEBİLİR).
fn flushWbio(conn: *TlsConn) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const pending = g_funcs.bio_ctrl(conn.wbio, BIO_CTRL_PENDING, 0, null);
        if (pending <= 0) return;
        const want: c_int = @intCast(@min(pending, @as(c_long, buf.len)));
        const n = g_funcs.bio_read(conn.wbio, &buf, want);
        if (n <= 0) return;
        try rawSockWriteAll(conn.scheduler, conn.fd, buf[0..@intCast(n)]);
    }
}

/// GERÇEK soketten TEK bir chunk okuyup `rbio`ya yazar — bu çağrı, fiber'ın
/// (varsa) KOOPERATİF olarak ASKIYA ALINDIĞI yerdir (`rawSockRead`in KENDİ
/// zaman-aşımlı, non-blocking makinesi ÜZERİNDEN, YENİ bir askıya-alma
/// mantığı İCAT EDİLMEDEN).
fn fillRbioOnce(conn: *TlsConn) !void {
    var buf: [4096]u8 = undefined;
    const n = try rawSockRead(conn.scheduler, conn.fd, &buf, conn.read_timeout_ms);
    if (n == 0) return error.EndOfStream;
    var off: usize = 0;
    while (off < n) {
        const w = g_funcs.bio_write(conn.rbio, buf[off..n].ptr, @intCast(n - off));
        if (w <= 0) return error.TlsBioWriteFailed;
        off += @intCast(w);
    }
}

fn drive(conn: *TlsConn, op: *const fn (?*anyopaque) callconv(.c) c_int) !c_int {
    var iter: usize = 0;
    while (iter < MAX_PUMP_ITERS) : (iter += 1) {
        try flushWbio(conn);
        const rc = op(conn.ssl);
        try flushWbio(conn);
        if (rc > 0) return rc;
        const err = g_funcs.ssl_get_error(conn.ssl, rc);
        switch (err) {
            SSL_ERROR_WANT_READ => {
                try fillRbioOnce(conn);
                continue;
            },
            SSL_ERROR_WANT_WRITE => continue,
            SSL_ERROR_ZERO_RETURN => return error.EndOfStream,
            else => return error.TlsFatal,
        }
    }
    return error.TlsPumpExhausted;
}

/// `ctx` (`newServerCtx`in döndürdüğü `SSL_CTX*`) İLE `fd` ÜZERİNDE bir
/// TLS sunucu el sıkışması yapar. `SSL_set_bio`, İKİ BIO'nun sahipliğini
/// `SSL*`e DEVREDER (`SSL_free` İkisini de serbest bırakır) — `rbio`/`wbio`
/// asla AYRICA `BIO_free` EDİLMEMELİDİR.
pub fn acceptHandshake(ctx: *anyopaque, fd: posix.fd_t, scheduler: ?*scheduler_mod.Scheduler, read_timeout_ms: u32, allocator: std.mem.Allocator) !*TlsConn {
    const ssl_or_null = g_funcs.ssl_new(ctx);
    // Bkz. `ctxTakeExtraRef`nin belge notu: `serveImpl`nin spawn anında
    // aldığı FAZLADAN referans burada, `SSL_new` çağrısından HEMEN SONRA
    // (başarı/hata FARK ETMEKSİZİN) geri verilir — `ctx`e bu noktadan
    // SONRA BİR DAHA HİÇ dokunulmaz (`SSL_new` BAŞARILIYSA `ssl`in KENDİ
    // bağımsız referansı ZATEN alınmıştır).
    ctxReleaseExtraRef(ctx);
    const ssl = ssl_or_null orelse return error.TlsFatal;
    errdefer g_funcs.ssl_free(ssl);
    const mem_method = g_funcs.bio_s_mem() orelse return error.TlsFatal;
    const rbio = g_funcs.bio_new(mem_method) orelse return error.TlsFatal;
    const wbio = g_funcs.bio_new(mem_method) orelse return error.TlsFatal;
    g_funcs.ssl_set_bio(ssl, rbio, wbio);
    g_funcs.ssl_set_accept_state(ssl);

    const conn = try allocator.create(TlsConn);
    errdefer allocator.destroy(conn);
    conn.* = .{ .ssl = ssl, .rbio = rbio, .wbio = wbio, .fd = fd, .scheduler = scheduler, .read_timeout_ms = read_timeout_ms };
    _ = try drive(conn, doHandshakeOp);
    return conn;
}

fn doHandshakeOp(ssl: ?*anyopaque) callconv(.c) c_int {
    return g_funcs.ssl_do_handshake(ssl);
}

/// **Dikkat — iş-parçacığı-yerel geçici depolar**: `tlsRead`/`tlsWrite`
/// çağrı SÜRESİNCE sabit kalan (bir `drive` döngüsü İÇİNDE, `fillRbioOnce`
/// ARADA BU globalleri BİR DAHA OKUMAZ) `threadlocal` değişkenler — bir
/// callback İmzası (`SSL_read`/`SSL_write` DIŞARIDAN, `ssl`i DIŞINDA hiçbir
/// parametre GEÇMEZ) İLE bir Zig closure ARASINDAKİ farkı KAPATMAK İçİn
/// GEREKLİ. `serve_multicore`nin AYRI OS iş parçacıkları HER BİRİ KENDİ
/// `threadlocal` KOPYASINA sahip OLDUĞUNDAN çapraz-iş-parçacığı veri
/// YARIŞI OLUŞMAZ.
threadlocal var tl_read_target: []u8 = &.{};
threadlocal var tl_write_source: []const u8 = &.{};

fn threadlocalReadOp(ssl: ?*anyopaque) callconv(.c) c_int {
    return g_funcs.ssl_read(ssl, tl_read_target.ptr, @intCast(tl_read_target.len));
}
fn threadlocalWriteOp(ssl: ?*anyopaque) callconv(.c) c_int {
    return g_funcs.ssl_write(ssl, tl_write_source.ptr, @intCast(tl_write_source.len));
}

pub fn tlsRead(conn: *TlsConn, buf: []u8) !usize {
    tl_read_target = buf;
    const rc = drive(conn, threadlocalReadOp) catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };
    return @intCast(rc);
}

pub fn tlsWrite(conn: *TlsConn, buf: []const u8) !usize {
    tl_write_source = buf;
    const rc = try drive(conn, threadlocalWriteOp);
    return @intCast(rc);
}

/// **GERÇEK, testle bulunan hata:** `SSL_shutdown` `close_notify` alert'ini
/// YALNIZCA `wbio`ya (bellek-BIO'ya) YAZAR — bizim `SSL_set_fd` KULLANMAYAN
/// tasarımımızda (bkz. modül üstü not) bu, `flushWbio` İLE GERÇEK soketE
/// AKTARILMADIKÇA HİÇBİR ZAMAN karşı tarafa ULAŞMAZ. Bu YÜZDEN önceden
/// (`flushWbio` ÇAĞRILMADAN doğrudan `ssl_free`) istemciler `close_notify`
/// ALMADAN ham bir TCP FIN görüyordu — Zig'in KENDİ `std.crypto.tls.Client`ı
/// (`allow_truncation_attacks = false`, VARSAYILAN GÜVENLİ ayar) bunu
/// KESİN OLARAK `error.TlsConnectionTruncated` İLE REDDEDİYORDU (GERÇEK
/// bir `http_serve_tls_golden_test.zig` çalıştırmasıyla YAKALANDI — el
/// sıkışma VE İSTEK/YANIT tam olarak DOĞRU çalışıyordu, yalnızca kapanış
/// eksikti). Düzeltme: `flushWbio` (best-effort — soket ÇOKTAN karşı
/// taraftan kapatılmış OLABİLİR, bu durumda `rawSockWriteAll` hatası
/// YOK SAYILIR, `catch {}`) EKLENDİ.
pub fn tlsShutdown(conn: *TlsConn, allocator: std.mem.Allocator) void {
    _ = g_funcs.ssl_shutdown(conn.ssl); // best-effort, tek çağrı, sonucu yok say
    flushWbio(conn) catch {};
    g_funcs.ssl_free(conn.ssl); // rbio/wbio'yu da serbest bırakır (SSL_set_bio sahiplik devretti)
    allocator.destroy(conn);
}

fn writeAllTls(conn: *TlsConn, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try tlsWrite(conn, bytes[off..]);
        if (n == 0) return error.WriteFailed;
        off += n;
    }
}

/// `http_server.zig`nin `FiberReader`ının BİREBİR YAPISAL kopyası —
/// `rawRead` YERİNE `tlsRead` (bellek-BIO pompa döngüsü) ÇAĞIRIR. Bkz.
/// plan dosyası §2.
pub const TlsServerReader = struct {
    interface: std.Io.Reader,
    conn: *TlsConn,

    pub fn init(conn: *TlsConn, buffer: []u8) TlsServerReader {
        return .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .conn = conn,
        };
    }

    fn stream(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TlsServerReader = @alignCast(@fieldParentPtr("interface", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = tlsRead(self.conn, dest) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        io_w.advance(n);
        return n;
    }
};

/// `http_server.zig`nin `FiberWriter`ının BİREBİR YAPISAL kopyası —
/// `rawWriteAll` YERİNE `writeAllTls` (`tlsWrite`nin TÜM baytlar yazılana
/// kadar döngüsü) ÇAĞIRIR.
pub const TlsServerWriter = struct {
    interface: std.Io.Writer,
    conn: *TlsConn,

    pub fn init(conn: *TlsConn, buffer: []u8) TlsServerWriter {
        return .{
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
            .conn = conn,
        };
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *TlsServerWriter = @alignCast(@fieldParentPtr("interface", io_w));
        writeAllTls(self.conn, io_w.buffered()) catch return error.WriteFailed;
        for (data[0 .. data.len - 1]) |chunk| {
            writeAllTls(self.conn, chunk) catch return error.WriteFailed;
        }
        const pattern = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            writeAllTls(self.conn, pattern) catch return error.WriteFailed;
        }
        const total = io_w.end + std.Io.Writer.countSplat(data, splat);
        return io_w.consume(total);
    }
};
