# Değişiklik Günlüğü (Changelog)

Bu proje [Semantic Versioning](https://semver.org/lang/tr/)yi izler —
semver politikası/stabilite garantisi İÇİN bkz. `VERSIONING.md`.
`v1.0.0`dan ÖNCEKİ değişiklikler (Faz Q'dan itibaren, temel
sağlamlaştırmadan paket ekosistemi olgunlaşmasına kadar TÜM üretim-
hazırlığı yol haritası — bkz. `docs/uretim-hazirlik-analizi.md`) TEK bir
`[1.0.0]` girişi altında toplanmıştır; öncesi için
`nox-teknik-spesifikasyon.md`nin tam geliştirme geçmişine bakın.

## [Yayımlanmamış]

### Değerlendirildi
- Gerçek M:N (çok çekirdekli) fiber zamanlayıcısı (Faz AA.1) — yalnızca
  araştırma, KOD DEĞİŞİKLİĞİ YOK. `nox-teknik-spesifikasyon.md` §3.46:
  mevcut M:1 modelden M:N'e geçişin somut mimari engelleri (zamanlayıcının
  süreç-geneli tekil oluşu, ARC refcount'unun bilinçli olarak atomik
  olmaması + QBE'ye inline edilmiş olması, havuzlanmış ayırıcının/döngü
  çözücünün senkronize olmayışı, birkaç stdlib globalinin M:1 garantisine
  açıkça dayanması) kod okunarak tespit edildi. Karar ERTELENDİ —
  kullanıcıyla bir kapsam-netleştirme görüşmesi olmadan hiçbir tasarım/
  implementasyon turuna girişilmeyecek.

### Eklendi
- `nox.thread` (Faz BB.1 — çalışma zamanı hazırlığı, henüz dil yüzeyi
  yok) — kullanıcının 1.0 için zorunlu kıldığı gerçek M:N (çok
  çekirdekli) fiber/yeşil iş parçacığı desteğinin ilk adımı. Beş
  "tehlikeli" global (`bridge.zig`nin `g_scheduler`, `random.zig`nin
  `g_prng`/`g_seeded`, `fs.zig`nin `g_last_ok`, `json.zig`nin
  `g_last_op_ok`/`g_make_json_value_fn`, `cycle_detector.zig`nin
  `g_trace_dispatch_fn`/`g_gc_free_dispatch_fn`) `threadlocal` yapıldı —
  `nox-teknik-spesifikasyon.md` §3.47. Gerçek `std.Thread.spawn`
  kullanan izolasyon testleri eklendi; `random.zig`nin testi, kasıtlı
  boz→kırmızı ritüelinde bir paylaşılan-PRNG veri yarışını gerçekten
  yakaladı.
- `nox.thread` Katman 1'in saf-Zig çekirdeği (Faz BB.2, henüz dil yüzeyi
  yok) — YENİ `runtime/async_rt/thread_bridge.zig`: `nox_thread_spawn`/
  `nox_thread_join`/`nox_thread_destroy`. Gerçek bir YENİ OS iş
  parçacığı başlatır, o iş parçacığında TAMAMEN BAĞIMSIZ bir
  `RuntimeState`/`Scheduler` kurar (`$main`in kendi önyükleme dizisinin
  bir kopyası) — çocuk KENDİ `spawn`/`await`/`Channel[T]`ini
  kullanabilir. `str` argüman/sonuçlar `http_client.zig`nin audit
  edilmiş "düz baytlarla kopyala, ARC'a hiç dokunma" protokolüyle
  taşınır. `nox-teknik-spesifikasyon.md` §3.48. Kasıtlı boz→kırmızı
  ritüelinde, str-hazırlık kopyalama adımının atlanması test sürecinin
  askıda kalmasına yol açtı — çapraz-iş-parçacığı bellek bozulmasının
  somut kanıtı.
- `nox.thread.start`/`ThreadHandle[T]`/`.join()` — checker desteği (Faz
  BB.3, henüz codegen yok). **İsim düzeltmesi:** plan `nox.thread.spawn`
  öngörüyordu, ama `spawn` zaten dilin kendi fiber-spawn anahtar kelimesi
  olduğundan (`kw_spawn`) bu parse hatasına yol açtı — gerçekten derlenip
  keşfedildi, isim `start`a değiştirildi. `entry`in (nox.http.serve'in
  tersine) `async def` olması zorunlu kılındı; argüman/dönüş tipi
  `isThreadTransferSafeType`den geçmeli (int/float/bool/str/None/ptr —
  Task/Channel/class/list/dict hariç, çünkü bunlar kendi zamanlayıcısına
  bağlıdır). `nox-teknik-spesifikasyon.md` §3.49. 7 yeni checker golden
  testi + kasıtlı boz→kırmızı ritüeli.
- `nox.thread.start`/`ThreadHandle[T]`/`.join()` — codegen + `stdlib/
  nox/thread.nox` (Faz BB.4). Gerçek `nox.thread.start(entry, arg)` artık
  yeni bir OS iş parçacığında GERÇEKTEN çalışır, `ThreadHandle.join()`
  fiber-farkında askıya alır (ebeveynin diğer fiber'ları çocuk çalışırken
  ilerlemeye devam eder), `int`/`str` payload'lar (arg VE dönüş) sızıntısız
  taşınır, join edilmeden scope'tan çıkan bir `ThreadHandle` sızmadan
  temizlenir (atomik referans sayımı). `nox-teknik-spesifikasyon.md`
  §3.50 — codegen'in checker'dan ayrı `resolveType`inin `ThreadHandle`i
  tanımaması (Unsupported hatası) ve `genThreadStartWrapper`nin `str`
  argümanı hedef fonksiyon çağrısından sonra serbest bırakmaması (gerçek
  bir sızıntı — uçtan uca golden testle yakalandı) dahil, gerçekten
  derlenip çalıştırılarak bulunan hatalar ve düzeltmeleri belgeler. 4 yeni
  uçtan uca codegen golden testi (int/str spawn+join, fiber-farkındalık
  sıralama kanıtı, detached/fire-and-forget sızıntı testi) + kasıtlı
  boz→kırmızı ritüeli.
- `ThreadChannel[T]` Katman 2'nin saf-Zig çekirdeği (Faz BB.5, henüz dil
  yüzeyi yok) — YENİ `runtime/async_rt/thread_channel.zig`:
  `nox_threadchannel_new`/`_send_val`/`_send_str`/`_recv_val`/`_recv_str`/
  `_destroy`. İş parçacıkları arasında gerçek, sürekli, çift-yönlü
  iletişim — simetrik çift-pipe geri basınç modeli (kullanıcının
  AskUserQuestion yanıtıyla seçilen tasarım), `nox_thread_join`ın aynı
  `Scheduler.suspendForIo`/`nonBlockingRead` ikilisini yeniden kullanır.
  `str` transferi `ThreadHandle` ile aynı "düz baytlarla kopyala"
  protokolünü izler. `nox-teknik-spesifikasyon.md` §3.51 — bu Zig
  sürümünde `std.Thread.Mutex`in artık olmadığının keşfini (CAS-tabanlı
  spin-kilide geçiş) belgeler. Kasıtlı boz→kırmızı ritüelinde, kilidin
  kaldırılması küçük hacimde gözlenmedi; hacim 2 milyon öğeye
  çıkarılınca kesin bir veri bozulması (`expected 44602, found 44601`)
  yakalandı.
