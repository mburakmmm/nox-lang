# Liste için kararlı başlık (handle) yeniden tasarımı: büyümede takma adların bayatlamasını gidermek (dogfood D1.2)

Kullanıcı kararı (2026-11-18): **geriye dönük kaynak uyumluluğu bozulmuyorsa yapılacak.** Dahili ABI sürümler arasında değişebilir (VERSIONING.md §2 "kapsam dışı": çalışma zamanı/ARC/nesne düzenleri), kullanıcı `.nox` kaynakları ve stdlib API'si değişmez.

## Sorun

Bugün bir `list[T]` tek bir bloktur: `[ARC başlığı][len: i64][cap: i64][elemanlar…]` (`shared/abi_layout.zig` `LIST_HEADER_SIZE = 16`). `append` kapasiteyi aşınca **yeni bir blok** ayırır ve yalnızca `append` çağrılan adın slotunu günceller. `ys = xs; xs.append(v)` büyümede `ys` eski, kısa bloğu görür (Python: ikisi de aynı liste). Güvenli (bellek bozulmaz, `IndexError`) ama Python'dan ve `docs/tutorial/05-collections.md`nin ilk cümlesinden sapar; selfhost'ta ilk tökezlediğimiz yerdi. Spesifikasyonda "bilinçli v1 sınırlaması" olarak kayıtlı.

## Ölçüm (C, `-O2 -fno-strict-aliasing`; Nox'un tiplenmemiş i64 yükleme/saklamasını taklit eder)

| Çekirdek | düz düzen (bugün) | kararlı başlık + `data` göstericisi | oran |
|---|---|---|---|
| sieve 20 M | 183,8 ms | 179,0 ms | 0,97× |
| matmul 400³ | 15,6 ms | 15,7 ms | 1,01× |
| sınır denetimli toplam 5×20 M | 11,5 ms | 11,6 ms | 1,00× |
| append 20 M | 43,5 ms | 43,1 ms | 0,99× |

(`-fstrict-aliasing` ile matmul 1,22× çıktı: tür-tabanlı takma ad analizi yokken ek yükleme saklamalar arasında taşınamadığından; Nox IR'ı tiplenmemiş olduğundan gerçek eşdeğeri `-fno-strict-aliasing` satırıdır, ama **uygulama sonrası `benchmarks/gate.py --check` ve cross-lang kernel'leri bunu doğrulamak ZORUNDADIR**; eşiği aşarsa tasarım gözden geçirilir.)

## Tasarım (hibrit: ilk tampon satır içi, büyüyünce ayrılır)

- Liste yükü: `[len: i64][cap: i64][data: ptr][satır içi elemanlar…]`, `LIST_HEADER_SIZE = 24`. `data` başlangıçta `payload + 24`'ü (satır içi tampon) gösterir; liste satır içi kapasiteyi aşınca **yeni bir tampon** ayrılır, eleman kopyalanır, `data` bu tampona çevrilir. **Başlığın adresi hiç değişmez**, bu yüzden her takma ad büyümeyi görür.
- Değişmeyen listeler (literaller, `split` sonuçları, comprehension'lar) tek tahsisle kalır (iki tahsis yok); yalnızca +8 bayt ve elemanlara bir ek yükleme.
- Serbest bırakma: `data != payload + 24` ise ayrı tamponu, sonra başlık bloğunu bırak (havuz sınıfları başlık+satır içi kapasiteye göre).
- `ptr_of(xs)`: artık `data` değeridir (elemanlar yine bitişik). `nox_list_realloc` yalnızca TAMPONU yeniden boyutlar (libc `realloc` yolu başlık adresini bozmaz).
- Sınır denetimi `len`e göre aynı kalır.

## Etki alanı (172 yer, ~35 dosya)

Codegen: `calls.zig`, `codegen.zig`, `inlining.zig`, `registration.zig`, `types.zig`, `stmt.zig`, `local_escape.zig`, `ownership.zig`, `expr.zig`, `layout.zig` (+ `dict_inline.zig` değil; `[x]*n` memset katlaması, liste literali/comprehension üretimi, `for` döngüsü iterasyonu, `copy`/dilim, arena listeleri `nox_arena_list_grow`). Çalışma zamanı: `alloc/arc.zig`, `collections/list_ops.zig`, `list_sort.zig`, `shared_list.zig`, `dict.zig`, `foreign_bridge.zig` (HPy), `stdlib_shims/*` (path, postgres, zip, process, fs, tar, redis, strings, regex, json, os, gzip, grpc, csv, wasm, pg_wasm, process_wasm), `tests/compat/zig_ext/util.zig`, `stdlib/nox/mem.nox`. Hedefler: LLVM + QBE, wasm32, freestanding, mobil, Windows.

## Adımlar (her adım yeşil kalmalı; tek commit/sürüm yalnızca TÜM adımlar bitince)

1. **Erişimci katmanı:** `abi_layout.zig`e `LIST_LEN_OFF/LIST_CAP_OFF/LIST_DATA_OFF/LIST_INLINE_OFF` sabitleri; çalışma zamanında `listData(p) [*]u8` yardımcısı; codegen'de `emitListData(obj)` (tek yer). 172 yerin hepsi bunlara geçirilir (`LIST_HEADER_SIZE + i*8` kalıbı kalmaz).
2. Çalışma zamanı: oluşturucu yardımcıları (`makeList(rt, n)` benzeri; stdlib kabukları elle düzen kurmaz), `nox_list_grow` (kararlı başlık: yeni tampon + `data` güncelle), `nox_rc_free_payload` liste dalı, havuz sınıfı hesabı, sıralama/`reverse`/`copy`/dilim, GC `trace` (liste elemanları `data` üzerinden), `shared_list`.
3. Codegen: indeks/atama/`for`/`len`/literal/comprehension/`[x]*n`/`append`/`extend`/`insert`/`pop`/`ptr_of`/arena listeleri/inline açma/`local_escape` yığın listeleri (başlık yığında, tampon satır içi). `append` büyüme yolu **slota geri yazma KALDIRILIR** (artık gerekmez; "alıcı parametre olamaz" kısıtı ve "obj.field.append" kısıtları da kalkar).
4. stdlib kabukları ve HPy/NNI/wasm köprüleri.
5. Testler: tüm fixture korpusu iki backend, sızıntı/çifte serbest bırakma (Debug), `tests/compat`, wasm korpusu, `kernel` (freestanding) testleri; YENİ fixture'lar: takma ad + büyüme (`ys = xs; xs.append`, alan üzerinden, parametre üzerinden, iç içe liste, `list[list[int]]` iç büyüme, çok işçili paylaşımlı liste).
6. Performans: `benchmarks/gate.py --check --repeat 5`, `benchmarks/cross_lang` (sieve/matmul/…), `compiler_bench`, `lex-bench`; bütçe aşılırsa durup tasarım gözden geçirilir.
7. Belgeler: öğretici ve `python-differences.md`deki "Growing a shared list" notları KALDIRILIR; spesifikasyondaki "bilinçli v1 sınırlaması" 1 ve 2 (parametre alıcı kısıtı) güncellenir; CHANGELOG, `docs/apis/internal-abi.md`.

## Kabul ölçütleri

`ys = xs; xs.append(v)` her büyümede Python ile aynı (iki backend); tam `zig build test` + `hpy-host-test` + `precheck` yeşil; gate ve cross-lang kernel'leri gürültü içinde (±%5); bellek: liste başına +8 B dışında artış yok; Windows/wasm/freestanding hedeflerinde derleme ve ilgili testler yeşil.
