# Kullanıcı listesi — 2026-11-17 akşam (2.3 sonrası "büyük plan listesi")

Kaynak: kullanıcının 2026-11-17 akşamı verdiği liste. Ana liste: `project/v2-3-yapilacaklar-2026-11.md`. Bir madde bitince burada `[x]` + sürüm yazılır.

Durum: `[ ]` açık · `[~]` sürüyor · `[x]` bitti (sürümle) · `[K]` kullanıcı kararı/eylemi gerekir · `[A]` yalnız analiz/rapor (kod değişikliği istenmedi).
Kural (AGENTS §16): dil özelliği / bellek modeli / ABI etkili maddeler `[K]` ile önce sorulur. M4 canlı dağıtımı her zaman kullanıcı onayı ister.

## Küçük işler

- [x] **K1 (kod ve yerel doğrulama bitti; sürüm: sonraki toplu sürüm; canlıya alma onay bekler `[K]`) noxlang.com `packages` sayfası: kartlarda ve ayrıntı sayfasında paket sürümü yazmıyor; sayfalar gelişmeli.**
  - Kök neden: `packages` tablosu yalnızca ad/repo/açıklama/etiket/kaynak tutuyor; yayıncının `noxc publish --ref` ile bildirdiği sürüm hiç saklanmıyor.
  - Yapılan (kod yazıldı, doğrulanacak): `packages.version` + `updated_ms` kolonları (idempotent göç), onay ve sahibi-yeniden-yayınlama yolunda `ref`in kaydı, `index.json`da `version` alanı (eski istemciler yok sayar), `noxc search` çıktısında sürüm.
  - Yapıldı: kart rozeti, ayrıntı sayfasında sürüm satırı + "Releases" tablosu (imzalı bildirimlerden ref/commit/tarih/imzalayan), CSS, `docs/tools/noxpkg.md`; yerel noxpkg ile (örnek paket + bildirim tohumlayarak) doğrulandı. Kalan: CHANGELOG (toplu sürümde).
  - Canlıya alma: **M4 dağıtımı kullanıcı onayı ister** (`[K]`); mevcut canlı paketlerin sürümü yayıncı yeniden yayınlayana ya da yönetici geri doldurana kadar boş görünür.
- [x] **K2 Bacon-Rajan döngü toplayıcımız eşzamanlı (concurrent) mı? Analiz.** (bitti: `project/bacon-rajan-analizi-2026-11-18.md`)
  - Bulgu: HAYIR. Senkron "trial deletion" (modül başlığı bunu açıkça söyler); eşzamanlı Bacon-Rajan değil. Tek iş parçacıklı programda eşiği aşan `possible_root` çağrısı toplamayı satır içi çalıştırır; M:N havuzda dünyayı durdurma (STW) bariyeri kullanır. Çıktı: kısa rapor (aşağıdaki K3 ile birleşik).
- [x] **K3 Bacon-Rajan ne kadar stop-the-world yapıyor? Ölçüm.** (bitti, v2.2.15: ölçüm + eşik düzeltmesi, 500 bin canlı düğümde yineleme başına 13,9 µs → 165 ns; rapor `project/bacon-rajan-analizi-2026-11-18.md`)
  - Devam (v2.2.18): eşzamanlı toplayıcı (E) değerlendirildi ve KAPATILDI (`project/bacon-rajan-e-tasarimi-2026-11-18.md`: gerçek yüklerde toplayıcı çalışmıyor); kullanıcı kararıyla paralel STW işaretleme (F) yapıldı: 500 bin düğümlü parent'lı ağaçta en uzun duraklama ~24 → ~13 ms.
  - Bilinenler (kaynak okumasıyla): varsayılan eşik 700 olası kök, verimsiz toplamada ×2 ile 16M'ye kadar uyarlanır; her toplama ziyaret edilen alt-graf kadar sürer (öbek boyutu kadar değil); havuzda beklemeyen işçiler `sleep 1 ms` döngüsüyle bariyerde bekler ve en yavaş işçinin güvenli noktaya varışı kadar gecikir.
  - Kalan: gerçek duraklama süresi ölçümü (saf çöp döngüleri / büyük canlı graf / M:N 4 işçi), rapor `project/` altına, gerekirse iyileştirme önerisi (artımlı/eşzamanlı işaretleme, `sleep` yerine park).

## Orta işler

