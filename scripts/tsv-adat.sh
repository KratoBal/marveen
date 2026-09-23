#!/usr/bin/env bash
# tsv-adat.sh -- adat-sorok szamolasa es kiirasa TSV alapvonal-fajlokbol.
#
# MIERT LETEZIK (acrobot, 2026-08-31 este, mert harmadszor oldottam fel ugyanazt).
# Barracuda esti korei ugyanazt a harom dolgot csinaljak, mindig egy for-ciklussal:
# hany adat-sor van fajlonkent, mely sorokban all ertek egy adott oszlopban, es mi
# all a sorok elso par oszlopaban. A ciklusvaltozo BEHELYETTESITES, ezert az
# engedely-ellenorzo minden ilyen hivason megall -- es amig egy agens ott all,
# INTER-AGENT UZENETET SEM KAP. Ma este haromszor allt meg ugyanezen az alakon,
# es a sora kozben tizenegy melyre nott.
#
# MIERT NEM VART EZ HOLNAPIG: nem a szkript hianyzik, hanem az en koreim mennek el
# ra. Harom feloldas harom kor, es mindegyik kozben az agens nema.
#
# AZ ADAT-SOR DEFINICIOJA, egy helyen: nem kezdodik `#` jellel, es nem a `nev`
# szoval kezdodo fejlecsor. A regebbi korok a `# oszlopok:` megjegyzesbe tettek az
# oszlopneveket, a 08-27 utaniak sima sorba -- mindketto ki van szurve.
#
# BIZTONSAG: csak OLVAS. Nincs benne rm, mv, curl, eval, sudo, chmod, es nem ir
# sehova. A kimenet a stdout.
#
# Hasznalat:
#   tsv-adat.sh sor      <konyvtar> <minta>              fajlonkent adat-sor, plusz osszeg
#   tsv-adat.sh oszlop   <konyvtar> <minta> <oszlopok>   a megadott oszlopok kiirasa
#   tsv-adat.sh nemures  <konyvtar> <minta> <oszlop>     azok a sorok, ahol az oszlop nem `-`
#
# A <minta> egy fajlnev-minta a konyvtaron BELUL, idezojelben add meg, hogy ne a
# hivo shellje bontsa fel:
#   tsv-adat.sh sor /ut/baseline "*-20260831.tsv"
#   tsv-adat.sh nemures /ut/baseline "korallszirt-*-20260831.tsv" 3
#   tsv-adat.sh oszlop /ut/baseline "tropus-*-20260831.tsv" 1,2,3
#
# Kilepesi kodok:
#   0 = lefutott
#   2 = ARGUMENTUM- vagy UTVONAL-HIBA (nem futott le semmi)
#   3 = A MINTARA EGYETLEN FAJL SEM ILLESZKEDIK. Ez KULON kod, mert a nulla sor es
#       a nulla fajl kivulrol egyforma, es a masodik a KERDES tulajdonsaga, nem az
#       adate.

set -uo pipefail

PARANCS="${1:-}"

usage() {
  echo "tsv-adat.sh hasznalat:" >&2
  echo "  tsv-adat.sh sor      <konyvtar> <minta>" >&2
  echo "  tsv-adat.sh oszlop   <konyvtar> <minta> <oszlopok>" >&2
  echo "  tsv-adat.sh nemures  <konyvtar> <minta> <oszlop>" >&2
  echo "A mintat IDEZOJELBEN add meg: \"*-20260831.tsv\"" >&2
}

# ARITY-ORZO. Parancsonkent kulon szam: egy kozos hatar helyes hivast is elvagna.
# Az indok mert: 2026-08-27-en egy helper CSENDBEN eldobta a tobblet-argumentumot,
# es tizenot naplobejegyzes torzse veszett el ugy, hogy a valasz vegig {"ok":true}
# volt. Ami tobb, mint amennyit a parancs olvas, az nem figyelmen kivul hagyando,
# hanem HIBA.
case "$PARANCS" in
  sor)      VART=3 ;;
  oszlop)   VART=4 ;;
  nemures)  VART=4 ;;
  ""|-h|--help) usage; exit 2 ;;
  *) echo "tsv-adat.sh: ismeretlen parancs: $PARANCS" >&2; usage; exit 2 ;;
esac

