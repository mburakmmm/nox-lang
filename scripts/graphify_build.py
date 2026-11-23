#!/usr/bin/env python3
"""Kod grafı (LLM'siz, AST): `graphify-out/graph.json` + `GRAPH_REPORT.md` üretir. Kullanım: ~/.local/bin/graphify'ın yorumlayıcısıyla
   $(head -1 ~/.local/bin/graphify | tr -d '#!') scripts/graphify_build.py [--force]
Doküman/görüntü anlamsal çıkarımı bu betiğin işi DEĞİL (token harcar): `/graphify . --update` ile ayrıca yapılır.
Toplulukları etiketlemez (etiket `graphify-out/.graphify_labels.json`dan okunur, yoksa `Community N`)."""
import json, sys, time
from pathlib import Path
from graphify.detect import detect
from graphify.extract import collect_files, extract
from graphify.build import build_from_json
from graphify.cluster import cluster, score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate
from graphify.export import to_json
from graphify.paths import out_path
from graphify.watch import _read_build_excludes, _read_build_gitignore

def nox_supplement(root, code_files, nodes, edges):
    """Python gramerinin göremediği Nox yapıları: `extern def` (FFI sınırı), `enum`, `protocol`. Düğüm kimlikleri graphify'ın şemasıyla aynıdır
    (`<dosya_yolu_alt_çizgili>_<ad>`); `extern def` adı bir Zig `export fn` ile aynı simgeyse `binds_ffi` kenarı (Nox <-> Zig köprüsü) eklenir."""
    import re
    ident = lambda rel: re.sub(r"[^0-9A-Za-z]+", "_", rel[: rel.rfind(".")]).strip("_").lower()
    have = {n["id"] for n in nodes}
    zig_by_label = {}
    for n in nodes:
        if n.get("source_file", "").endswith(".zig") and n["label"].endswith("()"):
            zig_by_label.setdefault(n["label"], []).append(n["id"])
    pat = re.compile(r"^(extern def|enum|protocol)\s+(\w+)", re.M)
    added = binds = 0
    for f in code_files:
        f = Path(f)
        if f.suffix != ".nox":
            continue
        rel = str(f.relative_to(root))
        fid = ident(rel)
        text = f.read_text(encoding="utf-8", errors="replace")
        for m in pat.finditer(text):
            kind, name = m.group(1), m.group(2)
            nid = f"{fid}_{name.lower()}"
            line = text.count("\n", 0, m.start()) + 1
            if nid not in have:
                have.add(nid)
                label = f"{name}()" if kind == "extern def" else name
                nodes.append({"id": nid, "label": label, "file_type": "code", "source_file": rel, "source_location": f"L{line}", "_origin": "ast", "_nox_kind": kind})
                edges.append({"source": fid, "target": nid, "relation": "contains", "confidence": "EXTRACTED", "confidence_score": 1.0, "_origin": "ast", "source_file": rel, "source_location": f"L{line}", "weight": 1.0})
                added += 1
            if kind == "extern def":
                for zid in zig_by_label.get(f"{name}()", [])[:3]:
                    edges.append({"source": nid, "target": zid, "relation": "binds_ffi", "confidence": "EXTRACTED", "confidence_score": 1.0, "_origin": "ast", "source_file": rel, "source_location": f"L{line}", "weight": 1.0})
                    binds += 1
    # selfhost köprüsü: Zig tarafındaki `extern fn <modül>_nox_<ad>` (compiler/selfhost_glue.zig, tests) <-> `selfhost/<modül>.nox` içindeki `def nox_<ad>` (C simgesi modül önekli).
    by_file_label = {(n.get("source_file"), n["label"]): n["id"] for n in nodes if (n.get("source_file") or "").startswith("selfhost/") and n["label"].endswith("()")}
    bridge = re.compile(r"^(lexer|parser|formatter|ast_schema)_(nox_\w+)\(\)$")
    for n in list(nodes):
        m = bridge.match(n["label"]) if (n.get("source_file") or "").endswith(".zig") else None
        tgt = by_file_label.get((f"selfhost/{m.group(1)}.nox", f"{m.group(2)}()")) if m else None
        if tgt:
            edges.append({"source": n["id"], "target": tgt, "relation": "binds_ffi", "confidence": "EXTRACTED", "confidence_score": 1.0, "_origin": "ast", "source_file": n["source_file"], "source_location": n.get("source_location", "L1"), "weight": 1.0})
            binds += 1
    print(f"Nox ek çıkarım: {added} düğüm (extern def/enum/protocol), {binds} Nox<->Zig binds_ffi kenarı")



def main():
    root = Path(__file__).resolve().parent.parent
    force = "--force" in sys.argv
    out = root / "graphify-out"
    out.mkdir(exist_ok=True)
    t0 = time.time()
    det = detect(root, extra_excludes=_read_build_excludes(out_path()), gitignore=_read_build_gitignore(out_path()))
    code = []
    for f in det.get("files", {}).get("code", []):
        code.extend(collect_files(Path(f)) if Path(f).is_dir() else [Path(f)])
    res = extract(code, cache_root=root, root=root)


    nox_supplement(root, code, res["nodes"], res["edges"])
    merged = {"nodes": res["nodes"], "edges": res["edges"], "hyperedges": [], "input_tokens": 0, "output_tokens": 0}
    G = build_from_json(merged, root=str(root), directed=False)
    if G.number_of_nodes() == 0:
        raise SystemExit("boş graf")
    communities = cluster(G)
    cohesion = score_all(G, communities)
    # Etiket: topluluğun baskın dizini + en yüksek dereceli iki düğümün adı (deterministik, LLM'siz). `.graphify_labels.json` varsa elle yazılanlar önceliklidir.
    import collections
    def auto_label(cid, members):
        dirs = collections.Counter("/".join((G.nodes[m].get("source_file") or "?").split("/")[:2]) for m in members)
        top = sorted(members, key=lambda m: -G.degree(m))[:2]
        names = ", ".join(G.nodes[m].get("label", m).strip(".()") for m in top)
        return f"{dirs.most_common(1)[0][0]} · {names}"
    lab_path = out / ".graphify_labels.json"
    manual = {int(k): v for k, v in json.loads(lab_path.read_text(encoding="utf-8")).items()} if lab_path.exists() else {}
    labels = {cid: manual.get(cid) or auto_label(cid, members) for cid, members in communities.items()}
    gods = god_nodes(G)
    surprises = surprising_connections(G, communities)
    questions = suggest_questions(G, communities, labels)
    if not to_json(G, communities, str(out / "graph.json"), force=force, community_labels=labels):
        raise SystemExit("graph.json küçülürdü; bilerek ise --force")
    (out / "GRAPH_REPORT.md").write_text(generate(G, communities, cohesion, labels, gods, surprises, det, {"input": 0, "output": 0}, str(root), suggested_questions=questions), encoding="utf-8")
    print(f"graf: {G.number_of_nodes()} düğüm, {G.number_of_edges()} kenar, {len(communities)} topluluk, {len(code)} kod dosyası, {time.time()-t0:.0f} sn")


if __name__ == "__main__":
    main()
