//! `nox.fs` Zig kabuğu — stdlib fazı §J (bkz. nox-teknik-spesifikasyon.md).
//! Basit senkron dosya G/Ç — bu Zig sürümünde `std.fs.cwd()` KALDIRILMIŞ
//! (yalnızca `io: std.Io` bağlamı gerektiren `std.Io.Dir` VAR, bkz.
//! `compiler/main.zig`nin kullanımı) — main.zig'in AKSİNE burada bir `Io`
//! bağlamı YOK, bu yüzden `http_client.zig`/`http_server.zig` İLE AYNI
//! desen: HAM libc çağrıları (`std.c.open`/`read`/`write`/`close`)
//! DOĞRUDAN kullanılır.
//!
//! Tasarım: `read_to_string_raw`/`write_string_raw` HER ZAMAN bir değer
//! döner (hata durumunda BOŞ bir `str`/hiçbir şey), `nox_fs_last_op_ok()`
//! SON çağrının başarılı olup olmadığını AYRICA bildirir (`nox.http`in
//! `nox_http_response_ok` deseniyle AYNI) — `stdlib/nox/fs.nox`nin KENDİSİ
//! sıradan `if`/`raise` İLE `FsError` fırlatır (HİÇBİR yeni checker/codegen
//! özel-durumu GEREKMEZ).
//!
//! **`threadlocal` (Faz BB.1, bkz. nox-teknik-spesifikasyon.md §3.47):**
//! Bu bayrak ESKİDEN düz bir `var`dı, GEREKÇESİ AÇIKÇA "Nox'un M:1 fiber
//! modelinde AYNI ANDA yalnızca TEK bir fiber ÇALIŞIR, bu yüzden bir çağrı
//! SONRASI hemen okunan bu bayrakta YARIŞ DURUMU OLUŞMAZ" İDİ — BU ÖNCÜL,
//! `nox.thread.spawn`in paylaşımsız (shared-nothing) modeliyle ARTIK
//! GEÇERSİZDİR (İKİ GERÇEK OS iş parçacığı AYNI ANDA `nox.fs.*`
//! ÇAĞIRABİLİR). `threadlocal`, HER iş parçacığına KENDİ BAĞIMSIZ bayrağını
//! VERİR — SIFIR ek senkronizasyon MALİYETİYLE ÖNCÜLÜ YENİDEN GEÇERLİ KILAR.

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");
const http_client = @import("http_client.zig");
const abi_layout = @import("abi_layout");

const dupeToNoxStr = http_client.dupeToNoxStr;
/// Faz P1.2: bkz. `strings.zig`nin AYNI re-export notu.
const LIST_HEADER_SIZE = abi_layout.LIST_HEADER_SIZE;
const FIELD_SLOT_SIZE = abi_layout.FIELD_SLOT_SIZE;

/// Faz LL.1 takibi (bkz. nox-teknik-spesifikasyon.md §3.71 — GERÇEK bir
/// `windows-latest` CI çalıştırması SIRASINDA, Windows'la İLGİSİZ olarak
/// keşfedilen bir Linux regresyonu): kullanılan Zig 0.16.0 derlemesinde
/// `std.c.fstat` VE `std.c.fstatat`nin İKİSİ DE `.linux => {}` İLE
/// (GERÇEK bir libc sembolüne BAĞLANMADAN, `void` olarak) tanımlı — İKİ
/// AYRI GERÇEK Linux CI çalıştırmasıyla (biri her ikisi de dene
/// nirken) doğrulandı. `std.c.statx` İSE (`extern "c" fn statx(...)`,
/// switch'e HİÇ girmeyen, KOŞULSUZ bir extern bildirimi) GERÇEK bir
/// glibc sembolüne bağlı KALIR — bir fd'yi (`AT.EMPTY_PATH` bayrağıyla
/// BOŞ göreli yol) stat'lamak İçin bu kullanılır. macOS'ta (VE
/// `std.c.fstat`in zaten ÇALIŞTIĞI diğer platformlarda) fstat'a
/// DOKUNULMADAN devam edilir — İKİ dal FARKLI struct döndürdüğünden
/// (`Stat` vs `Statx`), ORTAK bir `FileInfo` küçük değerine ÇEVRİLİR.
const FileInfo = struct { size: u64, mtime_sec: i64, mtime_nsec: i64 };

