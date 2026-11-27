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

## 4. DURUM (2026-11-27, v2.2.105 sonrası)

- **Son sürüm:** `v2.2.105` — `selfhost/typecheck.nox.in` (üretilen `selfhost/typecheck.nox`: **13.715 satır**) Paket 1: `mixin_flatten_run` (`class#bases`, `class#explicit_base_call`), `derive_run` (`class#decorators`), `class#method_features`, `index_call_fixup_run` + `bound_method_fixup_run` (`attr#bound_method`, `check_call#bind_method`), `elem_grow`/`list_extend`/`list_sort_kwargs`/`dict_items`, `lowlevel_stmt` + `adopt`, `try#dotted`, `enumerate`/`zip` kaynaşımı, `check_call#1`, `check_assign#1` ve 7 dunder kapısı.
- **Doğrulama:** `ck_gen.py --cls-mi-ops` (`files=3000 unsupported=0 accepted=1061 rejected=1939 diagnostics=1546 skipped_parse=0`), `ck_edge/cls_mi_ops` (`30` dosya, `unsupported=0 accepted=12 rejected=18 diagnostics=17`), `ck_mutants_cls_mi_ops.py` (`28/28 yakalandı, 0 yaşayan`), `ck_regress.sh` `22` kip + depo yeşil.
- **Depo `ck-diff check` (`v2.2.105`):** `files=1746 unsupported=59 accepted=618 rejected=1069 diagnostics=2256 skipped_parse=56` (`class#decorators`, `class#bases`, `class#explicit_base_call`, `class#method_features`, `attr#bound_method`, `check_call#bind_method`, `check_call#lowlevel`, `check_call#1`, `check_assign#1`, `try#dotted`, `list_sort_kwargs`, `dict_items`, `check_for_iterable#enumerate_zip`, ve dunder kapıları `0`; kalan üst engeller: `23 register_func#generator`, `22 nonlocal`, `4 stmt_kind#nested_async`, `2 check_stmt#async_for`, `1 check_stmt#async_with`, `1 lambda#captures_order`, `1 spawn#attribute`, `1 stmt_kind#nested_features`).
- **`ck-diff checkm` (`tests/golden/typecheck_cases/*.nox`, `v2.2.105`):** `files=347 unsupported=14 accepted=89 rejected=244 diagnostics=199 skipped=0` (**%96,0 kapsam**; kalanlar yalnızca: `6 register_func#generator`, `3 nonlocal`, `2 stmt_kind#nested_async`, `2 check_stmt#async_for`, `1 check_stmt#async_with`).

### Önceki (v2.2.104 sonrası)

- **Son sürüm:** `v2.2.104` — `selfhost/typecheck.nox.in` (üretilen `selfhost/typecheck.nox`: **11.752 satır**) `toplevel#2` (`type_alias_run`), `check_stmt#2`/`#1` (`:=` walrus + `__nox_tup_*` + `divmod` + `synth_follow`), `check_binary#1`/`#2` (`guard_normalize_run` + Optional `==`/`!=` + daraltma + `try_operator_overload`), `class#method_features` (`@staticmethod`/`@classmethod`/`@property`/`@x.setter`) ve `class#enum` + `match` (`matrix_exhaustive`, jenerik enum çıkarımı).
- **Doğrulama:** `ck_gen.py --enum-bin-alias` (`files=3000 unsupported=0 accepted=725 rejected=2275 diagnostics=2270 skipped_parse=0`), `ck_edge/enum_bin_alias` (`34` dosya, `unsupported=0 accepted=12 rejected=22 diagnostics=19`), `ck_mutants_enum_bin_alias.py` (`28/28 yakalandı, 0 yaşayan`), `ck_regress.sh` `21` kip + depo yeşil.
- **Depo `ck-diff check` (`v2.2.104`):** `files=1712 unsupported=123 accepted=576 rejected=1013 diagnostics=2166 skipped_parse=56` (`toplevel#2`, `check_stmt#2`, `check_binary#1`, `check_binary#2`, `class#enum`, `check_stmt#3` → `0`; kalan üst engeller: `22 register_func#generator`, `22 nonlocal`, `15 class#decorators`, `11 class#bases`, `10 elem_grow`, `6 check_call#1`, `5 list_extend`, `4 check_call#lowlevel`, `4 attr#bound_method`, `4 stmt_kind#nested_async`, `3 class#method_features`).
- **`ck-diff checkm` (`tests/golden/typecheck_cases/*.nox`, `v2.2.104`):** `files=347 unsupported=36 accepted=85 rejected=226 diagnostics=191 skipped=0` (**%89,6 kapsam**; kalan üst engeller: `8 class#decorators`, `6 register_func#generator`, `5 class#bases`, `3 elem_grow`, `3 nonlocal`, `2 list_extend`, `2 stmt_kind#nested_async`, `2 check_stmt#async_for`).

