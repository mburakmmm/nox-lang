//! `nox.sharedmem` Zig kabuğu — Faz NN.6 (bkz. proje belleği "nyx v2
//! limitasyon listesi doğrulaması"): GERÇEK, isimli bir paylaşımlı bellek
//! ilkeli — `shm_open`+`mmap(MAP_SHARED)` (POSIX: macOS/Linux) İLE
//! BAĞIMSIZ (fork edilmemiş) `noxc run` süreçlerinin AYNI bellek bölgesini
//! GÖRMESİNİ sağlar. Mevcut runtime'da HİÇ mmap/paylaşımlı-bellek kodu
//! YOKTU — bu SIFIRDAN yeni bir ilkel.
//!
//! **Senkronizasyon**: segmentin BAŞINDAKİ gömülü bir `i32` kilit sözcüğü
//! + atomik `cmpxchgWeak` tabanlı bir spinlock (isimli bir POSIX semaforu
//! DEĞİL — v1 İçin EN AZ hareketli parça: ekstra bir OS nesnesi/temizlik
//! sorumluluğu YOK).
//!
//! **Segment düzeni**: `[lock: i32 @0][kullanılan_boyut: i64 @8]
//! [veri...@16+]` — sabit toplam boyut (`open` çağrısında İSTENEN).
//!
//! **Kaynak yönetimi**: `nox_shm_close_raw` SADECE bu process'in mmap'ini
//! kapatır (segmenti SİLMEZ) — `nox_shm_unlink_raw` segmenti KALICI
//! olarak siler (`sqlite.nox`nin dosya-tabanlı "kullanıcı KENDİSİ ne
//! zaman sileceğine karar verir" felsefesiyle TUTARLI).
//!
//! **Bilinçli v1 kapsamı**: Windows İçİN de (`CreateFileMappingA`/
//! `MapViewOfFile`, sqlite.zig'in AYNI Windows-fallback deseni) GERÇEK bir
//! implementasyon HEDEFLENDİ (stub/hata DÖNDÜRÜLMEDİ).

const std = @import("std");
const builtin = @import("builtin");
const arc = @import("../alloc/arc.zig");
const str_mod = @import("../str.zig");

fn dupeToNoxStr(rt: ?*anyopaque, bytes: []const u8) ?[*:0]u8 {
    return str_mod.nox_str_from_bytes(rt, bytes);
}

fn dupeEmpty(rt: ?*anyopaque) ?[*:0]u8 {
    return dupeToNoxStr(rt, "");
}

const HEADER_SIZE: usize = 16; // [lock: i32][pad: i32][used_size: i64]
const LOCK_OFFSET: usize = 0;

const Kernel32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn CreateFileMappingA(
        hFile: ?*anyopaque,
        lpAttributes: ?*anyopaque,
        flProtect: u32,
        dwMaximumSizeHigh: u32,
        dwMaximumSizeLow: u32,
        lpName: [*:0]const u8,
    ) callconv(.c) ?*anyopaque;
    extern "kernel32" fn OpenFileMappingA(dwDesiredAccess: u32, bInheritHandle: i32, lpName: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn MapViewOfFile(hFileMappingObject: ?*anyopaque, dwDesiredAccess: u32, dwFileOffsetHigh: u32, dwFileOffsetLow: u32, dwNumberOfBytesToMap: usize) callconv(.c) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: ?*anyopaque) callconv(.c) i32;
    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.c) i32;
    extern "kernel32" fn GetLastError() callconv(.c) u32;
} else struct {};

const ShmHandle = struct {
    map_ptr: []align(std.heap.page_size_min) u8,
    size: usize,
    win_mapping: if (builtin.os.tag == .windows) ?*anyopaque else void = if (builtin.os.tag == .windows) null else {},
    posix_fd: if (builtin.os.tag == .windows) void else std.posix.fd_t = if (builtin.os.tag == .windows) {} else -1,

    fn data(self: *ShmHandle) []u8 {
        return self.map_ptr[HEADER_SIZE..self.size];
    }

    fn lockWord(self: *ShmHandle) *std.atomic.Value(i32) {
        return @ptrCast(@alignCast(self.map_ptr[LOCK_OFFSET..].ptr));
    }
};

