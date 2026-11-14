# Registry güvenliği tasarımı (TODO 7.4) — taslak, onay bekliyor

Durum: **TASARIM; kod yazılmadı.** Kullanıcı kararı (2026-11-14): "tasarım öner". Onaylanan aşamalar uygulanır (AGENTS §16: mimari karar önce sorulur).

## 1. Bugünkü durum (doğrulanmış)

- Registry (`services/noxpkg`) bir gönderiyi **metadata** (ad, depo, açıklama) için moderasyondan geçirir; kod incelenmez. İndeks sürüm taşımaz; kurulan şey `nox.json` ile seçilir, `nox.lock` ile (git commit + ağaç SHA-256) sabitlenir (`docs/reference/security.md`).
- **`noxc sign` zaten var** (ADR-011): Ed25519 ile `nox.lock` imzalama (`sign keygen/lock/trust/revoke/verify`). Eksik olan: (a) `noxc fetch` imzayı **zorunlu kılmıyor**, (b) registry yayıncı anahtarlarını hesaplara **bağlamıyor**, (c) otomatik tarama yok, (d) SBOM üretilmiyor.
- Güven sınırı: `extern def`/`lowlevel`/`bin` içeren paket çıplak yerel yetkiyle çalışır (AGENTS §9.5). Tasarım bu sınırı **değiştirmez**; yalnızca görünür ve doğrulanabilir kılar.

## 2. Hedefler / hedef dışı

Hedef: (1) bir paketin **kim tarafından** yayınlandığını doğrulamak, (2) yayınlanmış sürümün **değiştirilmediğini** kanıtlamak, (3) bir projenin **ne içerdiğini** (bağımlılıklar + yerel kod) makine-okunur vermek, (4) tehlikeli kalıpları yayında **işaretlemek**.
Hedef dışı: sandbox/izin zorlaması (ayrı, kapsamlı tasarım — §9.5), kod incelemesinin yerine geçmek.

## 3. Önerilen mimari (üç bağımsız aşama; her biri tek başına değer verir)

### Aşama S1 — SBOM (en düşük risk, hemen değer)
- `noxc sbom [dir]` (ve `noxc publish` içinde): **CycloneDX 1.5 JSON** üretir. Kaynak: `nox.json` (`requires[]`), `nox.lock` (commit + SHA-256), derleyici analizinden `extern def … from "<lib>"` / `lowlevel` / `@ffi` kullanan modüller ve `bin` girişleri ("native-code" bileşen etiketi).
- Çıktı deterministiktir (sıralı), imzalanabilir (S2 ile). Kimlik bilgisi/yol sızdırmaz (yalnız depo URL'si + commit).
- Test: golden SBOM (iki bağımlılıklı örnek proje), `extern def` içeren paketin native etiketi, deterministiklik.

### Aşama S2 — Yayıncı anahtarı + imza doğrulama (orta risk, mimari karar)
- **Kimlik:** `noxc login` (kullanıcı planı #3) ile hesap; `noxc sign keygen` anahtarının **açık anahtarı** hesaba kaydedilir (`POST /api/keys`, GitHub OAuth oturumuyla). Hesap başına birden çok anahtar, her birinin parmak izi (SHA-256 of pub) ve iptal durumu vardır (`noxc sign revoke` sunucuya da bildirilir).
- **Yayın:** `noxc publish` yayınlanan sürüm için `{ad, depo, commit, ağaç SHA-256, SBOM SHA-256}` bildirimini **yayıncı anahtarıyla imzalar**; registry imzayı doğrular ve **kendi anahtarıyla da imzalayıp** indekse koyar (sunucu imzası = "bu bildirim, bu hesaptan, şu anda alındı"). İndeks bu bildirimi taşır (şimdi sürüm taşımıyor; yalnız *yayınlanmış bildirimler* eklenir, mevcut `nox.json` seçim modeli değişmez).
- **Doğrulama:** `noxc fetch`/`add`: (a) `nox.lock`taki commit/SHA-256, indeksteki bildirimle eşleşiyor mu; (b) imza geçerli ve anahtar iptal edilmemiş mi. Varsayılan **uyar** (ilk sürümde), `--require-signed` / `nox.json` `"security": {"require_signed": true}` ile **reddet**. Bir sonraki ana sürümde varsayılan "reddet" tartışılır.
- **İptal/rotasyon:** iptal listesi indeksle birlikte imzalı dağıtılır; eski bildirimler "anahtar iptal sonrası" etiketlenir.
- **Tehdit modeli:** bu, depo sahibinin hesabının ele geçirilmesine karşı korumaz (anahtar da çalınabilir); korur: registry/indeks değişikliği, aracı saldırıları, commit'in sonradan yeniden yazılması (force-push) ve "başka yayıncı aynı adı aldı" durumu (ad → anahtar bağı).
- Risk: anahtar yönetimi kullanıcı yükü; mitigasyon: `noxc sign keygen` + `noxc login` tek komutta (anahtarı `~/.nox/keys` altında 0600).

### Aşama S3 — Yayın zamanı otomatik tarama (düşük risk, sinyal üretir; engellemez)
- Sunucu, yayınlanan commit'i **yalnız statik** inceler (kod çalıştırmaz): `extern def`/`lowlevel`/`bin` var mı, ağ/dosya/süreç stdlib'i (`nox.process`, `nox.fs` yazma, `nox.http`) kullanılıyor mu, `unsafe` benzeri `ptr_*`, büyük ikili/obfuskeli blob, ad benzerliği (typosquatting: mevcut paket adlarına Levenshtein ≤ 2), son 24 saatte açılmış hesap.
- Sonuç bir **risk etiketi listesi**dir (`native`, `network`, `process`, `typosquat?`, `new-publisher`); moderasyon kuyruğunda görünür, `noxc search/info`'da gösterilir. **Otomatik reddetme yok** (yanlış pozitif maliyeti).
- Kapsam dışı: antivirüs/dinamik analiz.

## 4. Verilmesi gereken kararlar

1. **S1 (SBOM)** tek başına başlasın mı? (öneri: **evet**, önce bu)
2. **S2:** imza **uyar** modunda başlasın, ayrı sürümde "reddet"e geçilsin mi? Hesap-anahtar bağı için GitHub OAuth yeterli mi (öneri: evet)?
3. **S3:** etiketler yalnız moderatöre mi, herkese mi gösterilsin? (öneri: herkese; şeffaflık)
4. Registry'de **sunucu imzası** için anahtarın yeri (M4 Docker sırrı) ve rotasyon süreci.

## 5. Uygulama sırası ve doğrulama

S1 → (karar) S2 → S3. Her aşama: golden test + `services/noxpkg` entegrasyon testi + `docs/reference/security.md` ve `docs/tools/noxc.md` güncellemesi + spesifikasyon bölümü. Değişmez ilkeler (§2) etkilenmez: yeni dil özelliği/ownership sözdizimi yok.
