# Selfhost tip denetleyicisi (Aşama 3) — DEVİR NOTU (2026-11-26)

Bu not, `noxc-nightly` içindeki Nox tip denetleyicisini (`selfhost/typecheck.nox.in`) **başka bir ajanın/aracın** bitirebilmesi için yazıldı. Önce bu dosyayı, sonra `CLAUDE.md` §1–§4 ve `AGENTS.md` §0–§2'yi (yalnız bu bölümleri) oku. Başka bir şey okumadan başlama.

## 0. KAPSAM SINIRI (kullanıcı kararı — bağlayıcı)

- **Yalnızca tip denetleyicisi** (`selfhost/typecheck.nox.in`, `scripts/ck_*`, ilgili belgeler) bu nottaki ajana aittir.
- **Codegen (QBE/LLVM üretimi), Host ABI (`include/nox_host.h`, `runtime/host.zig`, `compiler/host_adapt.zig`, `compiler/codegen_qbe/*`) ve runtime'a DOKUNMA.** Bunlar yalnızca Claude'a (bu notu yazan oturum) aittir; kullanıcı başkasına yaptırmak istemiyor. Orada bir değişiklik gerekiyorsa kullanıcıya yaz, kendin yapma.
- **Mimari/ABI/dil-özelliği kararı** (AGENTS §16) gerektiren her şeyde DUR ve kullanıcıya sor. Aşama 3.14 (tiplenmiş AST'nin Zig codegen'e verilmesi) `[K]` = kullanıcı kararıdır; **yapma**.
- **Değişmez kural (kullanıcı, 2026-11-18):** Nox'a geçen her bileşen Zig karşılığının TÜM yüzeyini/davranışını/çıktı alanlarını eksiksiz karşılar (kısmi geçiş yok); Zig denetleyicisi yedekte kalır, kapatılmaz. Bir madde "tamam" sayılmadan önce: farksal test eşit + mutasyon testi + belge.

## 1. TOKEN TASARRUFU (CLAUDE.md §1–§3 özeti; doğruluk asla feda edilmez)

1. **Önce graf:** `graphify explain "<sembol>"` / `graphify query "<soru>" --budget 1500` → dosya:satır → yalnızca o aralığı `Read` (offset+limit). `checker.zig` ÇOK büyük (12 000+ satır): tam okuma YOK, aynı aralığı iki kez okuma. 3'ten fazla art arda grep gerekirse `graphify query ... --seed <dosya>`.
2. **Terminal:** `rtk git/grep/read/gh/ls`; ham `cat`/`sed -n`/`head`/`tail` ve rtk çıktısını `| cut | head` ile süzme YOK. rtk'nin tanımadığı gürültülü komutlar (zig build, `scripts/*.sh`, `python3 scripts/*`, `noxc*`) için `sh scripts/qrun.sh <ad> <komut> > $TMPDIR/x.out 2>&1` **ve çıkış kodunu `grep cikis= $TMPDIR/x.out` ile oku** (qrun bildirimindeki "exit 0"a ve `| tail` ile kesilmiş çıktıya GÜVENME).
3. Düzenleme `Edit`/`Write` ile; Python/sed yalnızca gerçekten mekanik çok yerli değişimde. Büyük dosyaya heredoc ile kod yazma. Çıktıyı sınırla (`--budget`, log'dan grep).
4. Kod değişince, grafı sorgulamadan önce ve her commit'ten önce `sh scripts/graphify_refresh.sh --wait`. **`graphify update .` / graphify'ın kendi `install`/hook'unu KULLANMA** (Nox'a özgü ek çıkarımı siler). Yeni sembolü `graphify explain` ile bir kez doğrula.
5. Uzun işleri `run_in_background`; beklemek için `sleep` değil bildirim. Test koşusunu tek seferde yap: değiştir → farksal regresyon → mutasyon → **TEK** `sh scripts/test-fast.sh` → `precheck` → bump → graf → commit → tag/push. Bump sonrası test tekrarı yok.
6. Kırmızı testi süzgeçle gizleme, testi gevşetme/azaltma/atlama (açık gerekçe + kullanıcı onayı olmadan). `scripts/test-fast.sh` VERDICT basmaz: **çıkış kodu + `error: '` satırları**.

## 2. YÖNTEM (değişmez)

