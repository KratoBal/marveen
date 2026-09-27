#!/usr/bin/env bash
#
# Vonalkod- es azonosito-elemzo helper a flottanak. EAN ellenorzo jegy, szarmaztatott
# kodok felismerese, utkozes-vizsgalat es betoltendo CSV eloallitasa JSONL termekexportbol.
#
# MIERT LETEZIK: a tartalmi agensek szandekosan NEM kapnak altalanos python3 jogot
# (2026-08-17, Balazs dontese: "marad a mostani, tedd bele a helper szkriptekbe").
# Ezen a napon polip a vonalkod-atvezeteshez sajat Python-szkripteket irt, es minden
# futasnal engedelykeresen allt meg -- napi tobb orat vesztettunk vele. Amit ott kezzel
# megirt, az itt nevesitett, atnezett parancskent all rendelkezesre.
#
# BIZTONSAG: csak OLVAS es a megadott kimeneti fajlba IR. Nem hivja a halozatot,
# nem futtat mas parancsot, nem ertekel ki felhasznaloi kifejezest.
#
# MEZO-UTVONAL: pontokkal, ugyanugy mint a jsonl.sh-ban, pl. Sku, Name.
# Ha az uton barhol LISTA all, a szkript minden elemen vegigmegy.
# NEVESITETT PARAMETER: szogletes zarojellel, pl. Params.Param[Gyartoi cikkszam]
#   -> a lista azon elemenek Value mezoje, aminek a Name-je a zarojelben allo szoveg.
#      (Ekezet szamit. A UNAS-exportban ez az alak adja a termek-parametereket.)
#
# EGY MERT TANULSAG, AMI A SZKRIPTBE VAN EPITVE (2026-08-17):
# Ket ERVENYES EAN-13 soha nem oszthatja meg az elso 12 jegyet, mert a 13. jegyet a
# masik 12 hatarozza meg. Ezert a csalad-vizsgalat CSAK akkor mond barmit, ha az
# ERVENYTELEN kodokra is ranez -- egy csak-ervenyeseken futo valtozat matematikailag
# nem tud talalni. A "families" parancs ezert mindig a teljes keszleten dolgozik.
#
# Hasznalat:
#   barcode.sh check      <fajl.jsonl> <mezo> [kimenet.tsv]
#        -> minden ertek minositese: ervenyes EAN / hibas ellenorzo jegy / nem EAN alaku / ures
#   barcode.sh families   <fajl.jsonl> <mezo> [kimenet.tsv]
#        -> azonos elso 12 jegyu, KULONBOZO kodok. Ez fogja meg az utolso jegy
#           atirasaval szarmaztatott belso kodokat. Megjeloli, melyik tag az ervenyes.
#   barcode.sh collisions <fajl.jsonl> <mezoA> <mezoB> [kimenet.tsv]
#        -> az A mezo olyan ertekei, amik MAS rekordon mar B-kent szerepelnek.
#           (Pl. a gyartoi cikkszam mezoben egy masik termek cikkszama all.)
#   barcode.sh near       <fajl.jsonl> <mezo> [kimenet.tsv]
#        -> kodparok, amik az elso 12 jegy kozul PONTOSAN EGYBEN ternek el, azonos
#           ellenorzo jeggyel. Ez a szam BELSEJEBEN torteno atirast fogja meg.
#           ATNEZENDO lista, nem tiltolista: ket valodi EAN is elterhet egy jegyben.
#   barcode.sh loader     <fajl.jsonl> <mezo> <kimenet.csv> [--csalad-nelkul]
#        -> betoltendo CSV: sku,barcode,isPrimary. Csak ervenyes es egyedi kodok.
#           Ha barmelyik kapu bukik, a fajl NEM keszul el es a szkript hibaval all le.
#           --csalad-nelkul: a varians-csaladba eso kodokat visszatartja, es kulon
#           fajlba irja (<kimenet>-visszatartott.tsv).
#
# Kimenet: hiba eseten "FAIL <ok>" a stderr-en, exit 1.
set -uo pipefail

die() { echo "FAIL $*" >&2; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  check|families|collisions|near|loader) ;;
  *) die "ismeretlen parancs: '${cmd}' -- check | families | collisions | near | loader" ;;
esac

BARCODE_CMD="$cmd" python3 - "$@" <<'PYEOF'
import csv
import json
import os
import re
import sys
from collections import Counter, defaultdict

CMD = os.environ["BARCODE_CMD"]
a = sys.argv[1:]

# Az O(n^2) parkereses felso hatara. Folotte inkabb megtagadjuk, mint hogy egy agens
# eszrevetlenul percekre bealljon egy helper-hivasban.
NEAR_MAX = 20000


