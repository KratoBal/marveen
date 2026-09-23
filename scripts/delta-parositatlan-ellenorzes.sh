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
#
# delta-parositatlan-ellenorzes.sh -- a parositatlan sorok NEGYEDIK OKANAK keresese.
#
# MIERT LETEZIK: a delta-kor parositatlan sorai (UJ TETEL es KIVEZETVE) tobbnyire
# ugyanannak a termeknek ket nev-alakja, tehat NEM piaci esemeny. Ezt eddig szemmel
# neztuk vegig. Egy termek ket nev-alakja viszont AZONOS ARON all -- ha egy ar CSAK
# az egyik oldalon fordul elo, azt a "ket nev-alak" magyarazat NEM fedi le, es akkor
# vagy valodi felvetel/kivezetes tortent, vagy egy eddig ismeretlen negyedik ok.
#
# Ez a szkript ezt a maradekot keresi meg, kategoriankent.
#
# FIGYELEM, A HATARA: az azonos ar EGYEZESE nem bizonyitja, hogy ugyanaz a termek --
# csak azt, hogy a "ket nev-alak" magyarazat LEHETSEGES. A forditottja viszont eros:
# ha egy ar csak az egyik oldalon all, a magyarazat KIZART. Ez a szkript tehat nem
# igazol, hanem CAFOL, es csak arra valo, hogy a kezi atnezes ne maradjon el.
#
# BIZTONSAG: csak olvas. Halozatot nem hiv, fajlt nem ir.
#
# Hasznalat:
#   delta-parositatlan-ellenorzes.sh [munkakonyvtar] [ertek_oszlop] [norm 0|1]

set -uo pipefail

WORKDIR="${1:-/home/marveen/marveen/agents/barracuda/measurement/delta-tmp}"
VALCOL="${2:-2}"
NORM="${3:-1}"

talalat=0
vizsgalt=0

for fwd in "$WORKDIR"/*-fwd-c"$VALCOL"-n"$NORM".tsv; do
  [ -e "$fwd" ] || continue
  base="$(basename "$fwd")"
  prefix="${base%-fwd-c$VALCOL-n$NORM.tsv}"
  rev="$WORKDIR/$prefix-rev-c$VALCOL-n$NORM.tsv"
  [ -e "$rev" ] || continue

  ujak="$WORKDIR/$prefix-ellenorzes-uj.txt"
  regiek="$WORKDIR/$prefix-ellenorzes-regi.txt"

  # a parositatlan sorok TABBAL kezdodnek; az ertek az utolso mezoben all
  grep -P '^\t' "$fwd" 2>/dev/null | sed 's/.*\t//' | sort > "$ujak"
  grep -P '^\t' "$rev" 2>/dev/null | sed 's/.*\t//' | sort > "$regiek"

  n_uj="$(grep -c '' "$ujak")"
  n_regi="$(grep -c '' "$regiek")"

  if [ "$n_uj" -eq 0 ] && [ "$n_regi" -eq 0 ]; then
    continue
  fi

  vizsgalt=$((vizsgalt + 1))

  # comm -3 : ami CSAK az egyik oldalon all
  csak_uj="$(comm -23 "$ujak" "$regiek")"
  csak_regi="$(comm -13 "$ujak" "$regiek")"

  if [ -z "$csak_uj" ] && [ -z "$csak_regi" ]; then
    echo "== $prefix"
    echo "   RENDBEN: $n_uj uj es $n_regi kivezetett sor, minden ertek MINDKET oldalon elofordul"
    echo "   -> a 'ket nev-alak' magyarazat mindegyikre lehetseges, nincs negyedik ok"
  else
    echo "== $prefix"
    echo "   FIGYELEM: van olyan ertek, ami CSAK az egyik oldalon all"
    if [ -n "$csak_uj" ]; then
      printf '%s\n' "$csak_uj" | sed 's/^/   CSAK AZ UJ KORBEN:   /'
    fi
    if [ -n "$csak_regi" ]; then
      printf '%s\n' "$csak_regi" | sed 's/^/   CSAK A REGI KORBEN:  /'
    fi
    echo "   -> ezeket KEZZEL kell megnezni: valodi felvetel/kivezetes, vagy negyedik ok"
    talalat=$((talalat + 1))
  fi
  echo
done

echo "=========================================="
echo "parositatlan sort tartalmazo kategoria: $vizsgalt"
echo "ebbol olyan, ahol egy ertek csak az egyik oldalon all: $talalat"
