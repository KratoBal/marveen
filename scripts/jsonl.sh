#!/usr/bin/env bash
#
# JSONL elemzo helper a flottanak. Egy soronkent egy JSON objektumot tartalmazo
# fajlbol ertekeket gyujt ki, szamol es csoportosit.
#
# MIERT LETEZIK: a tartalmi agensek szandekosan NEM kapnak altalanos futtatasi jogot
# (python3, awk, jq), mert azzal a tiltolista gyakorlatilag megszunne. Ehelyett
# nevesitett, atnezett eszkozoket kapnak. Ezt polip kerte 2026-08-16 ejjel, miutan
# lement neki 1890 termek adata es kiderult, hogy grep-pel sorokat tud szamolni,
# de csoportositani nem.
#
# BIZTONSAG: csak OLVAS es a megadott kimeneti fajlba IR. Nem hivja a halozatot,
# nem futtat mas parancsot, nem ertekel ki felhasznaloi kifejezest.
#
# MEZO-UTVONAL: pontokkal, pl. Sku, Name, Prices.Price.Gross, Categories.Category.Name.
# Ha az uton barhol LISTA all, a szkript MINDEN elemen vegigmegy -- egy sorbol tobb
# ertek is szarmazhat. Ez szandekos: egy termek tobb kategoriaban is allhat.
#
# Hasznalat:
#   jsonl.sh values      <fajl.jsonl> <mezo.utvonal> <kimenet.tsv>
#        -> sorszam <tab> ertek   (minden elofordulas)
#   jsonl.sh dupes       <fajl.jsonl> <mezo.utvonal> <kimenet.tsv>
#        -> csak az ISMETLODO ertekek: ertek <tab> darab <tab> sorszamok
#   jsonl.sh count-filled <fajl.jsonl> <mezo.utvonal>
#        -> hany sorban van kitoltve, hany sorban ures vagy hianyzik
#   jsonl.sh histogram   <fajl.jsonl> <mezo.utvonal> [kimenet.tsv]
#        -> ertek <tab> darab, gyakorisag szerint csokkenoen
#   jsonl.sh stats       <fajl.jsonl> <mezo.utvonal>
#        -> szamszeru mezore: darab, min, max, atlag, median, osszeg
#   jsonl.sh pair        <fajl.jsonl> <mezo.A> <mezo.B> [kimenet.tsv]
#        -> ket mezo EGYUTT, ha KOZOS SZULOBEN allnak (pl. egy statusz Neve es Erteke).
#           Kiirja a parok gyakorisagat is. Ez kell akkor, ha egy listas mezoben
#           a nev es az ertek osszetartozasa szamit, es a kulon lekerdezes elveszti.
#   jsonl.sh filter      <fajl.jsonl> <mezo.utvonal> <ertek> [kimenet.jsonl]
#        -> azok a sorok, ahol a mezo felveszi az erteket (fajlnev nelkul csak sorszamok)
#   jsonl.sh count-prefix <fajl.jsonl> <mezo.utvonal> <elotag> [kimenet.tsv]
#        -> hany EGYEDI SOR-ban van olyan ertek, ami az elotaggal kezdodik (fa-agra).
#           Egy sor egyszer szamit, barhany illeszkedo erteke van. A histogram
#           ELOFORDULAST szamol, ezert az alkategoriak osszeadasa tobbszorosen szamol.
#   jsonl.sh fields      <fajl.jsonl> [mintavetel]
#        -> milyen mezo-utvonalak leteznek egyaltalan (alapertelmezes: elso 200 sor)
#
# Kimenet: hiba eseten "FAIL <ok>" a stderr-en, exit 1.
set -uo pipefail

die() { echo "FAIL $*" >&2; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  values|dupes|count-filled|histogram|stats|fields|pair|filter|count-prefix) ;;
  *) die "ismeretlen parancs: '${cmd}' -- values | dupes | count-filled | histogram | stats | pair | filter | count-prefix | fields" ;;
esac

