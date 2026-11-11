# Stdlib performans analizi (2026-11-11)

Amaç: Nox stdlib'inin sık kullanılan işlemlerini CPython 3.15.2'nin standart kütüphanesiyle (çoğu C ile yazılmış: `json`, `re`, `base64`, `zlib`, `hashlib`, `csv`...) aynı iş ve aynı sağlama toplamıyla karşılaştırmak; yavaş uçları ve olası nedenlerini bulmak; eksik modülleri listelemek.

**Araç:** `benchmarks/stdlib_perf/` (`stdlib_perf.nox`, `stdlib_perf.py`, `run.py`). Her iki program da aynı 26 işi yapar ve **sağlama toplamlarının eşleşmesi zorunludur** (`run.py` uyuşmazlıkta hata verir; 26/26 eşleşti). Python tarafı da bir fonksiyon içinde çalışır (Python 3.15'te modül düzeyi döngü global erişimi yüzünden ~200x yavaşlar; ilk denemede `str_concat` bu yüzden aykırı çıktı ve düzeltildi).

**Ortam:** macOS aarch64 (Apple M4), `zig build -Doptimize=ReleaseFast`, Python 3.15.2, her biri 3 koşunun medyanı. Düz `zig build` Debug runtime üretir ve ~100x yavaştır; ölçüm için kullanılmamalıdır.

## Sonuç

Geometrik ortalama **nox/python = 1.08 (LLVM)** ve **1.11 (QBE)**: Nox stdlib'i, C ile yazılmış CPython kütüphanesiyle genel olarak başa baş; iki backend arasındaki fark ihmal edilebilir (stdlib sıcak yolları Zig runtime'da). Oran < 1 Nox daha hızlı demek.

| Benchmark | Nox LLVM ms | Nox QBE ms | Python ms | LLVM/Python |
|---|---:|---:|---:|---:|
| `str_build_join_200k` | 5.4 | 5.3 | 9.7 | 0.56 |
| `str_split_200k_x5` | 15.5 | 16.5 | 15.0 | 1.03 |
| `str_replace_x5` | 16.9 | 17.0 | 11.7 | 1.44 |
| `str_find_300k_small` | 11.3 | 11.3 | 24.1 | 0.47 |
| `str_upper_lower_trim_x20` | 55.3 | 55.2 | 14.0 | 3.95 |
| `str_concat_1M` | 3.4 | 3.4 | 27.9 | 0.12 |
| `fstring_300k` | 14.1 | 13.6 | 28.6 | 0.49 |
| `json_parse_50k_objs` | 33.4 | 33.3 | 19.1 | 1.75 |
| `json_dump_50k_objs` | 27.2 | 29.4 | 15.8 | 1.72 |
| `regex_find_all_digits` | 5.7 | 6.0 | 3.4 | 1.68 |
| `regex_replace_digits` | 5.9 | 6.3 | 4.0 | 1.48 |
| `base64_encode_4MB` | 49.9 | 55.0 | 1.9 | 26.26 |
| `base64_decode_4MB` | 46.4 | 49.3 | 1.3 | 35.69 |
| `sha256_64KiB_x128` | 3.0 | 3.1 | 2.8 | 1.07 |
| `gzip_compress_4MB` | 16.3 | 16.4 | 6.5 | 2.51 |
| `gzip_decompress_4MB` | 3.0 | 3.0 | 0.9 | 3.33 |
| `csv_parse_50k_rows` | 23.9 | 25.1 | 17.7 | 1.35 |
| `url_parse_100k` | 135.1 | 153.5 | 132.0 | 1.02 |
| `url_percent_roundtrip_100k` | 88.7 | 97.9 | 185.1 | 0.48 |
| `path_join_basename_300k` | 21.1 | 20.0 | 106.5 | 0.20 |
| `set_add_contains_200k` | 9.2 | 10.4 | 9.5 | 0.97 |
| `dict_str_insert_lookup_300k` | 35.2 | 36.3 | 63.8 | 0.55 |
| `sort_1M_ints` | 67.0 | 66.5 | 261.0 | 0.26 |
| `sort_200k_strs` | 42.0 | 41.4 | 52.0 | 0.81 |
| `random_3M` | 15.0 | 14.9 | 67.1 | 0.22 |
| `uuid4_100k` | 45.1 | 48.8 | 132.0 | 0.34 |

## Yavaş uçlar ve nedenleri

