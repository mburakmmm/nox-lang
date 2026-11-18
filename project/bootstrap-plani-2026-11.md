# B3 — Bootstrap (self-hosting) için ayrıntılı plan (2026-11-18)

Amaç: Nox derleyicisinin (lexer → parser → tip denetleyici → sahiplik → IR üretimi → sürücü) Nox ile yazılıp **kendi kendini derlemesi** (`noxc` = Nox kaynağından derlenmiş ikili). Bu belge envanter, aşamalar, kabul ölçütleri, ön koşullar, riskler ve karar noktalarıdır. Kod yazılmadı; **karar sizin** (AGENTS §16: derleyici mimarisi, geri alınamaz yatırım).

## 1. Bugünkü durum (envanter)

| Parça | Zig satırı | Not |
|---|---|---|
| lexer | 1.400 | girinti/token; küçük, Nox'a taşınması kolay |
| parser + AST | 4.100 | özyinelemeli iniş, AST sınıfları; kenar durumlar çok |
| tip denetleyici (`typecheck/`) | 16.600 (12 dosya) | en büyük "anlambilim" parçası; generic monomorphization, protokoller, optional daraltma, kapanışlar |
| sahiplik analizi | 900 | tanılama; asıl kararlar codegen içinde |
| codegen (`codegen_qbe/`) | 31.800 (28 dosya) | QBE + LLVM metin üretimi, ASAP/ARC, inlining, taşıma analizleri; en büyük parça |
| sürücü + paket + LSP + fmt | ~15.000 | `main.zig`, `module_loader`, `pkg/`, `lsp_*`, `fmt/`, `bindgen` |
| **runtime** (Zig) | ~92.000 | allocator, ARC, async, HTTP, TLS, SQLite, ... — **Nox'a taşınmaz**, `noxrt.o` olarak kalır |
| stdlib | 86 `.nox` modülü | zaten Nox |

Doğrulama kaynakları (hazır **oracle**'lar): 644 IR anlık görüntüsü (`ir_snapshots`), ~630 çalıştırılabilir fixture + beklenen çıktı, ~330 tip denetleyici golden'ı, biçimlendirici golden'ları, 2.600 satırlık tip-denetleyici golden testi, LSP ve dokümantasyon örnekleri. Bu, bootstrap için nadir bir avantaj: **bayt-bayt karşılaştırılabilir çıktı** (QBE metni) var.

## 2. Hedef mimari (önerilen: aşamalı hibrit)

"Tek seferde her şey" yerine **ön yüzü Nox'a, arka yüzü sonra**:

```
Aşama A  Nox ön yüzü (lexer + parser + tip denetleyici)   → Zig sürücü/codegen onu FFI/JSON ile çağırır
Aşama B  Nox sahiplik + codegen (IR metni üretimi)         → tam Nox derleyici çekirdeği
Aşama C  Nox sürücüsü (modül yükleyici, paket, CLI)        → saf-Nox noxc (Zig tohumu hâlâ var)
Aşama D  Sabit nokta: noxc₁ (Zig ile derlenmiş) → noxc₂ (noxc₁ ile derlenmiş Nox kaynağı) → noxc₃; noxc₂ ≡ noxc₃ (bayt-bayt)
```

Zig **tohum (seed)** derleyicisi depoda kalır (`seed/` ya da mevcut `compiler/`): her sürüm Zig tohumuyla derlenmiş `noxc` ve Nox-kaynaklı `noxc` ikilisini birlikte test eder; Nox-kaynaklı derleyici üretimde yeterince hızlı/kararlı olunca varsayılan olur, tohum "bootstrap-only" kalır (Rust/Go modeli).

## 3. Aşamalar, kabul ölçütleri

**Aşama 0 — Ön koşullar (bkz. §4):** Nox'un derleyici yazmaya yetmesi için dil/çalışma zamanı eksikleri kapanır. *Ölçüt:* mini "ifade derleyici" (lexer+parser+AST+değerlendirici) Nox'ta yazılıp Python'dan hızlı ve çökmeden çalışır.

**Aşama A1 — Lexer + parser (Nox):** Zig AST'sinin metinsel dökümüyle (`--dump`) **eşdeğer** çıktı üretir. *Ölçüt:* tüm fixture + stdlib + örnek dosyalarında (≈1.500 dosya) Nox-parser dökümü == Zig-parser dökümü; sözdizimi hata konum/mesaj golden'ları aynı. Tahmin: 3-4 hafta.

**Aşama A2 — Tip denetleyici (Nox):** *Ölçüt:* ~330 typecheck golden'ında aynı tanı mesajları (konum + metin); tüm doğru programlarda aynı "anotasyonlu AST"/monomorphization listesi. En riskli aşama (16 bin satır, generic/protokol/optional daraltma). Tahmin: 8-12 hafta.

**Aşama B — Sahiplik + codegen (Nox):** *Ölçüt:* 644 IR anlık görüntüsünün **hepsi bayt-bayt aynı** (QBE) ve LLVM çıktısı fixture korpusunda davranış-eşdeğer. Tahmin: 8-12 hafta (en büyük kod hacmi; ASAP/taşıma/inlining analizleri dahil).

**Aşama C — Sürücü:** `noxc build/run/check/test/fmt/...` Nox'ta; paket/indeks/imza kodu. *Ölçüt:* mevcut CLI testleri (add/delete/fetch/lock, explain, help ekranı) aynı. Tahmin: 3 hafta.

**Aşama D — Sabit nokta:** noxc₂ ≡ noxc₃ bayt-bayt; bootstrap betiği (`scripts/bootstrap.sh`) CI'da; derleme süresi/bellek bütçesi (`noxc₂` Zig `noxc`'nin ≤ 2× süresinde). Tahmin: 1-2 hafta.