fn openPosix(name: []const u8, size: usize) !*ShmHandle {
    var name_buf: [256]u8 = undefined;
    const shm_name = try std.fmt.bufPrintZ(&name_buf, "/{s}", .{name});

    const fd = std.c.shm_open(shm_name, @bitCast(std.posix.O{ .ACCMODE = .RDWR, .CREAT = true }), @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.ShmOpenFailed;
    errdefer _ = std.c.close(fd);

    const total_size = HEADER_SIZE + size;
    // `shm_open` `O_CREAT`, HEM YENİ HEM ZATEN VAR OLAN bir segmenti AÇAR —
    // ama macOS'ta ZATEN boyutlandırılmış bir POSIX shm nesnesine TEKRAR
    // `ftruncate` çağırmak `EINVAL` İLE BAŞARISIZ olur (Linux'un aksine,
    // GERÇEK bir iki-process repro İLE KANITLANDI — bu YÜZDEN başarısızlığı
    // KOŞULSUZ ölümcül SAYMAK, İKİNCİ/SONRAKİ açan HER process'i BOZAR,
    // yani ÇAPRAZ-PROCESS paylaşımın TAMAMI çalışmaz hale gelir). Önce
    // MEVCUT boyutu `fstat` İLE kontrol et — ZATEN yeterince büyükse
    // `ftruncate` hatasını YOK SAY (segment ZATEN doğru boyutta).
    var st: std.c.Stat = undefined;
    const existing_size: i64 = if (std.c.fstat(fd, &st) == 0) st.size else 0;
    if (existing_size < @as(i64, @intCast(total_size))) {
        if (std.c.ftruncate(fd, @intCast(total_size)) != 0) return error.FtruncateFailed;
    }

    const map = try std.posix.mmap(
        null,
        total_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    const gpa = std.heap.page_allocator;
    const h = try gpa.create(ShmHandle);
    h.* = .{ .map_ptr = map, .size = total_size, .posix_fd = fd };
    return h;
}

fn openWindows(name: []const u8, size: usize) !*ShmHandle {
    if (builtin.os.tag != .windows) unreachable;
    var name_buf: [256]u8 = undefined;
    const win_name = try std.fmt.bufPrintZ(&name_buf, "noxshm_{s}", .{name});
    const total_size: usize = HEADER_SIZE + size;

    const PAGE_READWRITE: u32 = 0x04;
    const mapping = Kernel32.CreateFileMappingA(
        @ptrFromInt(0xFFFFFFFFFFFFFFFF), // INVALID_HANDLE_VALUE: sayfalama dosyası destekli
        null,
        PAGE_READWRITE,
        0,
        @intCast(total_size),
        win_name,
    ) orelse return error.CreateFileMappingFailed;

    const FILE_MAP_ALL_ACCESS: u32 = 0xF001F;
    const view = Kernel32.MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, total_size) orelse {
        _ = Kernel32.CloseHandle(mapping);
        return error.MapViewOfFileFailed;
    };

    const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(view));
    const gpa = std.heap.page_allocator;
    const h = try gpa.create(ShmHandle);
    h.* = .{ .map_ptr = bytes[0..total_size], .size = total_size, .win_mapping = mapping };
    return h;
}

pub export fn nox_shm_open_raw(name: ?[*:0]const u8, size: i64) callconv(.c) ?*anyopaque {
    const n = name orelse return null;
    if (size <= 0) return null;
    const h = if (builtin.os.tag == .windows)
        openWindows(str_mod.nox_str_slice(n), @intCast(size)) catch return null
    else
        openPosix(str_mod.nox_str_slice(n), @intCast(size)) catch return null;
    return h;
}

pub export fn nox_shm_is_null_ptr(p: ?*anyopaque) callconv(.c) i64 {
    return if (p == null) 1 else 0;
}

/// Basit atomik spinlock — `cmpxchgWeak` İLE `0 -> 1` geçişini BEKLER
/// (meşgul-bekleme, isimli bir semafor GEREKTİRMEZ — v1 İçin EN AZ
/// hareketli parça).
pub export fn nox_shm_lock_raw(handle: ?*anyopaque) callconv(.c) void {
    const h: *ShmHandle = @ptrCast(@alignCast(handle orelse return));
    const word = h.lockWord();
    while (word.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        std.Thread.yield() catch {};
    }
}

pub export fn nox_shm_unlock_raw(handle: ?*anyopaque) callconv(.c) void {
    const h: *ShmHandle = @ptrCast(@alignCast(handle orelse return));
    h.lockWord().store(0, .release);
}

/// `offset`ten BAŞLAYARAK `len` bayt OKUR (veri bölgesine GÖRELİ, başlık
/// HARİÇ) — sınır DIŞI bir istek BOŞ dize döner.
pub export fn nox_shm_read_bytes_raw(rt: ?*anyopaque, handle: ?*anyopaque, offset: i64, len: i64) callconv(.c) ?[*:0]u8 {
    const h: *ShmHandle = @ptrCast(@alignCast(handle orelse return dupeEmpty(rt)));
    if (offset < 0 or len < 0) return dupeEmpty(rt);
    const d = h.data();
    const o: usize = @intCast(offset);
    const l: usize = @intCast(len);
    if (o + l > d.len) return dupeEmpty(rt);
    return dupeToNoxStr(rt, d[o .. o + l]);
}

