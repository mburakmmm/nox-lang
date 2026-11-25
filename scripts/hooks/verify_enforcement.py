#!/usr/bin/env python3
"""Araç-disiplini zorlamasının (rtk + graphify + qrun) yapılandırma doğrulaması — yeni oturum/worktree/alt oturumda hook'ların ve talimatların GERÇEKTEN yüklenebilir olduğunu kanıtlar.
Hiçbir yan etki yapmaz (yalnızca okur + sentetik hook çalıştırır). Çıkış kodu: 0 = tüm zorunlu denetimler geçti; 1 = bir zorunlu denetim düştü. Kullanım: python3 scripts/hooks/verify_enforcement.py"""
import json, os, shutil, subprocess, sys, tempfile

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or os.getcwd()
fails, warns = [], []


def ok(name, cond, detail="", required=True):
    tag = "PASS" if cond else ("FAIL" if required else "WARN")
    print(f"[{tag}] {name}" + (f" — {detail}" if detail else ""))
    if not cond:
        (fails if required else warns).append(name)


def run(cmd, inp=None, env=None):
    return subprocess.run(cmd, input=inp, capture_output=True, text=True, cwd=ROOT, env=env)


def hooks_of(path):
    try:
        return json.load(open(path, encoding="utf-8")).get("hooks", {})
    except Exception:
        return None


def cmds(h, event):
    out = []
    for e in (h or {}).get(event, []):
        for x in e.get("hooks", []):
            out.append((e.get("matcher", ""), x.get("command", "")))
    return out


# 1) kullanıcı düzeyi rtk hook'u: tam bir kez, Bash PreToolUse
uh = hooks_of(os.path.expanduser("~/.claude/settings.json"))
rtk_hooks = [c for m, c in cmds(uh, "PreToolUse") if "rtk hook claude" in c]
ok("kullanıcı-düzeyi rtk PreToolUse(Bash) hook'u tam 1 kez", len(rtk_hooks) == 1, f"{len(rtk_hooks)} adet")
ok("rtk PATH'te", shutil.which("rtk") is not None, shutil.which("rtk") or "")
if shutil.which("rtk"):
    r = run(["rtk", "hook", "claude"], json.dumps({"tool_name": "Bash", "tool_input": {"command": "git status"}}))
    ok("rtk yeniden yazımı canlı (git status → rtk git status)", "rtk git status" in r.stdout, r.stdout.strip()[:80])

# 2) proje hook'ları
ph = hooks_of(os.path.join(ROOT, ".claude/settings.json"))
ok(".claude/settings.json okunur", ph is not None)
for ev in ("SessionStart", "SubagentStart", "PostToolUse"):
    cs = cmds(ph, ev)
    ok(f"proje {ev} hook'u tanımlı", len(cs) == 1, f"{len(cs)} adet")
    for _, c in cs:
        rel = c.split("scripts/hooks/")[-1].split('"')[0] if "scripts/hooks/" in c else ""
        ok(f"  {ev} betiği mevcut ({rel})", os.path.exists(os.path.join(ROOT, "scripts/hooks", rel)))
ok("proje düzeyinde PreToolUse/Bash hook'u YOK (rtk ile çakışma yok)", not [1 for m, c in cmds(ph, "PreToolUse") if "Bash" in m or m == ""])
tracked = run(["git", "ls-files", "--error-unmatch", ".claude/settings.json"]).returncode == 0
ok(".claude/settings.json git'te izleniyor (worktree/yeni klon güvenli)", tracked)

# 3) talimatlar
cm = open(os.path.join(ROOT, "CLAUDE.md"), encoding="utf-8").read() if os.path.exists(os.path.join(ROOT, "CLAUDE.md")) else ""
ok("CLAUDE.md @AGENTS.md içe aktarır", "@AGENTS.md" in cm)
g = os.path.expanduser("~/.claude/CLAUDE.md")
ok("~/.claude/CLAUDE.md @RTK.md içe aktarır", os.path.exists(g) and "@RTK.md" in open(g, encoding="utf-8").read())
ok("~/.claude/RTK.md mevcut ve kısa", os.path.exists(os.path.expanduser("~/.claude/RTK.md")) and sum(1 for _ in open(os.path.expanduser("~/.claude/RTK.md"))) <= 20)

# 4) araçlar
ok("graphify kurulu", shutil.which("graphify") is not None)
ok("graf mevcut", os.path.exists(os.path.join(ROOT, "graphify-out/graph.json")), required=False)
ok("scripts/qrun.sh mevcut", os.path.exists(os.path.join(ROOT, "scripts/qrun.sh")))

# 5) hook duman testleri
env = dict(os.environ, CLAUDE_PROJECT_DIR=ROOT)
r = run(["sh", "scripts/hooks/session_rules.sh"], '{"hook_event_name":"SessionStart"}', env)
ok("SessionStart kuralları basılıyor", "Nox araç disiplini" in r.stdout and r.returncode == 0)
r = run(["sh", "scripts/hooks/session_rules.sh"], '{"hook_event_name":"SubagentStart"}', env)
try:
    j = json.loads(r.stdout)["hookSpecificOutput"]
    ok("SubagentStart geçerli JSON additionalContext", j["hookEventName"] == "SubagentStart" and "Nox araç disiplini" in j["additionalContext"])
except Exception as e:
    ok("SubagentStart geçerli JSON additionalContext", False, str(e))
tmp = tempfile.mkdtemp()
try:
    env2 = dict(env, CLAUDE_PROJECT_DIR=tmp)
    ev = {"tool_name": "Bash", "tool_input": {"command": "sed -n 1,5p x.zig"}, "tool_response": "x", "session_id": "verify00"}
    r = run(["python3", "scripts/hooks/token_audit_hook.py"], json.dumps(ev), env2)
    ok("denetim hook'u: ham sed -n için uyarı döner, çıkış 0", r.returncode == 0 and "additionalContext" in r.stdout)
    ev["tool_input"]["command"] = "rtk git status"
    r = run(["python3", "scripts/hooks/token_audit_hook.py"], json.dumps(ev), env2)
    ok("denetim hook'u: rtk komutu için uyarı yok (updatedInput hiç dönmez)", r.returncode == 0 and "updatedInput" not in r.stdout)
    r = run(["python3", "scripts/hooks/token_audit_hook.py"], "bozuk girdi", env2)
    ok("denetim hook'u: bozuk girdide sessiz çıkış 0", r.returncode == 0 and r.stdout == "")
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print(f"\n{'ÖZET: ' + str(len(fails)) + ' zorunlu denetim düştü: ' + ', '.join(fails) if fails else 'ÖZET: tüm zorunlu denetimler geçti'}" + (f" ({len(warns)} uyarı)" if warns else ""))
sys.exit(1 if fails else 0)