Toplam: tek geliştirici için ~6-8 ay; AI destekli paralel çalışmayla ~3-4 ay hedeflenebilir (Aşama A1/A2 ve B büyük ölçüde bağımsız ilerler çünkü arayüz AST dökümü).

## 4. Aşama 0: Nox'un eksikleri (ön koşul listesi)

| Eksik / risk | Durum | Plan |
|---|---|---|
| **Özyineleme derinliği:** fiber yığını sabit 192 KiB (`STACK_SIZE`); derin AST üzerinde özyinelemeli inme taşabilir | tasarım gereği sabit | `main` ve derleyici görevleri için büyük/ayarlanabilir yığın (ya da açık yığınlı yineleme); NOX_STACK_PAINT ile ölç; **ilk iş** |
| **Performans:** sınıf-ağırlıklı iş yükü | B1 ile bu oturumda 28 → 16 ms (−%42, AST örneği); döngü toplayıcı eşiği düzeltildi | derleyici iş yüklerini (lexer/parser) kıyas setine ekle; hedef: Zig'in ≤ 3-5×'i |
| **Toplamalar:** `dict[str, X]`, `list` büyütme, `str` birleştirme (`nox_str_append`) | C'ye yaklaştırma yapıldı (LRU/Counter/Deque) | derleyici kıyaslarıyla yeniden ölç |
| **Toplam tipler:** AST düğümü için `enum` + payload / `match` | enum+match var; **jenerik enum açık** | düğümleri sınıf hiyerarşisi (tekli kalıtım) ya da yük taşıyan enum ile; jenerik enum gerekirse dil işi |
| **Arena/kapsam bellek:** AST binlerce küçük nesne | `lowlevel` arena, ASAP/arena terfisi var | AST'yi arenaya koyma deseni; ölç |
| **Çok dosyalı derleyici projesi** | paket sistemi + `nox.json` var | `compiler/` Nox paketi olarak (Nox'ta) |
| **Süreç/dosya/hash/JSON** (çıktı QBE/clang çağrısı, önbellek) | `nox.process/fs/json/crypto` var | sürücü aşamasında doğrula |
| **Hata raporlama kalitesi** (span, çok satırlı tanılar) | Zig'de hazır | Nox'ta aynı `Span` sınıfı; çıktı golden ile kilitli |
| **Derleme süresi** (Nox'ta 70 bin satır) | bilinmiyor | Aşama A1'de ölçüm; LLVM backend zaten varsayılan |

## 5. Test stratejisi (oracle'larla)
1. **Diferansiyel:** her aşamada Zig bileşeni ve Nox bileşeni **aynı girdide** koşturulur, çıktılar karşılaştırılır (AST dökümü, tanı listesi, QBE metni). Fark = hata; testler `zig build test` içinde, "Nox bileşeni vs Zig bileşeni" adıyla.
2. **Sabit nokta** (Aşama D) CI'da zorunlu; ikili boyut ve süre bütçeleri.
3. **Kademeli benimseme:** Nox bileşenleri önce yalnızca test/araç olarak çalışır (CI karşılaştırması), sonra `--frontend nox` bayrağıyla seçilebilir, en sonda varsayılan.
4. Her aşama kendi sürüm etiketiyle yayınlanır (toplu sürümleme politikası).

## 6. Riskler
- **Performans/bellek:** 70 bin satırlık sınıf-ağırlıklı kod; ARC/döngü toplayıcı yükü (ölçüldü: sınıf ağaçlarında süre %70 bellek yönetimi, B1 ile yarıya yakın indirildi) → derleyici kıyasları sürekli CI'da.
- **Çift bakım:** geçiş boyunca iki derleyici (Zig + Nox) aynı özelliği taşımalı → özellik dondurma penceresi ya da "önce Zig, sonra Nox" kuralı + diferansiyel testler yakalar.
- **Debug zorluğu:** derleyici hatasını kendi diliyle ayıklamak; LSP/`noxc explain`/stack paint araçları hazır, ek olarak AST/IR diff aracı.
- **Tasarım sapması:** Zig'e özgü yardımcıların (allocator, comptime) Nox karşılığı yok → ilgili kod yeniden tasarlanır (arena + sınıflar).
- **Kapsam kayması:** LSP/bindgen/pkg dışarıda bırakılabilir (Aşama C'de sonraya).

## 7. Önerilen ilk adımlar (karar sonrası, sırayla)
1. **Aşama 0 / yığın ve ölçüm:** derleyici-türü kıyas seti (lexer, parser, ağaç dönüşümü) + derin özyineleme için yığın çözümü + `NOX_RC_STATS` ile ARC maliyeti raporu.
2. **A1 minimal dilim:** token türleri + lexer (girinti, f-string) → Zig lexer ile token akışı diferansiyel testi.
3. AST sınıf hiyerarşisi ve `--dump` biçimi sabitlenir (Zig ile bire bir).
4. Parser; sonra yalnızca parser'la çalışan `noxc fmt` (biçimlendirici zaten sözdizimsel) ilk "Nox ile üretilen" araç olur (düşük risk, görünür kazanım).

## 8. Karar noktaları
1. **Kapsam:** "yalnızca ön yüz Nox'ta" (A) mı, "tam self-hosting" (A+B+C+D) mi? **Öneri:** A ile başla, A1+A2 sonunda B'ye geçiş kararını yeniden ver.
2. **Zaman iştahı:** önce Aşama 0 (yığın/performans/kıyas) tek başına da değerli (genel amaçlı Nox performansı); **önerilen ilk karar: Aşama 0'ı başlatmak.**
3. **Zig tohumunun kaderi:** süresiz "bootstrap-only" mi, yoksa belirli bir sürümden sonra mı kaldırılacak? **Öneri:** süresiz tut (yeniden bootstrap güvencesi).
4. **Özellik dondurma:** bootstrap sırasında yeni dil özelliği eklenecekse hem Zig hem Nox derleyicide mi yapılacak? **Öneri:** yeni özellikler "Zig'de önce, diferansiyel testle Nox'a" kuralıyla.
