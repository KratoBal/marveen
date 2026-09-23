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
# baseline-delta.sh -- ket versenytars-alapvonal kor osszevetese, kategoriankent.
#
# MIERT LETEZIK: a baseline/ mappaban koronkent egy TSV all szereplo-kategoria
# bontasban. Ket kor osszevetese eddig kategorianként HAROM kezi hivas volt
# (tsv-join oda, tsv-join vissza, grep az eltéresekre). Harminchárom kategoriara
# az szaz hivas, es mindegyik kulon engedely-kockazat. Ez a szkript egyszer fut.
#
# BIZTONSAG: csak olvas, es a megadott munkakonyvtarba ir ideiglenes fajlokat.
# Halozatot nem hiv.
#
# Hasznalat:
#   baseline-delta.sh <uj_datum_YYYYMMDD> [baseline_konyvtar] [munkakonyvtar]
#
# Kimenet a stdout-ra, kategoriankent egy blokk:
#   == <prefix>  (regi: <datum>  ->  uj: <datum>)
#   ARVALTOZAS   regi_ar | nev | uj_ar
#   UJ TETEL     nev | uj_ar
#   KIVEZETVE    nev | regi_ar
#   NINCS VALTOZAS   ha egyik sincs
#
# A "nev" oszlop a kulcs, tehat egy ATNEVEZES egy KIVEZETVE plusz egy UJ TETEL
# parkent jelenik meg. Ezt a szkript NEM tudja eldonteni, a nevekbol kell.

set -uo pipefail

NEWDATE="${1:-}"
# Melyik oszlopot hasonlitjuk: 2 = a ma ervenyes ar (alapertelmezes),
# 3 = az ATHUZOTT eredeti ar. A ketto KULON kor: egy akcio ugy is elindulhat,
# hogy a fizetendo ar valtozatlan marad es csak az athuzott ertek jelenik meg.
# Ha csak a 2. oszlopot nezzuk, az ilyen valtozas NEM latszik.
VALCOL="${2:-2}"
BASEDIR="${3:-/home/marveen/marveen/agents/barracuda/measurement/baseline}"
WORKDIR="${4:-/home/marveen/marveen/agents/barracuda/measurement/delta-tmp}"
# NORM=1 eseten a parositas NEM a nyers neven megy, hanem egy normalizalt kulcson.
# A nyers nev a baseline fajlban SZO SZERINT marad, ahogy a szabaly mondja -- a
# normalizalas csak a par ideiglenes masolatan tortenik, es csak a kulcs miatt.
# Amit egysegesit: a gondolatjel-fajtak sima kotojelre, a nem-toro szokoz sima
# szokozre, a tobbes szokoz egyre, a tabulator koruli es a sor eleji-vegi szokoz le.
# Merve 2026-08-28: a kilencedik koron 130 hamis sor jott ki, ebbol 5 pontosan
# ilyen karakter-elteres volt. A TOBBI (a 08-26-i kor rovidített nevei) NEM ilyen,
# azt normalizalassal nem lehet megfogni -- az valoban mas string.
NORM="${5:-0}"
JOIN=/home/marveen/marveen/scripts/tsv-join.sh

if [ -z "$NEWDATE" ]; then
  echo "FAIL hasznalat: baseline-delta.sh <uj_datum_YYYYMMDD> [ertek_oszlop] [baseline_konyvtar] [munkakonyvtar] [norm 0|1]" >&2
  exit 1
fi

mkdir -p "$WORKDIR" || { echo "FAIL nem tudom letrehozni: $WORKDIR" >&2; exit 1; }

