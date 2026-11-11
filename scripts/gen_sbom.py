#!/usr/bin/env python3
"""Release için SBOM (SPDX 2.3 JSON) üretir: `scripts/gen_sbom.py <sürüm> <çıktı.json>`.

Yalnızca depodan DOĞRULANABİLİR bileşenler yazılır (uydurma yok): Nox'un kendisi, `third_party/sqlite` (sürüm `sqlite3.h`dan okunur), arşive giren QBE (sürüm ve sağlama
toplamı `scripts/build_qbe.sh`tan) ve Zig standart kütüphanesi/compiler-rt (sürüm `build.zig.zon`un `minimum_zig_version`ından). Bir sürüm okunamazsa betik hata verir:
sessizce eksik SBOM üretilmez. `--check` çıktıyı yazmadan yalnızca doğrular.
"""
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def find(pattern: str, text: str, what: str) -> str:
    m = re.search(pattern, text)
    if not m:
        sys.exit(f"gen_sbom: {what} okunamadı ({pattern})")
    return m.group(1)


def build(version: str) -> dict:
    sqlite = find(r'#define SQLITE_VERSION\s+"([^"]+)"', read("third_party/sqlite/sqlite3.h"), "SQLite sürümü")
    libdeflate = find(r"tag \*\*v([0-9.]+)\*\*", read("third_party/libdeflate/NOX_VENDOR.md"), "libdeflate sürümü")
    qbe_script = read("scripts/build_qbe.sh")
    qbe_version = find(r'version="([^"]+)"', qbe_script, "QBE sürümü")
    qbe_sha = find(r'sha256="([0-9a-f]{64})"', qbe_script, "QBE sağlama toplamı")
    zig = find(r'\.minimum_zig_version\s*=\s*"([^"]+)"', read("build.zig.zon"), "Zig sürümü")
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    packages = [
        {
            "SPDXID": "SPDXRef-Package-nox-lang",
            "name": "nox-lang",
            "versionInfo": version,
            "supplier": "Person: Melih Burak Memiş",
            "downloadLocation": "https://github.com/mburakmmm/nox-lang",
            "filesAnalyzed": False,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright (c) 2026 Melih Burak Memiş",
        },
        {
            "SPDXID": "SPDXRef-Package-sqlite",
            "name": "sqlite",
            "versionInfo": sqlite,
            "supplier": "Organization: SQLite Consortium",
            "downloadLocation": "https://www.sqlite.org/",
            "filesAnalyzed": False,
            "licenseConcluded": "blessing",
            "licenseDeclared": "blessing",
            "copyrightText": "NOASSERTION",
            "comment": "Amalgamation, depoda third_party/sqlite altında; yalnızca WASM hedeflerinin çalışma zamanına bağlanır.",
        },
        {
            "SPDXID": "SPDXRef-Package-libdeflate",
            "name": "libdeflate",
            "versionInfo": libdeflate,
            "supplier": "Person: Eric Biggers",
            "downloadLocation": "https://github.com/ebiggers/libdeflate",
            "filesAnalyzed": False,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "Copyright 2016 Eric Biggers",
            "comment": "Değiştirilmemiş kaynak, depoda third_party/libdeflate altında; yalnızca macOS/Linux masaüstü çalışma zamanının nox.gzip yolunda derlenir.",
        },
        {
            "SPDXID": "SPDXRef-Package-qbe",
            "name": "qbe",
            "versionInfo": qbe_version,
            "supplier": "Person: Quentin Carbonneaux",
            "downloadLocation": f"https://c9x.me/compile/release/qbe-{qbe_version}.tar.xz",
            "filesAnalyzed": False,
            "checksums": [{"algorithm": "SHA256", "checksumValue": qbe_sha}],
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "NOASSERTION",
            "comment": "Arşivdeki bin/qbe: sabit sağlama toplamlı kaynaktan, upstream amd64_win yamasıyla derlenir (scripts/build_qbe.sh).",
        },
        {
            "SPDXID": "SPDXRef-Package-zig",
            "name": "zig",
            "versionInfo": zig,
            "supplier": "Organization: Zig Software Foundation",
            "downloadLocation": f"https://ziglang.org/download/{zig}/",
            "filesAnalyzed": False,
            "licenseConcluded": "MIT",
            "licenseDeclared": "MIT",
            "copyrightText": "NOASSERTION",
            "comment": "noxc ve çalışma zamanı Zig ile derlenir; Zig standart kütüphanesi ve compiler-rt ikililere bağlanır.",
        },
    ]
    rels = [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Package-nox-lang"}]
    for name in ("sqlite", "libdeflate", "qbe", "zig"):
        rels.append({"spdxElementId": "SPDXRef-Package-nox-lang", "relationshipType": "CONTAINS", "relatedSpdxElement": f"SPDXRef-Package-{name}"})
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"nox-lang-{version}",
        "documentNamespace": f"https://github.com/mburakmmm/nox-lang/releases/tag/{version}/sbom",
        "creationInfo": {"created": now, "creators": ["Tool: nox-lang/scripts/gen_sbom.py"]},
        "packages": packages,
        "relationships": rels,
    }


def main() -> None:
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    if not args or (not check and len(args) < 2):
        sys.exit("kullanım: gen_sbom.py <sürüm> <çıktı.json>   |   gen_sbom.py --check <sürüm>")
    doc = build(args[0])
    # Doğrulama: her paket sürümlü ve ilişkilendirilmiş olmalı.
    ids = {p["SPDXID"] for p in doc["packages"]}
    for r in doc["relationships"]:
        for key in ("spdxElementId", "relatedSpdxElement"):
            if r[key] != "SPDXRef-DOCUMENT" and r[key] not in ids:
                sys.exit(f"gen_sbom: ilişki bilinmeyen bir pakete işaret ediyor: {r[key]}")
    if any(not p.get("versionInfo") for p in doc["packages"]):
        sys.exit("gen_sbom: sürümü olmayan paket")
    if check:
        print(f"gen_sbom: temiz ({len(doc['packages'])} paket)")
        return
    Path(args[1]).write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"gen_sbom: {args[1]} yazıldı ({len(doc['packages'])} paket)")


if __name__ == "__main__":
    main()