- `ThreadChannel[T]` — checker + codegen (Faz BB.6), `nox.thread` faz
  serisinin (BB.1-BB.6) tamamlanışı. `ThreadChannel[T](capacity)` artık
  uçtan uca çalışıyor: iki gerçek OS iş parçacığı arasında sürekli,
  çift-yönlü iletişim, `int`/`str` payload'lar sızıntısız, kapasite
  geri basıncı (dual-pipe) tam boru hattından doğrulandı. `ThreadChannel`
  (Task/Channel/ThreadHandle'ın aksine) `*Scheduler` alanı taşımadığından
  `nox.thread.start`ın `arg`ı olarak geçirilebilir — bu, `isThreadTransferSafeType`e
  bilinçli bir istisna olarak eklendi. `nox-teknik-spesifikasyon.md`
  §3.52 — gerçekten çalıştırılıp bulunan iki hata belgelenir: (1)
  `registerFunc`in `isSpawnParamSafeType`i `ThreadChannel` parametreli
  `async def`leri reddediyordu (`isThreadTransferSafeType`den bağımsız,
  ayrı bir kapı); (2) `ThreadChannel` kurucu mantığının `checkExpr`in
  kendi switch'ine doğrudan eklenmesi, önceden var olan "çok uzun ifade
  çökmeden işlenir" fuzz regresyon testinde gerçek bir stack overflow'a
  yol açtı (Debug modunda bir fonksiyonun yığın çerçevesi tüm switch
  dallarının birleşimine göre boyutlanır) — ayrı bir `checkGenericConstruct`
  fonksiyonuna çıkarılarak düzeltildi. 3 yeni uçtan uca codegen golden
  testi + kasıtlı boz→kırmızı ritüeli (yanlış runtime fonksiyonuna
  yönlendirme, gerçek bir tip-karışıklığı çökmesi olarak yakalandı).
- Profesyonel kurulum: GitHub Releases + `install.sh` + `noxc --version`
  (Faz CC.1) — `curl -fsSL .../install.sh | sh` artık macOS (Apple
  Silicon) ve Linux (x86-64/aarch64) için önceden derlenmiş bir paket
  kurar (`noxc`/`noxlsp` + çalışma zamanı + stdlib + gömülü `qbe` —
  yalnızca sistem `cc`si dışarıda bırakılır, çünkü `noxc` gerçek bir
  tek statik ikili değildir). YENİ `.github/workflows/release.yml`,
  `v*` etiketlerinde 3 platform için (`ci.yml` ile aynı matris) tarball
  üretip yayımlar. YENİ `noxc --version`/`version`/`-V` — sürüm metni
  `build.zig.zon`den tek doğruluk kaynağı olarak türetilir. `nox-teknik-
  spesifikasyon.md` §3.53. Kullanıcı onayıyla (AskUserQuestion) kapsam
  netleştirildi: Homebrew tap yerine Releases+install.sh, ve qbe
  tarball'a gömülür. 1 yeni CLI golden testi + kasıtlı boz→kırmızı
  ritüeli.

### Düzeltildi
- CI/Release: `mlugg/setup-zig@v1` eylemi, `v1.0.0` etiketinin İLK
  denemesinde `ci.yml`/`release.yml`nin İKİSİNDE de Zig kurulum adımını
  ~1 dakikada çökertti. Kök neden ağ kesintisi DEĞİLDİ — o eylemin
  "official" yedek URL'si etiketli sürümler İÇİN yanlış bir yol
  (`ziglang.org/builds/...`, SADECE dev-snapshot'lar İÇİN doğru)
  KULLANIYORDU. Düzeltme: her iki workflow'da da Zig, `qbe`nin ZATEN
  kullandığı AYNI "doğrudan `curl`+`tar`" deseniyle DOĞRU
  (`ziglang.org/download/<sürüm>/...`) URL'den kuruluyor artık.
  `nox-teknik-spesifikasyon.md` §3.53 (addendum).
- `install.sh`: `resolve_version`in `curl | grep | sed` zinciri, `set -e`/
  `pipefail` aktifken `grep` hiçbir şey bulamadığında (henüz Release
  yokken ya da API'ye erişilemediğinde) betiği yardımcı `die` mesajına
  hiç ulaşmadan sessizce sonlandırıyordu (kullanıcı raporu: "otomatik
  kurulum scripti de çalışmıyor"). Düzeltme: yanıt önce ayrı bir
  değişkene (`|| true` ile) alınıp sonra ayrıştırılıyor, böylece boş
  sonuç her zaman açık hata mesajına ulaşıyor. Gerçek bir uçtan uca
  doğrulamayla (yayımlanan v1.0.0 varlığı indirilip açılıp `noxc
  --version` + gerçek bir .nox derlemesi çalıştırılarak) paketin tam
  işlevsel olduğu kanıtlandı.
- CI: gerçek, %100 yerel olarak tekrarlanabilir bir soğuk-önbellek yarış
  durumu (`rm -rf .zig-cache zig-out && zig build test` tek komutu,
  `noxc`/`noxlsp`yi alt süreç olarak çağıran test dosyalarını —
  `lsp_test.zig` dahil, `fetch`/`update`e özgü değil — `processSpawnPosix`
  ile çökertiyordu; kullanıcının gerçek CI çalıştırmasında gözlemlediği
  "test buildler takılıyor" raporuyla keşfedildi). Düzeltme: `ci.yml`de
  her mod için önce salt `zig build` (tüm install_* adımlarını bitirir),
  sonra ayrı bir komut olarak `zig build test`. `nox-teknik-spesifikasyon.md`
  §3.55.

### Eklendi
- `noxc fetch`/`noxc update` — gerçek implementasyon (Faz CC.2.1, Faz
  O §P.5'ten beri rezerve bırakılmıştı). `fetch`, proje kökündeki
  `nox.json`'daki `requires[]`i (bir .nox dosyası derlemeden) önbelleğe
  doldurur; `update`, her bağımlılığı ref'ten koşulsuz yeniden çözüp
  `nox.lock`taki kilitli SHA'ları günceller. `nox-teknik-spesifikasyon.md`
  §3.54 — gerçekten test edilip bulunan iki hata (kendi yazdığım yeni
  testlerde, ürün kodunda değil) belgelenir: `std.Io.Dir.openAbsolute`
  bu Zig sürümünde yok; `.cwd` kullanan bir alt süreç çağrısına göreli
  bir argv[0] geçmek, çalıştırılabilir dosyanın YENİ çalışma dizinine
  göre yanlış çözülmesine yol açar (genel bir kural olarak belgelendi).
  2 yeni uçtan uca CLI testi + kasıtlı boz→kırmızı ritüeli.
- `noxc init [proje-adi]`/`noxc check <dosya.nox>` (Faz CC.2.2). `init`,
  Cargo/Go tarzı proje iskeleti oluşturur (`nox.json`+`main.nox`+
  `.gitignore`; argümansız CWD'de, isimli yeni bir alt dizinde — var olan
  bir projenin üzerine asla yazmaz). `check`, codegen/`qbe`/`cc`
  tetiklemeden sadece lex→parse→import çözümü→tip denetimi çalıştırır —
  editör entegrasyonu/hızlı geri bildirim için. `nox-teknik-
  spesifikasyon.md` §3.56. 3 yeni uçtan uca CLI testi (üretilen projenin
  gerçekten derlenip çalıştığı dahil) + kasıtlı boz→kırmızı ritüeli.

### Düzeltildi
- Linux/x86-64 CI'de gerçekten gözlemlenen, önceden var olan üç hata
  (`noxc fetch`/`update`/`init`/`check` ile ilgisiz — soğuk-önbellek
  yarış düzeltmesi CI'yi bu kadar ileri götürene kadar hiç görünür
  değillerdi): (1) `runtime/stdlib_shims/http_client.zig`'in
  `workerThreadFn`'i, tamamlanma sinyalini yazdıktan SONRA `ctx.write_fd`yi
  `defer` bloğunda okumaya devam ediyordu — sinyal yazılır yazılmaz
  çağıran `ctx`yi serbest bırakabildiğinden gerçek bir kullanım-sonrası-
  serbest yarışıydı (bir bağlantı testinde segfault, iki `nox.http.get`
  altın testinde `ProgramFailed` olarak gözlemlendi — aynı kök neden).
  `write_fd` artık fonksiyon girişinde yerel bir değişkene kopyalanıyor.
  (2) `tests/compat/zig_ext/util.o`, `zig build-obj` ile `-fPIC` olmadan
  derleniyordu — dağıtımın PIE-varsayılan `cc`sine bağlanırken link
  hatası veriyordu; `-fPIC` eklendi. `nox-teknik-spesifikasyon.md` §3.57
  — bu yarış yerel olarak (macOS/aarch64'te) hiç tekrarlanamadığından
  doğrulama kod incelemesi + gerçek Linux/x86-64 CI'de yeniden
  çalıştırmaya dayanıyor. (3) Yukarıdaki iki düzeltme sonrası GERÇEK
  CI'de ortaya çıkan dördüncü, ayrı bir zamanlama hatası: fiber-sırası
  kanıtlayan bir `nox.http.get` testi, yerel test sunucusu yanıtı
  gecikmesiz yazdığından bazen Linux/x86-64'te hiç askıya alınmadan tek
  seferde tamamlanıyordu. `http_server.zig`'in "yavaş istemci" testinin
  (150ms gecikme) aynı deseni sunucu tarafına da uygulandı
  (`testServeOnceDelayed`).

### Eklendi
- Renkli/daha okunabilir `noxc` çıktısı (Faz CC.2.3). Checker tip
  hataları, `qbe`/`cc` başarısızlıkları ve tüm "bulunamadı"/"okunamadi"
  hata yolları artık kırmızı; `derlendi`/`olusturuldu`/"tip hatasi yok"
  yeşil. Gerçek bir terminale bağlı değilken (dosyaya/pipe'a
  yönlendirilmiş) veya `NO_COLOR` ayarlıyken otomatik devre dışı kalır
  — script/CI tüketicileri her zaman ham metin görür. `nox-teknik-
  spesifikasyon.md` §3.58. `script(1)` ile gerçek bir sanal TTY üzerinde
  manuel doğrulama + boru hattında (TTY olmayan) hiç ANSI kaçış dizisi
  sızmadığını doğrulayan yeni bir otomatik test + kasıtlı boz→kırmızı
  ritüeli.

### Değiştirildi
- Metod çağrıları için istisna-kontrolü eleme (Faz M.8, yeniden ele
  alındı — kullanıcının "sonraki aşama geliştirmeler" listesinin #2
  maddesi, "Dil Performans artışı"). Daha önce (dil stabilizasyonu fazı)
  "ölçülmeden kanıtlanmadı" gerekçesiyle ertelenmişti; izole bir mikro-
  benchmarkla ~%41'lik gerçek bir kazanç ölçülünce yeniden ele alındı.
  `computeMustNotRaise` artık TÜM sınıf metodlarını (yalnızca `__init__`
  değil) analiz ediyor; basit `obj.method()` çağrıları (alıcının sınıfı
  `self.`/bir yerel değişken üzerinden statik olarak bilinen durumlarda)
  artık `nox_exception_pending` kontrolünü, o metodun transitif olarak
  ASLA raise etmediği kanıtlanabildiğinde atlayabiliyor — belirsiz her
  durumda (zincirleme çağrı, yeniden bildirilmiş/"zehirlenmiş" bir
  değişken, vb.) kontrol MUHAFAZAKÂR olarak korunuyor, istisna hiçbir
  zaman sessizce yutulmuyor. `nox-teknik-spesifikasyon.md` §3.59. Aynı
  turda, araştırma sırasında bulunan önceden var olan gerçek bir hata da
  düzeltildi: `collectRaiseInfoExpr`, bilinmeyen bir çağrı hedefini (ör.
  iç içe bir closure) sessizce "güvenli" sayıyordu — artık koşulsuz
  güvensiz sayılıyor. 6 yeni golden test (3 katmanlı metod-zinciri raise
  yayılımı hem `self.` hem yerel değişken üzerinden, yeniden bildirme/
  zehirlenme güvenlik testi, pozitif eleme testi + IR-metni doğrulaması)
  + `benchmarks/method_call_elision.nox` (300M çağrı, ~480ms → ~270ms,
  ~%44 hızlanma) + kasıtlı boz→kırmızı ritüeli.

### Eklendi
- Çok çekirdekli `nox.http.serve` (Faz DD.1 — kullanıcının "sonraki
  aşama geliştirmeler" listesinin #3 maddesi, "HTTP kütüphane async m:n
  entegrasyonu ve performans artışı"). Gerçek bir *paylaşılan* M:N
  zamanlayıcı YERİNE (Faz AA.1'de somut mimari engeller nedeniyle
  ERTELENMİŞ, ERTELENMİŞ kalıyor), `nox.thread`in (Faz BB.1-BB.6) ZATEN
  sağladığı "N bağımsız M:1 dünyası" modeli üzerine inşa edildi: bir
  dinleme soketinin ham `fd`si (`nox.thread`in ZATEN desteklediği bir
  aktarım tipi olan düz bir `int`) N bağımsız iş parçacığına dağıtılıp
  her biri KENDİ kqueue/epoll'ıyla AYNI soketi izleyebiliyor — hiçbir
  yeni senkronizasyon ilkeli gerekmedi. Üç yeni parça: `nox.http.
  listen(port) -> int` (birleştirilebilir ilkel, mevcut FFI mekanizmasıyla
  sıfır yeni derleyici kodu), `nox.http.serve_fd(fd, handle[,
  max_connections])` (`nox.http.serve`nin kardeşi, `nox.thread.start`ile
  birleştirilebilir), `nox.http.serve_multicore(port, handle,
  num_threads[, max_connections])` (tek satırlık kolaylık sarmalayıcısı —
  thread-spawn döngüsünü derleyici üretir). `nox-teknik-spesifikasyon.md`
  §3.60. 5 yeni test (2 Zig birim testi — paylaşılan fd'de gerçek çift
  iş parçacığı kabulü + `owns_fd`in deterministik doğrulaması — + 3 uçtan
  uca golden test) + kasıtlı boz→kırmızı ritüeli (`owns_fd`i geçici
  olarak bozmak yalnızca bir birim testini KIRMIZI yapmakla kalmadı,
  gerçek bir çalışma-zamanı tıkanmasına — paylaşılan fd'nin erken
  kapanıp diğer iş parçacığının `accept()`ini sonsuza dek askıda
  bırakması — da yol açtı, düzeltmenin gerekliliğinin somut kanıtı).
- Stdlib geliştirme ve performans (Faz EE.1 — kullanıcının "sonraki aşama
  geliştirmeler" listesinin #4 maddesi). Beş kalem: (1) `nox.strings.
  byte_at(s, idx) -> int` — `s[i]`nin (her çağrıda tahsis eden) alloc-sız
  eşdeğeri; `starts_with`/`ends_with`/`index_of`/`contains` artık bunu
  kullanıyor, ÖNCEDEN hiç bayraklanmamış bir O(n·m) heap-tahsis darboğazını
  giderdi. (2) `nox.strings.join` artık Zig'de tek-geçiş O(n) (ÖNCEDEN saf
  Nox'ta `+`-birleştirme döngüsüyle O(n²)idi — `split`/`trim`/vb.'nin
  ZATEN izlediği "Zig'e sar" örüntüsüne UYMUYORDU). (3) YENİ `list[T].
  sort()` — `int`/`float`/`str` elemanlar, `.append`den FARKLI olarak
  alıcı çıplak bir isimle SINIRLI DEĞİL. (4) YENİ `nox.path` modülü —
  `join`/`basename`/`dirname`/`extension`/`is_absolute`, saf string
  manipülasyonu, I/O yok. (5) `nox.fs.exists`/`is_file`/`is_dir` — var
  OLMAMA durumunda `read_to_string`in AKSİNE ASLA `raise` etmez.
  `nox-teknik-spesifikasyon.md` §3.61. `strings_perf_bench.nox`
  ölçümü: 6040ms → 200ms (**~30x hızlanma**, çıktı değerleri birebir
  aynı). Yeni Zig birim testleri + 3 yeni uçtan uca golden test + 2
  kalem için kasıtlı boz→kırmızı ritüeli.

### Düzeltildi
- Sürüm tutarsızlığı (Faz FF.1 — harici bir teknik incelemede bulunan
  gerçek bir bulgu). `build.zig.zon` (dolayısıyla `noxc --version`)
  `1.0.0` DÖNDÜRÜYORDU, ama main dalı ZATEN `v1.0.0`dan SONRAKİ (Faz
  M.8/DD.1/EE.1) özellikleri İÇERİYORDU — kullanıcı `noxc --version`a
  GÜVENİP yanlış bir imaj edinebilirdi. `1.1.0-dev`e (Zig'in KENDİ
  `-dev` ön-sürüm sözleşmesiyle AYNI) güncellendi. `nox-teknik-
  spesifikasyon.md`nin başlığı da ("Versiyon: 0.1 (Taslak)", "Durum:
  Mimari tasarım aşaması" — GERÇEKTEN `v1.0.0` yayımlandıktan SONRA bile
  DEĞİŞTİRİLMEMİŞTİ) VE `README.md`nin sürüm rozeti güncellendi.
  Derleyici kaynak dosyalarının modül-üstü yorumlarındaki ("Nox v0.1
  lexer" gibi) ARTIK ANLAMSIZ kalmış `v0.1` etiketleri (9 dosya)
  KALDIRILDI.

## [1.0.0]

### Eklendi
- İlk git commit'i — proje artık gerçek sürüm kontrolü altında (Faz Q.1).
- `CHANGELOG.md` (bu dosya).
- GitHub Actions CI (Faz Q.2) — her push/PR'da `zig build test` (Debug +
  ReleaseFast).
- Linux epoll I/O reaktör backend'i (Faz R.1) — `runtime/async_rt`in
  async G/Ç'si artık macOS (kqueue) yanında Linux'u (epoll) da destekliyor.
  Gerçek (emülasyonsuz) bir Docker aarch64 Linux konteynerinde doğrulandı.
- x86-64 fiber bağlam değişimi desteği (Faz R.2) — `runtime/async_rt`
  artık aarch64 yanında x86-64'ü (SysV ABI) de destekliyor. Docker'daki bir
  x86-64 Linux konteynerinde (Rosetta ikili çevirisi üzerinden — gerçek
  donanım kadar kesin DEĞİL, dürüstçe belirtilir) doğrulandı.
- CI matrisi genişletildi (Faz R.3): macOS/aarch64 + Linux/x86-64
  (`ubuntu-latest`, R.2'nin x86-64 kodunu GERÇEK donanımda doğrular) +
  Linux/aarch64 (`ubuntu-24.04-arm`) — Linux'ta `qbe` kaynaktan derlenir.
- `build.zig`e Zig araç zinciri sürüm denetimi eklendi (Faz R.4) — çalışan
  derleyici sürümü CI'nin pinlediği sürümden (`0.16.0`) farklıysa net bir
  uyarı basılır (sert bir hata değil — yama sürümleri genelde uyumludur).
- **Katman 3 (döngü çözücü) uygulandı (Faz S.3)** — `runtime/alloc/
  cycle_detector.zig`, Bacon & Rajan'ın senkron trial-deletion algoritmasıyla
  (Nim'in ORC modelinin/CPython'ın döngü GC'sinin akrabası). Bunun İÇİN
  ÖNCE sınıfların KENDİ KENDİSİNE (`self.next = self`) atanabilmesi
  gerekiyordu (`codegen.zig`nin `inferFieldType`i genişletildi) — bu, GERÇEK
  bir A↔B referans döngüsü kurmanın (sonradan `a.next = b; b.next = a;`
  ile) tek bootstrap yoludur (`None`/opsiyonel tip HENÜZ yok). v1 kapsamı
  yalnızca SINIF örnekleri (`list[T]`/`dict[K,V]` elemanları dahil değil).
  Tetikleme: tahsis-baskısı eşiği (varsayılan 700) + program çıkışında son
  bir tarama.
- Tip denetleyici hataları artık kaynak SATIR numarası taşıyor (Faz T.1) —
  `HATA <kod>: satır N: <mesaj>` biçimi. Kapsam bilinçli olarak DEYİM
  (statement) granülerliğinde (ifade/`Expr` düzeyinde değil — bu, `checker.
  zig`/`codegen.zig` genelinde `ast.Expr`i eşleştiren düzinelerce yere HİÇ
  dokunmadan, yalnızca `ast.Stmt`i saran bir `{ kind, line }` yapısıyla
  güvenle uygulanabildi). 22 mevcut typecheck golden testinin `.expected`
  dosyası bu yeni önekle güncellendi.
- Tip denetleyici artık TEK çalıştırmada BİRDEN ÇOK hata raporlayabiliyor
  (Faz T.2) — kurtarma `checkModule`nin üst-düzey (fonksiyon/sınıf/gevşek
  deyim) döngüsünde VE `checkClassBody`nin metod döngüsünde, HER bağımsız
  birimin sınırında yapılır (AYNI birim İÇİNDEKİ İKİNCİ bir hata HÂLÂ
  raporlanmaz — bilinçli bir sınırlama). `CheckOutcome.err`e yeni bir `all:
  []const Diagnostic` alanı eklendi; `main.zig` VE doğrudan `Checker`
  kullanan 5 test dosyası TÜM kurtarılmış tanılamaları kontrol edip
  yazdıracak şekilde güncellendi (aksi halde bir hata sessizce codegen'e
  sızardı).
- `noxc build/run/test`e `-g` bayrağı eklendi (Faz T.3) — QBE IL'in
  belgelenmemiş `dbgfile`/`dbgloc` yönergeleri (assembler'ın `.file`/`.loc`
  sözde-yönergelerine BİREBİR eşlenir) üzerinden GERÇEK DWARF satır tablosu
  üretir. Linux'ta (GERÇEK bir Docker aarch64 konteynerinde `noxc build -g`
  ile uçtan uca doğrulandı) `gdb`de dosya:satır kesme noktaları/adımlama
  TAM ÇALIŞIYOR. Bilinen v1 sınırlamaları (dürüstçe belgelendi, bkz. spec
  §3.17): yalnızca SATIR bilgisi (değişken inceleme YOK — QBE'nin KENDİ
  sınırı), stdlib'e (import edilen modüllere) adım atıldığında dosya
  yanlış atfedilebilir (satır numarası doğru, dosya yanlış), macOS'ta
  BAĞLI (linked) ikili DWARF taşımaz (Apple'ın STABS/debug-map mekanizması
  ayrı bir mühendislik sorunu — ara `.o` GERÇEK DWARF taşır, doğrulandı).
- Lexer'a yorum/boş-satır konumu yakalama eklendi (Faz T.4a) — YENİ, opsiyonel
  `lexer.tokenizeWithTrivia` (mevcut `tokenize` DEĞİŞMEDEN, ~50+ çağrı sitesi
  ETKİLENMEDEN) `Trivia` (yorum METNİ + satır + trailing/standalone bayrağı,
  ya da boş-satır işareti) akışı üretir — GELECEKTEKİ gerçek `noxc fmt`
  formatlayıcısının (T.4b) yorumları SESSİZCE SİLMEDEN yeniden yerleştirebilmesi
  İÇİN ön koşul (kullanıcıyla netleşti: yorum-koruma OLMADAN bir formatlayıcı
  gerçek kullanıcı kodunda veri kaybına yol açardı).
- `noxc fmt` gerçek bir formatlayıcıya kavuştu (Faz T.4b) — YENİ `compiler/
  fmt/formatter.zig`, AST'yi 4-boşluk girinti + precedence-farkındalıklı
  (yalnızca GEREKLİ) parens ile kanonik Nox söz dizimine yeniden yazar,
  T.4a'nın yakaladığı yorumları/boş satırları en yakın deyime göre yeniden
  yerleştirir. Dosyayı YERİNDE (in-place) yeniden yazar, İDEMPOTENTTİR
  (ikinci formatlama dosyayı değiştirmez), tip denetimi ÇALIŞTIRMAZ
  (`gofmt`ın davranışıyla tutarlı — sözdizimsel olarak geçerli ama tipçe
  hatalı kod da formatlanabilir).
- `list[T]`e `.append()` (dinamik büyüme) VE indeksli atama (`xs[i] = v`)
  eklendi (Faz U.1) — kullanıcıyla netleşen karar: GERÇEK paylaşım semantiği
  (kapasite YETERLİYSE `.append()` YERİNDE yazar, TÜM alias'lar GÖRÜR;
  kapasite DOLUNCA YENİ, 2× büyüklükte bir blok ayrılır — Python listeleri
  gibi). Liste başlığı `{len, elemanlar...}`den `{len, cap, elemanlar...}`e
  genişletildi (`nox.json`/`nox.strings.split`in Zig-taraflı el-yapımı liste
  inşası DAHİL, TÜM liste kod yolları güncellendi). Bilinen v1 sınırlamaları:
  büyüme ANINDA var olan bir alias yeni elemanı görmez (TEMİZ bir
  `IndexError`e yol açar, bellek bozulması DEĞİL); alıcı bir parametre
  OLAMAZ; arena listeleri büyütülemez; boş liste literali (`[]`) hâlâ
  desteklenmiyor.
- Proje-içi çoklu-dosya birinci-taraf import desteği eklendi (Faz U.2) —
  `nox.json` içeren bir projede artık `import helpers` (doğrudan) ve
  `import utils.mathy` (iç içe yol, `<proje_kökü>/utils/mathy.nox`e
  çözümlenir) gibi hiçbir `requires[]` kaydı gerektirmeyen proje-yerel
  importlar çalışıyor. Çözümleme önceliği: `nox.*` (stdlib) → `requires[]`
  alias'ı (üçüncü-taraf) → proje-köküne göreli dosya (YENİ) → bilinmeyen
  alias hatası. `nox.json` OLMADAN (manifestsiz) tek-dosya kullanım eski
  ("yalnızca stdlib") davranışını aynen koruyor — birinci-taraf importlar
  bilinçli olarak bir manifest gerektiriyor (Go'nun `go.mod`u/Cargo'nun
  `Cargo.toml`ı ile tutarlı).
- `import X as Y` ve `from X import Y [as Z]` sözdizimi eklendi (Faz U.3) —
  `import nox.http as h` ile `h.get(...)` `nox.http.get(...)`e eşdeğer olur;
  `from nox.http import get` ile `get(...)` modül niteliği olmadan doğrudan
  çağrılabilir (`from nox.http import get as g` ile yerel takma ad da
  verilebilir). Bir `from`la içe aktarılan isim kullanıcının kendi yerel bir
  tanımıyla çakışırsa yerel tanım her zaman önceliklidir. Bilinen v1
  sınırlaması: `nox.http.serve` özel yerleşiği `import ... as`la tam
  desteklenir ama `from nox.http import serve` ile çıplak çağrı henüz özel
  olarak tanınmıyor (güvenli bir "tanımsız değişken" hatasına düşer, sessiz
  yanlış davranış değil).
- Birinci-sınıf fonksiyon değerleri (closure) için tip sistemi temeli
  eklendi (Faz U.4.1) — yeni `(int, int) -> int` tip ifadesi sözdizimi ve
  `Type.func` semantik tipi. Bu ilk alt-faz yalnızca tip sistemini kapsıyor;
  çalışma zamanı temsili/dolaylı çağrı desteği sonraki alt-fazlarda (U.4.2-
  U.4.4) geliyor. Kullanıcıyla netleşen karar: tam closure semantiği (dış
  kapsam değişkenlerini yakalama), yalnızca çıplak fonksiyon referansları
  değil.
- İç içe `def` + serbest değişken (capture) analizi eklendi (Faz U.4.2) —
  bir fonksiyon gövdesi içinde artık (generic/async olmayan) başka bir
  `def` tanımlanabilir; dış kapsamdaki değişkenlere yapılan referanslar
  otomatik olarak "yakalanır" (capture), iç fonksiyonun adı dış kapsamda
  `.func` tipinde bir yerel değişkene bağlanır. Yakalama yalnızca okunabilir
  (dış değişkene sonradan atama, closure'dan görünmez) — dış bir değişkene
  ATANMAYA çalışmak açık bir hatayla reddedilir. Çalışma zamanı temsili/
  dolaylı çağrı henüz yok (U.4.3/U.4.4'te geliyor) — şimdilik `noxc build`
  bu tür bir programı derlerken checker aşamasını geçer ama codegen
  aşamasında güvenli bir "henüz desteklenmiyor" hatasıyla durur.
- Closure çalışma zamanı temsili + QBE codegen eklendi (Faz U.4.3) — iç içe
  `def`ler artık gerçekten çalışıyor: yeni `HeapKind.closure` (sınıf
  örnekleriyle aynı ARC havuzu, `{fn_ptr, yakalanan değerler...}` bellek
  düzeni), `genNestedFuncDef`/`genClosureFunc`/`genClosureRelease`. Bir
  closure oluşturulduğunda yakalanan heap-yönetimli değerler retain edilir,
  closure serbest bırakıldığında (refcount sıfıra inince) release edilir —
  döngü içinde tekrar tekrar oluşturma/serbest bırakma sızıntısız. Bilinçli
  v1 kesintileri: Katman 3 döngü çözücüsüyle entegrasyon yok, closure'lar
  için `==`/`!=` yok, closure'ı DEĞER olarak dolaylı çağırma/parametre-dönüş
  olarak geçirme henüz yok (U.4.4'e ertelendi — bir closure'ı çıplak bir
  func-tipli değişkene atamak/döndürmek şimdilik güvenli bir "henüz
  desteklenmiyor" hatasına düşer, çökme değil).
- Closure değerleri üzerinden dolaylı çağrı + parametre/dönüş olarak
  geçirme eklendi (Faz U.4.4) — **Faz U.4 (birinci-sınıf fonksiyon
  değerleri/closure) TAMAMEN BİTTİ.** Bir closure artık func-tipli bir
  değişkene/parametreye atanabilir ve o değişken/parametre üzerinden
  dolaylı olarak çağrılabilir (`f(x)`) — hangi somut closure çağrıldığı
  derleme zamanında bilinmese de argüman/dönüş tipleri statik imzadan
  (`(int) -> int` gibi) doğru şekilde çözülür. Closure bellek düzenine
  ikinci bir işaretçi (`release_fn_ptr`, offset 8) eklendi — release artık
  tamamen dolaylı/polimorfik, U.4.3'ün `class_name` bilinmediğinde
  "henüz desteklenmiyor" hatasına düşen geçici kısıtlaması tamamen
  kaldırıldı. Bilinçli v1 sınırı: yalnızca bir iç içe `def`den inşa edilen
  closure'lar func-tipli olabilir — üst-düzey bir `def`e çıplak referans
  (`f: (int) -> int = add`) henüz desteklenmiyor.
- `with EXPR as NAME:` / `with EXPR:` (bağlam yöneticisi / context manager)
  eklendi (Faz U.5) — `EXPR`, bir `__enter__(self) -> T` / `__exit__(self)
  -> None` metod çiftine sahip bir sınıf örneği olmalıdır; `__exit__` HER
  ZAMAN çalışır (normal tamamlanma, `return`, yakalanmamış istisna DAHİL).
  Bilinçli v1 sınırları: `__enter__`/`__exit__` argüman almaz, `__exit__`
  bir istisnayı bastıramaz, birden çok bağlam yöneticisi tek bir `with`de
  virgülle birleştirilemez (her biri ayrı bir `with` olarak iç içe
  yazılmalıdır).
- `nox.log` modülü eklendi (Faz V.1) — basit, seviyeli konsol günlükleme
  (`debug`/`info`/`warn`/`error` + `format`). Tamamen saf Nox
  (`nox.time.now_ms` + `str()` + `print()` üzerine), hiç Zig/`extern def`
  gerekmedi. Bilinçli v1 sınırı: çalışma zamanında yapılandırılabilir bir
  minimum-seviye filtresi yok (Nox'ta paylaşılan mutable modül-düzeyi
  durum yok), çıktı her zaman stdout'a gider.
- `nox.random` modülü eklendi (Faz V.2) — basit PRNG (`seed`/`randint`/
  `random`, Xoshiro256 — kriptografik güvenlik iddiası yok). Diğer stdlib
  modüllerinden farklı olarak gerçek bir Zig kabuğu gerektirdi
  (`runtime/stdlib_shims/random.zig`); PRNG durumu, `nox.os`nin argc/argv'si
  ile aynı "süreç ömrü boyunca yaşayan statik değişken" deseninde tutulur.
  `seed` hiç çağrılmadıysa ilk kullanımda otomatik tohumlanır.
- `nox.crypto` modülü eklendi (Faz V.3) — `sha256(data: str) -> str` (64
  karakterlik küçük harf hex özet). Zig'in kendi `std.crypto.hash.sha2.
  Sha256`si sarılır (sıfırdan bir hash algoritması yazılmadı). FIPS 180-4
  test vektörleriyle doğrulandı.
- `nox.time` genişletildi (Faz V.4) — `DateTime` sınıfı (yıl/ay/gün/saat/
  dakika/saniye) + `from_epoch_ms(ms) -> DateTime` / `now() -> DateTime`.
  Zig'in kendi `std.time.epoch`u sarılır (sıfırdan takvim aritmetiği
  yazılmadı). Bilinçli v1 sınırı: yalnızca ayrıştırma (epoch-ms →
  DateTime), ters yön yok; yalnızca 1970 ve sonrası.
- `nox.test` genişletildi (Faz V.5) — yeni `TestSuite` sınıfı
  (`check_eq_int`/`check_eq_str`/`check_eq_float`/`check_true`, mevcut
  `raise`-tabanlı `assert_*`in aksine hiçbir zaman raise etmez, sonucu
  biriktirir) + `write_junit_xml`. `check_*`in raise etmemesi, kullanıcının
  kendi `setup()`/`teardown()`unu her kontrolün etrafına koyabilmesini
  sağlar — tek bir başarısız kontrol artık teardown'ı engellemez.
- `nox.regex` modülü eklendi (Faz V.6) — `is_match(pattern, text) -> bool`
  / `find(pattern, text) -> int`. Zig'de std'de regex bulunmadığından,
  Brian Kernighan'ın kamuya mal olmuş klasik minimal backtracking regex
  algoritmasının genişletilmiş bir versiyonu yazıldı. Desteklenenler:
  literal karakterler, `.`, `*`/`+`/`?`, `^`/`$`, `[abc]`/`[a-z]`/`[^abc]`.
  Bilinçli v1 kapsam dışı: gruplama, alternasyon, geri-referanslar,
  `{m,n}`, escape dizileri (`\d` vb.).
- Tree-sitter grameri eklendi (Faz W.1, `editors/tree-sitter-nox/`) — dilin
  neredeyse tamamını (girinti-duyarlı bloklar, tüm kontrol akışı, `with`/
  `lowlevel`, generics, fonksiyon tipleri, `async`/`await`/`spawn`,
  `extern def ... with_rt`, `import`/`from...import`, `list`/`dict`
  literalleri) kapsar. Girinti (NEWLINE/INDENT/DEDENT) üretimi, tree-sitter-
  python'ın kanıtlanmış algoritmasından uyarlanmış bir harici C tarayıcısıyla
  (`src/scanner.c`) yapılır. `queries/highlights.scm` ile sözdizimi
  vurgulama sorgusu dahil. Repodaki 201 gerçek `.nox` dosyasının TAMAMI
  (stdlib + benchmarks + tests/golden) sıfır ayrıştırma hatasıyla doğrulandı
  — derleyicinin kendi golden-test süitinden bağımsız bir ikinci doğrulama
  katmanı. Bu, ana derleyici/runtime'a hiçbir değişiklik getirmez (ayrı bir
  JS/C alt-projedir, `zig build test`i etkilemez).
- `noxlsp` eklendi (Faz W.2, `compiler/lsp_main.zig`, yeni `zig build`
  hedefi) — Nox için minimal bir Language Server Protocol sunucusu.
  `textDocument/didOpen`/`didChange`/`didClose` üzerinde derleyicinin
  gerçek lexer→parser→checker boru hattını doğrudan kütüphane olarak
  çağırıp sonucu `textDocument/publishDiagnostics`e çevirir (`hover`/
  `completion`/`definition` gibi diğer yetenekler bilinçli olarak v1
  kapsamı dışı). `tests/cli/lsp_test.zig` ile uçtan uca (spawn edilen
  gerçek `noxlsp` alt sürecine stdio üzerinden LSP çerçeveleriyle
  konuşularak) doğrulandı.
- DAP/debugger entegrasyonu eklendi (Faz W.3, `editors/vscode-nox/`) —
  yeni bir DAP sunucusu yazılmadı: `noxc build -g`nin (Faz T.3) ürettiği
  gerçek DWARF hat tablosu, var olan `lldb-dap`/CodeLLDB gibi standart
  debug adaptörleriyle doğrudan uyumlu. VS Code için `launch.json`/
  `tasks.json` şablonları + kurulum ve bilinen sınırlamaları (yalnızca
  satır-düzeyi, macOS'ta bağlı ikili DWARF taşımıyor) belgeleyen bir
  README eklendi. Bu makinede kurulu `lldb-dap`e ham DAP protokolüyle
  doğrudan konuşularak (initialize/launch/setBreakpoints/
  configurationDone) doğrulandı — macOS sınırlaması artık DAP protokolü
  seviyesinde de teyit edildi.
- `tests/fuzz/` dolduruldu (Faz X.2) — Zig'in kendi yerleşik, kapsam-güdümlü
  fuzzer'ı (`std.testing.fuzz`/`Smith`, `zig build test --fuzz`) kullanan
  iki hedef: lexer→parser→checker zinciri ve WASM ikili ayrıştırıcısı.
  Ayrıca, bu pinlenmiş Zig 0.16.0 araç zincirinde `--fuzz`in kendisinin
  (Zig'in kendi `compiler/test_runner.zig`sindeki bağımsız bir tip
  uyuşmazlığı yüzünden) derlenemediği keşfedildi — bu yüzden her iki
  dosyaya da `std.testing.fuzz`e bağımlı olmayan, her `zig build test`te
  koşulsuz çalışan elle yazılmış regresyon testleri eklendi.
- ARC atomikliği/cross-thread invariant'ı resmileştirildi (Faz X.3) —
  `runtime/alloc/arc.zig`nin refcount'u kasıtlı olarak atomik değil (ölçülen
  performans fazı gerekçesiyle) ve Nox'un eşzamanlılık modeli tek-OS-iş-
  parçacıklı fiber zamanlaması; bu invariant araştırıldı, `nox.http`
  istemcisinin tek istisnası (arka plan iş parçacığı) doğrulandı ve artık
  Debug modunda `asap.RuntimeState.arc_owner_tid` ile aktif olarak
  denetleniyor (Release'de sıfır maliyet). Gerçek bir `std.Thread.spawn`
  ile başlatılan ayrı iş parçacığından yapılan ihlalin doğru yakalandığı
  yeni bir birim testiyle doğrulandı.
- Hafif paket dizini eklendi (Faz Y.1) — `compiler/pkg/index.zig`, üçüncü-
  taraf Nox paketlerini keşfetmek için statik bir JSON indeksini
  ayrıştırıp arayan salt-okunur bir katalog (gerçek bir sunucu/registry
  DEĞİL, `docs/uretim-hazirlik-analizi.md`nin talimatına uygun). Yeni,
  tam işlevsel `noxc search <indeks-dosyasi.json> [sorgu]` alt komutu
  (hâlâ iskelet olan `fetch`/`update`den farklı olarak).
- Beş gerçek üçüncü-taraf Nox paketi yayımlandı (Faz Y.2) —
  `github.com/mburakmmm/nox-pkg-{greet,mathx,stack,strfmt,collections}`,
  hepsi MIT lisanslı ve `v1.0.0` etiketli genel GitHub repoları — Nox'un
  merkeziyetsiz (Git tabanlı) paket ekosisteminin GERÇEKTEN çalıştığını
  kanıtlamak için. `examples/thirdparty_demo/`, bu beş paketi GERÇEK ağ
  üzerinden getirip tüketen uçtan uca bir örnek + `noxc search` için
  örnek bir paket dizini içerir.
- 1.0 için somut bir "hazır" tanımı belgelendi (Faz Z.1) —
  `nox-teknik-spesifikasyon.md` §3.43: Faz Q–Y'nin (temel sağlamlaştırma,
  platform genişletme, bellek güvenliği, derleyici DX, dil
  tamamlanmışlığı, stdlib, araç ekosistemi, güvenlik sertleştirme, paket
  ekosistemi) TAMAMININ TAMAMLANDIĞINI doğrulayan bir kontrol listesi;
  gerçek M:N fiber zamanlayıcı değerlendirmesinin (AA.1) 1.0'ın kapsamı
  DIŞINDA, 1.0-sonrası açık bir araştırma öğesi olarak kaldığı AÇIKÇA
  belirtildi.
- `VERSIONING.md` eklendi (Faz Z.2) — `v1.0.0`dan itibaren geçerli
  olacak semver politikası (MAJOR/MINOR/PATCH tanımları, kaynak
  uyumluluğu garantisi, kullanımdan kaldırma kuralı) ve dil/ABI
  stabilite garantisinin bilinçli kapsam dışı bıraktığı dört alan
  (ikili/ABI uyumluluğu, hata mesajı metni, `--dump`/`-v` çıktısı,
  üçüncü-taraf paket API'leri) yazılı hale getirildi. `README.md`ye
  bağlantı eklendi.
- `v0.1 (taslak)` etiketi kaldırıldı, gerçek sürüm numaralandırmasına
  geçildi (Faz Z.3) — `build.zig.zon`nin `.version`i `1.0.0`e
  güncellendi, `README.md`nin durum banner'ı buna göre yeniden yazıldı,
  bu dosyanın Faz Q'dan beri biriken tüm girdileri tek bir `[1.0.0]`
  başlığı altında toplandı.

### Düzeltildi
- **Bellek sızıntısı (Faz X.2, `tests/fuzz/wasm_parser_fuzz.zig`nin yeni
  regresyon testi tarafından bulundu):** `runtime/wasm_bridge/module.zig`nin
  `parse` fonksiyonu, onlarca hata yolunun hiçbirinde o ana kadar
  biriktirilmiş `types`/`func_type_indices`/`bodies`/`exports`
  listelerini (ve içlerindeki `params`/`results`/`name`/`locals`
  alt-dilimlerini) serbest bırakmıyordu — bozuk/kısaltılmış bir `.wasm`
  girdisi her zaman bir sızıntıya yol açardı (Faz 13'ten beri var olan,
  sistemik bir tasarım boşluğu). Her ara listeye/alt-tahsise kendi
  `errdefer`i eklenerek düzeltildi.
- **Güvenlik (Faz X.1, `docs/uretim-hazirlik-analizi.md` P1 bulgusu #12):**
  WASM köprüsünün DÖRT LEB128 varint okuyucusu (`runtime/wasm_bridge/
  module.zig`nin `readVarU32`/`readVarI32`si + `runtime/wasm_bridge/
  interp.zig`nin `readVarU32At`/`readVarI32At`si), bozuk/kötü niyetli bir
  `.wasm` dosyası 6+ ardışık devam baytı (`0x80`) sağladığında `shift: u5`
  taşmasına (28+7=35 > 31) yol açıyordu — güvenli derlemelerde panik
  (DoS), güvensiz derlemelerde tanımsız davranış. Bayt sayısı 5 ile
  sınırlandı, birikim `u64`/`i64`e taşındı, sonuç hedef genişliğe (u32/
  i32) sığma açısından doğrulandı (kanonik olmayan kodlamalar artık
  sessizce kırpılmıyor, reddediliyor). Kasıtlı boz→kırmızı→düzelt
  ritüeli sırasında test vektörünün kendisinde de gerçek bir hata
  bulundu (bkz. nox-teknik-spesifikasyon.md §3.38) ve düzeltildi.
- `noxlsp`nin LSP çerçeveleme okuyucusunda (`readMessage`), `std.Io.Reader.
  takeDelimiterExclusive`in delimiter'ı (`\n`) TÜKETMEDİĞİ (yalnızca ONA
  KADAR ilerlediği) fark edilmeden `takeDelimiterExclusive` kullanılmıştı —
  bu, her başlık satırından sonra `\n`nin buferde kalıp bir sonraki okumanın
  yanlış konumdan başlamasına, dolayısıyla mesaj gövdesinin kaydırılmasına
  yol açıyordu. `zig build test`in tamamının askıda kalmasıyla (SIGKILL ile
  sonlandırma gerekti) keşfedildi; `takeDelimiterInclusive`e geçilerek
  düzeltildi.
- **Önemli test-altyapısı düzeltmesi:** `compiler/*.zig` dosyalarına gömülü
  onlarca birim testi (`compiler/lexer/lexer.zig`, `compiler/parser/
  parser.zig`, `compiler/typecheck/types.zig` vb.) `zig build test`
  tarafından SESSİZCE hiç çalıştırılmıyordu — `lib.zig`nin (`nox` modülünün
  kökü) hiçbir `refAllDecls` çağrısı içermemesi nedeniyle Zig'in tembel
  analiz modeli bu dosyaların içindeki `test` bloklarını hiç keşfetmiyordu.
  `lib.zig`ye özyinelemeli bir `refAllDeclsRecursive` yardımcısı eklendi;
  bu, `compiler/parser/parser.zig`deki DÖRT testin Faz T.1'den (AST'ye
  `{kind, line}` sarmalayıcısı eklenmesi) beri sessizce DERLENEMEZ durumda
  olduğunu ortaya çıkardı (düzeltildi). Test sayısı 300'den 318'e çıktı.
- `noxc` artık proje kökü DIŞINDAN (ör. sistem geneli bir kurulumdan)
  çalıştırılabiliyor — `main.zig`, kendi stdlib/runtime kaynak dizinlerini
  artık CWD-göreli sabit `"stdlib"`/`"zig-out/lib/noxrt.o"` yolları yerine
  `project.resolveResourceDirs`in (kendi çalıştırılabilir dosya konumuna
  göre) çözdüğü yolları kullanıyor (Faz Q.3). Yeni, isteğe bağlı
  `NOX_RESOURCE_DIR` ortam değişkeni eklendi (paket önbelleği kökü olan
  `NOX_HOME`den AYRI bir kavram).
- `swap_aarch64.s` → `swap_aarch64.S`: Mach-O'ya özgü `_` sembol öneki
  KALDIRILDI, macOS/Linux'ta AYNI kaynaktan doğru derlenen taşınabilir bir
  `SYM(...)` makrosu eklendi (önceden Linux'ta linklenmezdi).
- `build.zig`ye Linux hedefleri İÇİN `link_libc = true` eklendi (`runtime/`
  genelinde kullanılan `std.c.*` çağrıları Linux'ta AÇIK libc bağlama
  gerektirir — macOS'ta bu her zaman örtüktü).
- `qbe`nin `-t <target>`i artık AÇIKÇA geçiliyor (Faz R.3) — önceden
  `qbe`nin KENDİ build-time varsayılanına güveniliyordu, bu da AYNI
  derleyicinin platform/derleme-ortamına göre SESSİZCE farklı bir ABI
  üretmesine yol açabiliyordu (Linux'ta GERÇEKTEN yakalanan bir hata).
- `build.zig`deki `install_stdlib`, `test_step`e HİÇ bağlı DEĞİLDİ —
  `zig build test`, `zig-out/lib/nox/stdlib/`nin ÖNCEKİ bir `zig build`
  çalışmasından KALMA olmasına sessizce güveniyordu (temiz bir `zig-out`
  üzerinde GERÇEKTEN başarısız olduğu doğrulandı, şimdi düzeltildi).
- `cc`nin link satırına `-rdynamic` eklendi (Faz R.3, EN DERİN bulgu) —
  `nox.json`nin `dlsym(dlopen(null,...), ...)` deseni ana programın KENDİ
  (QBE'nin ürettiği) sembollerini bulmak İÇİN bunu Linux'ta ZORUNLU kılıyor
  (macOS'ta örtük). Eksikliği Linux'ta GERÇEK bir çökmeye (geçerli JSON'da)
  VE bellek sızıntısına (bozuk JSON'un hata yolunda) yol açıyordu. `qbe -t`
  seçim mantığı da tekrarı önlemek İÇİN yeni `compiler/qbe_target.zig`ye
  taşındı.
- `Task[T]`/`Channel[T]`/`dict[K,V]` tipli bir değişken/sınıf alanı YENİDEN
  atandığında eski değer artık sızmıyor (Faz S.1) — `genAssign` artık bu üç
  türü de `destroyNonArcValue` ile yok ediyor. `Task` İÇİN AYRICA bir bellek
  güvenliği düzeltmesi: henüz TAMAMLANMAMIŞ bir görev "yok edilirse" (ör.
  hiç `await` edilmeden yeniden atanırsa) artık struct'ı HEMEN serbest
  BIRAKMIYOR (bu, fiber SONRADAN tamamlanınca serbest bırakılmış belleğe
  yazan bir use-after-free olurdu) — yeni `Task.detached` bayrağı gerçek
  serbest bırakmayı görev KENDİ KENDİNE tamamlanana kadar erteliyor.
- `list[T]` indekslemesi (`xs[i]`) artık sınır kontrolü yapıyor (Faz S.2) —
  önceden `xs[999]` gibi bir erişim sınır kontrolü OLMADAN doğrudan geçersiz
  belleğe erişirdi (tanımsız davranış). `s[i]`nin ZATEN kullandığı AYNI
  desenle artık aralık dışı bir erişimde `IndexError` `raise` ediliyor.
  Yan bulgu: `tests/compat/extern_ffi_test.zig` `core.nox`u (dolayısıyla
  `IndexError`/`ValueError`i) hiç birleştirmiyordu — düzeltildi.
- Codegen'in `releaseValueIfSet`i, func-tipli bir değişkene atanan/
  döndürülen bir closure değerinin somut kökeni bilinmediğinde (`class_name
  == null`) "attempt to use null value" ile ÇÖKÜYORDU (Faz U.4.3 sırasında
  manuel uçtan-uca testte bulundu). `class_name.?` → `class_name orelse
  return error.Unsupported` — artık main.zig'in zaten yakaladığı güvenli
  "henüz desteklenmiyor" hatasına düşüyor, panik yok.
- **Kritik, Faz 7'den beri var olan bir `try/finally` hatası düzeltildi**
  (Faz U.5'in `with` doğrulaması sırasında bulundu): bir `finally` bloğu
  İÇİNDE bir METOD ÇAĞRISI varsa (metod çağrıları her zaman bir istisna
  kontrolü üretir) VE bu finally normal-tamamlanma/eşleşen-`except`
  yolunda çalıştırılıyorsa, noxc'nin KENDİSİ derleme sırasında sonsuz
  özyinelemeyle (yığın taşması) çöküyordu — `finally_body`, KENDİSİ
  çalışırken hâlâ `finally_stack`de olduğundan, içindeki çağrının istisna
  kontrolü `drainFinally`yi tetikleyip aynı `finally`yi tekrar tekrar
  çalıştırıyordu. Yeni `runDetachedFinally` yardımcısı bunu düzeltiyor
  (finally'yi çalıştırmadan önce geçici olarak yığından çıkarıp sonra
  geri ekliyor). Önceden hiçbir test bir metod çağrısı içeren `finally`
  yazmadığından fark edilmemişti — `with`in `__exit__`i her zaman bir
  metod çağrısı olduğundan bunu ilk kez ortaya çıkardı.

### Güvenlik
- `nox.http.serve`e iki DoS sertleştirmesi eklendi (Faz Q.5): bir isteğin
  gövdesi artık 10 MiB ile sınırlı (aşılırsa `413 Payload Too Large`,
  handler hiç çağrılmaz) ve eşzamanlı bağlantı sayısı artık 4096 ile
  sınırlı (aşan bağlantılar `receiveHead`e ulaşmadan sessizce kapatılır).
  Bilinen kalan sınırlama: okuma zaman aşımı (slowloris koruması) henüz
  yok — reaktöre zamanlayıcı desteği eklenene kadar ertelendi.
