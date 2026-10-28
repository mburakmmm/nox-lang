#!/usr/bin/env python3
"""Belge sözleşmesi denetimi (TODO 9.5): koddan türetilebilen olgular belgelerle çapraz doğrulanır.

1. `noxc --target` geçerli değerleri (compiler/main.zig'deki hata iletisi) -> her biri docs/reference/platforms.md veya
   docs/internals/mobile-matrix.md içinde adıyla geçmeli; mobil matris tablosundaki her hedef derleyicide tanımlı olmalı.
2. `--backend <llvm|qbe>` varsayılanı: yardım metni ve platforms.md "LLVM ... (default)" ifadesi uyumlu olmalı.
3. Sürüm: build.zig.zon, shared/hpy_host_contract.zig ve CHANGELOG'un en üst başlığı aynı sürümü söylemeli.
Kullanım: python3 scripts/check_doc_contracts.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


errors = []

# 1. hedefler
main_zig = read("compiler/main.zig")
m = re.search(r"unknown hosted target '\{s\}' \(valid values: ([^)]*)\)", main_zig)
if not m:
    errors.append("compiler/main.zig: --target geçerli değer listesi bulunamadı (ileti biçimi değişti mi?)")
    targets = []
else:
    targets = [t.strip() for t in m.group(1).split(",")]
platforms = read("docs/reference/platforms.md")
matrix = read("docs/internals/mobile-matrix.md")
joined = platforms + "\n" + matrix + "\n" + read("docs/install/index.md")
for t in targets:
    if t not in joined and t.replace("-", " ") not in joined:
        # masaüstü hedefler platforms.md'de "macOS arm64" gibi yazılır; adı ya da yazımı yeterli
        alias = {"macos-arm64": "macOS arm64", "macos-x64": "macOS x86-64", "linux-x64": "Linux x86-64", "linux-arm64": "Linux aarch64", "windows-x64": "Windows x86-64"}.get(t)
        if not alias or alias not in joined:
            errors.append(f"hedef '{t}' compiler/main.zig'de var ama platforms.md/mobile-matrix.md'de geçmiyor")
for row in re.findall(r"^\| (ios-[a-z0-9-]+|android-[a-z0-9-]+) \|", matrix, re.M):
    if row not in targets:
        errors.append(f"mobile-matrix.md hedefi '{row}' compiler/main.zig'de tanımlı değil")

# 2. backend
help_ok = "(default: llvm;" in main_zig
if not help_ok:
    errors.append("compiler/main.zig yardım metni artık 'default: llvm' demiyor")
if "**LLVM**" not in platforms:
    errors.append("platforms.md varsayılan backend olarak LLVM'i vurgulamıyor")

# 3. sürüm
zon = re.search(r'\.version = "([^"]+)"', read("build.zig.zon"))
host = re.search(r'"(\d+\.\d+\.\d+)"', read("shared/hpy_host_contract.zig"))
change = re.search(r"^## \[(\d+\.\d+\.\d+)\]", read("CHANGELOG.md"), re.M)
vers = {"build.zig.zon": zon and zon.group(1), "hpy_host_contract.zig": host and host.group(1), "CHANGELOG.md": change and change.group(1)}
if len(set(vers.values())) != 1:
    errors.append(f"sürümler uyuşmuyor: {vers}")

if errors:
    for e in errors:
        print("BELGE SÖZLEŞMESİ:", e)
    sys.exit(1)
print(f"belge sözleşmesi: temiz ({len(targets)} hedef, sürüm {zon.group(1)})")
