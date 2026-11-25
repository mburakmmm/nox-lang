# NoxPy upstream gereksinimleri (UR-001..007) — ara faz takibi

Kaynak: `/Users/melihburakmemis/Documents/nox-packages/noxPY/UPSTREAM_REQUIREMENTS.md` (NoxPy: Nox'la yazılmış kütüphaneleri Python'dan kullanma çerçevesi; reproducer'lar `noxPY/tests/reproducers/`, JSON şeması `noxPY/python/noxpy/ir.py`). Kullanıcı kararı (2026-11-25): selfhost Aşama 3'e ARA; sıra aşağıdaki gibi; `include/nox_host.h` = **deneysel v1** (`abi_version`/`struct_size`, `docs/apis/stability.md`'de experimental, AGENTS.md §9.5 güven sınırı notu); her UR ayrı commit/sürüm (v2.2.75+). Değişmez ilkeler (AGENTS.md §2: #4 iç düzen sızdırma yok, #6 global durum yok) bağlayıcı; ABI/mimari belirsizlikte önce sor (§16).

Doğrulama döngüsü: her UR bitince `noxPY/tests/reproducers/<ur>.sh` güncel `noxc` ile çalıştırılır; sonuç buraya yazılır.

## Sıra ve durum

- [x] **UR-001 (v2.2.75)** — kodlandı + test (`tests/cli/desktop_lib_emit_test.zig`); macOS-arm64 ana makine + linux-x64/arm64/windows-x64/macos-x64 çapraz `.so/.dll/.dylib` bağlandı. Açık: Linux x86-64'te PIC runtime hız ölçümü (yerelde ölçülemedi)
- [ ] **UR-007** `noxc expand --json` (şema v1, `ir.py` uyumlu): tipli dışa aktarım metadata'sı
- [ ] **UR-002** `include/nox_host.h` + açık dışa aktarım (`@export` thunk'ları, `NoxHostContext*`, init/fini)
- [ ] **UR-005** Abort etmeyen hata (OOM/taşma → durum kodu) + public istisna inceleme (class_name/message/line)
- [ ] **UR-003** Gizli sembol görünürlüğü + `dispatch_registry`/`halt_provider`/tl-errno durumunu RuntimeState'e taşıma (`native-runtime-*` planıyla örtüşür)
- [ ] **UR-004** Yabancı iş parçacığı attach/detach sözleşmesi
- [ ] **UR-006** Uzunluk-bilgili UTF-8/bytes span + nesil-denetimli `NoxHostHandle`

## Notlar

- NoxPy belgesi v2.2.70 tabanlı; güncel sürümle reproducer'lar baştan koşulmalı.
- UR-003/004, `project/native-runtime-migration-plan.md` M.4–M.9 kararlarıyla birlikte ele alınır.