### Önceki (v2.2.103 sonrası)

- **Son sürüm:** `v2.2.103` — `selfhost/typecheck.nox.in` (üretilen `selfhost/typecheck.nox`: **9.753 satır**) `class#consts` (`class_attr_promote_run`, `receiver_class_name`), `extern#decorators` (`@ffi.escape`/`noescape`/`callback`/`errors`/`@capability.requires`) ve `check_call#intrinsic` (`nox.http.serve*` 12 varyant + `nox.thread.start`/`pool_run`) + `h3_server.zig` GOAWAY kapanış yarışı düzeltmesi (§8).
- **Doğrulama:** `ck_gen.py --bytes-spawn-dec` (`files=3000 unsupported=0 accepted=1362 rejected=1638`), `ck_gen.py --consts-ffi-intr` (`files=3000 unsupported=0 accepted=1818 rejected=1182 diagnostics=1136`), `ck_edge/consts_ffi_intr` (`23` dosya, `unsupported=0 accepted=4 rejected=19`), `ck_mutants_consts_ffi_intr.py` (`27/27 yakalandı, 0 yaşayan`), `ck_regress.sh` `20` kip + depo yeşil.
- **Depo `ck-diff check` (`v2.2.103`):** `files=1689 unsupported=212 accepted=535 rejected=942 diagnostics=2078 skipped_parse=56` (`class#consts`=0, `extern#decorators`=0, `check_call#intrinsic`=0; kalan üst engeller: `31 check_binary#1`, `23 class#enum`, `22 register_func#generator`, `20 nonlocal`, `15 class#decorators`, `11 class#bases`, `10 check_stmt#1`, `10 check_binary#2`, `9 elem_grow`, `8 check_stmt#2`, `8 toplevel#2`, `8 class#method_features`).
- **`ck-diff checkm` (`tests/golden/typecheck_cases/*.nox`, `v2.2.103`):** `files=347 unsupported=76 accepted=76 rejected=195 diagnostics=165 skipped=0` (`class#consts`=0, `extern#decorators`=0, `check_call#intrinsic`=0; kalan üst engeller: `10 class#enum`, `9 check_binary#1`, `8 check_stmt#2`, `8 class#decorators`, `6 register_func#generator`, `5 class#bases`, `5 toplevel#2`, `4 check_stmt#1`, `4 class#method_features`, `3 elem_grow`, `3 nonlocal`).

### Önceki (v2.2.102 sonrası)

