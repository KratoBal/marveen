#!/usr/bin/env bash
# Egy MAR MEGIRT lap "Keszult:" fejlec-sorat merve allitja be, es kiirja, mennyit
# csuszott a regi ertek.
#
# MIERT LETEZIK, ES MERT SZAMOKKAL (barracuda merese, 2026-08-31 este):
# a mai lapjai kozul 21 volt ertekelheto, es EBBOL 11-ben a fejlecben allo idopont
# kesobbi volt, mint a fajl utolso irasa. A jovobe nem lehet menteni, tehat az a 11
# bizonyithatoan nem meresbol jott. Az elteresek: 3, 9, 10, 15, 16, 17, 26, 28, 34,
# 50 es 57 perc, ES MIND A TIZENEGY ELORE CSUSZIK. Nem szoras, hanem rendszeres
# torzitas: az idopont akkor kerul a szovegbe, amikor a mondatot irjuk, a fajl pedig
# kesobb keletkezik.
#
# Ugyanaz a kez, ugyanaz a delutan, a napi naploban NULLA ilyen eset -- mert ott a
# daily-log.sh meri az idot kikuldeskor. A kulonbseg nem a figyelemben van, hanem
# abban, hogy hol all eszkoz.
#
# AMIT EZ NEM OLD MEG: ha valaki a lap megirasa ELOTT futtatja. Akkor a csuszas
# masodperc nagysagrendu lesz percek helyett, tehat akkor is jobb, de a helyes
# sorrend: eloszor a lap, aztan ez.
#
# Hasznalat:
#   lap-fejlec.sh <fajl.md>
#
# Ha van mar "Keszult:" kezdetu sor, azt CSERELI, es kiirja a regi erteket meg az
# elterest. Ha nincs, beszurja az elso H1 cim utan. A tobbi sort nem erinti.
#
# Kilepesi kodok:
#   0  a fejlec a helyere kerult (a kimenet mondja meg, csere volt-e vagy beszuras)
#   2  hasznalati vagy orzo-hiba

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 1 ]; then
  echo "FAIL: pontosan egy argumentum kell." >&2
  echo "  bash /home/marveen/marveen/scripts/lap-fejlec.sh <fajl.md>" >&2
  exit 2
fi

FILE="$1"

case "$FILE" in
  -*) echo "FAIL: a fajlnev nem kezdodhet kotojellel: $FILE" >&2; exit 2 ;;
esac

if [ ! -f "$FILE" ]; then
  echo "FAIL: nincs ilyen fajl: $FILE" >&2
  echo "  Ez a szkript egy MAR MEGIRT lapot datumoz. Eloszor ird meg a lapot." >&2
  exit 2
fi

if [ ! -w "$FILE" ]; then
  echo "FAIL: nem irhato: $FILE" >&2
  exit 2
fi

NOW="$("$HERE/local-now.sh" full)" || { echo "FAIL: nem sikerult idot merni" >&2; exit 2; }

# A merest es a szerkesztest is python vegzi, hogy a lap tartalma NE menjen at a
# shellen: a lapokban idezojel, perjel es ekezet van.
FILE="$FILE" NOW="$NOW" python3 - <<'PY'
import os, re, sys

path = os.environ["FILE"]
now = os.environ["NOW"]          # "YYYY-MM-DD HH:MM:SS"
stamp = now[:16]                 # percig, masodperc nelkul

with open(path, encoding="utf-8") as fh:
    lines = fh.read().split("\n")

LINE = "**Keszult: %s (Europe/Budapest, merve)**" % stamp
pat = re.compile(r"^\**\s*K[eé]sz[uü]lt\s*[::]", re.IGNORECASE)
old_idx = next((i for i, l in enumerate(lines) if pat.match(l.strip())), None)

def drift(old_line):
    """Ha a regi sorban van egy YYYY-MM-DD HH:MM, add vissza a percbeli elterest."""
    m = re.search(r"(\d{4}-\d{2}-\d{2})[ T](\d{2}):(\d{2})", old_line)
    if not m:
        return None
    import datetime
    old = datetime.datetime(int(m.group(1)[:4]), int(m.group(1)[5:7]), int(m.group(1)[8:10]),
                            int(m.group(2)), int(m.group(3)))
    new = datetime.datetime(int(stamp[:4]), int(stamp[5:7]), int(stamp[8:10]),
                            int(stamp[11:13]), int(stamp[14:16]))
    return round((old - new).total_seconds() / 60)

if old_idx is not None:
    old_line = lines[old_idx]
    d = drift(old_line)
    lines[old_idx] = LINE
    action = "CSERE"
else:
    # az elso H1 utan, egy ures sorral elvalasztva; ha nincs H1, a fajl elejere
    h1 = next((i for i, l in enumerate(lines) if l.startswith("# ")), None)
    at = h1 + 1 if h1 is not None else 0
    ins = ([""] if at < len(lines) and lines[at].strip() != "" else []) + [LINE, ""]
    lines[at:at] = ins
    old_line, d, action = None, None, "BESZURAS"

with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))

print("%s %s" % (action, path))
print("  uj fejlec: %s" % LINE)
if old_line is not None:
    print("  regi sor : %s" % old_line.strip())
    if d is None:
        print("  elteres  : nem volt kiolvashato idopont a regi sorban")
    elif d > 0:
        print("  elteres  : a regi ertek %d perccel ELORE jart (becsles volt, nem meres)" % d)
    elif d < 0:
        print("  elteres  : a regi ertek %d perccel korabbi volt" % (-d))
    else:
        print("  elteres  : nulla perc, a regi ertek helyes volt")
PY