/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): bu Zig sürümünde
/// `std.c.O` (bu dosyanın `open` çağrılarının HER YERDE kullandığı bayrak
/// struct'ı) VE `std.c.Stat` İKİSİ DE Windows İçin `void`dir (`.windows`
/// dalı HİÇ CASE'lenmemiş, `else => void`e düşüyor) — `std.c.readdir`
/// (`.linux`nin `fstat`i GİBİ `.windows => {}`) DE aynı şekilde bozuk.
/// Bu YÜZDEN Windows'ta dosya G/Ç'si TAMAMEN AYRI, ham Win32/MinGW-CRT
/// ilkelleriyle yapılır: `_open`/`_read`/`_write`/`_close` (MSVCRT/UCRT'nin
/// alt-seviye G/Ç ailesi — `_O_BINARY` HER ZAMAN geçilir, aksi halde
/// VARSAYILAN metin modu `\r\n`↔`\n` çevirisi YAPARDI, Nox `str`lerini
/// SESSİZCE bozardı), boyut İçin `_filelengthi64`, mtime İçin
/// `_get_osfhandle` + `GetFileTime` (CRT fd'sinin ALTINDAKİ GERÇEK Win32
/// `HANDLE`'ı ALIR), dizin listeleme İçin `FindFirstFileA`/`FindNextFileA`/
/// `FindClose`, "dizin mi" sorusu İçin `GetFileAttributesA`.
const WinFile = if (builtin.os.tag == .windows) struct {
    const O_RDONLY: c_int = 0x0000;
    const O_WRONLY: c_int = 0x0001;
    const O_APPEND: c_int = 0x0008;
    const O_CREAT: c_int = 0x0100;
    const O_TRUNC: c_int = 0x0200;
    const O_BINARY: c_int = 0x8000;
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
    const INVALID_HANDLE_VALUE: isize = -1;

    const WIN32_FIND_DATAA = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: std.os.windows.FILETIME,
        ftLastAccessTime: std.os.windows.FILETIME,
        ftLastWriteTime: std.os.windows.FILETIME,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        dwReserved0: u32,
        dwReserved1: u32,
        cFileName: [260]u8,
        cAlternateFileName: [14]u8,
    };

    extern "c" fn _open(path: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int;
    extern "c" fn _read(fd: c_int, buf: [*]u8, count: c_uint) callconv(.c) c_int;
    extern "c" fn _write(fd: c_int, buf: [*]const u8, count: c_uint) callconv(.c) c_int;
    extern "c" fn _close(fd: c_int) callconv(.c) c_int;
    extern "c" fn _filelengthi64(fd: c_int) callconv(.c) i64;
    extern "c" fn _get_osfhandle(fd: c_int) callconv(.c) isize;
    extern "kernel32" fn GetFileTime(h: isize, creation: ?*std.os.windows.FILETIME, access: ?*std.os.windows.FILETIME, write: ?*std.os.windows.FILETIME) callconv(.c) i32;
    extern "kernel32" fn GetFileAttributesA(path: [*:0]const u8) callconv(.c) u32;
    extern "kernel32" fn FindFirstFileA(path: [*:0]const u8, data: *WIN32_FIND_DATAA) callconv(.c) isize;
    extern "kernel32" fn FindNextFileA(h: isize, data: *WIN32_FIND_DATAA) callconv(.c) i32;
    extern "kernel32" fn FindClose(h: isize) callconv(.c) i32;
} else struct {};

/// `windows-1601-epoch` FILETIME'ı (100ns birimler) Unix epoch saniye/
/// nanosaniyeye çevirir — 1601-1970 ARASI fark (100ns birimler cinsinden)
/// SABİTTİR: 116444736000000000.
fn filetimeToUnix(ft: std.os.windows.FILETIME) struct { sec: i64, nsec: i64 } {
    const ticks: u64 = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    const unix_100ns: i64 = @as(i64, @intCast(ticks)) - 116444736000000000;
    return .{ .sec = @divFloor(unix_100ns, 10_000_000), .nsec = @mod(unix_100ns, 10_000_000) * 100 };
}

