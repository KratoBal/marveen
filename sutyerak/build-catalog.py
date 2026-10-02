#!/usr/bin/env python3
# ANSWERS: Which GET endpoints of the Acropora OS API can Sutyerák read, with their permission and query params?
"""Build Sutyerák's endpoint catalog from the acropora-os controllers.

The catalog is what the model sees through `os_endpoints`: every GET route
that the read-only assistant session is not denied, with the permission it
requires and the query parameters the handler reads. It is a map for the
model, never a guard: the server's own AssistantReadonlyGuard and the
user's permissions decide what actually answers.

Usage: python3 build-catalog.py <acropora-os checkout> <out.json>
"""
import json
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
out = Path(sys.argv[2])
src = repo / "apps/api/src"

policy = (src / "auth/assistant-readonly.policy.ts").read_text()
denied_exact = set(re.findall(r'endpoint:\s*"([^"]+)"', policy))
prefix_block = re.search(r"ASSISTANT_FORBIDDEN_PREFIXES = \[(.*?)\]", policy, re.S)
denied_prefixes = re.findall(r'"([^"]+)"', prefix_block.group(1)) if prefix_block else []


def denied(path: str) -> bool:
    p = path.strip("/")
    return p in denied_exact or any(p == d or p.startswith(d + "/") for d in denied_prefixes)


def first_string(arg: str) -> str:
    m = re.search(r'["\']([^"\']*)["\']', arg or "")
    return m.group(1) if m else ""


dto_fields = {}
for file in src.rglob("*.ts"):
    if file.name.endswith(".spec.ts"):
        continue
    body = file.read_text()
    for cm in re.finditer(r"export class (\w+)[^{]*\{", body):
        end = body.find("\n}", cm.end())
        fields = re.findall(r"\n\s+(?:readonly\s+)?(\w+)[?!]?\s*:", body[cm.end(): end])
        dto_fields[cm.group(1)] = sorted(set(fields))

routes = []
for file in sorted(src.rglob("*.controller.ts")):
    text = file.read_text()
    cm = re.search(r"@Controller\(([^)]*)\)", text)
    if not cm:
        continue
    cprefix = first_string(cm.group(1))
    class_perm = None
    head = text[: cm.start()]
    for m in re.finditer(r"@RequirePermissions\(([^)]*)\)", text[: text.find("class ", cm.end()) if text.find("class ", cm.end()) > 0 else cm.end()]):
        class_perm = m.group(1)
    for gm in re.finditer(r"@Get\(([^)]*)\)", text):
        sub = first_string(gm.group(1))
        path = "/".join(x for x in [cprefix.strip("/"), sub.strip("/")] if x)
        if denied(path):
            continue
        after = text[gm.end(): gm.end() + 1500]
        mm = re.search(r"\n\s*(?:async\s+)?(\w+)\s*\(", after)
        method = mm.group(1) if mm else ""
        # decorators between the @Get and the method
        decos = after[: mm.start()] if mm else ""
        before = text[max(0, gm.start() - 600): gm.start()]
        perm_src = None
        pm = re.findall(r"@RequirePermissions\(([^)]*)\)", decos + before[-250:])
        if pm:
            perm_src = pm[-1]
        perms = re.findall(r"P(?:ERMISSIONS)?\.([A-Z_]+)|\"([a-z]+\.[a-z_.]+)\"", perm_src or class_perm or "")
        perms = [a or b for a, b in perms]
        sig = after[mm.end(): mm.end() + 900] if mm else ""
        sig = sig[: sig.find(")\s*{") if ")\s*{" in sig else len(sig)]
        queries = re.findall(r'@Query\(\s*["\']([^"\']+)["\']', sig)
        if re.search(r"@Query\(\s*\)", sig):
            dto = re.search(r"@Query\(\s*\)\s*\w+\s*:\s*(\w+)", sig)
            fields = dto_fields.get(dto.group(1), []) if dto else []
            queries.extend(fields or ["<" + (dto.group(1) if dto else "query object") + ">"])
        doc = ""
        dm = re.search(r"/\*\*((?:(?!\*/).)*)\*/\s*$", before, re.S)
        if dm:
            doc = re.sub(r"\s*\n\s*\*\s?", " ", dm.group(1)).strip()[:220]
        routes.append({
            "path": "/" + path,
            "handler": method,
            "permissions": perms,
            "query": queries,
            "note": doc,
            "file": str(file.relative_to(repo)),
        })

# Hungarian words per API area, so a Hungarian search term finds the route.
KEYWORDS = {
    "billing": "számla számlázás kimenő kiállított vevő bizonylat nyugta",
    "purchasing": "beszerzés bejövő számla szállító várható beérkezés rendelés",
    "integrations/nav": "nav bejövő számla adóhatóság",
    "missing-invoices": "hiányzó számla könyvelő",
    "service/worksheets": "munkalap",
    "service/jobs": "hibajegy szerviz",
    "service/assets": "eszköz eszköznyilvántartás",
    "service/material-requests": "anyagigény",
    "maintenance": "karbantartás ütemezés",
    "aquariums": "akvárium vízérték mérés",
    "partners": "partner ügyfél szerződés",
    "customers": "vevő ügyfél",
    "products": "termék cikkszám készlet",
    "stock": "készlet raktár leltár",
    "pos": "pos bolti eladás pénztár",
    "unas/orders": "rendelés webshop megrendelés",
    "integrations/gls": "gls futár utánvét elszámolás",
    "integrations/foxpost": "foxpost csomagautomata elszámolás",
    "integrations/simplepay": "simplepay kártyás fizetés elszámolás",
    "dashboard": "vezérlőpult összesítő",
    "users": "felhasználó dolgozó",
}
for r in routes:
    p = r["path"].strip("/")
    r["keywords"] = " ".join(v for k, v in KEYWORDS.items() if p.startswith(k) or ("/" + k + "/") in ("/" + p + "/"))

# The web menu (labels and routes), so "how do I ..." can name the page.
menu = []
nav = repo / "apps/web/src/components/navigation.ts"
if nav.exists():
    text = nav.read_text()
    for m in re.finditer(r'href:\s*"([^"]+)"', text):
        win = text[max(0, m.start() - 300): m.end() + 300]
        best, dist = None, 1e9
        for lm in re.finditer(r'label:\s*"([^"]+)"', win):
            if abs(lm.start() - 300) < dist:
                dist, best = abs(lm.start() - 300), lm.group(1)
        if best:
            menu.append({"href": m.group(1), "label": best})

out.write_text(json.dumps({"denied_prefixes": denied_prefixes, "denied_exact": sorted(denied_exact), "routes": routes, "menu": menu}, ensure_ascii=False, indent=1))
print(f"{len(routes)} GET routes written to {out}")
