# nyx.noxlang.com, aether.noxlang.com, aura.noxlang.com
# Bağlam DEPO KÖKÜ:
#   docker build -f services/frameworks-site/Dockerfile -t frameworks-site:latest .
#
# 1) site  : üç çerçevenin kılavuzu -> /public/{nyx,aether,aura}
# 2) tool  : noxc ile bu Nyx uygulamasını derle
# 3) run   : tek ikili; Host başlığı hangi ağacı sunacağını seçer

FROM python:3.12-slim-bookworm AS site
WORKDIR /src
COPY scripts/build_framework_sites.py ./scripts/build_framework_sites.py
COPY services/frameworks-site/content ./services/frameworks-site/content
COPY services/noxlang-site/site ./services/noxlang-site/site
RUN python3 scripts/build_framework_sites.py --out /public

FROM debian:bookworm-slim AS tool
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSL -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz \
    && tar xf /tmp/zig.tar.xz -C /opt && mv /opt/zig-aarch64-linux-0.16.0 /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
RUN curl -sSL -o /tmp/qbe.tar.xz https://c9x.me/compile/release/qbe-1.3.tar.xz \
    && tar xf /tmp/qbe.tar.xz -C /tmp && make -C /tmp/qbe-1.3 -j"$(nproc)" \
    && cp /tmp/qbe-1.3/qbe /usr/local/bin/qbe && rm -rf /tmp/qbe.tar.xz /tmp/qbe-1.3
WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseFast
WORKDIR /src/services/frameworks-site
RUN /src/zig-out/bin/noxc fetch && mkdir -p /app && /src/zig-out/bin/noxc build -o /app/frameworks-site main.nox

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home --uid 10001 nox
COPY --from=tool /app/frameworks-site /app/frameworks-site
COPY --from=site /public /app/public
WORKDIR /app
ENV SITE_ROOT=/app/public
USER nox
EXPOSE 8080
ENTRYPOINT ["/app/frameworks-site"]
