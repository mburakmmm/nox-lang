# O1 — Go gibi `x := ifade` (tip yazmadan tanım): getirelim mi? (analiz ve öneri, 2026-11-18)

**Karar sizin** (AGENTS §16): AGENTS.md §5 "Tüm parametre, değişken ve dönüş tipleri zorunludur" der; `:=` bu cümleyi yerel değişkenler için gevşetir. Bu belge karar için gerekçe ve önerilen kapsamdır; kod yazılmadı.

## Dil ilkeleriyle uyum
- **İlke #2 (statik tip) ihlal edilmez:** `x := 5` tipi derleme zamanında kesin (`int`) çıkarılır, dinamik tipleme değildir. Etkilenen yalnızca §5'in "yazılmak zorunda" metnidir.
- Önceki emsal var: `self` anotasyonsuz (§3.63) ve `-> T` yazılmayan `def` = `-> None` (v2.1.170) — "yüzey kısayolu, tip yine statik" ilkesiyle kabul edilmişti. `:=` aynı çizgidedir.
- İlke #1 (ownership görünmez) ve diğerleri etkilenmez.

## Artılar
- Gürültü azalır: `nd: Node = Node(...)`, `n: int = len(xs)`, `r: HttpResponse = nox.http.get(...)`; sağ taraf tipi zaten söylüyor (yinelenen bilgi).
- Go/Python-tip-ipucu kullanıcıları için tanıdık; yeni başlayanlar için eşik düşer.
- Teknik maliyet küçük: checker her ifadenin tipini zaten hesaplıyor (`checkExpr`); `var_decl` yalnızca hedef tipi ifade tipinden alır.

## Eksiler / riskler (ve önerilen çözüm)
| Durum | Sorun | Öneri |
|---|---|---|
| `x := []`, `x := {}` | eleman/değer tipi çıkarılamaz | **hata**: "tip yazın: `x: list[int] = []`" |
| `x := None` | Optional'ın iç tipi bilinmez | **hata**, aynı mesaj |
| `x := 1` ama `float` isteniyor | sessiz `int`; sonra `x = 1.5` tip hatası uzakta çıkar | `int`/`float` literal kuralı sabit (`1` int, `1.0` float); hata mesajı "x: int olarak çıkarıldı (satır N)" der |
| Optional dönen çağrı: `x := find(k)` | `T \| None` çıkarılır, daraltma zorunlu olur | doğru davranış (Go'daki `v, ok` yerine); mesaj çıkarım kaynağını göstermeli |
| Sabit-genişlikli tamsayılar (`u8`, `i32`) | `x := a + 1` genişlik kuralı kodda zaten var; çıkarım aynı kuralı izler | mevcut kuralları yeniden kullan |
| Modül düzeyi `x := ...` | başka işlevler bu global'in tipine bağlı; çıkarım sırası başlatma sırasına bağımlı | **v1'de yasak** (yalnızca işlev yerelleri) |
| Kapanış/iç içe `def` yakalamaları | yakalanan değişkenin tipi çıkarım sırasına bağlanır | yakalanan yerel için anotasyon gerekmez, çünkü bildirim satırında tip çıkarılmış olur |
| Hata mesajı yerelliği | tip hatası tanımdan uzakta çıkabilir | checker mesajına "x, satır N'de `Foo` olarak çıkarıldı" notu ekle |
| Biçimlendirici/LSP/`noxc explain`/golden fixture | `:=` korunmalı; LSP çıkarılan tipi hover/inlay olarak göstermeli | `noxc fmt` yazılan biçimi korur (v2.1.170 emsali) |
| Karışık stil | iki biçim bir arada | stil rehberi: sağ taraf tipi açıksa `:=`, açık değilse anotasyon |

## Önerilen kapsam (v1)
1. Yalnızca **işlev/metod/üst düzey `if`-dışı yerel** bildirimleri: `ad := ifade`. Modül düzeyi ve sınıf alanları **yok**.
2. Sağ taraf tipi **tek başına çıkarılabilir** olmalı: literal, kurucu çağrısı, açık dönüş tipli işlev/metod çağrısı, aritmetik/karşılaştırma, f-string, list/dict/tuple literal (boş değil). Boş kapsayıcı ve `None` **hata** (anotasyon iste).
3. Anotasyonlu `x: T = ifade` aynen geçerli kalır (`noxc fmt` yazılan biçimi korur).
4. `AGENTS.md` §5'e üçüncü dar istisna olarak eklenir; spesifikasyona (§3) bölüm.
5. Golden: çıkarım (int/float/str/list/class/Optional), hata (`[]`, `None`, yeniden atamada tip uyuşmazlığı mesajı), `fmt` korunumu, LSP/`explain`, iki backend.

## Maliyet
Lexer (`:=` belirteci) + parser (`var_decl.type_expr` isteğe bağlı) + checker (çıkarım, mesajlar) + codegen (checker AST'yi çıkarılan tipi yazarak doldurur, codegen değişmez) + fmt + LSP + docs + testler. Tahmin: **M** (tek sürüm, ~3-4 gün).

## Öneri
**Evet, kısıtlı biçimde (yukarıdaki v1).** Kısıtlamalar belirsiz yerleri (boş kapsayıcı, `None`, modül düzeyi) kapatır; geriye kalan kullanım dilin "Python gibi görünen, statik" pusulasına uyar. Onay verirseniz önce AGENTS.md §5 metnini birlikte güncelleyip uygularım.