JSONL_CMD="$cmd" python3 - "$@" <<'PYEOF'
import json, os, sys
from collections import Counter, defaultdict

CMD = os.environ["JSONL_CMD"]
a = sys.argv[1:]


def die(m):
    print("FAIL " + m, file=sys.stderr)
    raise SystemExit(1)


if not a:
    die("hianyzik a fajlnev")
PATH_FILE = a[0]
if not os.path.isfile(PATH_FILE):
    die("nincs ilyen fajl: " + PATH_FILE)


def rows():
    """Soronkent egy JSON objektum. A hibas sort nem nyeljuk le, hanem jelentjuk."""
    bad = 0
    with open(PATH_FILE, encoding="utf-8") as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield i, json.loads(line)
            except ValueError:
                bad += 1
                if bad <= 3:
                    print("FIGYELEM: a %d. sor nem ervenyes JSON, kihagyva" % i, file=sys.stderr)
    if bad > 3:
        print("FIGYELEM: osszesen %d hibas sor" % bad, file=sys.stderr)


def dig(obj, parts):
    """Vegigmegy a mezo-utvonalon. Listanal MINDEN agat bejarja, ezert listat ad vissza."""
    if not parts:
        if isinstance(obj, (dict, list)):
            return []          # egy reszfa nem ertek; a levelekig kell menni
        return [] if obj is None else [str(obj)]
    head, rest = parts[0], parts[1:]
    if isinstance(obj, list):
        out = []
        for it in obj:
            out.extend(dig(it, parts))
        return out
    if isinstance(obj, dict) and head in obj:
        return dig(obj[head], rest)
    return []


def path_parts(p):
    parts = [x for x in p.split(".") if x]
    if not parts:
        die("ures mezo-utvonal")
    return parts


def out_open(name):
    try:
        return open(name, "w", encoding="utf-8")
    except OSError as e:
        die("nem tudom irni a kimenetet: %s" % e)


def nodes_at(obj, parts):
    """A megadott utvonalon allo CSOMOPONTOK (nem levelek). Listat kibont."""
    if isinstance(obj, list):
        out = []
        for it in obj:
            out.extend(nodes_at(it, parts))
        return out
    if not parts:
        return [obj]
    head, rest = parts[0], parts[1:]
    if isinstance(obj, dict) and head in obj:
        return nodes_at(obj[head], rest)
    return []


if CMD == "pair":
    if len(a) < 3:
        die("hasznalat: jsonl.sh pair <fajl.jsonl> <mezo.A> <mezo.B> [kimenet.tsv]")
    pa, pb = path_parts(a[1]), path_parts(a[2])
    # A ket mezot a KOZOS SZULOJUKNEL kell osszeparositani, kulonben elveszik, hogy
    # melyik ertek melyik nevhez tartozik. barracuda kerte 2026-08-16: a UNAS Statuses
    # blokkjaban a Name es a Value kulon lekerdezve mar nem parosithato vissza.
    i = 0
    while i < min(len(pa), len(pb)) and pa[i] == pb[i]:
        i += 1
    common, ra, rb = pa[:i], pa[i:], pb[i:]
    if not ra or not rb:
        die("a ket mezo egymas resze; parositashoz kulonbozo levelek kellenek")
    pairs = Counter()
    rowsout = []
    for ln, obj in rows():
        for node in nodes_at(obj, common):
            va = [v for v in dig(node, ra)]
            vb = [v for v in dig(node, rb)]
            if len(va) == 1 and len(vb) == 1:
                pairs[(va[0], vb[0])] += 1
                rowsout.append((ln, va[0], vb[0]))
            elif va or vb:
                # Nem egy-egy: ezt NEM talaljuk ki. Jelezzuk, es kihagyjuk.
                pairs[("<nem egyertelmu par>", "%d:%d" % (len(va), len(vb)))] += 1
    if len(a) > 3:
        with out_open(a[3]) as out:
            out.write("sor\t%s\t%s\n" % (a[1], a[2]))
            for ln, x, y in rowsout:
                out.write("%d\t%s\t%s\n" % (ln, x.replace("\t", " "), y.replace("\t", " ")))
        print("%d par -> %s" % (len(rowsout), a[3]))
    print("# par-gyakorisag (%s + %s)" % (a[1], a[2]))
    for (x, y), n in pairs.most_common(100):
        print("%s\t%s\t%d" % (x.replace("\t", " "), y.replace("\t", " "), n))

