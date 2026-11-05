# noxlang.com — çok aşamalı build. Bağlam DEPO KÖKÜ olmalı (docs/, assets/, scripts/, compiler/ gerekir):
#   docker build -f services/noxlang-site/Dockerfile -t noxlang-site:latest .
#
# 1) tool  : Zig + QBE + noxc, Nyx uygulamasını (main.nox) native derler (noxpkg imajıyla AYNI desen) ve Playground'un
#            WebAssembly varlıklarını (noxc-frontend.wasm + çalışma zamanı nesneleri) üretir
# 2) site  : docs/ + site/ + Playground varlıkları -> public/ (scripts/build_site.py; Python yalnızca BU aşamada, çalışma zamanında YOK)
# 3) run   : debian-slim + libsqlite3 (Nyx bellek-içi SQLite açar) + tek ikili + public/

FROM debian:bookworm-slim AS tool
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl xz-utils build-essential ca-certificates git \
    && rm -rf /var/lib/apt/lists/*
# Zig, imajı derleyen makinenin mimarisine göre (aarch64: M4 / GitHub arm64 runner; x86_64: ordinary CI) indirilir.
RUN arch="$(uname -m)" \
    && curl -sSL -o /tmp/zig.tar.xz "https://ziglang.org/download/0.16.0/zig-${arch}-linux-0.16.0.tar.xz" \
    && tar xf /tmp/zig.tar.xz -C /opt && mv "/opt/zig-${arch}-linux-0.16.0" /opt/zig && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"
RUN curl -sSL -o /tmp/qbe.tar.xz https://c9x.me/compile/release/qbe-1.3.tar.xz \
    && tar xf /tmp/qbe.tar.xz -C /tmp && make -C /tmp/qbe-1.3 -j"$(nproc)" \
    && cp /tmp/qbe-1.3/qbe /usr/local/bin/qbe && rm -rf /tmp/qbe.tar.xz /tmp/qbe-1.3
WORKDIR /src
COPY . .
# `-Dcpu` AÇIKÇA verilir (release.yml'deki arşivlerle AYNI sabit taban; bkz. v1.142.7): varsayılan, imajı derleyen makinenin NATIVE CPU'sudur. GitHub'ın arm64 runner'ında
# (Neoverse, SVE2 vb.) derlenen imaj Apple Silicon'da (Mac mini M4) ilk komutta SIGILL (çıkış 132) veriyordu; v2.0.171 imajı bu yüzden sağlıksız çıkıp geri alındı.
# Çalışma zamanı nesnesi (noxrt.o) ve ondan türeyen site ikilisi de bu tabana göre derlenir. aarch64: baseline, x86-64: x86_64_v2.
RUN case "$(uname -m)" in aarch64|arm64) cpu=baseline;; *) cpu=x86_64_v2;; esac \
    && zig build -Doptimize=ReleaseFast -Dcpu="$cpu"
# Playground: tarayıcıda çalışan derleyicinin ön yüzü ve WASM çalışma zamanı nesneleri (site aşaması bunları public/playground/'a koyar).
RUN zig build wasm-compiler wasm-rt -Doptimize=ReleaseFast
WORKDIR /src/services/noxlang-site
RUN /src/zig-out/bin/noxc fetch && mkdir -p /app && /src/zig-out/bin/noxc build -o /app/noxlang-site main.nox

FROM python:3.12-slim-bookworm AS site
RUN pip install --no-cache-dir "Markdown==3.11" "Pygments==2.21.0" "PyYAML==6.0.3"
WORKDIR /src
COPY docs ./docs
COPY assets ./assets
COPY scripts/build_site.py ./scripts/build_site.py
COPY install.sh install.ps1 build.zig.zon ./
COPY compiler/wasm_compiler.mjs compiler/wasm_host.mjs ./compiler/
COPY services/noxlang-site/site ./services/noxlang-site/site
# Playground varlıkları `tool` aşamasında derlenir (zig build wasm-compiler wasm-rt).
COPY --from=tool /src/zig-out/lib/noxc-frontend.wasm /src/zig-out/lib/noxrt-wasm32-freestanding.o /src/zig-out/lib/noxrt-wasm32-freestanding-sqlite3.o /src/zig-out/lib/compiler-rt-wasm32.a /wasm-lib/
RUN python3 scripts/build_site.py --out /public --wasm-lib /wasm-lib

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
