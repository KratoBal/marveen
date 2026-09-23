#!/usr/bin/env bash
# ANSWERS: Letezik-e tenyleg minden hash, amit egy kimeno szovegbe irtam, es MELYIK repoban.
#
# hash-ellenorzo.sh -- egy kimeno szoveget nez at, es MINDEN hash-szeru mintat
# megmer a git-tel. Ami nem letezik, azt kiirja, es nem-nullaval lep ki.
#
# MIERT LETEZIK (merve 2026-09-03 19:0x, sajat hiba):
#
# Egy rossz PR-szamot javito uzenetbe KEZZEL GEPELT, hibas commit-hash kerult --
# ugyanabban a mondatban, amelyik azt allitotta, hogy "a hash-t a szkript merte".
# A rovid alak (`c9069e1`) HELYES volt es fajlbol jott; a jelentesbe viszont egy
# HOSSZABB alakot irtam (`c9069e1eb1a1e3f5`), es a hosszabbitas KITALALAS volt.
#
# A hibas ertek HAROM helyre ment el, mert egyszer irtam le, es utana sajat
# magamtol masoltam tovabb.
#
# ES A MECHANIZMUS, AMIERT ESZKOZ KELL RA: nem elmaradt meres volt. A mert
# erteket "javitottam fel", mert egy hosszabb hash PONTOSABBNAK LATSZIK. A
# pontossag latszata a hiba forrasa -- es arra egy szabaly nem ved, mert epp
# akkor sul el, amikor az ember gondos akar lenni.
#
# EGY ROVID ELOTAG AZONOSITO, NEM ERTEK: a hibas es a valodi hash az elso HET
# karakteren egyezett. Szemre helyesnek latszott. Csak a teljes alak osszevetese
# dont, es azt gep csinalja jol, nem szem.
#
# HASZNALAT (a repo gyokereben, kuldes ELOTT):
#   bash /home/marveen/marveen/agents/nautilus/scripts/hash-ellenorzo.sh <fajl>
#
# AMIT NEM CSINAL: nem javit es nem kuld. Csak megmondja, melyik ertek nem
# letezik ebben a repoban.
#
# A HATARA, KIMONDVA: a mintaja minden 7-40 karakteres hexa szot bevesz, tehat
# vonalkodokat es azonositokat is felszedhet (a mai meresben ket vonalkod es egy
# kartya-azonosito jott be). Ezert a kimenet KULON sorban jeloli, ami nem
# letezik -- es a hivo dolga eldonteni, hogy az hash akart-e lenni. Egy szurobb
# minta kihagyna a valodi hibat is.
#
# KALIBRALVA (2026-09-03 19:1x, a mai sajat szovegeimen, ot agon):
#
#   a hibas jelentes                 exit 1, es NEVEN nevezte a kitalalt erteket
#   egy tiszta jelentes              exit 0, egy valodi hash-sel
#   ures fajl                        exit 0, "nincs hash-szeru minta"
#   nem letezo fajl                  exit 2
#   a HELYESBITO uzenetem            exit 1 -- ES EZ NEM HIBA, lasd lent
#
# ES A MASODIK KOR (19:2x), miutan a fonok azt kerdezte, alkalmas-e a KOZOS
# mappaba. Nem volt az, es a meres mutatta meg: egy MASIK git repobol futtatva
# HAMIS RIASZTAST adott egy VALODI hash-re. A flottaban tobb repo van, tehat ez
# nem elmeleti. Az `HASH_REPOK` valtozo es a repo-megnevezes ezt zarja le:
#
#   sajat repobol, valodi hash        exit 0, es kiirja, MELYIK repoban van
#   masik repobol, HASH_REPOK-kal     exit 0 -- a hamis riasztas megszunt
#   a listan egy olvashatatlan repo   exit 0, de a repo NEV SZERINT jelolve
#   minden repo olvashatatlan         exit 2, es kimondja: "ez nem azt jelenti,
#                                     hogy jok" -- a nem-tudom nem a nulla
#
# ES A HARMADIK KOR (19:3x), a fonok ervebol -- ez a legfontosabb valtozas:
#
# A HIBA NEM AZ ALAPERTELMEZES VOLT, HANEM A MONDAT. Egy repo-listat nezo mero
# NEM TUDJA kimondani, hogy egy hash "nem letezik" -- csak azt, hogy AMIT
# MEGNEZETT, abban nincs benne. Egy MASIK repoban levo commit es egy KITALALT
# commit ugyanugy nez ki, amig a mondat nem mondja meg, hol kerestunk.
#
#   regi:  "NEM LETEZIK  <hash>"
#   uj:    "NINCS MEG    <hash>   (a megnezett 2 repoban; 1 repot NEM tudtam megnezni)"
#
# Ugyanaz a szam, ugyanaz a piros, de a MONDAT hordja a hatokoret. Ezert az
# alapertelmezes MARADHAT: nem az okozta a kart, hanem a tulzo allitas.
#
# ES AMIERT NEM KOTELEZO VALTOZO LETT (a fonok erve): egy kotelezo valtozo azt
# igeri, hogy aki megadja, jol adja meg. Aki harom repot ad meg negybol,
# ugyanugy hamis riasztast kap, csak most mar magabiztosan. A kotelezo valtozo
# a felelosseget mozgatja, a hibat nem.
#
#   hianyzo hash, egy repo            "a megnezett 1 repoban"
#   plusz egy olvashatatlan repo      "; 1 repot NEM tudtam megnezni"
#   a sajat 11812-es uzenetem         alapertelmezessel NINCS MEG, a helyes
#                                     repoval MEGVAN -- ugyanaz a fajl
#
# AZ OTODIK AG A LENYEG, ES EZ AZ ESZKOZ HATARA: egy helyesbito uzenetben a
# hibas erteket IDEZNI kell ("a c9069e1eb... KITALALT ERTEK"). Az eszkoz nem
# tudja megkulonboztetni az ALLITAST az IDEZETTOL, tehat ott jogosan pirosodik.
#
# Ezt NEM javitom ki mintaval (egy "csak allitasban szamit" szabaly ugyanugy
# kitalalas lenne, mint a hash volt): a hivo dolga ranezni. Az eszkoz azt
# mondja meg, MELYIK ertek nem letezik -- azt nem, hogy miert all ott.