- **Son sürüm:** `v2.2.102` — `selfhost/typecheck.nox.in` (üretilen `selfhost/typecheck.nox`: **8.547 satır**) tam `bytes` (+ `str#prelude`), `spawn#shared_arg` (`MutGraph`, `compute_return_alias_effects`, `SpawnFlow`) ve üst-düzey fonksiyon dekoratörleri (`register_func#2`, `@capability.requires`, `__nox_reflect_*`).
- **Doğrulama:** `ck_gen.py --bytes-spawn-dec` (`files=3000 unsupported=0 accepted=188 rejected=2812 diagnostics=3584`), `ck_edge/bytes_spawn_dec` (`22` dosya, `unsupported=0`), `ck_mutants_bytes_spawn_dec.py` (`27/27 yakalandı, 0 yaşayan`), `ck_regress.sh` `19` kip + depo yeşil.
- **Depo `ck-diff check` (`v2.2.102`):** `files=1667 unsupported=286 accepted=515 rejected=866 diagnostics=2003 skipped_parse=56` (`spawn#shared_arg`=0, `register_func#2`=0, `type#bytes`=0; kalan üst engeller: `48 check_call#intrinsic`, `33 class#consts`, `31 check_binary#1`, `22 register_func#generator`, `20 nonlocal`, `19 extern#decorators`, `15 class#decorators`, `11 class#bases`, `10 check_stmt#1`, `10 check_binary#2`, `9 elem_grow`, `8 check_stmt#2`, `8 toplevel#2`).
- **`ck-diff checkm` (`tests/golden/typecheck_cases/*.nox`, `v2.2.102`):** `files=347 unsupported=110 accepted=70 rejected=167 diagnostics=147 skipped=0` (`303 type#bytes` → `0`; kalan üst engeller: `17 class#consts`, `16 extern#decorators`, `12 check_call#intrinsic`, `9 check_binary#1`, `8 check_stmt#2`, `8 class#decorators`, `6 register_func#generator`, `5 class#bases`, `5 toplevel#2`, `4 check_stmt#1`, `4 class#method_features`, `3 elem_grow`, `3 nonlocal`).

### Önceki (v2.2.101 sonrası)

- **Son sürüm:** `v2.2.101` — `selfhost/typecheck.nox.in` (üretilen `selfhost/typecheck.nox`: **6.760 satır**) imza özellikleri (`default`, `*args`, `**kwargs`, `kw_only`, `pos_only`, anahtar-sözcük argümanları, `*xs`/`**d` açılımı, `spawn` kapsamı) + `Expr.bytes_lit` / `__nox_bytes_repr` + `scripts/ck_mutate.py` izole `$TMPDIR/ck_mutate_cache` ve çıkış kodu `3` düzeltmesi.
- **Doğrulama:** `ck_gen.py --sig` (`files=2785 unsupported=0 accepted=1274 rejected=1511`), `ck_edge/sig` (`20` dosya, `unsupported=0`), `ck_mutants_sig.py` (`23/23 yakalandı, 0 yaşayan`), `ck_regress.sh` `18` kip + depo yeşil.
- **Depo `ck-diff check` (`v2.2.101`):** `files=1647 unsupported=353 accepted=483 rejected=811 diagnostics=1901 skipped_parse=56` (`register_func#1`=0, `check_args_sig#kwarg`=0, `class#method_param_features`=0; kalan üst engeller: `51 spawn#shared_arg`, `48 check_call#intrinsic`, `33 class#consts`, `30 check_binary#1`, `22 register_func#generator`, `20 nonlocal`, `19 extern#decorators`, `15 class#decorators`, `14 register_func#2`, `11 class#bases`, `10 check_stmt#1`, `10 check_binary#2`).
- **`ck-diff checkm` (`tests/golden/typecheck_cases/*.nox`, `v2.2.101`):** `files=347 unsupported=341 accepted=0 rejected=6 diagnostics=0 skipped=0` (`303 type#bytes`, `17 class#consts`, `8 class#decorators`, `5 toplevel#2`, `5 class#bases`, `3 nonlocal`; `303 register_func#1` → `0`).

### Önceki (v2.2.100 sonrası)