# A megjegyzes-sorokat es a sima fejlecsort is kiszedi. A fejlecsor azert kell ki,
# mert a regebbi korok a `# oszlopok:` megjegyzesbe tettek az oszlopneveket, a
# 08-27 utaniak pedig sima sorba -- igy a "nev / ar_ft" sor kulon tetelnek latszott.
#
# A kimenet NEGY oszlop: normalizalt_nev, ar, eredeti_ar, NYERS_nev.
#
# A negyedik oszlop nem kenyelem. A normalizalt kulcs ARRA valo, hogy ket nev-alakot
# ugyanannak lasson -- ebbol viszont az kovetkezik, hogy egy VALODI atnevezest is
# elrejthet: ha a versenytars tenyleg atirja a nevet, es a valtozas eppen kotojel- vagy
# szokoz-szintu, a detektor hallgatna rola. A nyers nev megorzesevel a szkript kulon ki
# tudja irni, hol allt ossze a parositas CSAK a normalizalt kulcson.
normalize_to() {
  grep -v '^#' "$1" | grep -v '^nev	' \
    | sed 's/–/-/g; s/—/-/g; s/ / /g; s/  */ /g; s/ )/)/g; s/( /(/g; s/ *	/	/g; s/	 */	/g; s/^ *//; s/ *$//' \
    > "$2.norm"
  grep -v '^#' "$1" | grep -v '^nev	' | cut -f1 > "$2.raw"
  paste "$2.norm" "$2.raw" > "$2"
}

total_cat=0
total_price=0
total_new=0
total_gone=0
total_renamed=0
total_nobase=0