elif CMD == "filter":
    if len(a) < 3:
        die("hasznalat: jsonl.sh filter <fajl.jsonl> <mezo.utvonal> <ertek> [kimenet.jsonl]")
    parts = path_parts(a[1])
    want = a[2]
    hits = []
    out = out_open(a[3]) if len(a) > 3 else None
    for ln, obj in rows():
        if want in dig(obj, parts):
            hits.append(ln)
            if out:
                out.write(json.dumps(obj, ensure_ascii=False) + "\n")
    if out:
        out.close()
        print("%d sor -> %s" % (len(hits), a[3]))
    else:
        print("%d talalat" % len(hits))
        print(",".join(str(x) for x in hits[:500]))
        if len(hits) > 500:
            print("# ... tovabbi %d, adj meg kimeneti fajlt" % (len(hits) - 500))

elif CMD == "count-prefix":
    # MIERT KELL: a histogram ELOFORDULAST szamol, nem termeket. Egy termek tobb
    # kategoriaban is all, tehat a "Gerinctelenek" es a "Gerinctelenek|Csigak" sorok
    # osszeadasa TOBBSZOROSEN szamol -- korall merte ki 2026-08-18 ejjel, a korall-agon
    # 18+4+5=27 jott ki 20 helyett. Ez a parancs EGYEDI SOROKAT szamol: egy termek
    # egyszer szamit, barhany illeszkedo kategorianeve van.
    if len(a) < 3:
        die("hasznalat: jsonl.sh count-prefix <fajl.jsonl> <mezo.utvonal> <elotag> [kimenet.tsv]")
    parts = path_parts(a[1])
    pref = a[2]
    hits = []
    for ln, obj in rows():
        vals = [v for v in dig(obj, parts) if isinstance(v, str)]
        # Pontos egyezes VAGY az elotag utan fa-elvalaszto all. A puszta startswith
        # ("Halak" -> "Halakedel") mas agat is behuzna.
        if any(v == pref or v.startswith(pref + "|") for v in vals):
            hits.append((ln, next(v for v in vals if v == pref or v.startswith(pref + "|"))))
    if len(a) > 3:
        with out_open(a[3]) as f:
            f.write("sorszam\tillesztett_kategoria\n")
            for ln, v in hits:
                f.write("%d\t%s\n" % (ln, v))
        print("%d egyedi sor -> %s" % (len(hits), a[3]))
    else:
        print(len(hits))

elif CMD == "fields":
    limit = int(a[1]) if len(a) > 1 else 200
    seen = Counter()
    n = 0

    def walk(o, prefix):
        if isinstance(o, dict):
            for k, v in o.items():
                walk(v, prefix + "." + k if prefix else k)
        elif isinstance(o, list):
            for it in o:
                walk(it, prefix)
        else:
            seen[prefix] += 1

    for i, obj in rows():
        walk(obj, "")
        n += 1
        if n >= limit:
            break
    print("# %d sor mintavetelezve, %d kulonbozo mezo-utvonal" % (n, len(seen)))
    for p, c in sorted(seen.items(), key=lambda x: (-x[1], x[0])):
        print("%s\t%d" % (p, c))