fn fstatCompat(fd: c_int) ?FileInfo {
    if (builtin.os.tag == .windows) {
        const size = WinFile._filelengthi64(fd);
        if (size < 0) return null;
        const handle = WinFile._get_osfhandle(fd);
        var write_time: std.os.windows.FILETIME = undefined;
        if (WinFile.GetFileTime(handle, null, null, &write_time) == 0) return null;
        const t = filetimeToUnix(write_time);
        return .{ .size = @intCast(size), .mtime_sec = t.sec, .mtime_nsec = t.nsec };
    }
    if (builtin.os.tag == .linux) {
        var buf: std.os.linux.Statx = undefined;
        const mask: std.os.linux.STATX = .{ .SIZE = true, .MTIME = true };
        const rc = std.c.statx(fd, "", std.os.linux.AT.EMPTY_PATH, mask, &buf);
        if (rc != 0) return null;
        return .{ .size = buf.size, .mtime_sec = buf.mtime.sec, .mtime_nsec = buf.mtime.nsec };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return null;
    const mt = st.mtime();
    return .{ .size = @intCast(st.size), .mtime_sec = mt.sec, .mtime_nsec = mt.nsec };
}

/// `nox_fs_read_to_string_raw`/`writeAllToFile`/`nox_fs_copy_raw`nin ORTAK
/// aç/oku/yaz/kapat katmanı — Windows'ta `WinFile`nin ham `_open`/`_read`/
/// `_write`/`_close`sini, diğer platformlarda DOKUNULMADAN `std.c.open`/
/// `read`/`write`/`close`i çağırır.
fn openFileRead(path: [*:0]const u8) c_int {
    if (builtin.os.tag == .windows) return WinFile._open(path, WinFile.O_RDONLY | WinFile.O_BINARY, 0);
    const o: std.c.O = .{ .ACCMODE = .RDONLY };
    return std.c.open(path, o, @as(c_uint, 0));
}

fn openFileWrite(path: [*:0]const u8, append: bool) c_int {
    if (builtin.os.tag == .windows) {
        const flags = WinFile.O_WRONLY | WinFile.O_CREAT | WinFile.O_BINARY | (if (append) WinFile.O_APPEND else WinFile.O_TRUNC);
        return WinFile._open(path, flags, 0o644);
    }
    const o: std.c.O = if (append)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };
    return std.c.open(path, o, @as(c_uint, 0o644));
}

fn readFd(fd: c_int, buf: []u8) isize {
    if (builtin.os.tag == .windows) {
        const n = WinFile._read(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint))));
        return @intCast(n);
    }
    return std.c.read(fd, buf.ptr, buf.len);
}

fn writeFd(fd: c_int, buf: []const u8) isize {
    if (builtin.os.tag == .windows) {
        const n = WinFile._write(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint))));
        return @intCast(n);
    }
    return std.c.write(fd, buf.ptr, buf.len);
}

fn closeFd(fd: c_int) void {
    if (builtin.os.tag == .windows) {
        _ = WinFile._close(fd);
    } else {
        _ = std.c.close(fd);
    }
}

threadlocal var g_last_ok: bool = true;

export fn nox_fs_last_op_ok() callconv(.c) i32 {
    return if (g_last_ok) 1 else 0;
}

/// Faz III.3 (bkz. nox-teknik-spesifikasyon.md §3.69) — ÖNCEKİ sürüm
/// `std.heap.page_allocator`la BÜYÜYEN bir `ArrayListUnmanaged(u8)`e
/// okuyup SONRA `dupeToNoxStr` İLE İKİNCİ bir kopya çıkarıyordu (ÇAĞRI
/// başına 2 tahsis — `path.zig`nin EE.1-SONRASI `join` düzeltmesinden
/// ÖNCEKİ hâliyle AYNI desen, bkz. onun belge notu). Burada ÖNCE `fstat`
/// İLE GERÇEK dosya boyutu alınıp TEK bir `arc.nox_rc_alloc` yapılır,
/// doğrudan O BUFFER'a okunur — `path_bench`teki ~9.9x kazanımla AYNI
/// stratejinin `nox.fs`e uygulanışı (bkz. `benchmarks/fs_bench`). Dosya
/// okuma SIRASINDA BÜYÜRSE/küçülürse (nadir yarış) `fstat` ANINDAKİ
/// boyut ESAS alınır — bilinçli v1 basitleştirmesi.
export fn nox_fs_read_to_string_raw(rt: ?*anyopaque, path: ?[*:0]const u8) callconv(.c) ?[*:0]u8 {
    const p = path orelse {
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    };

    const fd = openFileRead(p);
    if (fd < 0) {
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    }
    defer closeFd(fd);

    const info = fstatCompat(fd) orelse {
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    };
    const size: usize = @intCast(info.size);

    const raw = arc.nox_rc_alloc(rt, size + 1) orelse {
        g_last_ok = false;
        return dupeToNoxStr(rt, "");
    };
    const out: [*]u8 = @ptrCast(raw);
    var total_read: usize = 0;
    while (total_read < size) {
        const n = readFd(fd, out[total_read..size]);
        if (n <= 0) break;
        total_read += @intCast(n);
    }
    out[total_read] = 0;
    g_last_ok = true;
    return @ptrCast(out);
}

fn writeAllToFile(append: bool, path: [*:0]const u8, content: [*:0]const u8) void {
    const fd = openFileWrite(path, append);
    if (fd < 0) {
        g_last_ok = false;
        return;
    }
    defer closeFd(fd);

    const bytes = std.mem.span(content);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = writeFd(fd, bytes[off..]);
        if (n <= 0) {
            g_last_ok = false;
            return;
        }
        off += @intCast(n);
    }
    g_last_ok = true;
}