if [ "$#" -ne "$VART" ]; then
  echo "tsv-adat.sh: a '$PARANCS' pontosan $VART argumentumot vesz, kaptam $#." >&2
  echo "            A tobblet CSENDBEN elveszne. Ellenorizd az idezojeleket." >&2
  usage
  exit 2
fi

KONYVTAR="$2"
MINTA="$3"

if [ ! -d "$KONYVTAR" ]; then
  echo "tsv-adat.sh: a konyvtar NEM LETEZIK: $KONYVTAR" >&2
  exit 2
fi

# A mintaban ne legyen utvonal: a keresés EGY konyvtarra szol, es igy nem lehet
# veletlenul kilepni belole.
case "$MINTA" in
  */*) echo "tsv-adat.sh: a minta nem tartalmazhat perjelet: $MINTA" >&2; exit 2 ;;
esac

# A fajllista egyszer all elo, es a nulla talalat KULON kilepesi kodot kap.
FAJLOK=0
for F in "$KONYVTAR"/$MINTA; do
  [ -e "$F" ] && FAJLOK=$((FAJLOK + 1))
done
if [ "$FAJLOK" -eq 0 ]; then
  echo "tsv-adat.sh: EGYETLEN fajl sem illeszkedik erre: $KONYVTAR/$MINTA" >&2
  echo "            Ez NEM azt jelenti, hogy nincs adat -- azt, hogy a kereses" >&2
  echo "            nem talalt fajlt. A nulla itt a kerdes tulajdonsaga." >&2
  exit 3
fi

# Az adat-sorok szurese egy helyen. A fejlecsor mintaja tabulatorral vegzodik,
# hogy egy `nev` kezdetu VALODI termeknev ne essen aldozatul.
adatsorok() {
  /bin/grep -v '^#' "$1" | /bin/grep -v "$(printf '^nev\t')"
}

case "$PARANCS" in

  sor)
    OSSZ=0
    for F in "$KONYVTAR"/$MINTA; do
      [ -e "$F" ] || continue
      N=$(adatsorok "$F" | /bin/grep -c '')
      OSSZ=$((OSSZ + N))
      printf '%6d  %s\n' "$N" "$(/usr/bin/basename "$F")"
    done
    echo "------"
    printf '%6d  ADAT-SOR OSSZESEN, %d fajlbol\n' "$OSSZ" "$FAJLOK"
    ;;

  oszlop)
    OSZLOPOK="$4"
    case "$OSZLOPOK" in
      *[!0-9,]*) echo "tsv-adat.sh: az oszlopok alakja: szamok vesszovel, pl. 1,2,3 (kaptam: $OSZLOPOK)" >&2; exit 2 ;;
    esac
    for F in "$KONYVTAR"/$MINTA; do
      [ -e "$F" ] || continue
      echo "--- $(/usr/bin/basename "$F") ---"
      adatsorok "$F" | /usr/bin/cut -f"$OSZLOPOK"
    done
    ;;

  nemures)
    OSZLOP="$4"
    case "$OSZLOP" in
      ''|*[!0-9]*) echo "tsv-adat.sh: az oszlop egy szam legyen (kaptam: $OSZLOP)" >&2; exit 2 ;;
    esac
    OSSZ=0
    for F in "$KONYVTAR"/$MINTA; do
      [ -e "$F" ] || continue
      # A `-` a "nincs ertek" jele ezekben a fajlokban. A -v szures elott a `--`
      # kell, kulonben a mintat kapcsolonak nezne.
      N=$(adatsorok "$F" | /usr/bin/awk -F'\t' -v c="$OSZLOP" 'NF>=c && $c != "-" && $c != "" { print }' | /bin/grep -c '')
      if [ "$N" -gt 0 ]; then
        echo "--- $(/usr/bin/basename "$F"): $N sor ---"
        adatsorok "$F" | /usr/bin/awk -F'\t' -v c="$OSZLOP" 'NF>=c && $c != "-" && $c != "" { print }'
        OSSZ=$((OSSZ + N))
      fi
    done
    echo "------"
    printf '%6d  SOR OSSZESEN, ahol a(z) %s. oszlop nem ures es nem `-`\n' "$OSSZ" "$OSZLOP"
    echo "MEGJEGYZES: ez a szam SOROKAT szamol, nem TERMEKEKET. Ha egy termek ket"
    echo "kategoria-fajlban is szerepel, ketszer szamol. A termekszamhoz a neveket"
    echo "kell egyszeresiteni."
    ;;
esac

exit 0
