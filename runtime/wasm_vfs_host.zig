//! `wasm32-freestanding`: sanal dosya sistemini (`wasm_vfs.zig`) KALICI kılmak isteyen host'un çağırdığı dışa aktarımlar (spec §3.350). Host, modül başlamadan önce
//! `nox_vfs_host_put`/`_mkdir` ile ağacı doldurur (ör. diskteki bir dizinden ya da IndexedDB'den) ve çıkışta `nox_vfs_host_snapshot` ile anlık görüntüyü alıp saklar.
//! Hiçbir `nox_host` import'u gerektirmez; `--threads`te de güvenlidir (VFS kilidi). Bu semboller yalnızca `nox.fs`/`nox.sqlite` kullanan programlara dışa aktarılır
//! (`noxc` bağlayıcıya `--export` verir); kullanmayan programlar etkilenmez.

const std = @import("std");
const vfs = @import("wasm_vfs.zig");

const gpa = std.heap.page_allocator;

/// Host'un modül belleğine bayt yazabilmesi için `len` baytlık geçici bir blok ayırır. Hata `null` (0).
export fn nox_vfs_host_alloc(len: usize) callconv(.c) ?[*]u8 {
    const block = gpa.alloc(u8, @max(len, 1)) catch return null;
    return block.ptr;
}

/// `nox_vfs_host_alloc` ya da `nox_vfs_host_snapshot`un döndürdüğü bloğu serbest bırakır (`len` aynı olmalıdır).
export fn nox_vfs_host_free(ptr: ?[*]u8, len: usize) callconv(.c) void {
    const p = ptr orelse return;
    gpa.free(p[0..@max(len, 1)]);
}

/// Dosyayı (üst dizinleriyle) oluşturur/değiştirir; `0` başarı, `-1` hata.
export fn nox_vfs_host_put(path: [*]const u8, path_len: usize, data: [*]const u8, data_len: usize) callconv(.c) i32 {
    return if (vfs.hostPut(path[0..path_len], data[0..data_len])) 0 else -1;
}

/// `mkdir -p`; `0` başarı, `-1` hata.
export fn nox_vfs_host_mkdir(path: [*]const u8, path_len: usize) callconv(.c) i32 {
    return if (vfs.hostMkdirAll(path[0..path_len])) 0 else -1;
}

/// Ağacın serileştirilmiş görüntüsünü döndürür (biçim: `wasm_vfs.snapshot`); uzunluk `out_len`e yazılır. Boş ağaçta bile geçerli bir (uzunluğu 0 olabilir) blok döner.
/// Host baytları kopyaladıktan sonra `nox_vfs_host_free(ptr, len)` çağırmalıdır. Hata `null`.
export fn nox_vfs_host_snapshot(out_len: *usize) callconv(.c) ?[*]u8 {
    const snap = vfs.snapshot() orelse return null;
    out_len.* = snap.len;
    if (snap.len == 0) {
        gpa.free(snap);
        const one = gpa.alloc(u8, 1) catch return null;
        return one.ptr;
    }
    return snap.ptr;
}
