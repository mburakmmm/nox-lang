# 2.2 aşama 8: stdlib'e gömülecek C kaynaklı kütüphane adayları (ölçüm + öneri)

Kural (kullanıcı kararı 2026-11-14): önce aday listesi + ölçüm; onaylananlar Nox API'siyle (Nox semantiği, Nox `str`/`list`/hata modeli) sarılır, çerçeveler (Nyx, Aether vb.) doğrudan kullanır. Gömülü = runtime'a statik derlenir; kullanıcı `extern def` yazmaz. AGENTS §9.5: gömülü kütüphaneler Nox'un KENDİ runtime'ının parçasıdır (güvenilen kod); yine de her biri fuzz/farksal testle kapsanır. Hello-world ikilisi şu an ≈377 KB; her aday "isteğe bağlı bağlama" ile (yalnızca kullanılan modül) eklenmelidir (aşama 9 ile birlikte).

## Ölçülen boşluklar (Apple M4, ReleaseFast)

| Alan | Nox bugün | C referansı | Oran |
|---|---|---|---|
| Regex `[0-9]+` find_all, 50k eşleşme | 4,15 ms | PCRE2 yorumlayıcı 1,93 ms / PCRE2 JIT 0,46 ms | 2,1× / 9× |
| JSON ayrıştırma, 50k nesne | 7,1 ms | yyjson 1,5-2,9 ms | 2,5-4,7× |
| JSON dump | 5,9 ms | yyjson 1,0-1,3 ms | ≈5× |
| Sıkıştırma (zstd/lz4/brotli) | **yalnızca açma** (`nox.zstd.decompress`), sıkıştırma YOK | zstd, lz4, brotli | özellik eksiği |
| Hızlı şifresiz özet (xxh3/wyhash) | Zig std wyhash içeride, kullanıcıya açık değil | xxHash | özellik eksiği |
| gzip/deflate | libdeflate (gömülü) | — | C hızında |
| sha256 | ≈2,7 GB/s | — | donanım hızlandırmalı |

## Adaylar

| Aday | Lisans | Yaklaşık maliyet | Ne kazandırır | Öneri |
|---|---|---|---|---|
| **zstd** (sıkıştırma + açma) | BSD-3 | ~400-500 KB kod | `nox.zstd.compress/decompress`, HTTP `Content-Encoding: zstd`, sıkıştırılmış günlükler/yedekler; açma zaten Zig'de var (8 MiB pencere sınırı), tam kütüphane akış + sözlük + yüksek seviye | **Evet** (en yüksek değer) |
| **lz4** | BSD-2 | ~100 KB | çok hızlı sıkıştırma (IPC, önbellek, WASM/FFI tamponları) | **Evet** (küçük) |
| **xxHash** (xxh3-64/128) | BSD-2 | ~50 KB (tek başlık) | `nox.hash` (dict anahtarı olmayan hızlı özet, dosya tekrar tespiti); sha256'dan 10-20× hızlı | **Evet** (küçük) |
| **PCRE2** (+ JIT) | BSD-3 (+istisna) | ~600-700 KB (+JIT ~300 KB; JIT wasm/freestanding'de yok) | Düzenli ifade 2-9× hızlı, tam PCRE sözdizimi (geriye başvuru, ileri/geri bakış) | **Ayrı modül** (`nox.pcre`); mevcut `nox.regex` dilbilgisi/anlamı değişmez (anlam riski) |
| **yyjson** (yazıcı) | MIT | ~400 KB (`yyjson.c`; yalnız yazıcı ~120 KB) | `nox.json.dump` ≈5× | **Şimdilik hayır**: kendi bant ayrıştırıcımız var; yazıcıyı Zig'de hızlandırmak yyjson gömmekten ucuz (aşama 12) |
| **brotli** (açma) | MIT | ~600 KB (sözlük 122 KB dahil) | HTTP `br` yanıtlarını açma | **İstemci HTTP için sonra** (istek geldikçe) |
| simdjson | Apache-2 | C++ (libc++ gerekir) | JSON | **Hayır** (C++ araç zinciri, kendi bantımız var) |
| picohttpparser | MIT | ~10 KB | HTTP/1 başlık ayrıştırma | **Hayır** (HTTP "ok" yolu zaten C kqueue tek-iş-parçacığı sunucusunu geçiyor) |

## Önerilen paket

1. `nox.zstd` genişletmesi: tam zstd (sıkıştırma dahil), mevcut `decompress` API'si korunur.
2. `nox.lz4`, `nox.hash` (xxh3).
3. `nox.pcre` (PCRE2, JIT'li olan hedeflerde JIT, yoksa yorumlayıcı).

Her biri: vendored kaynak `third_party/<ad>/` (+ LICENSE), `build.zig`te yalnızca ilgili modülü içeren programlara bağlanır (kullanılmayan program ikilisi büyümez; aşama 9 doğrular), Nox sarmalayıcısı `stdlib/nox/<ad>.nox` + `docs/stdlib/<ad>.md`, golden + farksal test (C referansıyla çıktı eşitliği) + `benchmarks/stdlib_perf` satırı (Nox / C / Python), wasm hedefinde desteklenen/reddedilen durumu `docs/internals/wasm-coverage.md`ye işlenir.