- [x] **O1 (v2.2.20, kısıtlı v1 uygulandı: lexer/parser/checker/fmt/LSP/editör gramerleri, AGENTS §5 üçüncü dar istisna) Go gibi tip vermeden `:=` ile tanımlama getirelim mi? Kötü olur mu?** (analiz + öneri yazıldı: `project/o1-tip-cikarimi-analizi-2026-11-18.md`; öneri: kısıtlı v1 ile EVET; karar bekliyor)
  - AGENTS §5: "Tüm parametre, değişken ve dönüş tipleri zorunludur… asla örtük düşüş yok." `:=` bu ilkenin yerel değişkenler için gevşetilmesidir (tip statik olarak çıkarılır, dinamik tipleme DEĞİL ama §5'in metnini değiştirir) → mimari karar, kullanıcı onayı gerekir.
  - Kalan: artı/eksi analizi + öneri (tip çıkarımının sınırları: `[]`/`{}`/`None`/Optional daraltma, `int` vs `float` literal, hata mesajı kalitesi, biçimlendirici/LSP/`noxc explain` etkisi, mevcut `x: T = v` ile birlikte yaşama) → karar → uygulama (lexer `:=`, parser, checker, golden).

## Büyük ve çok önemli işler

- [x] **B1 (kapandı v2.2.19, ölçümle: belge §13) ARC'ye düşen payı azaltıp ASAP'e gelen yüzdeyi artırmak (Gemini önerisi, `asap.md` 2026-11-17 geldi).**
  - Analiz bitti: `project/b1-arc-asap-analizi-2026-11-17.md`. Önermenin "%92 ARC" rakamı tanılama etiketlerinden (parametreler hep "ARC", `explain` skalerleri de "ARC" yazıyor) geliyor; öneri 1 (borrow) ve 4 (acyclic) zaten uygulanmış, öneri 3 (atomik olmayan sayaç) ölçüldü ≤%5, gerçek boşluk yığın/arena terfisi (heap-tipli yerellerin %0,6'sı) ve çağrıdan dönen değerler.
  - Gerçek-dünya ölçümü yapıldı (`NOX_RC_STATS=1` tanılaması eklendi; HTTP sunucusunda ARC darboğaz değil, ama sınıf-ağırlıklı AST iş yükünde süre %72 bellek yönetimi, %40 ARC/döngü-toplayıcı mekanizması). **İlk "ARC ucuz" yargım yanlış soruya cevaptı; düzeltildi.** Plan ve hesap: belge §6-§7 (I1 alan-okuması yerellerinde retain/release elemesi, I2 satır içi release hızlı yolu, I3 olası-kök ucuzlatma, I4 satır içi serbest-liste tahsisi, I5 str geçicileri, I6 move). Sıra: I2 → I4 → I3 → I1 `[K]` → I6/I5.
  - Kalan: B1-0 etiket düzeltmesi, I2/I4/I3 uygulaması (karar gerektirmeyen, yalnızca codegen/runtime), I1 tasarım onayı.
  - **Kapandı (v2.2.19):** uygulanan işler v2.2.10-14 (I1-I6, genel tüketen sözleşme); AST iş yükünde kalan retain'ler yaprak `return n` ile sınırlı (alt sınır), kalan üç aday ölçülebilir hedef bulmadığından yapılmadı (belge §13).
- [x] **B3 Bootstrap (self-hosting) sürecimiz için ayrıntılı plan.** (plan yazıldı: `project/bootstrap-plani-2026-11.md`; karar noktaları §8: kapsam, Aşama 0'ı başlatma, Zig tohumunun kaderi, özellik dondurma — onay bekliyor `[K]`)
  - Kalan: mevcut durum envanteri (derleyici Zig'de; Nox'ta yazılabilecek dilim: lexer/parser/checker/codegen sırası, `noxc-frontend.wasm`, tarayıcı derleyicisi, stdlib'in `nox.*` bağımlılıkları), aşamalar (stage0 Zig → stage1 Nox kendini derler → stage2 doğrulama, ikili özdeşlik testi), eksik dil özellikleri/performans ön koşulları, risk/ölçüt/zaman çizelgesi. Çıktı: `project/bootstrap-plani-2026-11.md`. (Madde numarası kullanıcıdaki gibi B3; B2 verilmedi.)

## Sıra önerisi

1. K1 bitir (kod yazıldı) → K2/K3 ölçüm + rapor → O1 analiz (karar bekler) → B1 ölçüm fazı → B3 plan belgesi.
2. K1 canlıya alma, O1 kararı ve B1 tasarımı kullanıcıya bağlıdır; diğerleri beklemeden yürür.
