# Kararlı liste başlığı denetimi (R1-P1.1 / P1.2 / P1.3) — 2026-11-24

Kapsam: v2.2.43 liste başlığı (`[len][cap][data][satır içi elemanlar]`, başlık ASLA taşınmaz). Yöntem: graphify sorguları + kaynak okuma (`runtime/alloc/arc.zig`,
`abi_layout`). **Bu belge yalnızca doğrulanmış gerçekleri ve açık soruları ayırır; kanıtlanmamış güvenlik iddiası içermez.**

## Doğrulanan gerçekler (kaynak: `runtime/alloc/arc.zig` 450–520)
- Büyüme (`nox_list_reserve_cap`) başlığı taşımaz; yalnızca `data`/`cap` alanlarını günceller → `ys = xs` takma adları büyümeyi görür (D1.2 hedefi).
- Satır içi liste ilk büyümede `[stash][elemanlar]` ayrı tampona geçer; stash = satır içi kapasite (serbest bırakma boyutu için). Sonraki büyümeler `nox_list_realloc` ile eski tamponu **serbest bırakır**.
- Bellek yetersizliğinde `null` döner ve başlığa dokunulmaz (v2.2.46 P0.2: `append` artık null'da `nox_out_of_memory` ile durur).
- Arena listesi (`nox_arena_list_grow`): eski tampon arena yıkılana kadar "çöp" olarak yaşar (serbest bırakılmaz).

## P1.3 — eşzamanlı erişim (doğrulandı: TASARIM SINIRI, kilitsiz yol güvenli DEĞİL)
- `listSetData` ve `listSetCap` **ayrı, atomik olmayan** yazmalardır; kilitsiz yolda büyürken başka bir iş parçacığı `len/cap/data` üçlüsünü tutarsız görebilir.
- Ayrı tampon durumunda `nox_list_realloc` eski tamponu serbest bırakır: eski `data` göstericisini tutan eşzamanlı okuyucu kullanım-sonrası-serbest-bırakma yaşar.
- Güvenli yol: yalnızca paylaşılan liste kipi (`dyn_share`, `list_locks`, SharedList) — büyüme/okuma kilit altında. Kullanıcıya görünür bir "paylaşım" bildirimi yoktur; derleyici paylaşılan global/yığın liste için bu kipi seçer. **Genel kilit eklenmemeli** (liste sözleşmesi).
- Açık soru (karar gerektirir): paylaşım kipine girmeyen ama iki fiber/işçi arasında closure/`spawn` argümanıyla taşınan listeler için derleyicinin yeterli kanıtı var mı? Bu belge bunu **kanıtlamaz**; ayrı bir M:N yarış testi (TSan benzeri) gerekir.

## P1.2 — FFI sözleşmesi (kısmen doğrulandı)
- Çalışma zamanında `nox_list_*detach/adopt*` adlı bir API **yoktur** (grep: runtime/compiler/stdlib). Rapordaki `detach/adopt` kavramı için kaynakta karşılık bulunamadı; madde "belirsiz/yanlış ad" olarak işaretlendi.
- FFI'ye ham liste göstericisi geçirmek `AGENTS.md` §9.5 güven sınırı altındadır (`extern def` çıplak native yetki). `data - 16` türü varsayımlar (ARC başlığı) **liste için artık geçersizdir**: liste başlığı ARC başlığı + `[len][cap][data]`'dır; dışarıdan `data`'dan geriye gidilmemeli.
- Yapılacak: `docs/` altında "FFI'ye liste/`str` geçirme" bölümüne, hangi alanın kararlı olduğunu (yalnızca `nox.ffi` sarmalayıcıları) ve ham göstericinin desteklenmediğini yazmak.

## P1.1 — sahiplik yolları denetim listesi (durum)
| Yol | Durum |
|---|---|
| ARC retain/release, kararlı başlık | v2.2.43 testleri (`ys = xs`, büyüme) — kapsandı |
| Cycle collector (`list[list[..]]`) | v2.2.43 sızıntı testleri — kapsandı |
| Ayrı tampon + stash | `listInlineCap` ile kapsandı; **DebugAllocator ile serbest bırakma boyutu doğrulaması** ayrı test olarak yok |
| Arena (kaçmayan listeler) | büyüme çöp bırakır (tasarım) |
| SharedList / M:N | bkz. P1.3 (kilitli yol), kilitsiz taşınma açık |
| Sabit genişlikli / heap elemanlı / iç içe | codegen golden'ları var; stdlib listeleri toplu denetlenmedi |
| Exception cleanup | v1.11.2 sızıntı turu; liste-özel yeni test yok |

## Sonuç
P1.1: denetim tablosu çıkarıldı, **eksik testler adlandırıldı** (ayrı tampon serbest bırakma boyutu, stdlib listeleri). P1.2: ham ad bulunamadı + belgelenecek sözleşme.
P1.3: kilitsiz büyümenin tasarım sınırı doğrulandı; kapsam dışı taşınma için M:N yarış testi açık. Üçü de listede `[~]` kalır.

## v2.2.51 kapanışı
- P1.1: ayrı tampon/stash büyümesi ve blok boyutu serbest bırakma denetimi `runtime/alloc/arc.zig` testi "R1-P1.1" ile eklendi (satır içi → ayrı tampon → havuz sınıfları → büyük blok; DebugAllocator boyut uyuşmazlığı/sızıntı denetimi). Stdlib listeleri aynı codegen yolundan geçer; stdlib golden testleri DebugAllocator sızıntı denetimiyle koşar.
- P1.2: sözleşme `docs/language/ffi.md` içinde yazıldı.
- P1.3: kapsam dışı taşınma: mutasyonlu `spawn` liste argümanı derleme hatasıdır (`SpawnSharedMutation`); paylaşılan modül listeleri yalnızca kilitli yoldan erişilir. Mevcut kanıt: `typecheck_cases/err_spawn_shared_list_*`, `codegen_cases/mn_shared_list*`, `mn_dyn_spawn_shared_mutation`, `tests/stress/mn_shared_churn.nox.in`. Kilitsiz büyüme tasarım sınırı olarak kalır (genel kilit eklenmez).
