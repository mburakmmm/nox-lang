# Sürümleme Politikası ve Stabilite Garantisi

Bu belge, Nox'un `v1.0.0`dan itibaren izleyeceği sürüm numaralandırma
politikasını ve kullanıcılara verilen somut stabilite garantilerini
tanımlar (bkz. `project/uretim-hazirlik-analizi.md` Faz Z.2). **`v0.1
(taslak)` sürümü bu politikanın KAPSAMI DIŞINDADIR** — taslak aşamasında
HİÇBİR geriye dönük uyumluluk garantisi verilmemiştir/verilmeyecektir;
bu belge yalnızca `v1.0.0` ETİKETİ atıldıktan SONRAKİ sürümler için
bağlayıcıdır (bkz. Faz Z.3).

## 1. Sürüm Numaralandırma (Semantic Versioning)

Nox, standart [Semantic Versioning 2.0.0](https://semver.org/lang/tr/)
şemasını (`MAJOR.MINOR.PATCH`) izler:

- **MAJOR** (`X.0.0`): geriye dönük UYUMSUZ bir değişiklik içerir — bkz.
  aşağıdaki "Neyin MAJOR sayıldığı" listesi.
- **MINOR** (`x.Y.0`): geriye dönük UYUMLU yeni bir özellik ekler (yeni
  sözdizimi, yeni stdlib modülü/fonksiyonu, yeni CLI alt komutu) —
  ÖNCEDEN geçerli olan HİÇBİR `.nox` kaynak dosyası bu sürümle
  BOZULMAZ.
- **PATCH** (`x.y.Z`): hata düzeltmesi, performans iyileştirmesi veya
  dokümantasyon güncellemesi — DOĞRU (tanımsız davranışa dayanmayan)
  hiçbir programın GÖZLEMLENEBİLİR davranışını DEĞİŞTİRMEZ.

## 2. Dil/Stdlib Kaynak Uyumluluğu Garantisi

**Aynı MAJOR sürüm İÇİNDE:** `vX.0.0` altında DERLENEN/ÇALIŞAN geçerli
bir `.nox` programı, `vX.Y.Z` (Y/Z herhangi) altında da AYNI şekilde
derlenir ve AYNI çalışma zamanı davranışını üretir. Bu garanti
KAPSAR: dil sözdizimi/semantiği (checker'ın kabul ettiği programlar
kümesi KÜÇÜLMEZ), stdlib (`nox.*`) fonksiyon imzaları ve davranışı,
`nox.json`/`nox.lock` manifest şeması, `noxc` CLI alt komutlarının
(`build`/`run`/`test`/`search`) mevcut davranışı.

**Bu garantinin KAPSAMI DIŞINDA (bilinçli olarak, açıkça belgelenir):**
- **Derleyici/çalışma zamanı ikili (ABI) uyumluluğu.** İÇ runtime ABI'si
  (`noxrt.o`, `nox_*` runtime sembolleri, ARC başlığı, nesne düzenleri,
  QBE/LLVM IR) TAMAMEN İÇ detaydır ve HERHANGİ bir sürümde DEĞİŞEBİLİR; ayrı
  derlenmiş Nox `.o` dosyalarının birbiriyle uyumu GARANTİ EDİLMEZ — bir Nox
  programı HER ZAMAN KAYNAKTAN yeniden derlenmelidir. **İSTİSNA (v2.0.0'dan
  itibaren, genel ve kararlı):** Nox Native Interface v1 (`include/nox_nni.h`,
  `docs/apis/` (NAPI, NNI, Plugin API)) ve belgelenmiş `extern def` C ABI eşlemesi.
- **Hata mesajı/tanılama METNİ.** Bir hatanın TÜRÜ (ör. `TypeMismatch`)
  sabit kalır, ama TAM metni (bkz. Faz T.2'nin çoklu-tanılama biçimi)
  PATCH sürümlerinde bile İYİLEŞTİRİLEBİLİR — hata metnini ayrıştırıp
  programatik KARAR veren araçlar bu METNE değil, `noxc`nin çıkış KODUNA
  (0 = başarı, sıfır-dışı = hata) GÜVENMELİDİR.
- **`--dump`/`-v` çıktı BİÇİMİ** (AST dökümü, sahiplik raporu) — bunlar
  hata ayıklama ARAÇLARIDIR, PROGRAMATIK tüketim İÇİN TASARLANMAMIŞTIR.
- **Üçüncü-taraf paket EKOSİSTEMİ** (bkz. Faz O/Y) — bir paketin KENDİ
  API'sinin stabilitesi TAMAMEN o paketin YAZARININ sorumluluğundadır
  (Go modüllerinin felsefesiyle AYNI); Nox'un KENDİSİ üçüncü-taraf
  paketler İÇİN semver ZORUNLU KILMAZ, ama `nox.lock`ın SHA-pinleme
  mekanizması (bkz. Faz P.5) HER durumda TEKRARLANABİLİR derlemeyi
  GARANTİ EDER (bir paket yazarı geriye dönük uyumsuz bir değişiklik
  yapsa BİLE, ZATEN kilitlenmiş bir proje ETKİLENMEZ — yalnızca `noxc
  update` ile bilinçli bir YÜKSELTME o değişikliği İÇERİ alır).
- **Araç zinciri (Zig) sürüm pini** (bkz. Faz R.4) — `noxc`nin KENDİSİNİ
  derlemek İÇİN gereken Zig sürümü, Nox DİLİNİN kendisiyle AYNI semver
  döngüsünü İZLEMEZ; derleyicinin build-zamanı bir bağımlılığıdır,
  DİLİN/stdlib'in kaynak uyumluluğunu ETKİLEMEZ.

## 3. Kullanımdan Kaldırma (Deprecation) Politikası

Bir dil özelliği/stdlib fonksiyonu KALDIRILMADAN ÖNCE EN AZ bir MINOR
sürüm boyunca "kullanımdan kaldırıldı" olarak İŞARETLENİR (CHANGELOG'da
açıkça belgelenir) — GERÇEK kaldırma yalnızca bir SONRAKİ MAJOR sürümde
gerçekleşir. Örnek: `v1.3.0`da kullanımdan kaldırılan bir özellik EN
ERKEN `v2.0.0`da kaldırılabilir, `v1.x`in HİÇBİR sürümünde KALDIRILMAZ.

## 4. Sürüm Artış Politikası — toplu (batch) sürümleme (2026-11-17'den itibaren)

`v1.0.0` ile `v2.2.2` arasında "her commit bir sürümdür" politikası uygulandı; bu, `2.1.196` gibi anlamsız ince numaralar üretti ve KALDIRILDI.
Artık `main`e giden her commit sürüm DEĞİLDİR: ara commit'ler tag'siz birikir, **sürüm yalnızca bir iş paketi/aşama (ör. 2.3 yol haritasının bir aşaması) bittiğinde** verilir.

**Ne zaman sürüm verilir:**
- Bir yol haritası aşaması ya da tutarlı bir iş paketi tamamlandığında; tam `zig build test` (VERDICT/çıkış kodu okunur) ve `scripts/precheck.sh` yeşil olmalıdır.
- Kullanıcıya yetişmesi gereken ivedi bir düzeltme (güvenlik, veri kaybı, kırık yayın) için ayrıca bir PATCH verilebilir.

**Sürüm numarası** (§1 tanımları aynen geçerli): salt hata düzeltmeleri/iç iyileştirmeler PATCH; yeni stdlib API/CLI alt komutu/sözdizimi paketi MINOR.
Bir pakette birden fazla kategori varsa en yükseği alınır; paket başına TEK numara artar.

**Mekanik** — yalnızca sürüm commit'inde:
1. `scripts/bump_version.sh {patch|minor|major}` (`build.zig.zon` `.version`; `shared/hpy_host_contract.zig` sürüm sabiti ve `nox_commit` özeti birlikte güncellenir) + CHANGELOG girişi.
2. Tek `&&` zincirinde: commit + `git tag vX.Y.Z` + `git push origin main` + `git push origin vX.Y.Z`. (Ayrı "bump" commit'i yoktur.)
3. Tag push'u `.github/workflows/release.yml`i tetikler (3 platform derlemesi + GitHub Release). Önceki sürümün Release'i bitmeden yenisi etiketlenmez.

**Ara commit'ler:** tag'siz `main`e gidebilir (CI yine koşar); `build.zig.zon` sürümü değişmez. Yarım/WIP durum yine commit edilmez.

**Sınır:** yayımlanmış bir sürümün etiketi/release'i silinmez; düzeltme yeni bir sürümle gelir. `install.sh`/`noxc upgrade` "en son Release"i çekmeye devam eder (artık daha seyrek ama anlamlı sürümler).

## 5. `v0.1` → `v1.0.0` Geçişi

`v1.0.0` etiketi, `project/uretim-hazirlik-analizi.md`nin Faz Q–Y
gruplarının TAMAMININ tamamlandığı somut kontrol listesini (bkz.
`nox-teknik-spesifikasyon.md` §3.43, Faz Z.1) KARŞILADIKTAN SONRA
atılır (bkz. Faz Z.3). `v1.0.0`dan ÖNCEKİ HİÇBİR etiket/commit BU
belgenin garantilerine TABİ DEĞİLDİR.

## 6. Stdlib sınıf kurucuları (v2.0.0 sözleşmesi)

Çalışma zamanının/stdlib'in ürettiği ve kullanıcı kodunun (özellikle testlerin ve çerçevelerin) doğrudan kurabildiği sınıflar (`HttpRequest`,
`HttpResponse`, `Row`, `Statement`, `JsonValue` sarmalayıcıları, ...) için: bir kurucunun mevcut parametreleri bir MAJOR sürüm içinde
DEĞİŞMEZ; yeni parametre YALNIZCA **varsayılan değerle** eklenir (MINOR). Alanlar eklenebilir, mevcut alanlar kaldırılmaz/yeniden adlandırılmaz.
Çalışma zamanının kendisinin kurduğu nesnelerin (ör. `serve` işleyicisine verilen `HttpRequest`) alan KÜMESİ de bu kurala uyar.
