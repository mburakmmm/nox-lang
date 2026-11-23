# Analiz araçları: graphify (kod grafı) ve rtk (komut çıktısı sıkıştırma) — kurulum ve kurallar (2026-11-23)

Amaç: ajanın bu depoyu **daha az token ve daha hızlı** çözümlemesi. Karar (kullanıcı, 2026-11-23): tüm projede uygula; Nox kısmına özel dikkat.

## graphify (kod grafı)

- **Üretim:** `$(head -1 ~/.local/bin/graphify | tr -d '#!') scripts/graphify_build.py` (~15 sn, LLM'siz, AST). Çıktı `graphify-out/` (git'te yok): `graph.json`, `GRAPH_REPORT.md`.
- **Kapsam/dışlama:** `.graphifyignore` (üretilmiş selfhost dosyaları, `zig-out`, `.zig-cache`, IR anlık görüntüleri, vendored `third_party`/`yyjson`, yml/json/toml veri dosyaları). `.graphifyrc`: `language.nox=python`.
- **Nox'a özel (Nox ≠ Python):** Python grameri `extern def`, `enum`, `protocol`, `lowlevel:` yapılarını göremez/hata düğümü yapar (107 dosyada kısmi çıkarım uyarısı). `scripts/graphify_build.py` içindeki `nox_supplement`: (1) bu yapıları düğüm olarak ekler (527 düğüm); (2) **`extern def` adı bir Zig `export fn` ile aynıysa `binds_ffi` kenarı** (647 kenar) — Nox ↔ Zig çalışma zamanı köprüsü grafta yürünebilir. Eksik: `defer`, `match`, `with_rt`/`retains` ayrıntısı, dekoratörler (ileride `noxc ast --full` tabanlı çıkarıma geçilebilir; selfhost'un doğal yan ürünü).
- **Etiketler:** topluluk adı = baskın dizin + en yüksek dereceli iki düğüm (deterministik). Elle etiket: `graphify-out/.graphify_labels.json` (öncelikli).
- **Doküman/görüntü anlamsal çıkarımı YAPILMADI** (297 doküman + 12 görüntü; LLM token maliyeti): gerekirse `/graphify . --update` ile ayrıca, önce `AGENTS.md`, `nox-teknik-spesifikasyon.md`, `project/*.md`.
- **Güncel tutma:** `sh scripts/graphify_refresh.sh [--wait]` (kilitli, graphify yoksa sessiz). `scripts/precheck.sh` her commit öncesi bunu başlatır; ajan kod değiştirdikten sonra `--wait` ile çağırır (AGENTS.md kuralı). Otomatik git hook'ları İSTEĞE BAĞLIDIR: `sh scripts/install_graphify_hooks.sh` (kullanıcı çalıştırır; ajan hook kurmaz — güvenlik denetimi reddetti). graphify'ın kendi `update`/hook'u `nox_supplement`i **bilmez** ve onu siler; KULLANILMAZ.
- **selfhost:** `selfhost/{lexer,parser,formatter,ast_schema}.nox` (üretilmiş) grafa dahildir — tüm `def`/`class`ları ve modüller arası çağrılar (`parse_stmt() → mk_Stmt()`) çıkarılır; Zig köprüsü `selfhost_glue.zig` `extern fn <modül>_nox_*` ↔ Nox `def nox_*` `binds_ffi` ile bağlıdır (`parseDump() → parser_nox_parse_run() → nox_parse_run()`). Bilinen boşluk: `nrt.parseDump()` gibi örnek-metod çağrıları Zig tarafında çözülmez.

## rtk kurulum durumu (2026-11-23, kullanıcı onayladı)

`brew install rtk` (1.2.1) + `rtk init -g --auto-patch`: `~/.claude/settings.json`a `PreToolUse/Bash → rtk hook claude`, `~/.claude/RTK.md` ve `CLAUDE.md`ye `@RTK.md`. Yedek: `~/.claude/settings.json.bak`. Etkinleşmesi için Claude Code yeniden başlatılır. Doğrulandı: `rtk rewrite` `git log`u sarıyor; `zig build test`, `zig build ...`, `scripts/precheck.sh` SARILMIYOR (ham kalır). Geri alma: `rtk init -g --uninstall`.

## rtk (rtk-ai/rtk — "Rust Token Killer")

- Komut çıktısını (git, test, build, log) ajan görmeden önce sıkıştıran CLI vekili; `rtk init -g` Claude Code'a hook kaydeder, `rtk gain` tasarrufu gösterir. Not: crates.io'da başka bir "rtk" var — doğru olan `rtk gain` panosunu gösterir.
- **Bu projede dikkat:** `zig build test` özet satırı (`Build Summary: ... tests passed`), `VERDICT`/`PRECHECK GREEN` satırları ve hata gövdeleri **asla** yutulmamalı (kural: test sonucu satırdan okunur). Pilot: önce dar komutlar (`git`, `ls`, `diff`); `zig build`/`zig test`/`precheck.sh` ham kalır ya da özel filtre doğrulanır.