export fn nox_fs_write_string_raw(rt: ?*anyopaque, path: ?[*:0]const u8, content: ?[*:0]const u8) callconv(.c) void {
    _ = rt;
    const p = path orelse {
        g_last_ok = false;
        return;
    };
    const c = content orelse {
        g_last_ok = false;
        return;
    };
    writeAllToFile(false, p, c);
}

/// Faz III.3 (bkz. nox-teknik-spesifikasyon.md §3.69) — `write_string`nin
/// AKSİNE dosyayı KISALTMAZ (`TRUNC` YOK), `content`i dosyanın SONUNA
/// ekler (`APPEND` — VAR OLMAYAN dosya İçin `CREAT` İLE OLUŞTURULUR, tıpkı
/// `write_string` gibi).
export fn nox_fs_append_string_raw(rt: ?*anyopaque, path: ?[*:0]const u8, content: ?[*:0]const u8) callconv(.c) void {
    _ = rt;
    const p = path orelse {
        g_last_ok = false;
        return;
    };
    const c = content orelse {
        g_last_ok = false;
        return;
    };
    writeAllToFile(true, p, c);
}

/// Faz EE.1 (bkz. nox-teknik-spesifikasyon.md §3.61) — `read_to_string`/
/// `write_string`nin AKSİNE bunlar `g_last_ok`ı HİÇ DOKUNMAZ/OKUMAZ: var
/// OLMAMA burada GEÇERLİ, BEKLENEN bir sonuçtur (kullanıcı `read_to_string`i
/// deneyip `FsError` yakalamak YERİNE ÖNCE sorabilir) — `.nox` sarmalayıcısı
/// (bkz. `stdlib/nox/fs.nox`) ASLA `raise` ETMEZ.
///
/// **`std.c.stat` DEĞİL, `access`/`open(O_DIRECTORY)`:** bu Zig sürümünün
/// `std.c.stat` cross-platform sarmalayıcısı aarch64-macOS İÇİN bağlı
/// DEĞİL (`private.stat` sembolü YOK — GERÇEKTEN derleme HATASI vererek
/// keşfedildi). `access`/`open` İSE HER platformda DOĞRUDAN bağlı,
/// TAM bir `stat` yapısına gerek OLMADAN "var mı"/"dizin mi" sorularını
/// yanıtlamaya YETERLİ.
export fn nox_fs_exists_raw(path: ?[*:0]const u8) callconv(.c) i32 {
    const p = path orelse return 0;
    return if (std.c.access(p, std.c.F_OK) == 0) 1 else 0;
}

/// `O_DIRECTORY` İLE açmak YALNIZCA hedef GERÇEKTEN bir dizinse başarılı
/// olur (`ENOTDIR` İLE başarısız olur AKSİ HALDE) — TAM bir `stat`
/// olmadan "dizin mi" sorusunu GÜVENİLİR şekilde yanıtlar.
/// **Windows'ta `O_DIRECTORY` YOK** (Linux/BSD'ye özgü bir uzantı,
/// `std.c.O` zaten Windows'ta `void` — bkz. `WinFile`nin belge notu) —
/// `GetFileAttributesA` (TEK bir Win32 çağrısı, `FILE_ATTRIBUTE_DIRECTORY`
/// bitini KONTROL eder) KULLANILIR.
export fn nox_fs_is_dir_raw(path: ?[*:0]const u8) callconv(.c) i32 {
    const p = path orelse return 0;
    if (builtin.os.tag == .windows) {
        const attrs = WinFile.GetFileAttributesA(p);
        if (attrs == WinFile.INVALID_FILE_ATTRIBUTES) return 0;
        return if ((attrs & WinFile.FILE_ATTRIBUTE_DIRECTORY) != 0) 1 else 0;
    }
    const o_dir: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true };
    const fd = std.c.open(p, o_dir, @as(c_uint, 0));
    if (fd < 0) return 0;
    _ = std.c.close(fd);
    return 1;
}

/// "Dosya" burada "var VE dizin DEĞİL" olarak TANIMLANIR (sembolik
/// link/özel dosya AYRIMI yapılmaz — `nox.fs`in ZATEN belgelenen v1
/// basitleştirmeleriyle TUTARLI, bkz. bu dosyanın modül-üstü notu).
export fn nox_fs_is_file_raw(path: ?[*:0]const u8) callconv(.c) i32 {
    const p = path orelse return 0;
    if (std.c.access(p, std.c.F_OK) != 0) return 0;
    return if (nox_fs_is_dir_raw(p) == 0) 1 else 0;
}

