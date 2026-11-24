# Native runtime — geçiş planı (R4+ YALNIZ PLAN), kapılar, rollback, durum

> **Kapsam uyarısı:** R0–R3 readiness'tır ve bu depoda yapılmıştır. **R4 ve sonrası gerçek runtime portu BU ÇALIŞMANIN DIŞINDADIR**; başlamak için ayrı kullanıcı onayı gerekir. "Nox runtime yazmaya hazır" ilanı ile "runtime Nox ile yazıldı" ilanı karıştırılmaz (görev belgesi Bölüm N son paragraf).

## 1. Durum (readiness, v2.2.64)

| Faz | Kapsam | Durum | Kanıt |
|---|---|---|---|
| R0 | envanter + capability audit | ✅ | `native-runtime-capability-audit.md`, inventory/manifest/DAG araçları |
| R1 | runtime-free leaf PoC + kapı | ✅ (macOS arm64 LLVM; Linux CI) | P01/P02/P02b/P04 + `neg_forbidden` |
| R2 | ham depolama/ABI/atomik/TLS | ✅ geçici shim ile; GAP-2/4/5/6/7 açık | P03/P05 |
| R3 | bootstrap allocator spike | ✅ | P06/P08 |
| R3b | P12 QEMU, QBE leaf, P09 mini ARC | ⏳ planlı, **koşulmadı** | bu belge §3 |
| R4–R8 | port | ⛔ kapsam dışı (plan) | §4 |

Çalıştırma: `python3 scripts/runtime_leaf_audit.py suite` → `VERDICT: GREEN (N fixture, 0 sapma)`.

## 2. Bölüm N kriter izlenebilirliği (13 kutu)

