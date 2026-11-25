#!/usr/bin/env python3
"""PostToolUse hook (Read|Grep|Glob|Bash): (1) KAYIT — çıktı boyutunu `.claude/token-audit/YYYY-MM-DD.jsonl`e yazar (özet: `python3 scripts/token_audit.py`);
(2) UYARI (advisory) — kaçınılabilir verimsiz kullanımda, oturum başına hız-sınırlı, kısa bir `additionalContext` ipucu döner.

ASLA engellemez, hiçbir girdiyi değiştirmez (`updatedInput` yok → kullanıcı-düzeyi `rtk hook claude` PreToolUse yeniden yazımıyla çakışmaz), hata olursa sessizce çıkar (exit 0).
Doğru/ham okuma meşru olabilir: uyarılar yalnız ipucudur, kural değildir. Kurallar (hepsi cooldown'lu): R1 ham sed -n/cat/head/tail, R2 gürültülü komut qrun'sız, R3 aynı dosya ≥3 kez,
R4 büyük aralıksız Read, R5 art arda arama, R6 rtk çıktısını boruyla süzme."""
import json, os, re, sys, time

RAW_READ = re.compile(r"(^|&&|;|\|\|)\s*(sed\s+-n|cat\s|head\s|tail\s)")
NOISY = re.compile(r"(^|&&|;|\s)(zig\s+(build|test)|(sh\s+)?scripts/test-fast\.sh|python3\s+scripts/\S+\.py|zig-out/bin/noxc(-nightly)?\s+\S+)")
GREPISH = re.compile(r"^(rtk\s+)?(git\s+grep|grep|rg)\b")
RTK_FILTERED = re.compile(r"^rtk\s.*\|\s*(cut|head|tail|awk|sed)\b")
BIG = 20000  # karakter ~ 5k token

MSG = {
    "R1": "İpucu: ham `sed -n/cat/head/tail` yerine `Read` (offset/limit) ya da `rtk read`; satır için önce `graphify explain`.",
    "R2": "İpucu: gürültülü çıktı — `sh scripts/qrun.sh <ad> <komut>` (tam çıktı log'a, çıkış kodu korunur); ayrıntıyı log'dan oku.",
    "R3": "İpucu: bu dosya oturumda {n} kez okundu — bulguları not et; `graphify explain` ile hedefle, dar aralık oku.",
    "R4": "İpucu: büyük tam Read ({k}K kar.) — önce `graphify explain`/`query` ile dosya:satır, sonra `offset`/`limit`.",
    "R5": "İpucu: art arda arama — `graphify query \"<soru>\" --seed <dosya>` kavramsal sorgu tek adımda daha ucuz olabilir.",
    "R6": "İpucu: rtk çıktısını `| cut/head/awk` ile süzme (rtk süzgecini bozar); gerekirse `rtk bypass <komut>`.",
}
COOLDOWN = {"R1": 6, "R2": 4, "R3": 5, "R4": 3, "R5": 8, "R6": 6}


def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"n": 0, "reads": {}, "recent": [], "last": {}}


def advise(st, tool, ti, size):
    """Bu olay için en fazla BİR uyarı kimliği döner (cooldown'a uyarak) ya da None."""
    st["n"] += 1
    n = st["n"]
    cand = []
    if tool == "Read":
        p = ti.get("file_path", "")
        ranged = bool(ti.get("offset") or ti.get("limit"))
        c = st["reads"].get(p, 0) + 1
        st["reads"][p] = c
        if c >= 3:
            cand.append(("R3", {"n": c}, p))
        if not ranged and size >= BIG:
            cand.append(("R4", {"k": size // 1000}, None))
    elif tool == "Bash":
        cmd = str(ti.get("command", ""))
        head = cmd.strip()
        isg = bool(GREPISH.match(head))
        st["recent"] = (st["recent"] + [1 if isg else 0])[-6:]
        if RAW_READ.search(head) and not head.startswith("rtk "):
            cand.append(("R1", {}, None))
        if NOISY.search(head) and "qrun" not in head and size > 4000:
            cand.append(("R2", {}, None))
        if RTK_FILTERED.match(head):
            cand.append(("R6", {}, None))
        if isg and sum(st["recent"]) >= 4:
            cand.append(("R5", {}, None))
    for rid, kw, key in cand:
        slot = rid + (":" + key if key else "")
        if n - st["last"].get(slot, -10**9) >= COOLDOWN[rid]:
            st["last"][slot] = n
            return rid, MSG[rid].format(**kw)
    return None


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
    sid = (d.get("session_id") or "")[:8]
    rec = {"t": int(time.time()), "s": sid, "tool": tool, "size": size}
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
    sp = os.path.join(out, "state-%s.json" % sid)
    if not os.path.exists(sp):  # yeni oturum: 3 günden eski durum dosyalarını temizle (hafif)
        try:
            for fn in os.listdir(out):
                if fn.startswith("state-") and time.time() - os.path.getmtime(os.path.join(out, fn)) > 3 * 86400:
                    os.remove(os.path.join(out, fn))
        except Exception:
            pass
    st = load_state(sp)
    adv = advise(st, tool, ti, size)
    if adv:
        rec["adv"] = adv[0]
    with open(os.path.join(out, time.strftime("%Y-%m-%d") + ".jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    try:
        with open(sp, "w", encoding="utf-8") as f:
            json.dump(st, f)
    except Exception:
        pass
    if adv:
        sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": adv[1]}}, ensure_ascii=False))


try:
    main()
except Exception:
    pass
sys.exit(0)
