# noxpkg — merkezi paket indeksi sunucusu

`noxc add`/`noxc delete`/`noxc publish`in konuştuğu, [`noxpkg.2mtechnology.org`](https://noxpkg.2mtechnology.org)'da barındırılması planlanan merkezi paket indeksi + admin paneli. Nox'un kendisinde yazılmıştır — `nox.router`/`nox.template`/`nox.validate`/`nox.crypto`/`nox.http`/`nox.os` üzerine, dış bağımlılık yok.

## Mimari kısaca

- **Salt-okunur genel uç nokta:** `GET /index.json` — `compiler/pkg/index.zig`'in `{"packages": [...]}` şemasıyla birebir aynı, bu sayede `noxc search`/`noxc add` sıfır CLI değişikliğiyle çalışır.
- **Gönderi kutusu:** `POST /api/publish` — `noxc publish`'in gönderdiği metadata (isim/repo/ref/açıklama) `data/inbox.json`'a eklenir, admin onayı bekler.
- **Admin paneli:** `/admin/*` — tek şifre (argon2id), imzalı/durumsuz oturum çerezi, CSRF korumalı, rate-limit'li giriş. Bekleyen gönderileri onaylar/reddeder, yayındaki girdileri çıkarır.
- **Depolama:** düz `data/index.json`/`data/inbox.json` (SQLite değil — bu ölçekte gereksiz, `libsqlite3` container bağımlılığından kaçınır).
- **Durumsuzluk:** Nox'ta modül-üstü durum fonksiyon içinden görülemediğinden (bkz. `auth.nox`'un belge notu), her istek kendi dosya round-trip'ini yapar. `num_threads=1` bunu yarış-koşulundan korur.

## Yerel geliştirme (bu Mac, OrbStack ile)

```sh
noxc run services/noxpkg/scripts/gen_admin_hash.nox -- 'gecici-sifre'
export NOXPKG_ADMIN_PASSWORD_HASH='<yukaridaki cikti>'
export NOXPKG_SESSION_SECRET="$(openssl rand -hex 32)"
docker compose -f services/noxpkg/docker-compose.yml up --build
curl http://localhost:8080/index.json
```

## Üretime alma (Mac mini M4, native arm64)

Mac mini'de bu depo `git pull` edilir, aynı `docker compose up --build` çalıştırılır (imaj taşıma yok — toolchain container içinde native derlenir). Ardından:

1. `brew install cloudflared`
2. `cloudflared tunnel login && cloudflared tunnel create noxpkg`
3. Ingress: `noxpkg.2mtechnology.org` → `http://localhost:8080`
4. `cloudflared tunnel route dns noxpkg noxpkg.2mtechnology.org`
5. `cloudflared tunnel run noxpkg`
