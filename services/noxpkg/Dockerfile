# noxpkg — çok-aşamalı, NATIVE arm64 build (bu Mac VE Mac mini M4 HER
# İKİSİ de Apple Silicon; OrbStack'in kendi arm64 Linux VM'i ÜZERİNDEN
# --platform=linux/amd64/QEMU emülasyonuna HİÇ GEREK YOK — bkz. proje
# belleği "noxc add/delete/publish + noxpkg merkezi sunucusu" planı).
#
# `noxc build`in HİÇBİR çapraz-derleme (`--target`) desteği OLMADIĞINDAN
# (derleyicinin KENDİ host mimarisine KİLİTLİ, doğrulandı) TÜM toolchain
# (Zig + kaynaktan derlenen QBE + `noxc`nin KENDİSİ) BU imajın İÇİNDE,
# NATIVE olarak inşa edilir — `.github/workflows/ci.yml`nin `aarch64-
# linux` matris satırıyla BİREBİR AYNI Zig/QBE sürüm+URL'leri.
#
# Build bağlamı DEPO KÖKÜ olmalı (compiler/stdlib/runtime gerekir):
#   docker build -f services/noxpkg/Dockerfile -t noxpkg:latest .

FROM debian:bookworm-slim AS toolchain
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz \
    && tar xf /tmp/zig.tar.xz -C /opt \
    && mv /opt/zig-aarch64-linux-0.16.0 /opt/zig \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

RUN curl -sSL -o /tmp/qbe.tar.xz https://c9x.me/compile/release/qbe-1.3.tar.xz \
    && tar xf /tmp/qbe.tar.xz -C /tmp \
    && make -C /tmp/qbe-1.3 -j"$(nproc)" \
    && cp /tmp/qbe-1.3/qbe /usr/local/bin/qbe \
    && rm -rf /tmp/qbe.tar.xz /tmp/qbe-1.3

WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseFast

WORKDIR /src/services/noxpkg
RUN mkdir -p /app && /src/zig-out/bin/noxc build -o /app/noxpkg main.nox

# ---- Çalışma zamanı imajı ----
FROM debian:bookworm-slim AS runtime
# Ekstra apt paketi GEREKMEZ: düz-JSON depolama (bkz. store.nox'un belge
# notu) `nox.sqlite`yi HİÇ import etmediğinden `libsqlite3` bağımlılığı
# YOK; `noxc build`in `cc -rdynamic` bağlantısının TEK gerçek çalışma
# zamanı bağımlılıkları (glibc/libm/libpthread/libgcc_s) taban imajda
# ZATEN mevcut.
COPY --from=toolchain /app/noxpkg /app/noxpkg
COPY services/noxpkg/data/index.example.json /app/data/index.example.json
WORKDIR /app
EXPOSE 8080
ENTRYPOINT ["/app/noxpkg"]
