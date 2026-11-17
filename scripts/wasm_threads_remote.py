#!/usr/bin/env python3
"""Mac/Linux'ta derlenmiş İŞ PARÇACIKLI WASM modüllerini UZAK bir Windows makinesinde (Node + `compiler/wasm_host.mjs`) koşturup `.expected` ile karşılaştırır (2.3 madde 5.5, Windows doğrulaması).

Kullanım: scripts/wasm_threads_remote.py --host noxdev@100.97.244.106 [--key ~/.ssh/nox_win] [--workdir C:/nox-dev/wt] [--targets wasm32-wasi-threads,wasm32-freestanding-threads] [filtre-regex]
Önkoşul: uzakta Node ve `tar`, yerelde `noxc` (zig-out/bin/noxc) ve scp/ssh anahtarı. Uzak kabuk PowerShell 5.1 varsayılır. Çıkış kodu: fark/zaman aşımı varsa 1.
"""
import argparse, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "tests/golden/codegen_cases")
NOXC = os.path.join(ROOT, "zig-out/bin/noxc")
DEFAULT_FILTER = r"^(mn_|atomic_|thread_spawn_stress|fs_written_by_threads|channel_|task_(?!local_basic|reassignment)|async_(?!deadlock)|spawn_|worker_)"
# Zamanlayıcıya bağlı sıra / kasıtlı deadlock / libm farkı: `wasm_corpus_test.zig` THREADS_DENYLISTED_SOURCES ile aynı.
SKIP = {"async_deadlock", "thread_spawn_ordering", "task_reassignment_frees_old", "task_local_basic", "mathx_trig_log_constants"}

ap = argparse.ArgumentParser()
ap.add_argument("filter", nargs="?", default=DEFAULT_FILTER)
ap.add_argument("--host", required=True)
ap.add_argument("--key", default=os.path.expanduser("~/.ssh/nox_win"))
ap.add_argument("--workdir", default="C:/nox-dev/wt")
ap.add_argument("--targets", default="wasm32-wasi-threads,wasm32-freestanding-threads")
ap.add_argument("--timeout", type=int, default=120)
a = ap.parse_args()
ssh = ["ssh", "-i", a.key, "-o", "BatchMode=yes", a.host]
scp_base = ["scp", "-q", "-i", a.key]

names = sorted(os.path.basename(p)[:-4] for p in os.listdir(CASES) if p.endswith(".nox") for p in [os.path.join(CASES, p)])
names = [n for n in names if re.search(a.filter, n) and n not in SKIP and os.path.exists(os.path.join(CASES, n + ".expected"))]
print(f"{len(names)} fixture x {a.targets}")
stage = tempfile.mkdtemp(prefix="nox-wt-")
built = []
for tgt in a.targets.split(","):
    for n in names:
        out = os.path.join(stage, f"{n}.{tgt}.wasm")
        r = subprocess.run([NOXC, "build", "--target", tgt, os.path.join(CASES, n + ".nox"), "-o", out], capture_output=True, text=True)
        if r.returncode == 0 and os.path.exists(out):
            built.append((n, tgt))
        # derlenemeyenler (modül wasm'da yok vb.) atlanır: Mac tarafı korpus testi zaten bunları sınıflar
print(f"{len(built)} modül derlendi")
shutil.copy(os.path.join(ROOT, "compiler/wasm_host.mjs"), stage)
ps = f'''$ErrorActionPreference = "Continue"
Set-Location "{a.workdir}\\\\run"
New-Item -ItemType Directory -Force out | Out-Null
foreach ($f in Get-ChildItem *.wasm) {{
  $o = "out\\\\" + $f.Name + ".txt"
  $p = Start-Process -FilePath node -ArgumentList @("--no-warnings","wasm_host.mjs",$f.Name) -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError ($o + ".err")
  if (-not $p.WaitForExit({a.timeout * 1000})) {{ $p.Kill(); Add-Content ($o + ".err") "TIMEOUT" }}
}}
'''
open(os.path.join(stage, "run.ps1"), "w").write(ps)
tarball = os.path.join(stage, "pkg.tar")
subprocess.run(["tar", "-cf", tarball, "-C", stage, "run.ps1", "wasm_host.mjs"] + [f"{n}.{t}.wasm" for n, t in built], check=True)
wd = a.workdir.replace("/", "\\")
subprocess.run(ssh + [f'if (Test-Path {wd}\\run) {{ Remove-Item -Recurse -Force {wd}\\run }}; New-Item -ItemType Directory -Force {wd}\\run | Out-Null'], check=True)
subprocess.run(scp_base + [tarball, f"{a.host}:{a.workdir}/pkg.tar"], check=True)
subprocess.run(ssh + [f'cd {wd}; tar -xf pkg.tar -C run; Remove-Item pkg.tar'], check=True)
r = subprocess.run(ssh + [f'powershell -NoProfile -ExecutionPolicy Bypass -File {wd}\\run\\run.ps1'], capture_output=True, text=True, timeout=a.timeout * (len(built) + 2))
subprocess.run(ssh + [f'cd {wd}\\run; tar -cf ..\\out.tar out'], check=True)
back = os.path.join(stage, "out.tar")
subprocess.run(scp_base + [f"{a.host}:{a.workdir}/out.tar", back], check=True)
subprocess.run(["tar", "-xf", back, "-C", stage], check=True)
bad, ok = [], 0
for n, tgt in built:
    got_p = os.path.join(stage, "out", f"{n}.{tgt}.wasm.txt")
    err_p = got_p + ".err"
    got = open(got_p, encoding="utf-8", errors="replace").read().replace("\r\n", "\n") if os.path.exists(got_p) else ""
    err = open(err_p, encoding="utf-8", errors="replace").read() if os.path.exists(err_p) else ""
    want = open(os.path.join(CASES, n + ".expected"), encoding="utf-8").read()
    if got == want and "TIMEOUT" not in err:
        ok += 1
    else:
        bad.append((n, tgt, "TIMEOUT" if "TIMEOUT" in err else "FARK", got[:120].replace("\n", "|"), err[:160].replace("\n", "|")))
print(f"Windows ({a.host}): ok {ok}, sorunlu {len(bad)}")
for b in bad:
    print("  ", *b)
shutil.rmtree(stage, ignore_errors=True)
sys.exit(1 if bad else 0)