Kapsam-kapılı port: Zig'deki bir davranışı `selfhost/typecheck.nox.in`'e taşı; taşınmayan yapı `raise unsup(ck, "etiket")` (durum 2, karşılaştırılmaz, histogramda görünür). Kapsam içi programlarda **kod, ileti, satır, span ve TÜM tanılamalar** Zig `checker.check` ile eşit olmalı.

Döngü (her dilim):
1. `graphify explain`/`query` ile Zig işlevini bul → dar `Read` → Nox'a port. (Zig'e yeni ileti eklenirse Nox iletisini AYNI turda güncelle.)
2. `python3 scripts/gen_selfhost_parser.py` (`.nox.in` → `selfhost/typecheck.nox`, **üretilmiştir, elle düzenleme**), sonra `zig build nightly` → `./zig-out/bin/noxc-nightly ck-diff check [--why] <dosya...>` (`--why` kapsam dışı etiket histogramı; `--why-deep` yalnız Nox, karşılaştırmaz).
3. Üreteç: `scripts/ck_gen.py --<kip>` (kipler: base, `--async --methods --builtins --recv --try --construct --ptr --extern --spawn --import --inherit --closure`). Yeni dilim = yeni kip (+ `scripts/ck_regress.sh` kip listesine ekle).
4. Elle kenar-durum korpusu: `tests/fixtures/ck_edge/<konu>/*.nox` (repo korpusuna girer; `ck_regress.sh` bunları da koşar).
5. **Mutasyon testi:** `python3 scripts/ck_mutate.py scripts/ck_mutants_<konu>.py <ck_gen çıktı dizinleri> tests/fixtures/ck_edge/<konu> --repo [--only=a,b]`. Mutant listesi `(ad, eski, yeni)`; `eski` `.nox.in`'de TAM BİR KEZ geçmeli. Karşılaştırma imzası kapsam dışı sayısını da içerir (kapsam dışına düşen mutantı da yakalar). Yaşayan mutant → ayırt edici kenar-durum `.nox` yaz, yalnız o mutantları `--only` ile yeniden koş. Gerçekten eşdeğer mutantı mutant dosyasının başlığında belgele. Betik koşu öncesi `selfhost/.ck_mutate_backup` yazar; yarım kalırsa (makine yeniden başladı/ENOSPC) bir sonraki çalıştırma kaynağı geri yükler. **Mutasyondan sonra nightly'yi yeniden derlemek betiğin işi (otomatik).** Mutant başına ≈1 dk (35–45 mutant ≈ 45 dk): `run_in_background` ile koş.
6. Tam regresyon: `sh scripts/qrun.sh r sh scripts/ck_regress.sh $TMPDIR/rg 1500 > $TMPDIR/r.out 2>&1` (≈12–16 dk, 14 kip + depo korpusu; çıkış kodu 0 olmalı).
7. Belge ZORUNLU: `nox-teknik-spesifikasyon.md` yeni `### 3.NNN` bölümü (son numaradan sonrasını al: `grep -n "^### 3.5" nox-teknik-spesifikasyon.md | tail -3`), `CHANGELOG.md` yeni sürüm girdisi (EN ÜSTTE), `project/noxc-nightly-selfhost-plani-2026-11.md` ilgili madde satırı.
8. Yayın: `bash scripts/bump_version.sh patch` → `PATH=$VENV/bin:$PATH sh scripts/precheck.sh` (venv: `python3 -m venv $TMPDIR/venv && $TMPDIR/venv/bin/pip install pyyaml markdown pygments`; macOS yeniden başlayınca silinir) → `git checkout services/frameworks-site/nox.lock` (precheck bunu boşuna değiştirir) → `sh scripts/graphify_refresh.sh --wait` → commit **yalnızca kendi dosyalarını AÇIK yollarla** (`git add -A`/`--amend` başkasının işini karıştırır; `project/framework-limitasyonlari-2026-11/` senin değil) → `git tag vX.Y.Z` → `git push origin main && git push origin vX.Y.Z`. Kullanıcının kalıcı yetkisi vardır ama **ancak** test-fast çıkış kodu 0, precheck "PRECHECK GREEN" ve regresyon yeşilse. Push öncesi `git fetch && git log HEAD..origin/main`: başka oturum main'e sürüm atmış olabilir → `git rebase origin/main`, sürüm/CHANGELOG/spec numaralarını sonrasına kaydır, çakışmayı dikkatle çöz, force-push YOK.

## 3. TUZAKLAR (hepsi gerçekten yaşandı)