# ORZO A NEMA NULLA ELLEN (barracuda kerese, 2026-08-31, mert belefutott).
# A ciklus alatta CSENDBEN ATUGRIK, ha a BASEDIR rossz vagy nincs benne fajl a
# megadott datumra: a `[ -e ]` minden jelolteт eldob, es a szkript vegen a
# "kategoria osszesen: 0 / arvaltozas: 0 / uj tetel: 0" osszesito all -- BETURE
# UGYANAZ, mint egy valodi nyugodt kor. Nulla hibauzenet, nulla kilepesi kod.
# Barracuda ma pontosan igy futtatta le (a munkakonyvtarat adta meg
# baseline_dir helyett), es a valasz hihetoen ugy nezett ki, mintha az athuzott
# aron nem lett volna valtozas -- holott a meres EL SEM INDULT.
# A kulonbseg nem kozmetikai: enelkul a nulla nem a vilag tulajdonsaga, hanem a
# kerdese, es a kimenet formaja ezt elrejti.
matches=0
for probe in "$BASEDIR"/*-"$NEWDATE".tsv; do
  [ -e "$probe" ] && matches=$((matches + 1))
done
if [ "$matches" -eq 0 ]; then
  echo "FAIL egyetlen fajl sem illeszkedik erre: $BASEDIR/*-$NEWDATE.tsv" >&2
  echo "     Ez NEM azt jelenti, hogy nincs valtozas -- azt, hogy a meres el sem indult." >&2
  echo "     Ellenorizd a baseline konyvtarat es a datumot. A konyvtar, amiben kerestem: $BASEDIR" >&2
  exit 3
fi

for newfile in "$BASEDIR"/*-"$NEWDATE".tsv; do
  [ -e "$newfile" ] || continue
  base="$(basename "$newfile")"
  prefix="${base%-$NEWDATE.tsv}"

  # a legutolso KORABBI kor ugyanarra a prefixre
  oldfile=""
  for cand in "$BASEDIR/$prefix"-2026*.tsv; do
    [ -e "$cand" ] || continue
    [ "$cand" = "$newfile" ] && continue
    oldfile="$cand"
  done

  total_cat=$((total_cat + 1))

  if [ -z "$oldfile" ]; then
    echo "== $prefix"
    echo "   NINCS KORABBI KOR -- ez az elso meres erre a kategoriara"
    echo
    total_nobase=$((total_nobase + 1))
    continue
  fi

  oldbase="$(basename "$oldfile")"
  olddate="${oldbase##*-}"
  olddate="${olddate%.tsv}"

  fwd="$WORKDIR/$prefix-fwd-c$VALCOL-n$NORM.tsv"
  rev="$WORKDIR/$prefix-rev-c$VALCOL-n$NORM.tsv"

  left="$oldfile"
  right="$newfile"
  if [ "$NORM" = "1" ]; then
    left="$WORKDIR/$prefix-old-norm.tsv"
    right="$WORKDIR/$prefix-new-norm.tsv"
    normalize_to "$oldfile" "$left"
    normalize_to "$newfile" "$right"
  fi

  "$JOIN" "$left" 1 "$VALCOL" "$right" 1 "$VALCOL" "$fwd" 2>/dev/null
  "$JOIN" "$right" 1 "$VALCOL" "$left" 1 "$VALCOL" "$rev" 2>/dev/null

  # A NORMALIZALAS SAJAT VAKSAGA, kiirva. Ahol a parositas CSAK a normalizalt kulcson
  # allt ossze, a nyers nev viszont valtozott, ott VALODI atnevezes tortent -- azt a
  # normalizalt kulcs elrejtene. Ezert kulon soron jelenik meg.
  renamed=""
  n_renamed=0
  if [ "$NORM" = "1" ]; then
    nm="$WORKDIR/$prefix-nyersnev-n$NORM.tsv"
    "$JOIN" "$left" 1 4 "$right" 1 4 "$nm" 2>/dev/null
    renamed="$(grep -vP '^([^\t]*)\t[^\t]*\t\1$' "$nm" 2>/dev/null | grep -vP '^\t' 2>/dev/null | grep -P '\S' 2>/dev/null)"
    [ -n "$renamed" ] && n_renamed="$(printf '%s\n' "$renamed" | grep -c '')"
  fi

  # eltero sorok: ahol a bal es a jobb ertek NEM azonos
  changed="$(grep -vP '^([^\t]*)\t[^\t]*\t\1$' "$fwd" 2>/dev/null)"
  gone="$(grep -vP '^([^\t]*)\t[^\t]*\t\1$' "$rev" 2>/dev/null | grep -P '^\t' 2>/dev/null)"

  price_lines="$(printf '%s\n' "$changed" | grep -vP '^\t' 2>/dev/null | grep -P '\S' 2>/dev/null)"
  new_lines="$(printf '%s\n' "$changed" | grep -P '^\t' 2>/dev/null)"

  n_price=0
  n_new=0
  n_gone=0
  [ -n "$price_lines" ] && n_price="$(printf '%s\n' "$price_lines" | grep -c '')"
  [ -n "$new_lines" ] && n_new="$(printf '%s\n' "$new_lines" | grep -c '')"
  [ -n "$gone" ] && n_gone="$(printf '%s\n' "$gone" | grep -c '')"

  echo "== $prefix  (regi: $olddate  ->  uj: $NEWDATE)"

  if [ "$n_price" -eq 0 ] && [ "$n_new" -eq 0 ] && [ "$n_gone" -eq 0 ] && [ "$n_renamed" -eq 0 ]; then
    echo "   NINCS VALTOZAS"
  else
    # A sorok TABBAL tagoltak es UGY is maradnak. A `read` NEM jo ide: a tabulator
    # IFS-feherkarakter, tehat a bash a vezeto tabot LENYELI es az egymas melletti
    # tabokat OSSZEVONJA -- egy ures elso mezo (eppen az "uj tetel" jele) igy
    # eltunik, es minden oszlop egyet csuszik. Merve 2026-08-28: az elso futas
    # minden nevet ures oszlopnak mutatott emiatt. A sed nem ertelmezi a mezoket.
    if [ "$n_price" -gt 0 ]; then
      printf '%s\n' "$price_lines" | sed 's/^/   ARVALTOZAS  regi=/'
    fi
    if [ "$n_new" -gt 0 ]; then
      printf '%s\n' "$new_lines" | sed 's/^\t/   UJ TETEL    /'
    fi
    if [ "$n_gone" -gt 0 ]; then
      printf '%s\n' "$gone" | sed 's/^\t/   KIVEZETVE   /'
    fi
    if [ "$n_renamed" -gt 0 ]; then
      printf '%s\n' "$renamed" | sed 's/^/   NEV-VALTOZAS  regi=/'
    fi
  fi
  echo

  total_price=$((total_price + n_price))
  total_new=$((total_new + n_new))
  total_gone=$((total_gone + n_gone))
  total_renamed=$((total_renamed + n_renamed))
done

echo "=========================================="
echo "kategoria osszesen: $total_cat"
echo "ebbol elso meres (nincs mihez hasonlitani): $total_nobase"
echo "arvaltozas osszesen: $total_price"
echo "uj tetel osszesen: $total_new"
echo "kivezetett tetel osszesen: $total_gone"
echo "nev-valtozas (a parositas CSAK a normalizalt kulcson allt ossze): $total_renamed"
