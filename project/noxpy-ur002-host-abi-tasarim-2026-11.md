# UR-002 tasarım taslağı — `include/nox_host.h` (deneysel v1) + açık dışa aktarım

Durum: **TASLAK (onay bekliyor)**. Kaynak gereksinim: NoxPy `UPSTREAM_REQUIREMENTS.md` UR-002. Kullanıcı kararı (2026-11-25): yeni public C ABI olarak tasarlanıp eklenecek, kararlılık = deneysel v1 (`abi_version`/`struct_size`, `docs/apis/stability.md`'de experimental, AGENTS.md §9.5 güven sınırı notu). Değişmez ilkeler: #4 (iç bellek düzeni sızmaz), #6 (global durum yok), #3 (unwind yok).

## Mevcut zemin (okundu)

- `include/nox_embed.h` (mobil gömme ABI 1): `NoxHostAllocator`, `NoxHostConfig`, durum kodları, `nox_exception_pending/take/release`, `nox_str_from_cstr`. Tek-uygulama olay döngüsü (`nox_app_*`, `nox_embed_user_entry`) — çok-işlevli tipli çağrı ABI'si DEĞİL.
- Codegen kütüphane kipleri (`compiler/codegen_qbe/registration.zig` ~2598-2672): `library_mode` (mobil: `nox_embed_user_entry(rt)` + `nox_embed_bind`), `lib_split` (iç `--selfhost-obj`: `nox_lib_init(rt)`/`nox_lib_fini(rt)`, async/spawn yok). Her `def` gizli ilk parametre `rt` alır (`RT_PARAM`).
- `RuntimeState` oluşturma: `nox_runtime_init()` (`runtime/alloc/asap.zig:973`), `embed.zig createWith` (host ayırıcısı).
- UR-001 (v2.2.75): `--emit-obj/--emit-static-lib/--emit-shared-lib` masaüstünde çalışıyor; dışa aktarım yüzeyi YOK.

## Önerilen tasarım

1. **Anahtar:** `noxc build --emit-obj|--emit-static-lib|--emit-shared-lib --host-abi <dosya>`. `--host-abi` yokken hiçbir şey değişmez. Dışa aktarılan işlevler `@export` taşıyan üst-düzey `def`ler (UR-007 `expand --json` ile AYNI küme).
2. **Genel başlık `include/nox_host.h`** (C/C++, `extern "C"`, yalnız `<stdint.h>/<stddef.h>`):
   - `NOX_HOST_ABI_VERSION 1`, `NoxHostStatus` (OK, ERR_INVAL, ERR_VERSION, ERR_NOMEM, ERR_EXCEPTION, ERR_OVERFLOW, ERR_INVALID_HANDLE ...), `NoxHostSpan {const uint8_t *data; size_t len;}`, `NoxHostError` (opak), `NoxHostContext` (opak).
   - `nox_host_abi_version()`, `nox_host_context_create(const NoxHostContextConfig*, NoxHostContext**)` (`struct_size`+`abi_version`; isteğe bağlı `NoxHostAllocator` — `nox_embed.h` ile aynı tür), `nox_host_context_destroy`.
   - Hata: `nox_host_error_release(NoxHostError*)` (inceleme işlevleri UR-005).
3. **Modül başına üretilen semboller** (yalnız `--host-abi` ile):
   - `NoxHostStatus nox_host_module_init(NoxHostContext*)` / `void nox_host_module_fini(NoxHostContext*)` — modül global durumu bağlam başına (`nox_lib_init/fini` mantığı); iki modül/iki bağlam birbirinden bağımsız.
   - Her `@export def f(a: int, b: float) -> int` için `NoxHostStatus nox_host_export_<modül>_f(NoxHostContext *ctx, int64_t a, double b, int64_t *out, NoxHostError **err)`: bağlamdan RuntimeState'i alır, işlevi çağırır, bekleyen Nox istisnasını **yutup** `NOX_HOST_ERR_EXCEPTION` + `NoxHostError*` olarak döner (süreç sonlanmaz). Özel `rt` işaretçisi hiçbir zaman C'ye geçmez.
   - Sembol adı UR-007 `c_symbol` ile birebir aynı (`nox_host_export_<modül>_<ad>`); `<modül>` = `--module` ya da dosya adı.
4. **Kapsam (UR-002'de):** skaler imzalar (`int`→`int64_t`, `float`→`double`, `bool`→`uint8_t`, `None` dönüş) ve istisna sarmalama. `str`/`bytes` span'leri **UR-006**'da, ayrıntılı istisna inceleme/OOM-trap koruması **UR-005**'te, gizli sembol/global durum **UR-003**'te, yabancı iş parçacığı **UR-004**'te. Desteklenmeyen imza (str, sınıf, varsayılan değer vb.) `--host-abi` ile derleme hatası verir (açık ileti).
5. **İki backend:** sarmalayıcılar hem QBE hem LLVM kod üretiminde (golden test + iki backend); LLVM varsayılan; masaüstü hedefler.
6. **Test:** C host testi yalnız `#include "nox_host.h"` ile (nox_runtime_* bildirimi yok): `add(20, 22) == 42`, istisna → `ERR_EXCEPTION` (süreç yaşar), bağlam oluştur/yık, sızıntı yok.

## Açık karar noktaları (kullanıcıya soruldu)

- A. `--host-abi` açık bayrak mı (öneri), `@export` varlığında otomatik mi?
- B. Aşamalama: UR-002 yalnız skalerlerle (öneri) mi, `str` için UR-006 beklemeden kaba bir span mı?
