# Nox 2.2 yol haritası (12 aşama) — kullanıcı verdi 2026-11-14

Durum: `[ ]` açık · `[~]` sürüyor · `[x]` bitti (sürümüyle). Sıra kullanıcının verdiği sıradır; bir aşama bitmeden sonrakine
geçilmez, ama ölçüm gerektiren aşamalar (1-4, 7) bulgularını 8/9/12'ye aktarır. Her aşamada: ölçüm (ReleaseFast, `-Dtrace-frames=0`),
referansa karşı doğrulama, yan hataları aynı sürümde düzeltme, golden/benchmark kaydı. Backend: iki backend (QBE+LLVM) de geçmeli.

Verilen kararlar (2026-11-14, kullanıcı):
- **Aşama 5:** dönüş tipi yazılmazsa `-> None` anlamına gelir (statik; gövdede değer döndürülürse hata); variadik homojen `*xs: T` → gövdede `list[T]`; `**kwargs` YOK. `-> None` yazmak geçerli kalır. Tasarım §3.xx'e eklenir, AGENTS §5'e FF.4 gibi dar istisna notu düşülür.
- **Aşama 6:** `source` etiketi yayıncı beyanıdır (`nox.json`), `noxc publish` yerelde dosya taramasıyla doğrular (çelişki → uyarı/ret); sunucu yalnızca saklar/gösterir, sayfada "yayıncı beyanı" ibaresiyle. Sunucu taraması YOK (S3 kararı).
- **Aşama 8:** önce aday listesi + ölçüm (lisans, ikili boyutu maliyeti); kullanıcı onaylayınca Nox API'siyle sarılır. Aşama 9 ile birlikte değerlendirilir.
- **Aşama 10:** admin paneli listelenmeyen yolda + GitHub OAuth zorunlu kalır; packages sayfasından link kalkar. M4'e canlı dağıtım her seferinde kullanıcı onayı ister.

## Aşamalar

