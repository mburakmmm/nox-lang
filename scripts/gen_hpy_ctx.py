import re, sys

path = ".hpy-venv/lib/python3.14/site-packages/hpy/devel/include/hpy/universal/autogen_ctx.h"
with open(path) as f:
    text = f.read()

m = re.search(r"struct _HPyContext_s \{(.*?)\n\};", text, re.S)
body = m.group(1)

raw_lines = [l.strip() for l in body.splitlines() if l.strip()]
lines = []
for l in raw_lines:
    l = re.sub(r"//.*$", "", l).strip()
    if not l:
        continue
    lines.append(l.rstrip(";").strip())

out = []
for line in lines:
    fm = re.match(r"^(.*?)\(\*(\w+)\)\((.*)\)$", line)
    if fm:
        name = fm.group(2)
        out.append((name, "fn"))
        continue
    sm = re.match(r"^(.*?)(\w+)$", line)
    if sm:
        typ = sm.group(1).strip()
        name = sm.group(2).strip()
        if typ == "const char *":
            out.append((name, "str"))
        elif typ == "HPy":
            out.append((name, "HPy"))
        elif typ == "int":
            out.append((name, "int"))
        elif typ == "void *":
            out.append((name, "voidp"))
        else:
            out.append((name, "other:" + typ))
        continue
    print("UNMATCHED:", line, file=sys.stderr)

for name, kind in out:
    if kind == "HPy":
        print(f"    {name}: HPy = HPy_NULL,")
    elif kind == "str":
        print(f'    {name}: ?[*:0]const u8 = null,')
    elif kind == "int":
        print(f"    {name}: c_int = 0,")
    elif kind == "voidp":
        print(f"    {name}: ?*anyopaque = null,")
    elif kind == "fn":
        print(f"    {name}: ?*const anyopaque = null,")
    else:
        print(f"    {name}: ?*const anyopaque = null, // {kind}")

print(f"\nTOTAL FIELDS: {len(out)}", file=sys.stderr)