set -uo pipefail

FAJL="${1:-}"
[ -n "$FAJL" ] || { echo "HASZNALAT: hash-ellenorzo.sh <fajl>" >&2; exit 2; }
[ -r "$FAJL" ] || { echo "FAIL: nem olvashato: $FAJL" >&2; exit 2; }

# MELYIK REPOKBAN KERESSEN -- ES MIERT NEM ELEG AZ AKTUALIS.
#
# Merve 2026-09-03 19:2x: egy MASIK git repobol futtatva a szkript HAMIS
# RIASZTAST ad egy VALODI hash-re. Az `e09b1fa7...` letezik az acropora-os
# repoban; egy ures repobol nezve "NEM LETEZIK".
#
# A flottaban tobb repo van (acropora-os, acropora-commerce, ai-agent), es a
# jelentesekben MINDEGYIKBOL szerepelnek hash-ek. Egy repora vak mero tehat
# pont akkor kiabal, amikor a legkevesbe szabadna: egy helyes ertekre.
#
# A lista a `HASH_REPOK` kornyezeti valtozobol jon (kettosponttal elvalasztva),
# kulonben az aktualis repo. Es a kimenet MINDIG kiirja, MELYIKBEN keresett --
# egy "nem letezik" a repo megnevezese nelkul nem allitas, hanem hivatkozas.
#
# A KOZOS VALTOZAT ALAPERTELMEZESE MAS, MINT NAUTILUS SAJATJAE, ES EZ SZANDEKOS.
# Nala az aktualis repo volt az alapertelmezes, es epp ez adott hamis riasztast:
# az agens-mappaja MAGA IS git repo, tehat a lista arra esett, amelyikben nincs
# kod-hash. Egy kozos eszkoznel ez rosszabb lenne, mert tobben hivjak, es a
# legtobben nem tudjak, hany repo van a fajukban.
#
# Ezert itt a lista a flotta MERT repoibol all (a klonok es a tukor), es a
# kimenet minden futasnal kiirja, mit nezett meg. A lista bovulhet: ha egy uj
# klon keletkezik, ide kell felvenni, kulonben az onnan szarmazo hash-ekre
# hamis riasztas jon. Ez a hatar a kimenetben is latszik, nem csak itt.
REPOK="${HASH_REPOK:-}"
if [ -z "$REPOK" ]; then
  REPOK="/home/marveen/marveen/store/github-repos/KratoBal--acropora-os"
  REPOK="$REPOK:/home/marveen/marveen/agents/murena/acropora-os"
  REPOK="$REPOK:/home/marveen/marveen/agents/murena/acropora-commerce"
  REPOK="$REPOK:/home/marveen/marveen/agents/nautilus/acropora-os"
  REPOK="$REPOK:/home/marveen/marveen/agents/nautilus/ai-agent"
  REPOK="$REPOK:/home/marveen/marveen/agents/nautilus/commerce-work"
  REPOK="$REPOK:/home/marveen/marveen"