// Faz III.3 (bkz. nox-teknik-spesifikasyon.md §3.69) — `metadata()`nin
// Zig-tarafı: TEK bir `open`+`fstat`+`close` YAPIP sonucu `threadlocal`
// (Faz BB.1'in AYNI "iki gerçek OS iş parçacığı" gerekçesiyle) statiklere
// ÖNBELLEKLER; `stdlib/nox/fs.nox` (`DateTime`nin AYNI Nox-tarafı sınıf
// inşa deseniyle) İKİ AYRI accessor çağrısıyla `FileMetadata`yı kurar.
// **`std.c.stat` (yol-tabanlı) DEĞİL `std.c.fstat` (fd-tabanlı) kullanılır**
// — `is_dir_raw`nin belge notundaki "yol-tabanlı stat aarch64-macOS'ta
// bağlı değil" kısıtlaması YALNIZCA `std.c.stat`i etkiliyor, `fstat`
// (zaten AÇIK bir fd üzerinden) GERÇEKTEN test EDİLİP ÇALIŞTIĞI
// DOĞRULANDI.
threadlocal var g_last_size: i64 = 0;
threadlocal var g_last_mtime_ms: i64 = 0;

export fn nox_fs_stat_raw(path: ?[*:0]const u8) callconv(.c) void {
    const p = path orelse {
        g_last_ok = false;
        return;
    };
    const fd = openFileRead(p);
    if (fd < 0) {
        g_last_ok = false;
        return;
    }
    defer closeFd(fd);

    const info = fstatCompat(fd) orelse {
        g_last_ok = false;
        return;
    };
    g_last_size = @intCast(info.size);
    g_last_mtime_ms = info.mtime_sec * 1000 + @divTrunc(@as(i64, @intCast(info.mtime_nsec)), 1_000_000);
    g_last_ok = true;
}

export fn nox_fs_stat_size_raw() callconv(.c) i64 {
    return g_last_size;
}

export fn nox_fs_stat_mtime_ms_raw() callconv(.c) i64 {
    return g_last_mtime_ms;
}

/// Faz III.3 — `list[str]` DÖNÜŞ desteğinin (Alt-Faz F, `nox_strings_
/// split_raw`nin AYNI 8-bayt-uzunluk+8-bayt-kapasite+işaretçi başlık
/// düzeni — bkz. `strings.zig`nin belge notu) BAŞKA bir kullanıcısı.
/// `.`/`..` GİRDİLERİ ATLANIR (Python'un `os.listdir`/Rust'ın `read_dir`
/// İLE TUTARLI). Bu Zig sürümünde `std.fs.Dir`/`std.Io.Dir` bir `Io`
/// bağlamı GEREKTİRDİĞİNDEN (bu dosyanın modül-üstü notu — burada YOK),
/// HAM libc `opendir`/`readdir`/`closedir` KULLANILIR — Windows'ta İSE
/// (`readdir` `void`dir, bkz. `WinFile`nin belge notu) `FindFirstFileA`/
/// `FindNextFileA`/`FindClose` kullanılır (Win32'nin KENDİ dizin-listeleme
/// API'si, `path\*` joker deseni GEREKTİRİR).
fn collectDirNames(path: [*:0]const u8, names: *std.ArrayListUnmanaged([]const u8)) !void {
    if (builtin.os.tag == .windows) {
        var pattern_buf: [std.c.PATH_MAX + 4]u8 = undefined;
        const pattern = std.fmt.bufPrintZ(&pattern_buf, "{s}/*", .{std.mem.span(path)}) catch return error.PathTooLong;
        var data: WinFile.WIN32_FIND_DATAA = undefined;
        const h = WinFile.FindFirstFileA(pattern.ptr, &data);
        if (h == WinFile.INVALID_HANDLE_VALUE) return error.OpenDirFailed;
        defer _ = WinFile.FindClose(h);
        while (true) {
            const name = std.mem.sliceTo(&data.cFileName, 0);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const owned = try std.heap.page_allocator.dupe(u8, name);
                try names.append(std.heap.page_allocator, owned);
            }
            if (WinFile.FindNextFileA(h, &data) == 0) break;
        }
        return;
    }
    const dir = std.c.opendir(path) orelse return error.OpenDirFailed;
    defer _ = std.c.closedir(dir);
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const owned = try std.heap.page_allocator.dupe(u8, name);
        try names.append(std.heap.page_allocator, owned);
    }
}

