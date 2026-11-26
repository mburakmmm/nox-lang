#!/usr/bin/env python3
"""UR-013: Host ABI bağlam yalıtımı denetimi (alt yorumlayıcı güvenliği).

`runtime/host.zig` (Host ABI çalışma zamanı) dosya-seviyesi HİÇBİR değişken durum (`var`/`threadlocal var`) bildirmemelidir: tüm durum `Context`/`RuntimeState` içinde yaşar,
böylece iki bağımsız `NoxHostContext` (ör. iki CPython alt yorumlayıcısı) hiçbir değişken durumu paylaşmaz. Çekirdek yola ulaşan geri kalan dosya-seviyesi bildirimler
`project/global-state-allowlist.tsv`de gerekçelidir (`scripts/check_global_state.py`).
"""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
src = (root / "runtime" / "host.zig").read_text(encoding="utf-8")
bad = [(i + 1, l.strip()) for i, l in enumerate(src.splitlines()) if re.match(r"^(pub\s+)?(threadlocal\s+)?var\s", l)]
if bad:
    for n, l in bad:
        print(f"runtime/host.zig:{n}: dosya-seviyesi değişken durum yasak (bağlam yalıtımı): {l}")
    sys.exit(1)
print("host yalıtımı: runtime/host.zig dosya-seviyesi değişken durum içermiyor")