fi

MINTAK="$(/bin/grep -ohE '\b[0-9a-f]{7,40}\b' "$FAJL" | /usr/bin/sort -u)"

if [ -z "$MINTAK" ]; then
  echo "nincs hash-szeru minta a fajlban"
  exit 0
fi

# A REPOK ALLAPOTAT ELOSZOR IRJUK KI, es kulon jeloljuk azt, amit NEM tudtunk
# megnezni. A "nem talaltam" es a "nem tudtam megnezni" ket kulonbozo dolog, es
# egy kozos nulla osszemosna oket.
echo "--- a keresett repok ---"
OLVASHATO_DB=0
OLVASATLAN_DB=0
IFS=':' read -r -a REPO_TOMB <<< "$REPOK"
for R in "${REPO_TOMB[@]}"; do
  [ -n "$R" ] || continue
  if git -c safe.directory="$R" -C "$R" rev-parse --git-dir > /dev/null 2>&1; then
    echo "  olvasom       $R"
    OLVASHATO_DB=$((OLVASHATO_DB + 1))
  else
    echo "  NEM OLVASOM   $R   (nem git repo, vagy nincs jogom hozza)"
    OLVASATLAN_DB=$((OLVASATLAN_DB + 1))
  fi
done
# A ki nem olvasott repok a HATOKORT szukitik, tehat a mondatban a helyuk van.
# Enelkul egy "nincs meg" ugy hangzana, mintha mindent megneztunk volna.
OLVASATLAN_JELZO=""
[ "$OLVASATLAN_DB" -gt 0 ] && OLVASATLAN_JELZO="; $OLVASATLAN_DB repot NEM tudtam megnezni"
if [ "$OLVASHATO_DB" -eq 0 ]; then
  echo "FAIL: egyetlen megadott repot sem tudok olvasni. A hash-ekrol SEMMIT nem" >&2
  echo "      mondok -- ez nem azt jelenti, hogy jok." >&2
  exit 2
fi
echo

HIANYZO=0
DB=0
while read -r H; do
  [ -n "$H" ] || continue
  DB=$((DB + 1))
  HOL=""
  for R in "${REPO_TOMB[@]}"; do
    [ -n "$R" ] || continue
    if git -c safe.directory="$R" -C "$R" cat-file -e "$H" 2>/dev/null; then
      HOL="$R"
      break
    fi
  done
  if [ -n "$HOL" ]; then
    echo "megvan     $H   ($HOL)"
  else
    # A MONDAT HORDJA A HATOKORT, ES EZ NEM STILUS.
    #
    # Egy repo-listat nezo mero NEM TUDJA kimondani, hogy egy hash "nem
    # letezik" -- csak azt, hogy AMIT MEGNEZETT, abban nincs benne. A ketto
    # kozott az a kulonbseg, hogy egy MASIK repoban levo commit es egy
    # KITALALT commit ugyanugy nez ki, amig a mondat nem mondja meg, hol
    # kerestunk.
    echo "NINCS MEG  $H   (a megnezett $OLVASHATO_DB repoban$OLVASATLAN_JELZO)"
    HIANYZO=$((HIANYZO + 1))
  fi
done <<< "$MINTAK"

echo "---"
echo "$DB hash-szeru minta, ebbol $HIANYZO nincs meg a megnezett $OLVASHATO_DB repoban$OLVASATLAN_JELZO."
if [ "$HIANYZO" -gt 0 ]; then
  echo "Nezd meg mindegyiket: vagy MASIK repoban van, vagy kitalalt ertek." >&2
  exit 1
fi
exit 0