export fn nox_fs_read_dir_raw(rt: ?*anyopaque, path: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    const p = path orelse {
        g_last_ok = false;
        return null;
    };

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| std.heap.page_allocator.free(n);
        names.deinit(std.heap.page_allocator);
    }
    collectDirNames(p, &names) catch {
        g_last_ok = false;
        return null;
    };

    const raw = arc.nox_rc_alloc(rt, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * names.items.len) orelse {
        g_last_ok = false;
        return null;
    };
    const bytes: [*]u8 = @ptrCast(raw);
    @as(*align(1) i64, @ptrCast(bytes)).* = @intCast(names.items.len);
    @as(*align(1) i64, @ptrCast(bytes + 8)).* = @intCast(names.items.len);
    for (names.items, 0..) |name, i| {
        const dup = dupeToNoxStr(rt, name) orelse {
            g_last_ok = false;
            return null;
        };
        const slot = bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i;
        @as(*align(1) i64, @ptrCast(slot)).* = @bitCast(@as(isize, @intCast(@intFromPtr(dup))));
    }
    g_last_ok = true;
    return @ptrCast(bytes);
}

/// Faz III.3 — TAŞINABİLİR (macOS'a-özgü `copyfile()` KULLANILMAZ):
/// kaynağı OKUYUP hedefe YAZAR, 4096-baytlık parçalar hâlinde (Nox `str`
/// yuvarlağına HİÇ GİRMEDEN — ARC tahsisi GEREKMEZ).
export fn nox_fs_copy_raw(src: ?[*:0]const u8, dst: ?[*:0]const u8) callconv(.c) void {
    const s = src orelse {
        g_last_ok = false;
        return;
    };
    const d = dst orelse {
        g_last_ok = false;
        return;
    };

    const src_fd = openFileRead(s);
    if (src_fd < 0) {
        g_last_ok = false;
        return;
    }
    defer closeFd(src_fd);

    const dst_fd = openFileWrite(d, false);
    if (dst_fd < 0) {
        g_last_ok = false;
        return;
    }
    defer closeFd(dst_fd);

    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = readFd(src_fd, &chunk);
        if (n < 0) {
            g_last_ok = false;
            return;
        }
        if (n == 0) break;
        var off: usize = 0;
        const want: usize = @intCast(n);
        while (off < want) {
            const w = writeFd(dst_fd, chunk[off..want]);
            if (w <= 0) {
                g_last_ok = false;
                return;
            }
            off += @intCast(w);
        }
    }
    g_last_ok = true;
}

export fn nox_fs_rename_raw(old: ?[*:0]const u8, new: ?[*:0]const u8) callconv(.c) void {
    const o = old orelse {
        g_last_ok = false;
        return;
    };
    const n = new orelse {
        g_last_ok = false;
        return;
    };
    g_last_ok = std.c.rename(o, n) == 0;
}

export fn nox_fs_remove_file_raw(path: ?[*:0]const u8) callconv(.c) void {
    const p = path orelse {
        g_last_ok = false;
        return;
    };
    g_last_ok = std.c.unlink(p) == 0;
}

export fn nox_fs_create_dir_raw(path: ?[*:0]const u8) callconv(.c) void {
    const p = path orelse {
        g_last_ok = false;
        return;
    };
    g_last_ok = std.c.mkdir(p, 0o755) == 0;
}

/// Faz LL.4 (bkz. nox-teknik-spesifikasyon.md §3.71): testler `/tmp`i
/// SABİT bir yol olarak varsayıyordu — Windows'ta `/tmp` YOKTUR, GERÇEK
/// yazılabilir geçici dizin `%TEMP%` ortam değişkenidir (Windows'un
/// KENDİSİ HER ZAMAN AYARLAR). Diğer platformlarda DOKUNULMADAN `/tmp`
/// döner.
fn testTmpPrefix() []const u8 {
    if (builtin.os.tag == .windows) {
        if (std.c.getenv("TEMP")) |t| return std.mem.span(t);
        return "C:/Windows/Temp";
    }
    return "/tmp";
}

test "nox_fs_exists/is_file/is_dir_raw dogru sonuc doner" {
    var full_buf: [128]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_buf, "{s}/nox_ee1_fs_test_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(full_path.ptr);

    try std.testing.expectEqual(@as(i32, 0), nox_fs_exists_raw("/definitely/does/not/exist/nox_ee1_test"));

    nox_fs_write_string_raw(null, full_path.ptr, "hi");
    try std.testing.expectEqual(@as(i32, 1), nox_fs_exists_raw(full_path.ptr));
    try std.testing.expectEqual(@as(i32, 1), nox_fs_is_file_raw(full_path.ptr));
    try std.testing.expectEqual(@as(i32, 0), nox_fs_is_dir_raw(full_path.ptr));

    const tmp_z = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}", .{testTmpPrefix()}, 0);
    defer std.heap.page_allocator.free(tmp_z);
    try std.testing.expectEqual(@as(i32, 1), nox_fs_exists_raw(tmp_z.ptr));
    try std.testing.expectEqual(@as(i32, 1), nox_fs_is_dir_raw(tmp_z.ptr));
    try std.testing.expectEqual(@as(i32, 0), nox_fs_is_file_raw(tmp_z.ptr));
}