Nedenler **koddan okunarak** bulundu; "doğrulandı" yazanlar dışındakiler ölçülmüş hipotezlerdir.

| Öncelik | Alan | Oran | Neden | Durum |
|---|---|---:|---|---|
| **P1** | `nox.base64` encode/decode | **26x / 36x** | `stdlib/nox/base64.nox` saf Nox: bayt başına `char_from_byte` + dize birleştirme. | Kod okundu; Zig `std.base64` shim'ine taşıma ~1x beklenir. |
| **P1** | `strings.upper/lower` (+`trim`) | **4x** | `strings.zig` `caseMapRaw`: ASCII taraması ve dönüşümü bayt bayt skaler döngü. | Kod okundu; `@Vector` ile SIMD hızlı yol beklenir (aynı dosyada `fastIndexOf` zaten SIMD). Benchmark `trim`i de içerir; ayrı ölçülmedi. |
| P2 | `nox.gzip` sıkıştırma / açma | 2.5x / 3.4x | Zig `std.compress.flate`, zlib'den yavaş. | Hipotez. Alternatif: zlib/libdeflate bağımlılığı (**kullanıcı kararı**, bağımlılık ilkesi). |
| P2 | `nox.json` parse / dump | 1.75x / 1.72x | Ağaç düğümü başına tahsis (`JsonValue`). | Hipotez (profil çıkarılmadı). |
| P2 | `nox.regex` find_all / replace | 1.7x / 1.5x | Kendi motoru; CPython `re` sre'si cilalı. | Hipotez. |
| P3 | `strings.replace` | 1.44x | İki geçiş; sonuç dizisi tahsisi. | Hipotez. |
| P3 | `nox.csv.parse` | 1.35x | Alan başına dize tahsisi. | Hipotez. |

Nox'un belirgin önde olduğu yerler (hepsi 0.5x altı): `random` (0.22), `sort` int (0.26), `uuid4` (0.34), `path`, `str_concat`, `str_find`, `fstring`, `dict[str,int]`, `percent_encode/decode`.

**Not (sağlama):** `sha256` 1.08x (ikisi de hızlandırılmış yerel koda yakın), `set` 0.97x.

## Eksik modül adayları

Bunlar kodda `grep` ile **bulunamadı**; her biri için önce gerçek talep doğrulanmalıdır:

- Keyfi hassasiyetli tamsayı (`bigint`) ve `decimal`/`fraction` (para hesabı, kriptografi tabanı).
- Komut satırı argüman ayrıştırma (`argparse` benzeri); `nox.os` yalnızca ham `argv` verir (doğrulanmalı).
- Geçici dosya/dizin (`tempfile`), `glob`/`fnmatch`.
- XML/HTML ayrıştırıcı.
- Sıkıştırma: `zip`, `tar` (yalnızca `upgrade.zig` içinde var), `zstd`, `brotli`.
- Özetler: `md5` (yalnızca uuid/pg içinde, genel API yok), `sha3`, `blake3`; `base32`.
- Eşzamanlılık: kullanıcıya açık `Mutex`/`Semaphore`/`RwLock` (yalnızca `atomic`, `Task`, `Channel` var).
- Yapılandırma: `.env`/`ini`.

Var olanlar (tekrar yazılmasın): `collections` (`Stack`, `Queue`, `Deque`, `Set`, `Counter`, `OrderedDict`, `LRUCache`, `Heap`, `PriorityQueue`), `csv`, `toml`, `yaml`, `json`, `protobuf`, `template`, `validate`, `jwt`, `uuid`, `url`, `timezone`.

## Öneri

1. `nox.base64` ve `strings.upper/lower` için Zig yoluna taşıma (küçük, düşük riskli, 4–36x kazanç); her ikisi golden test + benchmark ile.
2. gzip için karar: zlib/libdeflate vendor'lamak mı, mevcut Zig flate'ı mı korumak mı (kullanıcı kararı).
3. json/regex/csv için profil çıkarıp (perf/Instruments) tahsis noktalarını doğrula, sonra optimize et.
4. Eksik modüllerden hangilerinin gerçek talebi olduğunu birlikte seç.

## Yeniden ölçüm

```sh
zig build -Doptimize=ReleaseFast
python3 benchmarks/stdlib_perf/run.py --repeat 3                # LLVM
python3 benchmarks/stdlib_perf/run.py --repeat 3 --backend qbe
```
