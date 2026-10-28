#!/usr/bin/env python3
"""Mobil stable kapısı (TODO 4.6/4.7) — fail-closed.

Matris `Stable: yes` demedikçe kapı yalnızca matrisin "experimental" kaldığını doğrular. `Stable: yes` denirse:
  * `mobile-evidence/dod.txt` içindeki ZORUNLU her anahtar bulunmalı ve boş ya da `no` olmamalı (eksik anahtar da `=no` gibi hatadır);
  * imzalı artifact anahtarları (`signed_ipa`, `signed_apk`, `signed_aab`) için `<anahtar>_sha256=<64 hex>` satırı olmalı;
  * en yeni `mobile-evidence/*-gates.txt` dosyası temiz bir Nox ağacından (`nox_tree=clean`), git'te var olan bir `nox_head` ve
    derleme-mi-çalıştırma-mı ayrımını (`backend=`, `date=`) taşımalı. Bayat/kirli kanıt kapıyı açamaz.
`python3 scripts/check_mobile_stable.py --self-test` mantığı örnek girdilerle sınar.
"""
import pathlib
import re
import subprocess
import sys

REQUIRED = [
    "signed_ipa", "signed_apk", "signed_aab", "device_lab",
    "emulator_chat", "accessibility", "page_16k", "simulator_call",
]
SIGNED = ["signed_ipa", "signed_apk", "signed_aab"]


def parse_kv(text):
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def stable_problems(dod, gates, commit_exists):
    problems = []
    for key in REQUIRED:
        if key not in dod:
            problems.append(f"{key}: zorunlu anahtar eksik")
        elif dod[key] in ("", "no"):
            problems.append(f"{key}={dod[key] or '(boş)'}")
    for key in SIGNED:
        if dod.get(key) not in (None, "", "no"):
            if not re.fullmatch(r"[0-9a-f]{64}", dod.get(key + "_sha256", "")):
                problems.append(f"{key}_sha256: 64 haneli SHA-256 gerekli")
    if gates is None:
        problems.append("kanıt dosyası (*-gates.txt) yok")
    else:
        if gates.get("nox_tree") != "clean":
            problems.append(f"kanıt temiz bir ağaçtan değil (nox_tree={gates.get('nox_tree', 'eksik')})")
        head = gates.get("nox_head", "")
        if not head or not commit_exists(head):
            problems.append(f"kanıttaki nox_head git'te bulunamadı ({head or 'eksik'})")
        for key in ("date", "backend"):
            if not gates.get(key):
                problems.append(f"kanıt dosyasında {key} yok")
    return problems


def self_test():
    ok_dod = {k: "yes" for k in REQUIRED}
    for k in SIGNED:
        ok_dod[k + "_sha256"] = "a" * 64
    ok_gates = {"nox_tree": "clean", "nox_head": "abc1234", "date": "2026-10-28", "backend": "llvm"}
    assert stable_problems(ok_dod, ok_gates, lambda h: True) == [], "tam kanıt geçmeli"
    missing = dict(ok_dod)
    del missing["device_lab"]
    assert any("device_lab" in p for p in stable_problems(missing, ok_gates, lambda h: True)), "eksik anahtar hata olmalı"
    no = dict(ok_dod, signed_ipa="no")
    assert any("signed_ipa=no" in p for p in stable_problems(no, ok_gates, lambda h: True))
    nohash = dict(ok_dod)
    del nohash["signed_aab_sha256"]
    assert any("signed_aab_sha256" in p for p in stable_problems(nohash, ok_gates, lambda h: True))
    assert any("nox_tree" in p for p in stable_problems(ok_dod, dict(ok_gates, nox_tree="dirty"), lambda h: True)), "kirli ağaç reddedilmeli"
    assert any("nox_head" in p for p in stable_problems(ok_dod, ok_gates, lambda h: False)), "bilinmeyen commit reddedilmeli"
    assert any("kanıt dosyası" in p for p in stable_problems(ok_dod, None, lambda h: True))
    print("mobile stable gate: self-test geçti")


def main():
    if "--self-test" in sys.argv:
        self_test()
        return
    root = pathlib.Path(__file__).resolve().parents[1]
    matrix = (root / "docs/internals/mobile-matrix.md").read_text()
    claims_stable = "Stable: yes" in matrix
    if "experimental" not in matrix and not claims_stable:
        sys.exit("mobile matrix must stay experimental until Stable: yes")
    if not claims_stable:
        print("mobile stable gate: experimental")
        return
    dod = parse_kv((root / "mobile-evidence/dod.txt").read_text())
    gate_files = sorted((root / "mobile-evidence").glob("*-gates.txt"))
    gates = parse_kv(gate_files[-1].read_text()) if gate_files else None

    def commit_exists(h):
        return subprocess.run(["git", "-C", str(root), "cat-file", "-e", h + "^{commit}"], capture_output=True).returncode == 0

    problems = stable_problems(dod, gates, commit_exists)
    if problems:
        sys.exit("stable claim is blocked:\n" + "\n".join(problems))
    print("mobile stable gate: stable")


main()
