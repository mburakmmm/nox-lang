# CI hızlandırma planı (2026-11-25)

**Amaç:** test kapsamını AZALTMADAN tam CI süresini ~100 dk → hedef 30–45 dk; hızlı geri bildirim ~5–10 dk.
**Kaynak:** GPT 6.2 analizi + gerçek koşu verisi (aşağıda). Hedefler mühendislik hedefidir; ölçülmeden "kazanıldı" denmez.

## Ölçülen başlangıç (CI #45597580504, tüm iş yeşil, 2026-11-25)

| İş | Toplam | Zig kur | build Debug | test Debug | build RF | test RF |
|---|---|---|---|---|---|---|
| macOS (aarch64) | ~85 dk | 8,8 | 3,8 | 27,6 | 6,4 | 36,8 |
| Linux (x86-64) | ~62 dk | 7,3 | 3,1 | 12,5 | 6,9 | 30,9 |

Bulgular: (1) Zig kurulumu Linux'ta bile 7 dk (ziglang.org aktarımı; bazı koşularda 19–28 dk). (2) ReleaseFast testi Debug'dan ~2,5× uzun
(Linux): iki mod aynı koşucuda SIRALI. (3) Başarılı koşuda `zig build test` sessiz → adım-başına dağılım log'dan okunamıyor (→ `--summary all`).
(4) Ardışık push'larda aynı anda birden çok tam CI sürüyor; macOS eşzamanlılık sınırında kuyruk süreyi şişirebilir.

## Fazlar ve durum

| Faz | İş | Durum |
|---|---|---|
| CI.1 | Zig (sağlama toplamlı, önbellekli, yeniden denemeli) + yamalı QBE + pip önbelleği: `.github/actions/setup-zig`, `setup-qbe` | **YAPILDI (kodda; ilk CI koşusuyla doğrulanacak)** |
| CI.2 | `test` matrisi platform × {Debug, ReleaseFast} = 6 paralel iş (core-dump/zip/Node vektör adımları yalnızca Debug) | **YAPILDI (kodda)** |
| CI.3 | `zig build test … --summary all` (test işleri + Windows) → adım-başına süre | **YAPILDI**; veri ilk koşudan sonra okunur |
| CI.4 | Golden fixture sharding mekanizması (`-Dtest-shard-count/-index`, `test-golden`, `-Dtest-skip-golden`) | **Mekanizma YAPILDI, CI'da KAPALI** (aşağıya bak) |
| CI.5 | Ortak build artefaktı (bir kez derle, shard işlerine dağıt) | AÇIK — shard açılacaksa ön koşul |
| CI.6 | Fast CI (Tier 1): `.github/workflows/fast-ci.yml` | **YAPILDI (kodda)**; Nightly zaten `nightly.yml`/`stress.yml` |
| CI.7 | `concurrency` (yalnız PR koşuları iptal edilir; `main` push ASLA) + `workflow_dispatch` | **YAPILDI**; release `ci-gate` → `workflow_run` mimarisi AÇIK (aşağıya bak) |
| CI.8 | Self-hosted noxc ile CI | AÇIK — Aşama 3 sonrası |

## Değişmez kısıtlar (neden böyle)

- **release.yml `ci-gate`** `ci.yml`in `head_sha` için en yeni koşusunun `conclusion == success` olmasını bekler. Bu yüzden `ci.yml`in adı/tek-workflow yapısı korunur ve `main` push koşuları
  iptal edilemez (concurrency grubu push için SHA'dır). Fast CI ayrı workflow: release'i etkilemez.
- **`zig build` ve `zig build test` ayrı adım** (soğuk önbellek yarışı, ci.yml başlık notu) — matrisle de korundu.
- **`.zig-cache` önbelleğe ALINMADI:** `zig build test` çalıştırma adımları girdi özetine göre atlanabilir; fixture/noxc gibi bildirilmemiş girdilere bağlı testler eski sonucu yeniden kullanabilirdi.
  "Test sonuçlarını körü körüne önbellekleme." Yalnızca araç zinciri (Zig, QBE, pip) önbelleklenir; Zig önbelleği içerik-adreslidir ve doğrulanmış arşivden gelir.
- **`zig fmt --check` Fast CI'da YOK:** HEAD'de 6 dosya biçimsiz (exceptions.zig, selfhost_ck_diff.zig, shared_list.zig, wasm_call.zig, selfhost_contract_test.zig, selfhost/spike harness.zig). Temizlenince eklenir.
- Zig sürümü tek kaynaktan: `build.zig.zon` `minimum_zig_version` (setup-zig buradan okur; sağlama toplamları `.github/actions/setup-zig/zig-sha256.txt`, resmî `download/index.json`'dan). Sürüm yükseltirken bu dosyaya yeni satırlar eklenir.

## CI.4 — shard nasıl açılır (veriye bakıldıktan sonra)

Mekanizma (varsayılan davranış DEĞİŞMEZ):

```
zig build test-golden -Dtest-shard-count=4 -Dtest-shard-index=K   # K = 0..3; yalnızca golden dosyası
zig build test -Dtest-skip-golden=true                            # golden DIŞINDAKİ her şey
```

- Fixture→parça ataması fixture ADI üzerinden Wyhash (korpus büyüyünce kayma yok); `NOX_FIXTURE_SHARD=<K>/<N>` geçersizse test yüksek sesle çöker (sessiz "hepsini çalıştır" yok).
- Birim testi her parçalama sayısı için "her fixture TAM bir parçada" kanıtını verir (her koşuda çalışır).
- **Yerel doğrulama (temiz worktree, Apple Silicon, Debug):** `zig build test-golden -Dtest-shard-count=4 -Dtest-shard-index=0` → `SHARD 0/4: 172 / 642 fixture çalıştırıldı`, 38/38 test geçti, golden adımı ~4 dk
  (tam korpus ≈ 4× → ~16 dk bu hızlı makinede; GitHub macOS/Linux/Windows'ta daha yavaş). `-Dtest-skip-golden=true` yolu yerelde çalıştırılmadı (CI'da kullanılmıyor; açılırken ilk koşuyla doğrulanır).
- Golden dosyasındaki 36 diğer test (IR metni, `wasm_call`, `nox.process` vb.) her shard'da çalışır (ucuz); fixture testi bölünür.
- **Açma kararı verisi:** ilk CI koşusundaki `--summary all` çıktısında golden adımının payı. Golden toplam testin ≳%40'ıysa 3–4 shard; değilse sharding kazandırmaz (her shard ayrıca kurulum + `zig build` öder: 3–7 dk).
- Açılırken CI.5 (ortak artefakt) düşünülmeli; aksi halde her shard derlemeyi tekrarlar ve macOS eşzamanlılığı sınırlayıcı olabilir.

## Açık / sonraki

1. İlk CI koşusu (PR/dispatch) sonrası: `--summary all` verisini oku, Zig önbellek isabetini (`Zig X hazır (önbellek isabeti: true)` satırı) doğrula, süreleri bu tabloya yaz.
2. CI.4'ü aç/kapat kararı + CI.5.
3. release.yml: Zig kurulumunu `setup-zig`e taşı; `ci-gate` bekleme döngüsünü `workflow_run`/SHA-doğrulamalı mimariye çevir (release derlemeleri CI ile paralel hazırlansın, yayın CI yeşil olmadan olmasın; AUR/Snap/AppImage/Windows kurucu aynı kapıya tabi doğrulanmalı).
4. nightly/stress/external-fixtures/mobile iş akışlarındaki Zig kurulumlarını `setup-zig`e taşı.
