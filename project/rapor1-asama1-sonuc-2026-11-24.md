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
- **R1-H (gerileme denetimi) — KAPANDI (v2.2.53).** Konu → adlandırılmış test (dosya varlığı doğrulandı; v2.2.52 tam `test-fast` 875/875'te yeşil):

| Konu | Test |
|---|---|
| Aether worker istisna deposu yarışı (v2.2.25) | `tests/compat/http_serve_multicore_golden_test.zig`, `http_serve_multicore_pool_golden_test.zig`; `http_factory_probe` |
| SafeHTTP yönlendirme başlık sızıntısı | `tests/compat/http_stdlib_golden_test.zig` (Authorization sınaması) |
| GC mark/scan OOM + collect-OOM | `runtime/alloc/cycle_detector.zig` "GPT-6 P0.2…", "R1-P1.5…" |
| GC seri/paralel eşdeğerlik (serbest bırakılan küme) | `cycle_detector.zig` "F: paralel işaretleme/tarama, sıralı toplayıcıyla AYNI nesneleri…" |
| Yıldızlı unpack minimum uzunluk | `codegen_cases/star_unpack_min_len` (iki backend) |
| `type` takma adı izolasyonu/döngü | `codegen_cases/type_alias_basic`, typecheck golden alias zincirleri |
| Lexer span/CRLF | `frontend_diff --component lexer/fmt` (CRLF mutasyonlu), `fmt_properties` crlf=0, `fmt_golden_test` CRLF testi |
| Sızıntı / tüketen kurucu stresi | `codegen_cases/ctor_consume_stress`, runtime DebugAllocator sızıntı denetimleri |
| Liste alias semantiği | `codegen_cases/list_alias_growth_shared`, `ownership_cases/arc_alias_escape` |
| QBE = LLVM | fixture korpusu her codegen fixture'ını iki backend'de çalıştırır (AGENTS §3) |

Önceki durum notu: Tam `test-fast` (2300+ test) her değişiklikte yeşil koştu; liste alias semantiği/QBE=LLVM/sızıntı testleri bu kümenin içindedir. Ancak her alt başlığı (Aether worker istisnası v2.2.25, SafeHTTP, GC mark/scan OOM, GC seri/paralel eşdeğerlik, yıldızlı unpack, type alias izolasyonu, lexer span/CRLF) için ADLANDIRILMIŞ bir test eşlemesi bu turda ÇIKARILMADI; yalnızca şu kanıtlar doğrulandı: GC mark/scan OOM (P0.2 testi, bu turda genişledi), GC paralel↔sıralı eşdeğerlik (`cycle_detector.zig` "F: paralel işaretleme/tarama…" testi), type alias (`codegen_cases/type_alias_basic`), CRLF (bu turda `fmt_properties` 0 ihlal + golden test), SafeHTTP (`tests/compat/http_stdlib_golden_test.zig`). Kalan alt başlıklar için test eşlemesi AÇIK.
- **R1-I (ekosistem) — KISMİ (v2.2.53).** `noxc build` (LLVM, v2.2.52 derleyicisi): Aether, Aura, Atlas, Feather, Nova, Noxen, Rune → 7/7 derlenir. Aether `hello_api` çalıştırıldı: `/health` 200 `{"status":"ok"}`, `/api/users/1` 200 JSON, `/api/users` GET 405 JSON hata (beklenen). **Nyx `examples/blog/main.nox` derlenmez**: `nyx.server.use_listen_fd` Nyx kaynağında tanımlı değil (yalnız kullanım: `main.nox`, `probe.nox`, `tests/v17_mn_release_test.nox`, README) — derleyici regresyonu değil, Nyx tarafı. Vault/Quartz yerelde yok (erişilemeyen). YAPILMADI: çok-worker yük, sızıntı ve perf koşuları (Nyx düzelmeden "Nox 1.2 dönemi Nyx web uygulaması" senaryosu da koşulamaz).
- **R1-J (test matrisi) — KISMİ.** Bu turda: macOS aarch64, LLVM (varsayılan) + QBE (`--backend qbe` ile P1.7c/P1.1 probları), Debug (bellek) + ReleaseFast (davranış: nightly/parite). Linux/Windows/WASM/mobil/NNI/HPy: CI'ya bırakıldı (push sonrası). Perf baseline: v2.2.49 R2-N1.a ölçümü; düzeltme sonrası aynı set tekrar koşulmadı.
- **R1-L (tamamlanma ölçütleri) — KISMİ.** P0/P1/P2 maddeleri kapalı; açık: R1-H alt test eşlemesi, R1-I çalışma-zamanı koşuları, R1-J Linux/Windows/ARM CI sonuçları.

## Yan bulgu
- Aynı sonuç-konumu örtüşmesi kalıbı (`x = .{ ..., x... }`) depoda başka yerlerde olabilir; ayrı tarama maddesi: **R1-P1.7d**.
