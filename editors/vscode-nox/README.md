# Nox için DAP/hata ayıklama entegrasyonu (Faz W.3)

## Neden özel bir DAP sunucusu YOK

`noxc build -g` (Faz T.3, bkz. `nox-teknik-spesifikasyon.md` §3.17) QBE
aracılığıyla **gerçek DWARF hat tablosu** (`dbgfile`/`dbgloc` → assembler'ın
`.file`/`.loc` yönergeleri → `.debug_line`) üretir. [Debug Adapter Protocol]
(https://microsoft.github.io/debug-adapter-protocol/) TAMAMEN dilden
bağımsızdır — bir DAP istemcisi (VS Code, vb.) kaynak dosyayı/satırı DWARF
hat tablosundan ÇÖZER, dilin KENDİSİNİ (Nox'u) hiç TANIMASI GEREKMEZ. Bu
YÜZDEN Nox'un KENDİ DAP sunucusunu YAZMASI **gerekli DEĞİLDİR** — `nox.regex`
(Kernighan'ın algoritmasını uyarlama) ya da W.1'in tree-sitter-python
tarayıcısını uyarlama İLKESİNİN DAHA GÜÇLÜ bir versiyonu: burada UYARLAMAYA
bile GEREK YOK, VAR OLAN, olgun bir DAP sunucusu (`lldb-dap`, Apple/LLVM'in
resmi native debugger adaptörü — Xcode Command Line Tools İLE GELİR;
Linux'ta `lldb` paketi İLE GELİR — VEYA GDB tabanlı herhangi bir DAP köprüsü)
DOĞRUDAN kullanılabilir. `noxc`nin işi YALNIZCA DOĞRU DWARF üretmektir
(T.3'ün ZATEN yaptığı) — bu dosya/dizin, bunu STANDART bir editör iş
akışına (VS Code + CodeLLDB) NASIL bağlayacağınızı gösterir.

## Kurulum

1. VS Code'da [CodeLLDB](https://marketplace.visualstudio.com/items?itemName=vadimcn.vscode-lldb)
   uzantısını kurun (native/DWARF-tabanlı HERHANGİ bir dili destekler —
   Nox'a ÖZGÜ bir eklenti DEĞİLDİR).
2. `.vscode/launch.json.example` → `.vscode/launch.json`, `.vscode/
   tasks.json.example` → `.vscode/tasks.json` olarak projenizin KÖK
   dizinine kopyalayın; `program`/`command` yollarını KENDİ `noxc`
   kurulumunuza göre düzenleyin.
3. Nox dosyanızı açıp F5'e basın — `preLaunchTask` `noxc build -g` çalıştırır,
   sonra CodeLLDB üretilen ikiliyi başlatıp DWARF hat tablosu üzerinden
   kesme noktalarınızı çözer.

## Bilinen sınırlamalar (Faz T.3'ten DEVRALINAN, YENİ bir kısıt DEĞİL)

- **Yalnızca SATIR-düzeyi adımlama/kesme noktaları** — QBE'nin IL'i
  `dbgfile`/`dbgloc` DIŞINDA hiçbir debug yönergesi tanımadığından
  (bkz. T.3 sınırlama 2) **değişken inceleme (`variables` isteği) HİÇBİR
  ZAMAN veri DÖNDÜRMEZ** — "Locals" paneli HER ZAMAN boş görünecektir.
  Bu, DAP istemcisinin/Nox'un bir eksikliği DEĞİL, QBE'nin DWARF desteğinin
  KENDİ sınırıdır.
- **macOS: bağlı (linked) ikili DWARF TAŞIMAZ** (bkz. T.3 sınırlama 3,
  Apple `ld`sinin STABS/`N_OSO` "debug map" GEREKSİNİMİ) — kesme
  noktaları `"verified": false` olarak KALIR, ASLA tetiklenmez. **BU
  OTURUMDA (macOS/aarch64, Xcode Command Line Tools'un KENDİ `lldb-dap`si
  İLE) doğrulandı** — DAP el sıkışmasının (initialize/launch/setBreakpoints/
  configurationDone) TAMAMI BAŞARIYLA tamamlandı, program NORMAL şekilde
  çalışıp çıktı verdi, AMA kesme noktası `verified: false` OLARAK kaldı ve
  hiç TETİKLENMEDİ — T.3'ün lldb/gdb İLE elle yaptığı gözlemle BİREBİR
  TUTARLI, şimdi DAP protokolü seviyesinde de doğrulanmış oldu.
- **Linux: TAM ÇALIŞIR** — T.3'ün Docker/Debian doğrulaması, `readelf`
  bağlı ikilide DOĞRU satır tablosu GÖSTERDİĞİNİ VE `gdb`nin GERÇEK bir
  kesme noktasına DURDUĞUNU kanıtladı. `lldb`/`lldb-dap` DE (Debian
  bookworm'un `lldb-14` paketiyle GELEN `lldb-vscode-14`, `lldb-dap`nin
  ESKİ adı) AYNI standart DWARF `.debug_line` bölümünü OKUR — bu YÜZDEN
  AYNI garantinin (satır-düzeyi kesme noktaları ÇALIŞIR) bu ADAPTÖR İÇİN de
  GEÇERLİ olması BEKLENİR, ama BU spesifik kombinasyon (`lldb-dap` + Linux)
  bu OTURUMDA AYRICA test EDİLMEDİ (yalnızca gdb, T.3'te) — dürüstçe
  belirtilir.
- **Çoklu-dosya yanlış atıf** (bkz. T.3 sınırlama 1) AYNEN GEÇERLİDİR —
  `nox.strings`/`nox.json` gibi stdlib fonksiyonlarına ADIM ATILDIĞINDA
  debugger doğru satırı AMA yanlış dosya bağlamını gösterebilir.

## Doğrulama (bu fazda yapılan)

Ham DAP protokolü (`Content-Length` çerçevelemesi, LSP İLE AYNI temel
aktarım — bkz. `compiler/lsp_main.zig`nin AYNI mekanizması) üzerinden
`lldb-dap`e (bu makinede zaten kurulu, Xcode Command Line Tools'un bir
PARÇASI) doğrudan konuşan geçici bir Python betiği ile:
`initialize` → `launch` (`noxc build -g` İLE derlenmiş bir ikili) →
`setBreakpoints` → `configurationDone` — DÖRDÜ de BAŞARIYLA (`"success":
true`) yanıtlandı, süreç GERÇEKTEN başlatılıp normal çalıştı, kesme
noktası isteği `verified: false` DÖNDÜ (T.3'ün macOS sınırlamasıyla TAM
TUTARLI). Bu betik geçicidir (T.3'ün KENDİ manuel gdb doğrulaması İLE AYNI
"oturum-içi araştırma, kalıcı bir test dosyası DEĞİL" desenİ) — kalıcı bir
`zig build test` hedefi OLARAK EKLENMEDİ, çünkü `lldb-dap`/`gdb`nin
varlığı ortama göre DEĞİŞİR (CI'de macOS runner'ları `lldb-dap`e SAHİPTİR,
ama Linux runner'ları HENÜZ `lldb`/`gdb` KURMAZ, bkz. `.github/workflows/
ci.yml`) — böyle bir bağımlılık `zig build test`in "her ortamda yeşil"
garantisini BOZARDI.