- [x] **1. Builtin fonksiyonların yeterliliği ve performans analizi.** BİTTİ (v2.1.159-163). Eksik builtin'ler eklendi (`pow`/3-arg `pow`, `hex/oct/bin`, `sum(start)`, `enumerate(start)`, `zip` 3 liste, `min/max(default=)`, `int(s, taban)`); hızlandırmalar: `round` hızlı yolu, `any/all(genexpr)` kısa devre, `enumerate/zip` döngüleri ve tuple/`divmod` açma demet üretmeden, liste comprehension ön-ayırma + satır içi ekleme, `len(str)` satır içi. Ölçüm paketi: `benchmarks/builtins/run.sh` (Nox / C / CPython, 17 iş). Dışarıda bırakılan (tasarım gereği dinamik): `isinstance/type/id/hash/next/iter`; `min/max` 3+ argüman ve `print(file=)` aşama 5'e (variadik) bağlı. Açık fark (C'ye göre): `sum/max/min` ~2x (bellek bant genişliği/vektörleme), `map/filter` kapanış çağrısı, `any/all(gen)` kapanış çağrısı.
- [ ] **2. Stdlib daha agresif performans analizi ve düzeltmeleri.** Modül modül ölçüm (collections, str, regex, url, time, fs, csv...), sıcak yolların düzeltilmesi.
- [x] **3. JSON kütüphanesi agresif performans analizi ve düzeltmeleri.** BİTTİ (v2.1.166-168): bant (tape) tabanlı tembel `JsonValue` (`project/json-bant-tasarimi-2026-11.md`); 50k nesne ayrıştırma 17,7 → 7,1 ms (yyjson 1,5-2,9). Açık kalan (aşama 12'ye): `dump` ≈5× ve gezinme ≈10× yyjson'un gerisinde (düğüm kurma/atomik ARC; `putEscaped` taraması).
- [ ] **4. HTTP ve IO performans analizi ve agresif çözümler.** sunucu/istemci sıcak yol, fs/stream, kqueue/epoll, kopya sayısı, tampon yönetimi.
- [x] **5. Variadik fonksiyonlar + dönüş tipsiz (None) fonksiyon sadeliği.** BİTTİ (v2.1.170): variadik (`*xs: T`, `**kwargs`, kw-only, açma) ZATEN vardı; `-> T` atlanabilir (`def f(x: int):`), `min/max` 3+ argüman. Tasarım kararı: dönüş tipi yoksa `None` (AGENTS §5 ikinci dar istisna).
- [x] **6. `source` etiketi (pure nox / c / rust / cpp / go) — publish + noxpkg sayfası.** BİTTİ (v2.1.171, canlı dağıtım hariç): kod + duman testi hazır; M4 dağıtımı tüm aşamalar bitince (kullanıcı kararı 2026-11-15).
- [ ] **7. Agresif FFI performans analizi ve geliştirmeleri.** `extern def` çağrı maliyeti, trampolin, bindgen kabaları; C2 (11.8) ile birleşir. AGENTS §9.5 sınırı korunur.
- [x] **8. Standart kütüphaneye C kaynaklı performanslı kütüphaneler (Nox semantiğiyle).** BİTTİ (v2.1.172-175): isteğe bağlı `noxclibs-<hedef>.a` arşivi (macOS=Linux=Windows, kullanmayan program büyümez); `nox.zstd.compress`, `nox.lz4`, `nox.xxhash`, `nox.yyjson` (ayrıştır+gez 1,46 ms, C 0,94), `nox.pcre2` (JIT, C'ye %10 içinde, `dynamic_code` yetkisi), `nox.brotli` (açıcı). Mevcut modüllere dokunulmadı. Aday listesi: `project/stdlib-c-kutuphane-adaylari-2026-11.md`.
- [x] **9. `noxc` ve Nox uygulama ikili boyutu analizi.** BİTTİ (v2.1.176-178): hello-world Linux 19 MB → 0,34 MB, Windows 3,45 MB + 11,9 MB pdb → 0,78 MB, macOS 0,38 → 0,21 MB (bağlamada `--strip-debug`, çapraz nesnelerde bölümleme, Windows `--gc-sections`, Release çalışma zamanı `strip`); release arşivine `noxclibs.a` eklendi. Bilinen kalan (küçük): `std.Io.Threaded` vtable ≈ 89 KB, Windows `.text` macOS'unkinin ~2 katı; `noxc` 5,7 MB (makul). Ayrıntı CHANGELOG 2.1.176.
- [~] **10. Web sitesi güncellemesi.** (dilim 1-2 v2.1.179-180: Teknik özellikler sayfası, noxpkg'de herkese açık admin bağlantısı kalktı; kalan: noxpkg'nin canlı dağıtımı (elle, kullanıcı onayı) Tüm veri içerikleri güncel; "Teknik özellikler" sayfası; admin paneli listelenmeyen yola + OAuth; packages sayfasında herkese görünmez.
- [ ] **11. Python-docs kıvamında docs sitesi + 3 Nox API'sinin güncellenmesi.** Ajanlar ve geliştiriciler için ayrıntılı içerik; Nox API, NNI (native), Plugin API güncellemesi, eskiye dönük uyumluluk korunarak.
- [ ] **12. 2.2 öncesi agresif performans analizi + düzenlemeler → 2.2 sürüm ilanı.** Tüm aşamaların toplu benchmark'ı, regresyon kapısı, sürüm notları, duyuru. (Sürüm numarası "2.2" kullanıcı kararı: önceki "2.2 adı verme, patch" kararı bu aşamada yeniden teyit edilir.)

## Notlar
- Açık işler listesi (`acik-isler-2026-11-14.md`) ile birleşme: C1 (REPL) ve C2 (FFI maliyeti) → C2 aşama 7'ye girer; B6 aşama 4 (WASM threads doğrulamaları) bu listeden bağımsız kalır.
- Windows PC (`noxdev@100.97.244.106`) erişilebilir; Windows'u etkileyen her aşamada orada doğrula (MinGW gcc `C:\msys64\mingw64\bin`).