/// `offset`ten BAŞLAYARAK `data`yı YAZAR — sınır DIŞI bir istek SESSİZCE
/// YOK SAYILIR (`.nox` tarafı boyutu KENDİSİ bilir/kontrol eder).
pub export fn nox_shm_write_bytes_raw(handle: ?*anyopaque, offset: i64, data_ptr: ?[*]const u8, data_len: i64) callconv(.c) void {
    const h: *ShmHandle = @ptrCast(@alignCast(handle orelse return));
    if (offset < 0 or data_len < 0) return;
    const d = h.data();
    const o: usize = @intCast(offset);
    const l: usize = @intCast(data_len);
    if (o + l > d.len) return;
    const src = data_ptr orelse return;
    @memcpy(d[o .. o + l], src[0..l]);
}

/// `offset`teki 8 baytı (little-endian) bir `i64` olarak OKUR — sınır DIŞI
/// bir istek `0` döner. Nox'un `str`i strlen-tabanlı (sonu-NUL) bir temsil
/// olduğundan (bkz. `runtime/str.zig` modül-üstü not) GÖMÜLÜ bir NUL bayt
/// (int'in çoğu değeri İçin YAYGIN — ör. küçük pozitif int'lerin yüksek
/// baytları hep `0x00`) `str` üzerinden geçirilirse ARC boyut hesabı
/// (`strlen`) BOZULUR (gerçek bir çift-serbest-bırakma/boyut-uyuşmazlığı
/// çökmesiyle KANITLANDI, test yazarken bulundu) — bu YÜZDEN int'ler İçin
/// `str` ARA KATMANI TAMAMEN ATLANIR, ham baytlar DOĞRUDAN belleğe
/// okunur/yazılır.
pub export fn nox_shm_read_i64_raw(handle: ?*anyopaque, offset: i64) callconv(.c) i64 {
    const h: *ShmHandle = @ptrCast(@alignCast(handle orelse return 0));
    if (offset < 0) return 0;
    const d = h.data();
    const o: usize = @intCast(offset);
    if (o + 8 > d.len) return 0;
    var buf: [8]u8 = undefined;
    @memcpy(&buf, d[o..][0..8]);
    return @bitCast(buf);
}

/// `offset`e 8 baytı (little-endian) YAZAR — sınır DIŞI bir istek SESSİZCE
/// YOK SAYILIR.
pub export fn nox_shm_write_i64_raw(handle: ?*anyopaque, offset: i64, value: i64) callconv(.c) void {
    const h: *ShmHandle = @ptrCast(@alignCast(handle orelse return));
    if (offset < 0) return;
    const d = h.data();
    const o: usize = @intCast(offset);
    if (o + 8 > d.len) return;
    const buf: [8]u8 = @bitCast(value);
    @memcpy(d[o..][0..8], &buf);
}

/// SADECE bu process'in eşlemesini (mmap/`MapViewOfFile`) kapatır —
/// segmentin KENDİSİNİ SİLMEZ (bkz. `nox_shm_unlink_raw`).
pub export fn nox_shm_close_raw(handle: ?*anyopaque) callconv(.c) void {
    const h: *ShmHandle = @ptrCast(@alignCast(handle orelse return));
    if (builtin.os.tag == .windows) {
        _ = Kernel32.UnmapViewOfFile(h.map_ptr.ptr);
        if (h.win_mapping) |m| _ = Kernel32.CloseHandle(m);
    } else {
        std.posix.munmap(h.map_ptr);
        _ = std.c.close(h.posix_fd);
    }
    std.heap.page_allocator.destroy(h);
}

/// Segmenti KALICI olarak SİLER (POSIX: `shm_unlink` — Windows'ta İSİMLİ
/// eşlemeler SON handle kapandığında KENDİLİĞİNDEN silinir, bu YÜZDEN
/// Windows'ta bu fonksiyon bilinçli bir NO-OP'tur).
pub export fn nox_shm_unlink_raw(name: ?[*:0]const u8) callconv(.c) void {
    if (builtin.os.tag == .windows) return;
    const n = name orelse return;
    var name_buf: [256]u8 = undefined;
    const shm_name = std.fmt.bufPrintZ(&name_buf, "/{s}", .{str_mod.nox_str_slice(n)}) catch return;
    _ = std.c.shm_unlink(shm_name);
}