def die(m):
    print("FAIL " + m, file=sys.stderr)
    raise SystemExit(1)


def need(n, usage):
    if len(a) < n:
        die("hianyzo argumentum -- " + usage)


SEG = re.compile(r"^([^\[]+)(?:\[(.+)\])?$")


def extract(obj, path):
    """A mezo-utvonalon talalt OSSZES erteket adja vissza, listakon vegigmenve."""
    cur = [obj]
    for raw in path.split("."):
        m = SEG.match(raw)
        if not m:
            die("ertelmezhetetlen mezo-utvonal: " + path)
        key, named = m.group(1), m.group(2)
        nxt = []
        for node in cur:
            if isinstance(node, list):
                items = node
            else:
                items = [node]
            for it in items:
                if not isinstance(it, dict):
                    continue
                val = it.get(key)
                if val is None:
                    continue
                if named is None:
                    nxt.append(val)
                else:
                    # nevesitett parameter: Name == named -> Value
                    for cand in (val if isinstance(val, list) else [val]):
                        if isinstance(cand, dict) and str(cand.get("Name", "")).strip() == named:
                            v = cand.get("Value")
                            if v is not None:
                                nxt.append(v)
        cur = nxt
        if not cur:
            return []
    out = []
    for v in cur:
        for item in (v if isinstance(v, list) else [v]):
            if isinstance(item, (dict, list)):
                continue
            out.append(str(item).strip())
    return out


def first(obj, path):
    vals = extract(obj, path)
    return vals[0] if vals else ""


