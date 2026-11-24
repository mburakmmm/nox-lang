# Native runtime — performans: yöntem, baseline, readiness ölçümleri

> Görev belgesi Bölüm K. Bu belge **readiness** ölçümlerini (spike kalitesi; nihai runtime performansı DEĞİL) ve port sırasında kullanılacak yöntemi/baseline'ı kaydeder. "Nox ile yazıldı" tek başına başarı ölçütü değildir.

## 1. Baseline (port öncesi, kayıt)

| Kaynak | Değer | Not |
|---|---|---|
| Derleyici selfhost süre oranı (Nox/Zig), `project/rapor2-sonuc-2026-11-24.md`, v2.2.59–2.2.62 | lexer **0,5×**, parse **0,7×**, fmt **0,7×** (dize ağırlıklı lexer 0,41×) | aynı korpus/flags/donanım ile; tarihsel ≈1,27× yalnız aynı koşulda karşılaştırılır |
| Düz enum skaler etiket (v2.2.61) | `list[Kind]` 6,2×, kaçmayan döngü 3,8× | ReleaseFast, LLVM |
| GC duraklama kapısı | `scripts/gc_pause_gate.py` (nightly) | R5'te eski Zig referansına karşı |
| Fixture/test taban çizgisi (v2.2.64) | `NOX_TEST_FAST=1 zig build test -Dtrace-frames=0`: 875/875 adım, 2351/2367 test (16 skip) | skip'ler başarı sayılmaz; ayrı raporlanır |

Port sırasında zorunlu ölçümler (görev belgesi K.1–K.10): aynı emitted IR ile Zig runtime ↔ Nox runtime; derleyici süresi ile program süresi ayrı; tahsis/serbest, ARC retain/release, cycle-collection duraklaması, list/dict/str, HTTP, scheduler ayrı; gerçek peak RSS ile heap capacity/live/allocator overhead/alloc count **ayrı metrik**; Debug ile ReleaseFast karıştırılmaz; warm-up, medyan, min, tekrar, ortam kaydı; kontrol kaldırarak kazanılan hız kabul edilmez; Aether/Nyx throughput + tail latency ve diğer ekosistem projeleri.

## 2. Yöntem (bu belgedeki ölçümler)

`python3 scripts/native_runtime_bench.py --runs 5` — Apple M4, macOS arm64, `clang -O2`, `noxc 2.2.64` LLVM, 5 tekrar (min + medyan), instrumentation yok, spike kodu **runtime-free leaf** (ReleaseFast ayrımı gerekmez: Nox runtime nesnesi bağlı değildir). Linux x86-64 sayıları CI'da (yerel ölçüm yok ⇒ yok olarak işaretli).

## 3. Sonuçlar

### 3.1 Bootstrap allocator spike (R3) — `tests/native_runtime/leaf/p06_allocator.nox`

| Ölçüm | nox-alloc (spike) | libc `malloc+free` | Not |
|---|---:|---:|---|
| 64 B tahsis+serbest çifti, tek iş parçacığı (5 M işlem) | **min 3,47 / med 3,57 ns** | min 11,35 / med 13,99 ns | **eşdeğer karşılaştırma DEĞİL**: spike kilitsiz-tek-sahipli (iş parçacığı güvenliği yok), boyut-sınıfı serbest liste; libc iş parçacığı güvenli. Yalnız "Nox ile yazılmış allocator makul sıcak yolda ölçülebilir" kanıtı. |

Kayıtlı sınırlar: tek sahip; ISR yeniden girişi yok; hizalama ≤16; büyük blok kendi chunk'ı (O(n) çıkarma); kilitli/thread-local havuz R5'te. Debug canary kapalı ölçüldü (`flags=0`); canary açıkken ek maliyet ayrı ölçülecek (R5).

### 3.2 Ham atomik (R2) — shim maliyeti

| Ölçüm (relaxed `fetch_add`, 100 M, tek iş parçacığı) | ns/op (min / med) |
|---|---:|
| Nox leaf → `extern def` shim | 1,619 / 1,648 |
| C satır içi `__atomic_fetch_add` | 1,618 / 1,623 |
| C → shim (satır içi olmayan çağrı) | 1,607 / 1,615 |

Sonuç: shim çağrı maliyeti Apple M4'te **atomik işlemin kendi gecikmesinden ayırt edilemiyor** (≈1,6 ns). Bu, *tek çekirdek, çekişmesiz* durumdur; çok işçili çekişmede (p05: 4 iş parçacığı) doğruluk kanıtlıdır, throughput ölçülmemiştir. Satır içi `atomicrmw` (public API/intrinsic) kazanç sağlar mı sorusu x86-64 + çekişmeli yükte ayrıca ölçülmeli (M.3 uygulama turu).

### 3.3 Derleyici düzeltmesinin etkisi (v2.2.64, istisna analizi)

15 fixture'ın QBE IR anlık görüntüsü değişti (hepsi ham-bellek yerleşikli); toplam `nox_exception_pending` çağrı-sonrası denetimi **1719 → 1682** (−37; `nox_mem_copy_move_set_volatile`: 27 → 17, satır 5187 → 5007), diğerlerinde −1…−3. Davranış: tam test paketi yeşil (875/875 adım). Çalışma zamanı kazancı ayrıca ölçülmedi (yalnız denetim kalktı; mikro-benchmark etkisi beklenen küçük).

## 4. Henüz ölçülmeyenler (açık)

| Konu | Neden açık | Plan |
|---|---|---|
| ARC retain/release sıcak yolu, havuz, GC duraklaması | ARC henüz taşınmadı (R5) | Zig referansı vs Nox; `gc_pause_gate.py` |
| Allocator çok iş parçacıklı + RSS/overhead metrikleri | spike tek sahipli | R5 |
| Linux x86-64 ve diğer hedefler | yerelde yok; CI | `gh run` + hedef matrisi (P13) |
| HTTP/Aether/Nyx throughput + tail latency | runtime portu yok | R6 |
| Derleyici derleme süresi etkisi | port yok | R4+ |
| Kayıpsız dönüşüm denetimi kaldırma (GAP-2) | uygulanmadı | onay sonrası IR boyutu + süre |

## 5. Politika (kullanıcı kararı M.8)

Varsayılan yapma koşulu: mikro ölçümde **±%5 gürültü** içinde, tam fixture korpusu (iki backend) yeşil, `gc_pause_gate` geçer; Zig fallback varsayılandan sonra ≥1 minor sürüm. Herhangi bir regresyonun kabulü ayrıca kullanıcı onayı gerektirir. (%5 bir ölçüm sonucu değil politikadır.)