| # | Kriter | Durum | Kanıt / gerekçeli açık madde |
|---:|---|---|---|
| 1 | Self-hosting + önceki iki audit tamam; baseline/ABI sabit | KISMİ (dürüst) | Rapor 1/2 (sertleştirme + mühendislik/performans) tamam: v2.2.59–2.2.63 (`project/rapor2-sonuc-2026-11-24.md`); lexer/parser/formatter Nox'ta. **Açık:** typechecker + codegen'in Nox'a taşınması (Aşama 3) sürüyor — "derleyici tam self-hosting" kriteri HENÜZ sağlanmadı; ABI manifesti `native-runtime-symbols/layout.tsv`; baseline `native-runtime-performance.md` §1 |
| 2 | Mevcut özellikler vs doğrulanmış boşluklar repro seviyesinde | ✅ | capability-audit §2/§4 (C01–C30, GAP-2…13) |
| 3 | Runtime-free leaf eski runtime olmadan link/run | ✅ | P01–P06 suite (`noxrt.o` link satırında yok; son ikilide `nox_*` yok) |
| 4 | Yasak bağımlılıklar compile/obje seviyesinde yakalanıyor | ✅ (dış kapı) | `runtime_leaf_audit.py` + `neg_forbidden` (7 sınıf). **Derleyici-içi hata** kullanıcı kararı (M.1): şimdilik dış kapı; açık madde GAP-8/C23 |
| 5 | Ham storage/layout/pointer/aritmetik/atomik kabiliyetleri kanıtlandı | ✅/KISMİ | P02/P03/P04/P05; atomik shim ile; **açık:** GAP-2 (sarmalı/kayıpsız dönüşüm), GAP-5 (public API), GAP-7 (`@raw`) |
| 6 | Bootstrap allocator cycle'sız | ✅ | P06 (link-zamanı sağlayıcı; indirect çağrı yok — kapı doğrular) |
| 7 | Allocation-free fatal/OOM, kısmi init/fini test edildi | ✅ | P04 (fatal sink), P06 (OOM enjeksiyonu, geri alma, çift init/fini, yeniden yarat/yık) |
| 8 | Platform/assembly sınırları ve TLS/ABI ihtiyaçları belirlendi | ✅ | architecture §6; dependencies §1–§4; GAP-6 |
| 9 | Gerçek runtime symbol/layout manifesti + geçiş DAG'ı | ✅ | `native-runtime-{symbols,layout}.tsv`, `--dag` (architecture §3) |
| 10 | QBE/LLVM + hedef platform açıkları gerekçeli/ölçümlü/izlenebilir | KISMİ | §5 tablosu; QBE leaf ve hedef matrisi **KANITLANMADI** (açık, plan R3b) |
| 11 | Debug güvenlik yaklaşımı + fault injection stratejisi | ✅ | architecture §5 (spike'ta ledger/double-free/canary/OOM-enjeksiyonu çalışıyor) |
| 12 | Büyük mimari/dil kararları kullanıcı onayına sunuldu | ✅ | §6: M.1–M.9 TÜMÜ yanıtlandı (2026-11-24); uygulama gerektirenler (GAP-2/4/5/7, parmak izi, R9) port onayıyla birlikte |
| 13 | R4+ plan + rollback mekanizması | ✅ (plan) | §4 ve §7 |

## 3. R3b — readiness'ı tamamlayan, henüz KOŞULMAMIŞ spike'lar (sıralı)

| ID | Spike | Önkoşul | Kabul |
|---|---|---|---|
| P12 | QEMU'da (x86_64 önce) Zig managed runtime'sız minimal Nox çekirdeği: seri checksum | `runtime/freestanding/*` boot, QBE nesne yolu (GAP-12) | seri çıktı = beklenen checksum; `noxrt` yok |
| P09 | mini ARC nesnesi (retain/release/publication/trace callback), bağımsız raw allocator | P06 + atomik API kararı | çok-işçili sayaç + serbest bırakma sırası; sızıntı 0 |
| P10 | stable list-benzeri tampon (taşınan `data`, sabit başlık, OOM güvenliği) | P06 | alias + OOM enjeksiyonu |
| P11 | fiber bağlamı: register koruma, stack hizası, yield/resume (`swap_*.S` `extern def` ile) | assembly bağlama | callee-saved/FP durum testleri; derin yield |
| P13 | hedef ABI matrisi: pointer genişliği, endian, CPU özelliği, link kuralları | GAP-11 | Linux x86-64/aarch64, macOS, Windows, wasm32 satırları |

## 4. R4+ port planı (yalnız plan)

Genel kural (Kural 10): **önce eşdeğer port, sonra ayrı optimizasyon**; aynı anda davranış+algoritma+layout değiştirilmez. Her modül için *tek sahip* (Zig veya Nox), manifestte `owner` sütunu.

| Faz | Kapsam | Kapı |
|---|---|---|
| R4 | saf math/hash/bayt algoritmaları, str/list/dict yardımcıları; hibrit runtime (Zig+Nox aynı `rt` ABI'si); modül-bazlı build seçimi | mevcut uygulamalar tüm davranışlarını korur; ±%5 mikro; tam fixture korpusu (LLVM+QBE) |
| R5 | allocator (P06 → üretim), ARC, exception, cycle collector — **mevcut algoritma birebir** | fault injection, leak/double-free, cycle oracle (nesne-kimliği tabanlı), OOM, çok-işçili stres; ARC sıcak yol/GC duraklaması Zig referansına göre ölçülür |
| R6 | scheduler/fiber/worker/IO/TLS; assembly bağlantısı korunur | STW altında CPU yükü, kanal stresi, derin yield, HTTP gerçek iş yükü; Windows/WASM/freestanding farkları |
| R7 | native stdlib shim'leri (NNI/NAPI/HPy/FFI/embedding) | aynı public ABI testleri; kalıcı sağlayıcı manifesti |
| R8 | Stage0→Stage3 bootstrap, deterministik çıktı, Zig'siz temiz ortam | Zig runtime kaynakları/nesneleri/executable'ı olmadan temiz build+run |
| R9 | **Toolchain bağımsızlığı (kullanıcı kararı M.9: bu proje kapsamında)** | masaüstü `--target` çapraz derleme ve `--selfhost-obj` yedek yolunda `zig cc` yok (clang/lld/LLVM veya kendi bağlama stratejisi; Windows PE/COFF dahil); `zig` olmayan temiz ortamda kurulum + build + çapraz-link; ayrıca ayrı plan/ölçüm belgesi gerekir |

**Önkoşullar (kullanıcı onayı / tasarım):** GAP-2 codegen iyileştirmesi, GAP-4 `rt`'siz export, GAP-5 atomik API, GAP-7 `@raw` veya generator, GAP-8 prelude'suz nesne kipi, ABI parmak izi (abi.md §5).

## 5. QBE/LLVM ve hedef platform açık izleme tablosu

| Alan | LLVM | QBE | Not | Takip |
|---|---|---|---|---|
| Leaf nesne üretimi | `--selfhost-obj` (hosted, `--target`'sız) ✅ | ✗ (hosted QBE nesne yok; `--emit-obj` yalnız mobil) | prelude'un tamamı girer; dead-strip şart | GAP-8/12 |
| Ham ptr/volatile/fence | ✅ (`fence seq_cst`, `singlethread`) | KANITLANMADI | | R3b |
| Atomik (ARC imm) | ✅ `atomicrmw acq_rel` | hedefe özgü | ham-adres yok (GAP-5) | |
| Linux x86-64 | CI | CI | suite CI'da koşar; yerel kanıt yok | `gh run list` |
| macOS arm64 | ✅ (yerel) | KANITLANMADI | | |
| Windows | KANITLANMADI | — | `-dead_strip`/`--gc-sections` yerine MinGW/MSVC bayrakları | R3b |
| wasm32 | KANITLANMADI | **eklenmez** (İlke #5) | pointer genişliği vs i64 slot (C.2) | P13 |
| freestanding | ✗ (LLVM+freestanding reddedilir, `main.zig:4097`) | ✅ (Zig runtime ile) | P12 | GAP-12 |

## 6. Kullanıcı kararları (Bölüm M)

| # | Karar | Durum | Not |
|---:|---|---|---|
| M.1 | runtime-core ifadesi | **Yanıtlandı (2026-11-24):** dış denetim aracı + analiz kesinliği düzeltmesi; derleyici-içi profil/attribute sonra | leaf kapısı derleyici hatası değil dış araç |
| M.2 | raw record | **Yanıtlandı:** başlıksız `@raw` öneri hazırla | `abi.md` §7; generator ilk adım olarak önerildi |
| M.3 | atomik API | **Yanıtlandı:** public sistem programlama API'si | tasarım önerisi `abi.md` §6; uygulama ayrı iş |
| M.4 | platform sağlayıcı sınırı | **Yanıtlandı:** libc/OS + küçük C/asm sağlayıcı kalıcı (B sınıfı) | Zig-stage ara adaptörü manifestte `geçici` işaretlenir |
| M.5 | hedef önceliği | **Yanıtlandı:** macOS arm64 → Linux x86-64 → QEMU freestanding → Windows/WASM | parity bu sırayla; P13 satırları aynı sıra |
| M.6 | ABI/fingerprint/packaging | **Yanıtlandı:** önerilen tasarım onaylandı (parmak izi + `NOX_RUNTIME` + iki artifact); uygulama R4 öncesi | `abi.md` §5, §rollback |
| M.7 | allocator stratejisi | **Yanıtlandı:** önce eşdeğer port; yeni allocator araştırması port'tan ayrı | spike ölçümü performance.md §3.1 |
| M.8 | varsayılan yapma koşulları + Zig fallback süresi | **Yanıtlandı:** ±%5 mikro + tam korpus (iki backend) + `gc_pause_gate`; Zig fallback varsayılandan sonra ≥1 minor sürüm (`NOX_RUNTIME=zig`) | regresyon kabulü ayrıca kullanıcı onayı (görev belgesi K) |
| M.9 | `zig cc` bağımsızlığı | **Yanıtlandı:** bu projenin KAPSAMINDA | **Kapsamı büyütür:** R8 kapısına `zig cc`'siz kurulum/build/çapraz-link eklenir (§4 R9); öneri (ayrı milestone) kabul EDİLMEDİ |

## 7. Rollback mekanizması (plan)

1. **Zig referansı + çalışan bootstrap binary'leri KORUNUR** (Kural 11); `noxc-nightly` bugün Zig bileşenini yedekte tutar — aynı desen.
2. **Derleme-zamanı seçim:** `NOX_RUNTIME=zig|native|hybrid` (build.zig seçeneği; varsayılan `zig` ta ki M.8 koşulları sağlanana dek). Hibritte modül-bazlı sahip tablosu (`owner`), çift tanım link hatası.
3. **Parmak izi** (abi.md §5): yanlış runtime nesnesi link/init'te reddedilir.
4. **Kademeli varsayılan:** nightly → opt-in bayrak → varsayılan; her adımda `scripts/runtests` + `gc_pause_gate.py` + fixture korpusu iki backend; regresyon = otomatik `NOX_RUNTIME=zig`'e dönüş (tek commit geri alınabilir).
5. **Paket:** release artifact'ında iki runtime (`noxrt-zig.o`, `noxrt-native.o`) yan yana; `noxc` varsayılanı manifest `default_runtime` ile belirlenir.
6. **Kanıt arşivi:** her faz raporu: değişen dosyalar, komutlar, commit/hash, platform sonuçları, açık riskler (görev belgesi L).
