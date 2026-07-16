# Nox'a Katkıda Bulunma

*Türkçe | [English](CONTRIBUTING.en.md)*

Nox aktif geliştirme aşamasında bir dil projesidir. Bu belge, bir
değişiklik göndermeden önce bilmeniz gereken kuralları ve disiplini
özetler.

## Başlarken

```sh
git clone https://github.com/mburakmmm/nox-lang.git
cd nox-lang
zig build test    # her şey yeşil başlamalı
```

Gereksinimler: [Zig 0.16](https://ziglang.org/download/) (bkz.
`build.zig.zon`'daki `minimum_zig_version`) ve
[QBE](https://c9x.me/compile/) (`brew install qbe`).

## Zorunlu Okuma

Herhangi bir değişikliğe başlamadan önce:

1. **[`AGENTS.md`](AGENTS.md)** — mimari değişmez ilkeler (§2), Zig kodlama
   standartları (§6), derleyici geliştirme kuralları (§7), ve **§13'teki
   "Definition of Done" kontrol listesi** (bu, HER görev için ZORUNLUDUR).
2. **[`nox-teknik-spesifikasyon.md`](nox-teknik-spesifikasyon.md)** — dilin
   TAM tasarım geçmişi ve gerekçesi, numaralı bölümler halinde (`§3.x`).
   Yeni bir dil özelliği/derleyici davranışı ekliyorsanız buraya YENİ bir
   numaralı alt bölüm eklemeniz beklenir.
3. **[`docs/uretim-hazirlik-analizi.md`](docs/uretim-hazirlik-analizi.md)**
   — üretime hazırlık boşlukları ve MVP-sonrası yol haritası (Faz Q-Z).
   Büyük bir katkı yapmayı düşünüyorsanız önce burada zaten planlanmış bir
   şey olup olmadığını kontrol edin.

## Değişiklik Disiplini (AGENTS.md §7/§13'ten özet)

- **Her davranış değişikliği en az bir golden test'le gelir**
  (`tests/golden/`, `tests/unit/`, ya da `tests/compat/` — hangisi uygunsa).
  "Kasıtlı boz → kırmızıyı doğrula → düzelt" ritüeli beklenir: yeni testin
  GERÇEKTEN o davranışı sınadığını kanıtlamak için önce testi/kodu bilerek
  BOZUP kırmızı görün, sonra düzeltin.
- **`zig build test` HEM Debug HEM `-Doptimize=ReleaseFast`'ta yeşil
  olmalı** — CI (`.github/workflows/ci.yml`) ikisini de çalıştırır.
- **Bellek yönetimiyle ilgili değişikliklerde**: leak testi + double-free
  testi, `DebugAllocator`ın kendi güvenlik modu yeşil.
- **Hiçbir Değişmez İlke (`AGENTS.md` §2) ihlal edilmemeli** — özellikle:
  kullanıcıya hiçbir açık ownership sözdizimi hissettirilmemesi, zorunlu
  statik tipleme, whole-program (tek derleme birimi) modeli.
- **`zig fmt` ile formatlanmış olmalı** (değiştirilen dosyalar üzerinde).
- Yorum yazarken: sadece kodun NEDEN öyle olduğunu (gizli bir kısıt, ince
  bir invariant, belirli bir hatanın çözümü) açıklayın — NE yaptığını
  DEĞİL (iyi isimlendirme bunu zaten anlatır).

## PR Göndermeden Önce

`AGENTS.md` §14'teki checklist'i (Definition of Done + Değişmez İlkeler +
spesifikasyon tutarlılığı) kendi değişikliğinize karşı çalıştırın. PR
açıklamanızda hangi bölümleri etkilediğinizi ve hiçbir değişmez ilkenin
ihlal edilmediğini AÇIKÇA belirtin.

## Sorular / Belirsizlik

`AGENTS.md` §16'daki "Belirsizlik Durumunda Karar Prosedürü"nü izleyin —
büyük ölçüde geriye dönük UYUMLULUĞU koruyan, en dar kapsamlı çözümü
tercih edin; emin değilseniz bir issue açıp tartışın.
