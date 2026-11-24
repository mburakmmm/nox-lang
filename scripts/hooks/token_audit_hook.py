#!/usr/bin/env python3
"""PostToolUse denetim hook'u (YALNIZ KAYIT, asla engellemez): Read/Grep/Glob/Bash çağrılarının çıktı boyutunu
`.claude/token-audit/YYYY-MM-DD.jsonl`e yazar. Özet: `python3 scripts/token_audit.py`. Hata olursa sessizce çıkar (exit 0)."""
import json, os, sys, time

def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        return
    ti = d.get("tool_input") or {}
    tool = d.get("tool_name", "")
    try:
        size = len(json.dumps(d.get("tool_response", ""), ensure_ascii=False))
    except Exception:
        size = 0
    rec = {"t": int(time.time()), "s": (d.get("session_id") or "")[:8], "tool": tool, "size": size}
    agent = d.get("agent_id") or d.get("agent_type")
    if agent:
        rec["agent"] = str(agent)[:24]
    if tool == "Read":
        rec["path"] = ti.get("file_path", "")
        rec["ranged"] = bool(ti.get("offset") or ti.get("limit"))
    elif tool in ("Grep", "Glob"):
        rec["pat"] = str(ti.get("pattern", ""))[:80]
    elif tool == "Bash":
        rec["cmd"] = str(ti.get("command", ""))[:160]
    root = os.environ.get("CLAUDE_PROJECT_DIR") or d.get("cwd") or "."
    out = os.path.join(root, ".claude", "token-audit")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, time.strftime("%Y-%m-%d") + ".jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")

try:
    main()
except Exception:
    pass
sys.exit(0)
