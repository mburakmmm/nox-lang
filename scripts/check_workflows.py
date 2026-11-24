#!/usr/bin/env python3
"""`.github/workflows/*.yml` dosyalarının YAML olarak ayrıştığını doğrular (geçersiz dosya CI'da her push'ta 'workflow file issue' ile kırmızı koşu üretir)."""
import glob, os, sys
import yaml

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bad = 0
for p in sorted(glob.glob(os.path.join(root, ".github/workflows/*.yml"))):
    try:
        d = yaml.safe_load(open(p, encoding="utf-8"))
        if not isinstance(d, dict) or "jobs" not in d:
            raise ValueError("'jobs' anahtarı yok")
    except Exception as e:
        bad += 1
        print(f"{os.path.relpath(p, root)}: {e}", file=sys.stderr)
print("workflow YAML: " + ("HATA" if bad else "tamam"))
sys.exit(1 if bad else 0)
