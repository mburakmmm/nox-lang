# nox.json: bant (tape) tabanlı tembel `JsonValue` tasarımı — 2.2 aşama 3

Durum: **TASARIM** (kullanıcı onayı 2026-11-14: "Bant tabanlı tembel JsonValue (yyjson benzeri)"). Uygulama dilimleri en altta.

## 1. Ölçülen taban (Apple M4, ReleaseFast, 50k nesneli 2,9 MB belge, `benchmarks/yyjson` ile aynı girdi)

| İş | Nox (v2.1.165) | yyjson (C) | Oran |
|---|---|---|---|
| ayrıştırma | 17,7 ms | 1,45-2,9 ms | 6-12× |
| gezinme (`array_get` + `get("id")` + `as_int`) | 1,7 ms / geçiş | 0,18 ms | ≈10× |
| `dump` | 6,3 ms | 1,0-1,3 ms | ≈5× |

Profil (`sample`, ayrıştırma döngüsü): `validString`/`validValue`/`validNumber` ≈ %28 (ayrıştırma İKİ geçişli: önce doğrulama, sonra kurma), düğüm kurma (`buildValue`/`node`/`nox_rc_alloc`/`poolSlotFor`) ≈ %25, ağaç serbest bırakma (`JsonValue_release`/`nox_rc_free_payload`/`nox_str_release`) ≈ %20, yinelenen-anahtar denetimi %4, sayı ayrıştırma %3. Gezinmede maliyet yerel ARC (atomik retain/release) + işlev çağrıları. Anahtar arama (`get`) darboğaz DEĞİL (v2.1.166'da yerel `nox_json_object_find` yine de eklendi: büyük nesnelerde doğrusal Nox döngüsünü kaldırır).

## 2. Hedef

50k nesneli belge: ayrıştırma ≤ 4 ms (C'nin ~2×'i), dump ≤ 2,5 ms; ilk kullanımda yalnızca erişilen yollar için düğüm kurulur. `nox.json` kamu API'si DEĞİŞMEZ (`parse/is_*/as_*/get/get_or_null/array_*/object_*/dump/dump_pretty`); `JsonValue`nun alanlarına doğrudan dokunan başka kod yoktur (doğrulandı: yalnızca `stdlib/nox/json.nox` ve `core.nox`; toml/yaml kendi değer sınıflarını kullanır).

## 3. Veri modeli

`runtime/stdlib_shims/json_tape.zig` (yeni):

```
Doc = struct { refs: atomic u32, mu: u8 (spin), tape: []Entry, strs: []u8 }
Entry (16 bayt) = { kind u8, flags u8, _ u16, len u32, val u64 }
  null/bool : val = 0/1
  sayı      : val = f64 bitleri; flags.bit0 = "tam metin var" (büyük tamsayı / `1e2` gibi `s` alanı gereken sayılar) → len = strs bayt uzunluğu, ofset ayrı Entry'de değil: val yerine ikinci 8 bayt YOK; bu yüzden metinli sayı iki Entry kaplar (ikincisi {len, ofset})
  dize      : len = bayt uzunluğu, val = strs ofseti (çözülmüş, NUL'suz)
  dizi      : len = çocuk sayısı, val = bitiş Entry indeksi (atlama)
  nesne     : len = çiftsayısı, val = bitiş indeksi; çocuklar (anahtar-Entry, değer alt ağacı) çiftleri
```

Tek geçişli ayrıştırma: aynı pass hem doğrular hem bandı yazar (hata → bant atılır, `last_op_ok = 0`, bugünkü hata yüzeyi aynı). Yinelenen anahtar denetimi (`hasDuplicate`) ve derinlik sınırı (`MAX_JSON_NESTING_DEPTH`) AYNEN korunur. Dize çözümü (kaçışlar, vekil çiftler, UTF-8 doğrulaması) bugünkü `FastJson` ile aynı kurallarla `strs` arenasına yazılır.

## 4. `JsonValue` sınıfı

Alanlar (kind, b, n, s, arr, keys, vals) KALIR; iki gizli alan eklenir: `doc: JsonDoc | None` ve `idx: int`. `JsonDoc` küçük bir Nox sınıfı (`handle: int`; `__del__` → `nox_json_doc_release(handle)`), böylece belge ömrü sıradan ARC'ye bağlanır (atomik sayaç, M:N'de güvenli; özel yıkıcı mekanizması gerekmez).

