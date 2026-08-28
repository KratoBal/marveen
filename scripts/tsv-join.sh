#!/usr/bin/env bash
#
# TSV-osszefuzo helper a flottanak. Ket tabulatorral tagolt fajlt kot ossze egy
# kozos kulcs-oszlop menten, es a talalatokat egy sorban adja vissza.
#
# MIERT LETEZIK: a mero agensek ezt eddig kezzel irt awk-kal csinaltak, es minden
# egyes hivas engedelykeresen allt meg (merve 2026-08-24 ejjel: hat megallas
# negyvenot perc alatt, mind ugyanez az alak). Az awk-ot NEM adjuk meg helyette,
# mert a system() fuggvenyen at tetszoleges parancsot futtat, tehat egy awk
# engedely gyakorlatilag shell-engedely. Ehelyett ez a nevesitett eszkoz all,
# ugyanabban a mintaban, mint a jsonl.sh.
#
# BIZTONSAG: csak OLVAS es a megadott kimeneti fajlba IR. Nem hivja a halozatot,
# nem futtat mas parancsot, es nem ertekel ki felhasznaloi kifejezest: az
# oszlopok SZAMMAL vannak megadva, nem mintaval.
#
# Hasznalat:
#   tsv-join.sh <bal.tsv> <bal_kulcs> <bal_ertek> <jobb.tsv> <jobb_kulcs> <jobb_ertek> [kimenet.tsv]
#
#   Az oszlopok 1-tol szamozva. A BAL fajlbol epul a kulcs-ertek tabla, majd a
#   JOBB fajl minden sorara kiirjuk:  bal_ertek <tab> kulcs <tab> jobb_ertek
#
#   Kapcsolok (a fajlnevek utan barhol):
#     --skip-header-left   a bal fajl elso sora fejlec, kihagyjuk
#     --skip-header-right  a jobb fajl elso sora fejlec, kihagyjuk
#     --only-matched       csak azok a sorok, amikhez van bal ertek
#
# A vegen a stderr-re jon egy szamlalo sor: hany jobb sort olvastunk, hanyhoz
# volt bal ertek, es hany kulcs volt a bal tablaban. A parositatlan sorok szama
# nem melleklet, hanem eredmeny: enelkul egy ures oszlop ugy nezne ki, mintha
# az ertek maga lenne ures.
#
# Kimenet: hiba eseten "FAIL <ok>" a stderr-en, exit 1.
set -uo pipefail

die() { echo "FAIL $*" >&2; exit 1; }

[ "$#" -ge 6 ] || die "hasznalat: tsv-join.sh <bal.tsv> <bal_kulcs> <bal_ertek> <jobb.tsv> <jobb_kulcs> <jobb_ertek> [kimenet.tsv] [--skip-header-left] [--skip-header-right] [--only-matched]"

python3 - "$@" <<'PYEOF'
import os
import sys

a = sys.argv[1:]


def die(m):
    print("FAIL " + m, file=sys.stderr)
    raise SystemExit(1)


flags = {x for x in a if x.startswith("--")}
pos = [x for x in a if not x.startswith("--")]
for f in flags:
    if f not in ("--skip-header-left", "--skip-header-right", "--only-matched"):
        die("ismeretlen kapcsolo: " + f)
if len(pos) < 6:
    die("hat kotelezo argumentum kell, kapott: %d" % len(pos))

left_path, jobb_path = pos[0], pos[3]
out_path = pos[6] if len(pos) > 6 else None

def col(v, name):
    try:
        n = int(v)
    except ValueError:
        die("a(z) %s oszlop nem szam: %r" % (name, v))
    if n < 1:
        die("a(z) %s oszlop 1-tol szamozodik" % name)
    return n - 1

lk, lv = col(pos[1], "bal_kulcs"), col(pos[2], "bal_ertek")
jk, jv = col(pos[4], "jobb_kulcs"), col(pos[5], "jobb_ertek")

for p in (left_path, jobb_path):
    if not os.path.isfile(p):
        die("nincs ilyen fajl: " + p)


def read_rows(path, skip_header):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if skip_header and i == 0:
                continue
            yield line.rstrip("\n").split("\t")


table = {}
for parts in read_rows(left_path, "--skip-header-left" in flags):
    if len(parts) <= max(lk, lv):
        continue
    table.setdefault(parts[lk], parts[lv])

olvasott = 0
parositott = 0
lines = []
for parts in read_rows(jobb_path, "--skip-header-right" in flags):
    if len(parts) <= max(jk, jv):
        continue
    olvasott += 1
    key = parts[jk]
    val = table.get(key)
    if val is None:
        if "--only-matched" in flags:
            continue
        val = ""
    else:
        parositott += 1
    lines.append("%s\t%s\t%s" % (val, key, parts[jv]))

body = "\n".join(lines)
if out_path:
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(body + ("\n" if body else ""))
    print("KIIRVA %s (%d sor)" % (out_path, len(lines)))
elif body:
    print(body)

print(
    "jobb sorok: %d, parositott: %d, parositatlan: %d, bal kulcsok: %d"
    % (olvasott, parositott, olvasott - parositott, len(table)),
    file=sys.stderr,
)
PYEOF
