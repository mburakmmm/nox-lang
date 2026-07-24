# Sürümleme Politikası ve Stabilite Garantisi

Bu belge, Nox'un `v1.0.0`dan itibaren izleyeceği sürüm numaralandırma
politikasını ve kullanıcılara verilen somut stabilite garantilerini
tanımlar (bkz. `docs/uretim-hazirlik-analizi.md` Faz Z.2). **`v0.1
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
- **Derleyici/çalışma zamanı ikili (ABI) uyumluluğu.** Nox'ta HENÜZ
  stabil bir ikili dağıtım formatı/ABI YOKTUR — `noxrt.o`, `extern
  def`in C ABI'si, HPy/WASM köprü düzenleri TAMAMEN İÇ implementasyon
  detaylarıdır ve `x.y.z`nin HERHANGİ bir bileşeninde DEĞİŞEBİLİR.
  Pratik sonuç: bir Nox programı HER ZAMAN KAYNAKTAN yeniden
  derlenmelidir — önceden derlenmiş bir `.o`/ikili dosyanın farklı bir
  `noxc` sürümüyle ÇALIŞACAĞI GARANTİ EDİLMEZ (Rust'ın `cargo` öncesi
  dönemine ya da Zig'in KENDİ mevcut politikasına BENZER bir duruş).
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

## 4. Sürüm Artış Otomasyonu — "her commit bir sürümdür" (2026-07-24'ten itibaren)

`v1.0.0`dan sonra, `main`e giden HER commit KENDİ BAŞINA gerçek,
tag'lenmiş, YAYIMLANMIŞ bir sürümdür — commit'ler artık bir SONRAKİ
sürüme doğru sessizce BİRİKMEZ (eski `X.Y.0-dev` son eki BU YÜZDEN
KALDIRILDI, bkz. `build.zig.zon`; "geliştirme aşamasında" ayrı bir ara
durum artık YOK).

**Mekanik** — her commit'te:
1. `scripts/bump_version.sh {patch|minor|major}` çalıştırılır —
   `build.zig.zon`nin `.version` alanını, bu commit'in İÇERDİĞİ
   değişikliğin GERÇEK semver kategorisine göre (§1'deki TANIMLAR
   AYNEN uygulanır — yeni bir stdlib fonksiyonu/CLI alt komutu/
   sözdizimi MINOR'dur, salt bir hata düzeltmesi PATCH'tir) artırır.
2. `build.zig.zon`, o commit'in DİĞER dosyalarıyla BİRLİKTE stage
   edilip TEK bir commit olarak yapılır (AYRI bir "chore: bump
   version" commit'i YOK — bir commit = bir sürüm).
3. O commit `vX.Y.Z` OLARAK tag'lenir.
4. Commit + tag `origin`a push edilir — bu, `.github/workflows/
   release.yml`i (`v*` deseni İLE eşleşen HERHANGİ bir tag push'unda
   TETİKLENİR) OTOMATİK olarak çalıştırır: 3 platform İçin `noxc`/
   `noxlsp`/`noxrt.o`/stdlib ReleaseFast'ta derlenir, `qbe` gömülür,
   GERÇEK bir GitHub Release (otomatik oluşturulan notlarla)
   YAYIMLANIR.

**Neden:** `install.sh`/`install.ps1` HER ZAMAN "en son Release"i
çeker — sürüm numarasının GERÇEK zamanlı, HER geliştirmeyi yansıtır
durumda kalması, VE gelecekteki `noxc upgrade` komutunun (bkz.
`nox-teknik-spesifikasyon.md`, henüz tasarım aşamasında) HER ZAMAN
tazeyi bulabilmesi İçindir — kullanıcı açıkça bu davranışı SEÇTİ (bkz.
proje belleği `project_versioning_automation.md`), alternatifi
("yalnızca bir özellik/oturum bitince bump+tag+release") daha az
CI/release trafiği ÜRETİRDİ ama "her geliştirmede" isteğine TAM
UYMAZDI.

**Sınır:** bu politika yalnızca `main`e giden GERÇEK, tamamlanmış
commit'ler İçindir — bir özelliğin ORTASINDAKİ ara/WIP durumlar HİÇ
commit edilmiyorsa (bu projenin ZATEN mevcut disiplini) hiçbir sorun
YOK; eğer bir commit SONRADAN hatalı çıkar/geri alınırsa, O sürüm
etiketi/release'i SİLİNMEZ (semver'in KENDİ "bir sürüm YAYIMLANDIKTAN
sonra asla değiştirilmez" ilkesiyle TUTARLI) — düzeltme her zaman
YENİ bir PATCH sürümüyle gelir.

## 5. `v0.1` → `v1.0.0` Geçişi

`v1.0.0` etiketi, `docs/uretim-hazirlik-analizi.md`nin Faz Q–Y
gruplarının TAMAMININ tamamlandığı somut kontrol listesini (bkz.
`nox-teknik-spesifikasyon.md` §3.43, Faz Z.1) KARŞILADIKTAN SONRA
atılır (bkz. Faz Z.3). `v1.0.0`dan ÖNCEKİ HİÇBİR etiket/commit BU
belgenin garantilerine TABİ DEĞİLDİR.