- Kök düğüm: skaler → bugünkü gibi dolu; konteyner → `kind` dolu, `arr/keys/vals` paylaşılan boş listeler, `doc/idx` dolu (tembel).
- `array_len(v)`: `doc` varsa bant `len`, yoksa `len(v.arr)`.
- `array_get(v, i)`: tembelse ilk erişimde bu seviyenin TÜM doğrudan çocukları düğüme dönüştürülür (konteyner çocuklar yine tembel, skaler çocuklar dolu) ve `v.arr` doldurulur, `v.doc = None` olur; sonraki erişimler bugünkü yoldur (O(1), sıralı döngülerde ikinci dereceden tarama yok). Dönüşüm `Doc.mu` altında, yalnız bir kez ve `doc` yeniden okunarak (çift dönüşümü önler).
- `get/get_or_null(v, key)`: tembel nesnede bantta doğrudan anahtar taraması; yalnızca bulunan değer düğüme dönüştürülür (seviye zorlanmaz).
- `object_len/key/value(v, i)`: seviyeyi zorlar (yukarıdaki gibi).
- `dump/dump_pretty`: tembel düğümler bantlardan doğrudan yazılır (ara düğüm yok); zorlanmış/karışık ağaçlar mevcut `dumpNodeInto` ile.

## 5. Güvenlik ve ilkeler

- İlke 6: `Doc` allocator'ı açık parametre olarak çalışma zamanından alır (`rt` allocator'ı); bant/dize arenası tahsisleri `rt`ye bağlı. Global durum eklenmez (spin kilidi belge içindedir).
- İlke 4 (opak tutamaç): `JsonDoc.handle` yalnızca opak tamsayı; Nox nesne adresi dışarı verilmez.
- `lowlevel`/`extern` sınırı değişmez.
- Hata modeli aynı: geçersiz belge → `JsonError`; bellek yetersizliği → bugünkü `makeLeaf` yedeği.

## 6. Test planı

1. Farksal: aynı girdi kümesinde (mevcut `json_*` golden'ları + 5000 rastgele geçerli/geçersiz/sınır belge: kaçışlar, vekil çiftler, büyük sayılar, tekrar eden anahtarlar, derinlik sınırı) yeni yol ile referans (`std.json` tabanlı) yolun ağaçlarının `dump` çıktıları ve hata sonuçları birebir aynı olmalı.
2. Yaşam süresi: kök bırakıldıktan sonra çocuk tutulur (`doc` ömrü), kısmi zorlama, iki iş parçacığından aynı düğüme eş zamanlı `array_get` (M:N, sızıntı/çift serbest yok; `GeneralPurposeAllocator` safety).
3. Golden: tembel erişim sırası (`get` sonra `array_get`, `object_key` sonra `get`), `dump` tembel/karışık, boş konteynerler, kök skaler.
4. Benchmark: `benchmarks/stdlib_perf` json işleri + bu belgedeki 3 ölçüm (`benchmarks/json/`).

## 7. Dilimler (güncel: 167 = bant ayrıştırıcı + tembel düğümler birlikte yayınlandı; neredeyse tüm tasarım uygulandı)

- **166** (bu sürüm): `nox_json_object_find` + tasarım belgesi.
- **167** (yayınlandı): `json_tape.zig` tek geçişli ayrıştırıcı + farksal test + `JsonValue` tembel erişimciler (`doc`/`tpos` alanları; değişmez düğümler, önbellek yok) + bantlardan `dump`.
- **168**: ayar (dize taraması 16 bayt, bant yazımı, düğüm kurma, `dump` kaçışları); gezinme için düğüm önbelleği gerekirse ayrı karar.
- **169**: ölçüm sonuçlarının `benchmarks/RESULTS.md`ye yazılması, kullanılmayan eski eager yolun temizliği.