test "Faz III.3: nox_fs_read_to_string_raw (fstat-tabanli tek-tahsis) dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    var full_buf: [64]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_buf, "{s}/nox_iii3_read_test_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(full_path.ptr);

    nox_fs_write_string_raw(rt, full_path.ptr, "hello world");
    try std.testing.expect(g_last_ok);

    const str = @import("../str.zig");
    const content = nox_fs_read_to_string_raw(rt, full_path.ptr) orelse return error.Failed;
    defer str.nox_str_release(rt, content);
    try std.testing.expectEqualStrings("hello world", std.mem.sliceTo(content, 0));
    try std.testing.expect(g_last_ok);
}

test "Faz III.3: nox_fs_append_string_raw dosyayi KISALTMAZ, SONUNA ekler" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    var full_buf: [64]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_buf, "{s}/nox_iii3_append_test_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(full_path.ptr);

    nox_fs_write_string_raw(rt, full_path.ptr, "abc");
    nox_fs_append_string_raw(rt, full_path.ptr, "def");
    try std.testing.expect(g_last_ok);

    const str = @import("../str.zig");
    const content = nox_fs_read_to_string_raw(rt, full_path.ptr) orelse return error.Failed;
    defer str.nox_str_release(rt, content);
    try std.testing.expectEqualStrings("abcdef", std.mem.sliceTo(content, 0));
}

test "Faz III.3: nox_fs_stat_raw boyut/mtime dogru doner" {
    var full_buf: [64]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_buf, "{s}/nox_iii3_stat_test_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(full_path.ptr);

    nox_fs_write_string_raw(null, full_path.ptr, "12345");
    nox_fs_stat_raw(full_path.ptr);
    try std.testing.expect(g_last_ok);
    try std.testing.expectEqual(@as(i64, 5), nox_fs_stat_size_raw());
    try std.testing.expect(nox_fs_stat_mtime_ms_raw() > 0);

    nox_fs_stat_raw("/definitely/does/not/exist/nox_iii3_test");
    try std.testing.expect(!g_last_ok);
}