- **macOS yeniden başlayınca** `$TMPDIR` (venv, korpuslar, `files.txt`) silinir; kalıcı betikler `scripts/`te. Mutasyon yarım kaldıysa `.nox.in` mutant halinde kalabilir: her mutantın `eski` metninin `.nox.in`'de tam 1 kez geçtiğini doğrula (artık otomatik yedek var), `git diff selfhost/typecheck.nox.in` ile bak.
- **Disk dolması (ENOSPC):** hiçbir komut çalışmaz; `.zig-cache` bozulur → `failed to spawn build runner ... FileNotFound` hatası: `rm -rf .zig-cache/h` sonra `zig build nightly`. Yer için kendi geçici korpuslarını (`$TMPDIR/rg ckmut* ckcl ckinh ckimp`) sil; paralel oturumların `.zig-cache`/`zig-out`'u da büyük.
- `ck-diff` Zig tarafı **ham modülü** denetler (yükleyici/prelude yok): `import` edilen modülün tanımı yoktur; mangled ad (`lib_util_g`) yalnız dosyada elle tanımlıysa çözülür. `__all__` yalnız yükleyicide `module_exports`a girer.
- Üreteçte tipsiz `t = spawn ..` ve `x = lambda ..` gibi `:=` biçimleri `check_stmt#2` ile kapsam dışıdır → açık tip anotasyonu kullan. `lowlevel` anahtar sözcük (alan adı `ll_depth`); dict yinelemesi codegen'de yalnız `.keys()`; `list[int | None]` Nox codegen'inde derlenmez.
- Zig `HashMap` yineleme sırası taklit edilemez: ≥2 öğenin sırasına bağlı tanı üretilen yerlerde `unsup` (`class#unassigned_multi`, `lambda#captures_order`).
- Zig `checker`'ın AST'yi YERİNDE yeniden yazdığı yerler (callee mangled adı, `rewriteExprTo`, `expr_rewrites`) Nox'ta yazılmaz (tanı etkisi yoksa). Etkisi varsa (ör. `Taban.metod(self)` → `super()` yeniden yazımı) kapsam dışı yapılır.
- Ön geçişler checker'dan ÖNCE AST'yi dönüştürür: `type_alias.zig`, `generator_desugar.zig`, `nonlocal_desugar.zig`, `guard_normalize.zig`, `mixin_flatten.zig`, `class_attr_promote.zig`, `derive.zig`, `index_call_fixup.zig`, `bound_method_fixup.zig` (sıra için `checkModule`, `checker.zig` ≈4253). Bir yapı bunlardan birine bağlıysa Nox'ta aynı dönüşümü taklit et ya da kapsam dışı yap.
- CI'da bilinen flake'ler: Linux Debug `wasm32-freestanding-threads` ağ testi (aarch64) ve `mn_shared_str` yarışı (v2.2.86'da düzeltildi); macOS ReleaseFast `http_serve`/HTTP/3 loopback testleri zaman zaman ağ flake'i verir (kodun değil). Yayından önce `gh run list --workflow CI --limit 6` ile geçmişe bak; kırmızıyı kök nedeniyle çöz, "flake" diye geçme.
- `qrun` bildirimi hep "exit 0" der; gerçek sonuç `cikis=` satırı.
- Zig'in test-fast'i `error: '...' failed` satırları basar; `failed command:` satırları tek başına hata değildir (stderr basan testler).

## 4. DURUM (2026-11-26, bu nottan hemen önce)

Yayınlananlar (hepsi Zig ile eşit, mutasyon testli): 3.12 dilim A (`extern def`, v2.2.83), **dilim B** import/from-import/takma ad/nitelikli çağrı ve tip (v2.2.87, spec §3.521), **3.4b-A** tekli sınıf kalıtımı (v2.2.88, §3.522). `origin/main` başka bir oturumun Host ABI işleriyle v2.2.93'e ilerledi (UR-009..015; DOKUNMA).

**YAYINLANMAMIŞ iş (yerel; bunu ilk bitir):** **3.7-A kapanış dilimi** (iç içe `def`, `lambda`, `defer`, işlev-değeri çağrısı, `nonlocal` kapısı). Durum: kod + `scripts/ck_gen.py --closure` + `tests/fixtures/ck_edge/closure/` + `scripts/ck_mutants_closure.py` (40 mutant, hepsi yakalandı; `nested_scope_nocaps` ve `defer_scope_nocaps` eşdeğer) + 13 kiplik regresyon yeşil (rebase öncesi) + belgeler (spec §3.528, CHANGELOG `[2.2.94]`, plan satırı). Yerel `main` = `origin/main` (v2.2.93) üstüne tek WIP commit; `build.zig.zon` 2.2.94'e bump edilmiş (commit edilmemiş olabilir). **Kalan yayın adımları:** (a) birleşik ağaçta `zig build nightly` + repo korpusunda `ck-diff check` eşit mi doğrula; (b) TEK `sh scripts/test-fast.sh` (çıkış kodu 0 + `error: '` yok); (c) `precheck`; (d) `git checkout services/frameworks-site/nox.lock`; graf yenile; (e) WIP commit'i `git commit --amend` ile gerçek mesajla düzelt (bu yerel, push edilmemiş commit olduğu için serbest) ve **açık yollarla** ekle; (f) `git tag v2.2.94`, push. `git status`/`git log -3` ile gerçek durumu önce doğrula.

## 5. KALAN İŞ SIRASI (Zig işlev konumları `checker.zig` ≈ satır; graf yenilenince kayar — `graphify explain` ile yeniden bul)

Histogram (`xargs ./zig-out/bin/noxc-nightly ck-diff check --why < <(git ls-files '*.nox' | grep -v '^selfhost/')`; son ölçüm: 1434 dosya, **450 kapsam dışı**, 387 kabul, 597 ret):

| Etiket | Dosya | Anlamı / Zig karşılığı |
|---|---|---|
| `spawn#shared_arg` | 50 | `SpawnSharedMutation`: `collectSpawnTargets`, `computeMutatesGraph` (`scanMutatesGraphFunc`), `checkNoPostSpawnCallerMutation`, `removeAwaitedTaskSharing` |
| `check_call#intrinsic` | 48 | `nox.http.serve*` (12 ad) / `nox.thread.start|pool_run`: `matchIntrinsicKind` (≈3837), `tryResolveHttpServeCall/FdCall/MulticoreCall/Generic` (≈3565–3890), `validateHttpHandler` (≈3480), `tryResolveThreadSpawnCall` (≈3889), `tryResolvePoolRunCall` (≈3939); bu dilimde yalnız kapı (`is_intrinsic_call`) var |
| `class#generic` | 26 | jenerik sınıf (`generic_classes`, `instantiateGenericClass`) |
| `class#consts` | 26 | sınıf sabitleri: `registerClassSignatures` `cd.consts` (≈4064–4100), `class_attr_promote.zig` ön geçişi, `Sınıf.NAME` okuma/atama (`receiverClassName`, `checkAttribute` ≈8545, `checkAssign` ≈6798) |
| `type_expr_generic#prelude` | 25 | `__nox_*` prelude jenerik tipleri (`core.nox` yönlendirmesi) |
| `check_binary#1/#2` | 25+10 | dunder operatörler (`__add__`…), `hasDunder` yeniden yazımları |
| `register_func#1/#2` | 22+21 | varsayılan/`*args`/`**kwargs`/dekoratör/jenerik işlev imzaları (`registerFunc` ≈2961, `validateParamDefaults`, `expandCallArgs`) |
| `toplevel#9` | 21 | `protocol_def` (`collectProtocols`, `satisfiesProtocol`, `ensureProtocolBase`) |
| `extern#decorators` | 19 | `@ffi.*`, `@capability.requires` (`registerExternFunc` ≈2096, `registerCapabilityDecorator`) |
| `check_expr_expected#1` | 16 | `tuple_lit`, `ternary`, `list_comp`, `dict_comp` |
| `check_call#prelude` | 15 | `tryDesugarPreludeCall` (≈8605: `max/min/sorted/sum/round/map/filter/any/all/list/set/bool/next/zip/enumerate/reversed/hex/oct/bin/pow/format`) |
| `class#decorators` | 13 | sınıf dekoratörleri (`@repr/@packed/@dataclass/@derive`; `derive.zig`) |
| `check_expr_inner#18` | 12 | dilim ifadesi `xs[a:b]` (Expr etiketi 18 = `slice`; lambda 19 artık yapıldı) |
| `class#bases` | 11 | çoklu taban/mixin (`mixin_flatten.zig` tam yolu, `validateMixinCompat`) |
| `type_expr_generic#tuple` | 10 | `tuple[...]` (`instantiateTupleClass`) |
| `check_stmt#1/#2`, `elem_grow`, `list_extend`, `toplevel#2`, `class#method_features`, `check_args_sig#kwarg`, `nonlocal`, `check_call#lowlevel` | 5–8 her biri | küçük kapılar: `:=` çıkarımı (`infer_assign`), `__nox_*` ad kuralı, liste büyütme (`grow_stmt_gate`), `type` takma adları (`type_alias.zig`), async/dekoratörlü metot, kwarg çağrılar, `nonlocal_desugar.zig` taklidi, `adopt` |
| diğer | — | `class#unassigned_multi` (HashMap sırası), `class#explicit_base_call` (`Taban.metod(self)`→`super()`), `check_identifier#fromimport`, iç içe `async def` (`hoistNestedAsync` ≈6665), dekoratörlü iç `def`, `spawn#attribute` |

**Önerilen sıra (kullanıcının sırası):** (0) yukarıdaki 3.7-A yayını → (1) **jenerik/protokol/prelude** (`type_expr_generic#prelude/#tuple`, `check_call#prelude`, `check_expr_expected#1` tuple/ternary, `class#generic`, `toplevel#9` protokol; monomorphization = `instantiateGeneric` ≈12383, `unifyTypeExpr` ≈11185, `substituteStmts` ≈11682: **AST kopyalamak yerine tip-parametre bağlamasıyla (binding haritası) denetlemek** düşünülebilir ama tanı metinleri Zig ile birebir kalmalı; bu bir TASARIM kararıdır → önce kullanıcıya/planı yazan oturuma sor) → (2) **imza özellikleri** (`register_func#1/#2`, kwarg çağrılar) → (3) **spawn analizleri** → (4) `class#consts/decorators/bases` → (5) intrinsic'ler (`nox.http.serve*`/`nox.thread.*`; stdlib tip adlarına `nox_http_HttpRequest` vb. bağlıdır, ham kipte yalnız elle tanımlı mangled sınıflarla çözülür) → (6) küçük kapılar → (7) **`ck-diff checkm`** (yükleyici + prelude birleşik modül; kalıtım+jenerik+prelude olmadan tümüyle `class#base`/prelude'a düşer; `__all__`/`requirePublic`/`validateModuleExports` burada) → (8) kapanış: tanı sırası/sayısı eşitliği, perf/bellek bütçesi (stdlib kontrolü ≤ 2× Zig, sızıntı testi), belge (3.13–3.17). 3.14 kararı kullanıcıya aittir.

