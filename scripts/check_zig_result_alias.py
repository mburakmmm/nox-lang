#!/usr/bin/env python3
"""R1-P1.7d (v2.2.53): Zig sonuç-konumu örtüşmesi denetimi.

`x = .{ ..., .f = if (x) |o| o.f else null }` gibi, ATAMA HEDEFİNİ kendi başlatma ifadesinde OKUYAN struct/birleşim ataması Zig'de ReleaseFast'te çöp okuyabilir
(alanlar yerinde yazılırken hedef kısmen başlatılmış görünür; Debug'da geçici değişken kullanıldığı için gizlenir). v2.2.52'de `syntax_report.zig` bu yüzden hata iletisinde
bellek çöpü basıyordu. Çözüm: okunan değeri önce yerel değişkene alın.

Kullanım: python3 scripts/check_zig_result_alias.py   (bulgu varsa çıkış 1)
"""
import pathlib
import re
import sys

ROOTS = ("compiler", "runtime", "shared", "tests")
NAME = r"([a-z_][A-Za-z0-9_.]*)"
ONE_LINE = re.compile(r"^\s*" + NAME + r" = (?:[A-Za-z_.]+)?\{(.*)\};?\s*$")
OPEN = re.compile(r"^\s*" + NAME + r" = (?:[A-Za-z_.]+)?\{\s*$")


def reads(name: str, text: str) -> bool:
    return re.search(r"(?<![A-Za-z0-9_.])" + re.escape(name) + r"(?![A-Za-z0-9_(])", text) is not None


def main() -> int:
    hits = []
    for root in ROOTS:
        for p in pathlib.Path(root).rglob("*.zig"):
            lines = p.read_text(errors="ignore").split("\n")
            for i, line in enumerate(lines):
                if "= " not in line or "{" not in line:
                    continue
                m = ONE_LINE.match(line)
                if m and line.count("{") > 0 and reads(m.group(1), m.group(2)):
                    hits.append((p, i + 1, line.strip()))
                    continue
                m = OPEN.match(line)
                if not m:
                    continue
                depth, j, body = 1, i + 1, []
                while j < len(lines) and depth > 0 and j - i <= 60:
                    depth += lines[j].count("{") - lines[j].count("}")
                    body.append(lines[j])
                    j += 1
                if reads(m.group(1), "\n".join(body[:-1])):
                    hits.append((p, i + 1, line.strip()))
    for p, n, l in hits:
        print(f"{p}:{n}: hedef kendi başlatma ifadesinde okunuyor: {l}")
    print(f"check_zig_result_alias: {len(hits)} bulgu")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