def load(path):
    if not os.path.exists(path):
        die("nincs ilyen fajl: " + path)
    rows = []
    with open(path, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                die("a %d. sor nem ervenyes JSON" % i)
    if not rows:
        die("ures fajl: " + path)
    return rows


def ean_ok(c):
    """EAN-13 es EAN-8 ellenorzo jegy. Mas hosszra mindig False."""
    if not c.isdigit():
        return False
    if len(c) == 13:
        s = sum(int(d) * (1 if i % 2 == 0 else 3) for i, d in enumerate(c[:12]))
        return (10 - s % 10) % 10 == int(c[12])
    if len(c) == 8:
        s = sum(int(d) * (3 if i % 2 == 0 else 1) for i, d in enumerate(c[:7]))
        return (10 - s % 10) % 10 == int(c[7])
    return False


def classify(c):
    if not c:
        return "ures"
    if not c.isdigit():
        return "nem EAN alaku"
    if len(c) not in (8, 13):
        return "nem EAN alaku"
    return "ervenyes" if ean_ok(c) else "hibas ellenorzo jegy"


def label_of(rec):
    """Emberi cimke a riportokhoz. A UNAS-exportban ez a Name."""
    for key in ("Name", "name", "Title", "title"):
        v = rec.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def write_tsv(path, header, rows_):
    with open(path, "w", encoding="utf-8") as f:
        f.write("\t".join(header) + "\n")
        for r in rows_:
            f.write("\t".join(str(x).replace("\t", " ") for x in r) + "\n")
    print("kiirva: %s (%d sor)" % (path, len(rows_)))


# --------------------------------------------------------------------------------------
if CMD == "check":
    need(2, "check <fajl.jsonl> <mezo> [kimenet.tsv]")
    rows = load(a[0])
    field = a[1]
    out = []
    tally = Counter()
    for i, rec in enumerate(rows, 1):
        vals = extract(rec, field) or [""]
        for v in vals:
            k = classify(v)
            tally[k] += 1
            out.append((i, v, k, label_of(rec)[:70]))
    print("=== ELLENORZO JEGY: %s ===" % field)
    print("rekord:                   %5d" % len(rows))
    print("vizsgalt ertek:           %5d" % len(out))
    for k in ("ervenyes", "hibas ellenorzo jegy", "nem EAN alaku", "ures"):
        print("  %-22s  %5d" % (k, tally.get(k, 0)))
    if len(a) > 2:
        write_tsv(a[2], ["sorszam", "ertek", "minosites", "termeknev"], out)

# --------------------------------------------------------------------------------------
elif CMD == "families":
    need(2, "families <fajl.jsonl> <mezo> [kimenet.tsv]")
    rows = load(a[0])
    field = a[1]
    by_prefix = defaultdict(list)
    total13 = 0
    for rec in rows:
        for v in extract(rec, field):
            if v.isdigit() and len(v) == 13:
                total13 += 1
                by_prefix[v[:12]].append((v, label_of(rec)))
    fams = {}
    for p, members in by_prefix.items():
        uniq = {}
        for code, name in members:
            uniq.setdefault(code, name)
        if len(uniq) > 1:
            fams[p] = uniq
    n_prod = sum(len(u) for u in fams.values())
    print("=== VARIANS-CSALADOK: %s ===" % field)
    print("13 jegyu szam osszesen:            %5d" % total13)
    print("azonos elso 12 jegyu csalad:       %5d" % len(fams))
    print("ebbe eso KULONBOZO kod:            %5d" % n_prod)
    print()
    print("Ket ERVENYES EAN-13 nem lehet azonos elso 12 jeggyel, tehat csaladonkent")
    print("legfeljebb egy tag ervenyes -- a tobbi szarmaztatott, kitalalt kod.")
    print()
    out = []
    for p, uniq in sorted(fams.items(), key=lambda x: -len(x[1])):
        print("  %s*  (%d kod)" % (p, len(uniq)))
        for code, name in sorted(uniq.items()):
            mark = "ERVENYES" if ean_ok(code) else "szarmaztatott"
            print("      %-14s %-14s %s" % (code, mark, name[:52]))
            out.append((p, code, mark, name))
    if not fams:
        print("  nincs ilyen csalad")
    if len(a) > 2:
        write_tsv(a[2], ["elotag", "kod", "minosites", "termeknev"], out)

# --------------------------------------------------------------------------------------
elif CMD == "collisions":
    need(3, "collisions <fajl.jsonl> <mezoA> <mezoB> [kimenet.tsv]")
    rows = load(a[0])
    fa, fb = a[1], a[2]
    owner = {}
    for idx, rec in enumerate(rows):
        for v in extract(rec, fb):
            if v:
                owner.setdefault(v, (idx, label_of(rec)))
    out = []
    for idx, rec in enumerate(rows):
        for v in extract(rec, fa):
            if not v:
                continue
            hit = owner.get(v)
            if hit and hit[0] != idx:
                out.append((v, hit[1], first(rec, fb), label_of(rec)))
    print("=== UTKOZES: '%s' erteke mar '%s' egy MASIK rekordon ===" % (fa, fb))
    print("talalat: %d" % len(out))
    print()
    for v, holder, own_b, own_name in out[:40]:
        print("  %s" % v)
        print("      mar hasznalja: %s" % holder[:66])
        print("      ra akarnank tenni: %-14s %s" % (own_b, own_name[:52]))
    if len(out) > 40:
        print("  ... es meg %d sor (a teljes lista a kimeneti fajlban)" % (len(out) - 40))
    if len(a) > 3:
        write_tsv(a[3], [fa + "_erteke", "mar_ezen_a_rekordon", "erintett_" + fb,
                         "erintett_neve"], out)

# --------------------------------------------------------------------------------------
elif CMD == "near":
    need(2, "near <fajl.jsonl> <mezo> [kimenet.tsv]")
    rows = load(a[0])
    field = a[1]
    name_of = {}
    for rec in rows:
        for v in extract(rec, field):
            if v.isdigit() and len(v) == 13:
                name_of.setdefault(v, label_of(rec))
    codes = sorted(name_of)
    if len(codes) > NEAR_MAX:
        die("tul sok kod a parkereseshez (%d > %d) -- szurd elobb a fajlt"
            % (len(codes), NEAR_MAX))
    buckets = defaultdict(list)
    for c in codes:
        buckets[c[12]].append(c)
    out = []
    for _, group in buckets.items():
        for i in range(len(group)):
            for j in range(i + 1, len(group)):
                x, y = group[i], group[j]
                if sum(1 for p, q in zip(x[:12], y[:12]) if p != q) == 1:
                    out.append((x, "ervenyes" if ean_ok(x) else "hibas", name_of[x][:44],
                                y, "ervenyes" if ean_ok(y) else "hibas", name_of[y][:44]))
    print("=== EGY JEGYBEN ELTERO KODPAROK: %s ===" % field)
    print("vizsgalt kulonbozo kod: %d" % len(codes))
    print("par, ami az elso 12 jegy kozul PONTOSAN egyben ter el, azonos ellenorzo jeggyel: %d"
          % len(out))
    print()
    print("EZ ATNEZENDO LISTA, NEM TILTOLISTA: ket kulonbozo termek valodi EAN-ja is")
    print("elterhet egyetlen jegyben. Amire gyanus: ha az egyik tag HIBAS ellenorzo jegyu,")
    print("mert akkor valoszinuleg a masikbol irtak at.")
    print()
    for x, xs, xn, y, ys, yn in out[:40]:
        print("  %s (%s) %s" % (x, xs, xn))
        print("  %s (%s) %s" % (y, ys, yn))
        print()
    if len(a) > 2:
        write_tsv(a[2], ["kod_A", "A_minosites", "A_neve", "kod_B", "B_minosites", "B_neve"],
                  out)

# --------------------------------------------------------------------------------------
elif CMD == "loader":
    need(3, "loader <fajl.jsonl> <mezo> <kimenet.csv> [--csalad-nelkul]")
    rows = load(a[0])
    field, dest = a[1], a[2]
    hold_families = "--csalad-nelkul" in a[3:]
    for extra in a[3:]:
        if extra != "--csalad-nelkul":
            die("ismeretlen kapcsolo: " + extra)

    all13 = []
    cand = []          # (kod, termeknev)
    for rec in rows:
        for v in extract(rec, field):
            if v.isdigit() and len(v) == 13:
                all13.append(v)
            if ean_ok(v):
                cand.append((v, label_of(rec)))

    # A UNIQUE megszoritas miatt egy kodot csak akkor lehet betolteni, ha EGY rekordhoz
    # tartozik. Az osztott kodok kimaradnak, es ezt kulon ki is mondjuk.
    seen = Counter(c for c, _ in cand)
    shared = sorted({c for c, _ in cand if seen[c] > 1})
    loadable = [(c, n) for c, n in cand if seen[c] == 1]

    fam_all = Counter(s[:12] for s in all13)
    in_family = sorted({c for c, _ in loadable if fam_all[c[:12]] > 1})
    held = []
    if hold_families and in_family:
        held = [(c, n) for c, n in loadable if c in in_family]
        loadable = [(c, n) for c, n in loadable if c not in in_family]

    print("=== BETOLTENDO LISTA: %s ===" % field)
    print("rekord:                                  %5d" % len(rows))
    print("ervenyes EAN a mezoben:                  %5d" % len(cand))
    print("  ebbol tobb rekord osztozik rajta:      %5d kod (kimarad)" % len(shared))
    if hold_families:
        print("  ebbol varians-csaladba esik:           %5d kod (visszatartva)" % len(held))
    else:
        print("  ebbol varians-csaladba esik:           %5d kod (BENNE MARAD)" % len(in_family))
    print("betoltendo:                              %5d" % len(loadable))
    print()

    # ELOFELTEVES, NEM ELLENORZES: ennel a betoltesnel a cikkszam MAGA a vonalkod, ezert
    # all a kod mindket oszlopban. Ezt nem "ellenorizzuk" a kiirt fajlon, mert mindket
    # oszlop ugyanabbol a mezobol jon -- egy ilyen osszevetes soha nem tudna megbukni.
    print("ELOFELTEVES (nem ellenorzes): a '%s' mezo MAGA a vonalkod, ezert all" % field)
    print("mindket oszlopban ugyanaz az ertek.")
    print()

    gates = []
    gates.append(("minden kod atmegy az ellenorzo jegyen",
                  all(ean_ok(c) for c, _ in loadable),
                  "%d kod bukik" % sum(1 for c, _ in loadable if not ean_ok(c))))
    dupes = [c for c, n in Counter(c for c, _ in loadable).items() if n > 1]
    gates.append(("a kodok egyediek a fajlon belul", not dupes,
                  "%d kod ismetlodik" % len(dupes)))
    gates.append(("nincs ures vagy hianyzo kod", all(c for c, _ in loadable),
                  "ures kod a listaban"))
    if hold_families:
        left = [c for c, _ in loadable if fam_all[c[:12]] > 1]
        gates.append(("egyetlen betoltendo kod sem esik varians-csaladba", not left,
                      "%d kod maradt bent" % len(left)))

    print("=== KAPUK ===")
    for text, ok, detail in gates:
        print("  [%s] %-52s %s" % ("OK " if ok else "BUK", text, "" if ok else detail))
    print()
    if not all(ok for _, ok, _ in gates):
        die("kapu-ellenorzes bukott -- a CSV NEM keszult el")

    with open(dest, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["sku", "barcode", "isPrimary"])
        for c, _ in loadable:
            w.writerow([c, c, "igen"])
    print("kiirva: %s (%d sor + fejlec)" % (dest, len(loadable)))

    if held:
        base = dest[:-4] if dest.endswith(".csv") else dest
        hp = base + "-visszatartott.tsv"
        rows_ = []
        for c, n in held:
            others = sorted({s for s in all13 if s[:12] == c[:12] and s != c})
            rows_.append((c, n, "; ".join(others),
                          "ervenyes EAN, de a varians-testverek szarmaztatott kodot "
                          "hasznalnak; ha a gyarto nem ad varians-vonalkodot, a beolvasas "
                          "rossz variansra fut"))
        write_tsv(hp, ["kod", "termeknev", "csalad_tobbi_tagja", "megjegyzes"], rows_)

    if shared:
        print()
        print("OSZTOTT KOD, EZERT KIMARADT (%d):" % len(shared))
        for c in shared[:20]:
            print("  %s" % c)
PYEOF
