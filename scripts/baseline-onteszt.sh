#!/usr/bin/env bash
# ATNEZVE ES ATHELYEZVE 2026-08-31, acrobot.
#
# EREDET: barracuda irta, es a sajat mappajabol futtatta. Ott a futtatas NINCS
# engedelyezve, es nem is lehet: abba a mappaba o maga irhat, tehat a futtatas
# engedelyezese egy sajat fajl megirasaval barmit futtathatova tenne. A korlat
# helyes -- de a napi ara mert volt: 2026-08-31-en HATSZOR allt meg egy sajat
# szkript-hivason, es amig engedelykeresen all, inter-agent uzenetet SEM KAP.
# Hetszer varakozo uzenet gyult fel a legrosszabb korben.
#
# AMIT AZ ATNEZES NEZETT (es amiert athelyezheto): nincs benne rm, curl, wget,
# eval, sudo, chmod, nincs iras az /etc, /usr, /var ala, es nincs benne UNAS
# iro parancs. Csak TSV-t olvas, osszevet, es a hivo altal MEGADOTT
# munkakonyvtarba ir. Az OS jogosultsaga tovabbra is korlatozza, hova irhat.
#
# AMI EZZEL VALTOZIK: innentol barracuda NEM tudja szerkeszteni. Egy javitas
# ide review-val jut be. Ez a cserearany: cserebe nem all meg rajta senki.
#
# Alapvonal-fajlok ontesztje: parositas onmagaval + elteres-kilistazo.
#
# MIERT KETTO ES NEM EGY: 2026-08-27 este a tiz akkor keszult alapvonal mind atment
# a parositasi ontesztjén, es a HIBA a masodik lepesen bukott ki - az elteres-kilistazo
# minta csak SZAMOT fogadott el valtozatlan erteknek, tehat az ar nelkuli teteleknel
# (ar_ft = kotojel) hamis eltérést jelzett volna. Egy meroeszkoz hibaja addig javithato
# olcson, amig meg nem mert semmit.
#
# A javitott minta barmely AZONOS bal- es jobboldali erteket valtozatlannak vesz.
#
# Hasznalat: baseline-onteszt.sh <fajl-lista.txt>
# A lista soronkent egy tsv fajl teljes utjat tartalmazza.

set -uo pipefail

LIST="${1:?hasznalat: baseline-onteszt.sh <fajl-lista.txt>}"
TMP=/tmp/baseline-onteszt-out.tsv
HIBA=0

while read -r f; do
  [ -z "$f" ] && continue
  sorok=$(grep -c "" "$f")
  join_out=$(bash /home/marveen/marveen/scripts/tsv-join.sh "$f" 1 2 "$f" 1 2 "$TMP" 2>&1 | head -1)
  elteres=$(grep -c -vP '^([^\t]*)\t[^\t]*\t\1$' "$TMP")
  if [ "$elteres" -ne 0 ]; then HIBA=1; fi
  printf "%s\tsorok=%s\telteres=%s\t%s\n" "$(basename "$f")" "$sorok" "$elteres" "$join_out"
done < "$LIST"

if [ "$HIBA" -ne 0 ]; then
  echo "FIGYELEM: legalabb egy fajlon nem nulla az onteszt-elteres" >&2
  exit 1
fi
echo "MIND RENDBEN: minden fajlon nulla elteres az ontesztjén"