elif CMD == "count-filled":
    if len(a) < 2:
        die("hasznalat: jsonl.sh count-filled <fajl.jsonl> <mezo.utvonal>")
    parts = path_parts(a[1])
    filled = empty = total = 0
    for i, obj in rows():
        total += 1
        vals = [v for v in dig(obj, parts) if v.strip() != ""]
        if vals:
            filled += 1
        else:
            empty += 1
    print("mezo\t%s" % a[1])
    print("sor osszesen\t%d" % total)
    print("kitoltve\t%d" % filled)
    print("ures vagy hianyzik\t%d" % empty)
    if total:
        print("kitoltottseg\t%.1f%%" % (100.0 * filled / total))

elif CMD == "values":
    if len(a) < 3:
        die("hasznalat: jsonl.sh values <fajl.jsonl> <mezo.utvonal> <kimenet.tsv>")
    parts = path_parts(a[1])
    n = 0
    with out_open(a[2]) as out:
        out.write("sor\tertek\n")
        for i, obj in rows():
            for v in dig(obj, parts):
                out.write("%d\t%s\n" % (i, v.replace("\t", " ").replace("\n", " ")))
                n += 1
    print("%d ertek -> %s" % (n, a[2]))

elif CMD == "dupes":
    if len(a) < 3:
        die("hasznalat: jsonl.sh dupes <fajl.jsonl> <mezo.utvonal> <kimenet.tsv>")
    parts = path_parts(a[1])
    where = defaultdict(list)
    for i, obj in rows():
        for v in set(dig(obj, parts)):      # egy soron belul ne szamitson duplanak
            v = v.strip()
            if v:
                where[v].append(i)
    dup = {v: ls for v, ls in where.items() if len(ls) > 1}
    with out_open(a[2]) as out:
        out.write("ertek\tdarab\tsorszamok\n")
        for v, ls in sorted(dup.items(), key=lambda x: (-len(x[1]), x[0])):
            out.write("%s\t%d\t%s\n" % (v.replace("\t", " "), len(ls),
                                        ",".join(str(x) for x in ls[:50])))
    print("%d kulonbozo ertek ismetlodik, osszesen %d sorban -> %s"
          % (len(dup), sum(len(x) for x in dup.values()), a[2]))

elif CMD == "histogram":
    if len(a) < 2:
        die("hasznalat: jsonl.sh histogram <fajl.jsonl> <mezo.utvonal> [kimenet.tsv]")
    parts = path_parts(a[1])
    c = Counter()
    for i, obj in rows():
        for v in dig(obj, parts):
            v = v.strip()
            if v:
                c[v] += 1
    lines = ["%s\t%d" % (v.replace("\t", " "), n) for v, n in c.most_common()]
    if len(a) > 2:
        with out_open(a[2]) as out:
            out.write("ertek\tdarab\n")
            out.write("\n".join(lines) + ("\n" if lines else ""))
        print("%d kulonbozo ertek -> %s" % (len(c), a[2]))
    else:
        print("# %d kulonbozo ertek" % len(c))
        print("\n".join(lines[:200]))
        if len(lines) > 200:
            print("# ... tovabbi %d sor, adj meg kimeneti fajlt a teljes listahoz" % (len(lines) - 200))

elif CMD == "stats":
    if len(a) < 2:
        die("hasznalat: jsonl.sh stats <fajl.jsonl> <mezo.utvonal>")
    parts = path_parts(a[1])
    nums, skipped = [], 0
    for i, obj in rows():
        for v in dig(obj, parts):
            try:
                nums.append(float(v))
            except ValueError:
                skipped += 1
    if not nums:
        die("egyetlen szamma alakithato erteket sem talaltam ezen az utvonalon: " + a[1])
    nums.sort()
    n = len(nums)
    med = nums[n // 2] if n % 2 else (nums[n // 2 - 1] + nums[n // 2]) / 2
    print("mezo\t%s" % a[1])
    print("darab\t%d" % n)
    print("min\t%g" % nums[0])
    print("max\t%g" % nums[-1])
    print("atlag\t%g" % (sum(nums) / n))
    print("median\t%g" % med)
    print("osszeg\t%g" % sum(nums))
    if skipped:
        print("nem szam\t%d  (ezeket kihagytam)" % skipped)
PYEOF
