#!/usr/bin/env bash
# Yerel ön kontrol: CI'ın "Dokümanlar" işindeki TÜM denetimleri `git push`tan önce çalıştırır (v2.1.195 ve 2.2.0-rc.1 bunları atladığı için CI kırmızı çıktı).
# Gerekenler: zig-out/bin/noxc (önce `zig build`), python3 + pyyaml + markdown + pygments (`python3 -m venv /tmp/dv && /tmp/dv/bin/pip install pyyaml markdown pygments`; PYTHON=/tmp/dv/bin/python ile verin).
# Kullanım: scripts/precheck.sh        (ilk hatada durur; yeşilse "PRECHECK GREEN" yazar)
set -euo pipefail
cd "$(dirname "$0")/.."
PY="${PYTHON:-python3}"
step() { echo; echo "== $* =="; }
[ -x zig-out/bin/noxc ] || { echo "zig-out/bin/noxc yok: önce 'zig build'" >&2; exit 1; }

step "dokümanlar (bağlantılar + kod blokları + toc)";  "$PY" scripts/check_docs.py
step "global durum izin listesi";                       "$PY" scripts/check_global_state.py
step "belge sözleşmesi (sürümler, hedefler)";           "$PY" scripts/check_doc_contracts.py
step "ayrılmış semboller";                              "$PY" scripts/check_reserved_symbols.py; "$PY" scripts/gen_reserved_symbol_fixture.py --check
step "fixture kaydı (yeni codegen_cases fixture'ı bir test dosyasında anılmalı)"; "$PY" scripts/check_fixture_registration.py
step "selfhost/lexer.nox güncel mi (token türleri, anahtar sözcükler, Unicode tabloları)"; "$PY" scripts/gen_selfhost_lexer.py --check
step "WASM http stub uyumu";                            "$PY" scripts/check_wasm_http_stubs.py
step "WASM ABI tablosu eksiksizliği";                    "$PY" scripts/check_wasm_abi_table.py
step "SBOM üreteci";                                    "$PY" scripts/gen_sbom.py --check v0.0.0-ci
step "hizmetler tip denetimi";                          zig-out/bin/noxc check services/noxpkg/main.nox
(cd services/noxlang-site && ../../zig-out/bin/noxc fetch >/dev/null && ../../zig-out/bin/noxc check main.nox)
step "site üretimi";                                    "$PY" scripts/build_site.py --verify
echo; echo "PRECHECK GREEN"