Yayınlananlar (hepsi Zig ile eşit, mutasyon testli): 3.12 dilim A (`extern def`, v2.2.83), **dilim B** import/from-import/takma ad/nitelikli çağrı ve tip (v2.2.87, spec §3.521), **3.4b-A** tekli sınıf kalıtımı (v2.2.88, §3.522), **3.7-A** kapanış/iç içe `def`/`lambda`/`defer` (v2.2.94, §3.528), **3.6-A** `tuple`/`ternary`/`list_comp`/`dict_comp`/`slice` (v2.2.96, §3.529), **3.6-B** AST klonlama/ikame + jenerik sınıflar (`Box[T]`, `mod.Box[T](...)`, `Sub(Base[int])`, v2.2.97, §3.530), **v2.2.98** Nightly CI + frontend/harness sağlamlaştırmaları (§8 ve spec §3.531), **3.6-C** jenerik işlevler ve jenerik metodlar (`def f[T]`, `unify_type_expr`, lambda çıkarımı, `def m[T](self, ...)`, `self.m[T](...)`, v2.2.99, §3.532), **3.6-D** prelude jenerik tipleri/çağrıları & `protocol_def` (monomorfik + heterojen kutulama, v2.2.100, §3.533 — **Aşama 3.6 tamamlandı**). (`origin/main` Host ABI UR-009..015 ile v2.2.93/v2.2.95'e ilerledi; DOKUNMA.)

**Sıradaki iş:** İmza özellikleri (`register_func#1` varsayılan/`*args`/`**kwargs` imzaları, `register_func#2` dekoratörlü üst-düzey işlevler, `check_args_sig#kwarg`), ardından `spawn#shared_arg` (`SpawnSharedMutation` + mutasyon grafı).

## 5. KALAN İŞ SIRASI (Zig işlev konumları `checker.zig` ≈ satır; graf yenilenince kayar — `graphify explain` ile yeniden bul)

Histogram (`xargs ./zig-out/bin/noxc-nightly ck-diff check --why < <(git ls-files '*.nox' | grep -v '^selfhost/')`; son ölçüm v2.2.100 depo: 1620 dosya, **383 kapsam dışı**, 471 kabul, 766 ret, 1837 tanılama, 56 ayrıştırma atlanan):

| Etiket | Dosya | Anlamı / Zig karşılığı |
|---|---|---|
| `spawn#shared_arg` | 50 | `SpawnSharedMutation`: `collectSpawnTargets`, `computeMutatesGraph` (`scanMutatesGraphFunc`), `checkNoPostSpawnCallerMutation`, `removeAwaitedTaskSharing` |
| `check_call#intrinsic` | 48 | `nox.http.serve*` (12 ad) / `nox.thread.start|pool_run`: `matchIntrinsicKind` (≈3837), `tryResolveHttpServeCall/FdCall/MulticoreCall/Generic` (≈3565–3890), `validateHttpHandler` (≈3480), `tryResolveThreadSpawnCall` (≈3889), `tryResolvePoolRunCall` (≈3939); bu dilimde yalnız kapı (`is_intrinsic_call`) var |
| `class#consts` | 33 | sınıf sabitleri: `registerClassSignatures` `cd.consts` (≈4064–4100), `class_attr_promote.zig` ön geçişi, `Sınıf.NAME` okuma/atama (`receiverClassName`, `checkAttribute` ≈8545, `checkAssign` ≈6798) |
| `check_binary#1/#2` | 28+10 | dunder operatörler (`__add__`…), `hasDunder` yeniden yazımları |
| `register_func#1` | 26 | varsayılan/`*args`/`**kwargs` işlev imzaları (`registerFunc` ≈2961, `validateParamDefaults`, `expandCallArgs`) |
| `register_func#generator` | 22 | `generator_desugar.zig` (`yield`/`yield from` durum makinesi — Aşama 3.8) |
| `nonlocal` | 20 | `nonlocal_desugar` hücre dönüşümü |
| `extern#decorators` | 19 | `@ffi.*`, `@capability.requires` (`registerExternFunc` ≈2096, `registerCapabilityDecorator`) |
| `class#decorators` | 15 | sınıf dekoratörleri (`@repr/@packed/@dataclass/@derive`; `derive.zig`) |
| `register_func#2` | 13 | dekoratörlü üst-düzey işlev imzaları (`async def f[T]` dahil) |
| `class#bases` | 11 | çoklu taban/mixin (`mixin_flatten.zig` tam yolu, `validateMixinCompat`) |
| `check_stmt#1/#2`, `toplevel#2`, `elem_grow`, `check_args_sig#kwarg`, `list_extend`, `check_call#1`, `class#method_features`, `check_call#lowlevel`, `stmt_kind#nested_async`, `class#method_param_features` | 4–10 her biri | küçük kapılar: `__nox_*` ad kuralı / tuple açma (`tryFuseTupleUnpack`), `:=` çıkarımı (`infer_assign`), liste büyütme (`grow_stmt_gate`), `type` takma adları (`type_alias.zig`), kwarg çağrılar, async/dekoratörlü metot, `adopt`, iç içe `async def` |
| diğer | — | `class#unassigned_multi` (HashMap sırası), `class#explicit_base_call` (`Taban.metod(self)`→`super()`), `attr#bound_method`, `check_identifier#fromimport`, dekoratörlü iç `def`, `spawn#attribute`, `slice#bytes` (`type_expr_generic#prelude`/`check_call#prelude`/`toplevel#9` v2.2.100'de kapandı) |

**Önerilen sıra (kullanıcının sırası):** (1) **jenerik/protokol/prelude** (`type_expr_generic#prelude`, `check_call#prelude`, `class#generic`, `toplevel#9` protokol; monomorphization = `instantiateGeneric` ≈12383, `unifyTypeExpr` ≈11185, `substituteStmts` ≈11682: **AST kopyalamak yerine tip-parametre bağlamasıyla (binding haritası) denetlemek** düşünülebilir ama tanı metinleri Zig ile birebir kalmalı; bu bir TASARIM kararıdır → önce kullanıcıya/planı yazan oturuma sor) → (2) **imza özellikleri** (`register_func#1/#2`, kwarg çağrılar) → (3) **spawn analizleri** → (4) `class#consts/decorators/bases` → (5) intrinsic'ler (`nox.http.serve*`/`nox.thread.*`; stdlib tip adlarına `nox_http_HttpRequest` vb. bağlıdır, ham kipte yalnız elle tanımlı mangled sınıflarla çözülür) → (6) küçük kapılar → (7) **`ck-diff checkm`** (yükleyici + prelude birleşik modül; kalıtım+jenerik+prelude olmadan tümüyle `class#base`/prelude'a düşer; `__all__`/`requirePublic`/`validateModuleExports` burada) → (8) kapanış: tanı sırası/sayısı eşitliği, perf/bellek bütçesi (stdlib kontrolü ≤ 2× Zig, sızıntı testi), belge (3.13–3.17). 3.14 kararı kullanıcıya aittir.

## 6. DOĞRULAMA KONTROL LİSTESİ (bir dilimi "bitti" demeden önce)

- [ ] `ck_gen --<yeni kip>` 3000 program: fark yok, kabul oranı makul (temiz-program kipi ekle; yalnız hatalı programlar derin yolu test etmez).
- [ ] Kenar-durum korpusu: her mutant için ayırt edici dosya; yaşayan mutant 0 (eşdeğerler başlıkta belgeli).
- [ ] `ck_regress.sh` tüm kipler + depo: çıkış kodu 0.
- [ ] TEK `test-fast` (çıkış 0, `error: '` yok), `precheck` GREEN.
- [ ] spec + CHANGELOG + plan güncel; graf yenilendi; commit yalnızca kendi dosyaların; tag + push; CI geçmişi kontrol edildi.
- [ ] Hafıza/devir: bu dosyanın §4–§5'ini güncelle (durum + histogram).

## 7. İLGİLİ DOSYALAR

`selfhost/typecheck.nox.in` (kaynak), `selfhost/types.nox` (tip tablosu `TT`, `ty_*`), `selfhost/ast_schema.nox` + `scripts/gen_selfhost_ast.py` (AST düzeni; `{{O:Tür.alan}}`, `{{T:...}}`, `{{NONE}}`), `compiler/selfhost_ck_diff.zig` (`ck-diff` sürücüsü), `compiler/typecheck/checker.zig` (referans), `scripts/ck_gen.py`, `scripts/ck_regress.sh`, `scripts/ck_mutate.py`, `scripts/ck_mutants_{import,inherit,closure,tuple,generic_cls}.py`, `tests/fixtures/ck_edge/{import,inherit,closure,tuple,generic_cls}/`, `project/noxc-nightly-selfhost-plani-2026-11.md` (plan + canlı takip), spec §3.50x–§3.531, hafıza dosyası `~/.claude/projects/-Users-melihburakmemis-Documents-nox-lang/memory/project_selfhost_stage3_state_2026_11_25.md`.

## 8. KAPSAM DIŞI MÜDAHALELER (kullanıcı onayıyla — Claude bilgisine)

Normalde §0 yalnız `selfhost/typecheck.nox.in` ve `scripts/ck_*` dosyalarını kapsar; ancak Nightly CI loglarındaki iki frontend hatası ve `ck_regress.sh` boru sorunu üzerine **kullanıcıdan açık onay alınarak (`v2.2.98`)** aşağıdaki müdahaleler yapılmıştır (codegen, Host ABI ve runtime'a yine DOKUNULMAMIŞTIR):

1. **[scripts/frontend_diff.py](../../scripts/frontend_diff.py) — JSON lexer hata sınıflandırması (P0):**
   - `tokens --json [--trivia]` modunda dil hatası aldığında `cmdTokens` stderr'e yazmadan stdout'a `{"error":"<LexError>"...}` JSON'u yazıp `rc=1` döner; önceki `classify()` bunu `UNEXPECTED_EXIT` sayıyordu (Nightly CI'da 2445 dosyada 369 başarısızlık). `_is_json_lex_error()` eklendi (`OutOfMemory` hariç → `EXPECTED_LANGUAGE_ERROR`); `--selftest` yeni JSON vakalarıyla güncellendi ve `--component lexer --sub-args="--json --trivia" --fuzz 800 --seed 3` 2445 dosyada `FARK YOK` verdi.
2. **[compiler/parser/parser.zig](../../compiler/parser/parser.zig) & [selfhost/parser.nox.in](../../selfhost/parser.nox.in) (`selfhost/parser.nox` üretildi) — üç tırnaklı `bytes` literal CRLF normalleştirmesi (P1):**
   - `decodeBytes` / `decode_bytes` artık ham `\r\n` kaynak satır sonlarını (`decodeEscapes`/`normalizeCrlf` ile aynı şekilde) `\n` yapar; açık `\r\n` kaçışları (`b"a\r\nb"`) olduğu gibi korunur. `bytes_type.nox` ve `ok2.nox` üzerindeki `fmt(CRLF x) != fmt(x)` ihlalleri kapandı; `fmt_properties.py` hem `noxc` hem `noxc-nightly`'de `ok=1589, skip=56` (0 ihlal) ve `frontend_diff.py --component parser|fmt` eşit geçti; `parser.zig` altına yeni Zig birim testi eklendi.
3. **[scripts/ck_regress.sh](../../scripts/ck_regress.sh) — `| head -1` çıkış kodu kaybı düzeltmesi (P1):**
   - Her kip ve `repo` çalıştırması artık boru kullanmadan `check_out()` yardımcısından geçer; gerçek çıkış kodu korunur ve çok gruplu `xargs` dahil tüm çıktı satırlarının `^ck-diff: OK` ile başladığı doğrulanır.

### v2.2.103 — Kullanıcı onayıyla `runtime/stdlib_shims/h3_server.zig` düzeltmesi

4. **[runtime/stdlib_shims/h3_server.zig](../../runtime/stdlib_shims/h3_server.zig) — HTTP/3 zarif kapanış GOAWAY yarışı (CI Linux x86-64 ReleaseFast flaky testi):**
   - `allQuiet()` ve `loopOnce()` (`any_out`) içinde `cs.ours_buf` bekleyen çerçeve kontrolü eklendi; `run()` kapanışında `cs.close(.no_error)` (`CONNECTION_CLOSE`) öncesi sınırlı 50 ms'lik GOAWAY iletim penceresi (`std.Io.Clock.Timestamp`) eklendi. `zig build runtime-test -Druntime-test-filter=h3_server` Debug, ReleaseFast ve 10× ReleaseFast stres koşusunda 10/10 yeşil geçti.
