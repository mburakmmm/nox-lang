# Rapor 1 — Aşama 1 sonuç raporu (v2.2.52, 2026-11-24)

Kaynak liste: `project/selfhost-sertlestirme-listesi-2026-11-23.md`. Biçim: bulgu → kök neden → düzeltme → kanıt → durum.

## Kapanan bulgular (bu tur)
| Madde | Kök neden | Düzeltme | Kanıt |
|---|---|---|---|
| **R1-P1.7c** ReleaseFast nightly `parse-nox` hata iletisi çöp bayt | Nox'ta DEĞİL: `compiler/syntax_report.zig` `reportParseFailure` içinde `diag = .{ ..., .note = if (diag) |old| old.note else null }` hedefi kendi başlatma ifadesinde okuyordu (Zig sonuç-konumu örtüşmesi); Debug'da geçici değişkenle çalışır, ReleaseFast'te alanlar yerinde yazılırken `old.note` çöp okunur | `old.note` önce yerel değişkene alınır | Debug nightly doğru/ReleaseFast çöp ayrımı + `DBG` tanısıyla bulundu; `frontend_diff --component parser` 4 dosya farkı → 0 (aşağıda sonuç) |
| **R1-P1.5** paralel cycle collector collect aşaması OOM yutuluyordu | `parPhase`/`processCollect`/`run` ve `collectRootsDiscover` `catch continue`/`catch {}` ile sessiz | `dropped_whites` sayacı (paralel: `ParShared.dropped` atomik), tüm sitelerde sayılır; tasarım: collect-OOM yalnız SIZINTI (sayaçlar tutarlı, erken serbest bırakma yok) | birim test "R1-P1.5": enjekte OOM → `dropped_whites==1`, kayıtlı beyazlar tutarlı, `deinit` sızıntı denetimi geçer |
| **R1-P2.1** `put_span_suffix` O(n²) | düğüm başına `sp_ids` doğrusal tarama | üretici `gen_selfhost_ast.py`: yoğun düğüm→span dizini (ilk eşleşme kazanır) | 759 KB kaynak: 0,09 s → 0,04 s (2,2×), tepe RSS +5 MiB; çıktı BAYT-EŞDEĞER (`cmp`) |
| **R1-P2.2** nightly platform/dağıtım | belirsiz | `project/nightly-dagitim-sozlesmesi-2026-11-24.md`; Windows'ta `zig build nightly` açık hata; `selfhost-info` platform doğrulama durumu | belge + build.zig + main.zig |

## Doğrulama/denetim maddeleri (kısmi; dürüst durum)
- **R1-H (gerileme denetimi) — KISMİ.** Tam `test-fast` (2300+ test) her değişiklikte yeşil koştu; liste alias semantiği/QBE=LLVM/sızıntı testleri bu kümenin içindedir. Ancak her alt başlığı (Aether worker istisnası v2.2.25, SafeHTTP, GC mark/scan OOM, GC seri/paralel eşdeğerlik, yıldızlı unpack, type alias izolasyonu, lexer span/CRLF) için ADLANDIRILMIŞ bir test eşlemesi bu turda ÇIKARILMADI; yalnızca şu kanıtlar doğrulandı: GC mark/scan OOM (P0.2 testi, bu turda genişledi), GC paralel↔sıralı eşdeğerlik (`cycle_detector.zig` "F: paralel işaretleme/tarama…" testi), type alias (`codegen_cases/type_alias_basic`), CRLF (bu turda `fmt_properties` 0 ihlal + golden test), SafeHTTP (`tests/compat/http_stdlib_golden_test.zig`). Kalan alt başlıklar için test eşlemesi AÇIK.
- **R1-I (ekosistem) — KISMİ.** `noxc check` (yalnız tip denetimi; derleme/çalıştırma/perf YOK): Aether, Aura, Atlas, Feather, Nova, Noxen, Rune → temiz. **Nyx `examples/blog/main.nox` → `module 'nyx.server' has no member named 'use_listen_fd'`**: `use_listen_fd` Nyx kaynağında tanımlı değil (yalnız kullanım var; `tests/v17_mn_release_test.nox` ve README'de de), derleyici regresyonu değil, Nyx tarafı eksik/tutarsız (Nyx sahibine rapor). Rune/Vault/Quartz: Vault ve Quartz yerelde bulunamadı (erişilemeyen: raporlandı). Çok worker/HTTP/sızıntı/perf koşuları yapılmadı.
- **R1-J (test matrisi) — KISMİ.** Bu turda: macOS aarch64, LLVM (varsayılan) + QBE (`--backend qbe` ile P1.7c/P1.1 probları), Debug (bellek) + ReleaseFast (davranış: nightly/parite). Linux/Windows/WASM/mobil/NNI/HPy: CI'ya bırakıldı (push sonrası). Perf baseline: v2.2.49 R2-N1.a ölçümü; düzeltme sonrası aynı set tekrar koşulmadı.
- **R1-L (tamamlanma ölçütleri) — KISMİ.** P0/P1/P2 maddeleri kapalı; açık: R1-H alt test eşlemesi, R1-I çalışma-zamanı koşuları, R1-J Linux/Windows/ARM CI sonuçları.

## Yan bulgu
- Aynı sonuç-konumu örtüşmesi kalıbı (`x = .{ ..., x... }`) depoda başka yerlerde olabilir; ayrı tarama maddesi: **R1-P1.7d**.
