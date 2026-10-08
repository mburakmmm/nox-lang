# noxlang.com — çok aşamalı build. Bağlam DEPO KÖKÜ olmalı (docs/, assets/, scripts/, compiler/ gerekir):
#   docker build -f services/noxlang-site/Dockerfile -t noxlang-site:latest .
#
# 1) site  : docs/ + site/ -> public/ (scripts/build_site.py; Python yalnızca BU aşamada, çalışma zamanında YOK)
# 2) tool  : Zig + QBE + noxc, Nyx uygulamasını (main.nox) native derler (noxpkg imajıyla AYNI desen)
# 3) run   : debian-slim + libsqlite3 (Nyx bellek-içi SQLite açar) + tek ikili + public/

FROM python:3.12-slim-bookworm AS site
RUN pip install --no-cache-dir "Markdown==3.11" "Pygments==2.21.0" "PyYAML==6.0.3"
WORKDIR /src
COPY docs ./docs
COPY assets ./assets
COPY scripts/build_site.py ./scripts/build_site.py
COPY install.sh install.ps1 ./
COPY services/noxlang-site/site ./services/noxlang-site/site
RUN python3 scripts/build_site.py --out /public

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
WORKDIR /src/services/noxlang-site
RUN /src/zig-out/bin/noxc fetch && mkdir -p /app && /src/zig-out/bin/noxc build -o /app/noxlang-site main.nox

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home --uid 10001 nox
COPY --from=tool /app/noxlang-site /app/noxlang-site
COPY --from=site /public /app/public
WORKDIR /app
ENV SITE_ROOT=/app/public
USER nox
EXPOSE 8080
ENTRYPOINT ["/app/noxlang-site"]