## 6. DOĞRULAMA KONTROL LİSTESİ (bir dilimi "bitti" demeden önce)

- [ ] `ck_gen --<yeni kip>` 3000 program: fark yok, kabul oranı makul (temiz-program kipi ekle; yalnız hatalı programlar derin yolu test etmez).
- [ ] Kenar-durum korpusu: her mutant için ayırt edici dosya; yaşayan mutant 0 (eşdeğerler başlıkta belgeli).
- [ ] `ck_regress.sh` tüm kipler + depo: çıkış kodu 0.
- [ ] TEK `test-fast` (çıkış 0, `error: '` yok), `precheck` GREEN.
- [ ] spec + CHANGELOG + plan güncel; graf yenilendi; commit yalnızca kendi dosyaların; tag + push; CI geçmişi kontrol edildi.
- [ ] Hafıza/devir: bu dosyanın §4–§5'ini güncelle (durum + histogram).

## 7. İLGİLİ DOSYALAR

`selfhost/typecheck.nox.in` (kaynak), `selfhost/types.nox` (tip tablosu `TT`, `ty_*`), `selfhost/ast_schema.nox` + `scripts/gen_selfhost_ast.py` (AST düzeni; `{{O:Tür.alan}}`, `{{T:...}}`, `{{NONE}}`), `compiler/selfhost_ck_diff.zig` (`ck-diff` sürücüsü), `compiler/typecheck/checker.zig` (referans), `scripts/ck_gen.py`, `scripts/ck_regress.sh`, `scripts/ck_mutate.py`, `scripts/ck_mutants_{import,inherit,closure}.py`, `tests/fixtures/ck_edge/{import,inherit,closure}/`, `project/noxc-nightly-selfhost-plani-2026-11.md` (plan + canlı takip), spec §3.50x–§3.528, hafıza dosyası `~/.claude/projects/-Users-melihburakmemis-Documents-nox-lang/memory/project_selfhost_stage3_state_2026_11_25.md`.