test "Faz III.3: nox_fs_read_dir_raw dizin girdilerini dogru doner (./.. haric)" {
    const asap = @import("../alloc/asap.zig");
    const str = @import("../str.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    var dir_buf: [64]u8 = undefined;
    const dir_path = try std.fmt.bufPrintZ(&dir_buf, "{s}/nox_iii3_readdir_{d}", .{ testTmpPrefix(), std.c.getpid() });
    _ = std.c.mkdir(dir_path.ptr, 0o755);
    defer _ = std.c.rmdir(dir_path.ptr);

    var f1_buf: [80]u8 = undefined;
    const f1_path = try std.fmt.bufPrintZ(&f1_buf, "{s}/nox_iii3_readdir_{d}/a.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(f1_path.ptr);
    nox_fs_write_string_raw(null, f1_path.ptr, "x");

    var f2_buf: [80]u8 = undefined;
    const f2_path = try std.fmt.bufPrintZ(&f2_buf, "{s}/nox_iii3_readdir_{d}/b.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(f2_path.ptr);
    nox_fs_write_string_raw(null, f2_path.ptr, "y");

    const list_ptr = nox_fs_read_dir_raw(rt, dir_path.ptr) orelse return error.Failed;
    const bytes: [*]u8 = @ptrCast(list_ptr);
    const count: usize = @intCast(@as(*align(1) i64, @ptrCast(bytes)).*);
    try std.testing.expectEqual(@as(usize, 2), count);

    var saw_a = false;
    var saw_b = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const addr: usize = @bitCast(@as(*align(1) i64, @ptrCast(bytes + LIST_HEADER_SIZE + FIELD_SLOT_SIZE * i)).*);
        const p: [*:0]u8 = @ptrFromInt(addr);
        defer str.nox_str_release(rt, p);
        const name = std.mem.sliceTo(p, 0);
        if (std.mem.eql(u8, name, "a.txt")) saw_a = true;
        if (std.mem.eql(u8, name, "b.txt")) saw_b = true;
    }
    arc.nox_rc_release(rt, list_ptr, LIST_HEADER_SIZE + FIELD_SLOT_SIZE * count);
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "Faz III.3: nox_fs_copy_raw/rename_raw/remove_file_raw/create_dir_raw dogru calisir" {
    const asap = @import("../alloc/asap.zig");
    const rt = asap.nox_runtime_init() orelse return error.InitFailed;
    defer asap.nox_runtime_deinit(rt);

    const str = @import("../str.zig");
    var src_buf: [64]u8 = undefined;
    const src_path = try std.fmt.bufPrintZ(&src_buf, "{s}/nox_iii3_copy_src_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    var dst_buf: [64]u8 = undefined;
    const dst_path = try std.fmt.bufPrintZ(&dst_buf, "{s}/nox_iii3_copy_dst_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    var ren_buf: [64]u8 = undefined;
    const ren_path = try std.fmt.bufPrintZ(&ren_buf, "{s}/nox_iii3_copy_ren_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(src_path.ptr);
    defer _ = std.c.unlink(dst_path.ptr);
    defer _ = std.c.unlink(ren_path.ptr);

    nox_fs_write_string_raw(rt, src_path.ptr, "copy me");
    nox_fs_copy_raw(src_path.ptr, dst_path.ptr);
    try std.testing.expect(g_last_ok);
    {
        const content = nox_fs_read_to_string_raw(rt, dst_path.ptr) orelse return error.Failed;
        defer str.nox_str_release(rt, content);
        try std.testing.expectEqualStrings("copy me", std.mem.sliceTo(content, 0));
    }
    try std.testing.expectEqual(@as(i32, 1), nox_fs_exists_raw(src_path.ptr));

    nox_fs_rename_raw(dst_path.ptr, ren_path.ptr);
    try std.testing.expect(g_last_ok);
    try std.testing.expectEqual(@as(i32, 0), nox_fs_exists_raw(dst_path.ptr));
    try std.testing.expectEqual(@as(i32, 1), nox_fs_exists_raw(ren_path.ptr));

    nox_fs_remove_file_raw(src_path.ptr);
    try std.testing.expect(g_last_ok);
    try std.testing.expectEqual(@as(i32, 0), nox_fs_exists_raw(src_path.ptr));

    var dir_buf: [64]u8 = undefined;
    const dir_path = try std.fmt.bufPrintZ(&dir_buf, "{s}/nox_iii3_mkdir_{d}", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.rmdir(dir_path.ptr);
    nox_fs_create_dir_raw(dir_path.ptr);
    try std.testing.expect(g_last_ok);
    try std.testing.expectEqual(@as(i32, 1), nox_fs_is_dir_raw(dir_path.ptr));
}

// Faz BB.1: `g_last_ok`nin `threadlocal` OLMASININ, İKİ GERÇEK OS iş
// parçacığının AYNI ANDA `nox.fs` ÇAĞIRDIĞINDA birbirinin bayrağını
// EZMEDİĞİNİ kanıtlar — biri BAŞARISIZ (var olmayan yol), diğeri BAŞARILI
// (gerçek yazma+okuma) işlemi TEKRAR TEKRAR, AYNI ANDA yapar; HER iş
// parçacığı KENDİ `nox_fs_last_op_ok()` sonucunu GÖZLEMLER — paylaşılan bir
// bayrak OLSAYDI bu SONUÇLAR ARA SIRA birbirini EZERDİ.
test "g_last_ok threadlocal: iki gerçek OS iş parçacığı bağımsız bayrak görür" {
    // Bu dosya ZATEN "ham libc çağrıları" katmanında (bkz. modül üstü not) —
    // `std.testing.tmpDir`/`std.Io.Dir` KARMAŞIKLIĞINDAN kaçınmak İÇİN
    // `/tmp` altında PID'e göre BENZERSİZ bir yol DOĞRUDAN inşa edilir.
    var full_buf: [64]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&full_buf, "{s}/nox_bb1_fs_test_{d}.txt", .{ testTmpPrefix(), std.c.getpid() });
    defer _ = std.c.unlink(full_path.ptr);

    const Worker = struct {
        fn failing(iterations: usize, all_false: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                _ = nox_fs_read_to_string_raw(null, "/definitely/does/not/exist/nox_bb1_test");
                if (nox_fs_last_op_ok() != 0) all_false.* = false;
            }
        }
        fn succeeding(iterations: usize, path: [*:0]const u8, all_true: *bool) void {
            var i: usize = 0;
            while (i < iterations) : (i += 1) {
                nox_fs_write_string_raw(null, path, "hi");
                if (nox_fs_last_op_ok() == 0) all_true.* = false;
            }
        }
    };

    var all_false = true;
    var all_true = true;
    const thread_a = try std.Thread.spawn(.{}, Worker.failing, .{ 2000, &all_false });
    const thread_b = try std.Thread.spawn(.{}, Worker.succeeding, .{ 2000, full_path.ptr, &all_true });
    thread_a.join();
    thread_b.join();

    try std.testing.expect(all_false);
    try std.testing.expect(all_true);
}
