# Değişiklik Günlüğü (Changelog)

Bu proje henüz **v0.1 (taslak)** aşamasındadır — semver garantisi henüz YOK
(bkz. `docs/uretim-hazirlik-analizi.md`, Faz Z). Bu dosya, Faz Q'dan
(temel sağlamlaştırma) itibaren yapılan değişiklikleri özetler; öncesi
için `nox-teknik-spesifikasyon.md`'nin tam geliştirme geçmişine bakın.

## [Yayımlanmamış]

### Eklendi
- İlk git commit'i — proje artık gerçek sürüm kontrolü altında (Faz Q.1).
- `CHANGELOG.md` (bu dosya).
- GitHub Actions CI (Faz Q.2) — her push/PR'da `zig build test` (Debug +
  ReleaseFast).

### Düzeltildi
- `noxc` artık proje kökü DIŞINDAN (ör. sistem geneli bir kurulumdan)
  çalıştırılabiliyor — `main.zig`, kendi stdlib/runtime kaynak dizinlerini
  artık CWD-göreli sabit `"stdlib"`/`"zig-out/lib/noxrt.o"` yolları yerine
  `project.resolveResourceDirs`in (kendi çalıştırılabilir dosya konumuna
  göre) çözdüğü yolları kullanıyor (Faz Q.3). Yeni, isteğe bağlı
  `NOX_RESOURCE_DIR` ortam değişkeni eklendi (paket önbelleği kökü olan
  `NOX_HOME`den AYRI bir kavram).

### Güvenlik
- `nox.http.serve`e iki DoS sertleştirmesi eklendi (Faz Q.5): bir isteğin
  gövdesi artık 10 MiB ile sınırlı (aşılırsa `413 Payload Too Large`,
  handler hiç çağrılmaz) ve eşzamanlı bağlantı sayısı artık 4096 ile
  sınırlı (aşan bağlantılar `receiveHead`e ulaşmadan sessizce kapatılır).
  Bilinen kalan sınırlama: okuma zaman aşımı (slowloris koruması) henüz
  yok — reaktöre zamanlayıcı desteği eklenene kadar ertelendi.
