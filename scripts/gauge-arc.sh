#!/usr/bin/env bash
# gauge-arc.sh -- barometer-stilusu feny- es aramlas-igeny, faj-bemutato lapokhoz.
#
# A sav-valtozat (gauge.sh) testverje. Luca keresere keszult: "talan az emberek szeme
# jobban raall egy barometer stilusra". Igaza van, a felkor-forma gyorsabban olvashato,
# es a sajat Canva-lapjain mar ez a vizualis nyelv.
#
# A LENYEGES KULONBSEG A KLASSZIKUS BAROMETERHEZ KEPEST: itt NINCS MUTATO.
# korall szakmai kikotese (2026-08-16): egy faj fenyigenye nem egy ertek, hanem
# TARTOMANY. Egy mutato pontot allit, es a pont ugy nez ki, mintha meres lenne --
# pedig tapasztalat. Ezert a tartomanyt maga a KISZINEZETT IVSZAKASZ mutatja.
# Igy megmarad a barometer olvashatosaga, es nem allitunk hamis pontossagot.
#
# Tovabbi kotesek korall specifikaciojabol:
#   - Harom fokozat, soha nem ot.
#   - Balrol jobbra novekvo, MINDEN fajnal ugyanugy, kulonben az osszehasonlithatosag
#     vesz el, ami az egesz grafika ertelme.
#   - FENY balra, ARAMLAS jobbra, mindig ebben a sorrendben, mindig azonos meretben.
#   - Nincs szam, mertekegyseg, szazalek, faj-abra.
#
# SZIN: szandekosan EGYSZINU (Luca #162270 navy), nem piros-sarga-zold. Egy piros-zold
# skala ITELETET mond (rossz -> jo), pedig az alacsony fenyigeny nem hiba, csak adottsag.
# A kezdo akvarista a pirosat problemanak olvasna.
#
# Usage:
#   bash scripts/gauge-arc.sh <feny-tol> <feny-ig> <aramlas-tol> <aramlas-ig> <kimenet.png>
#   Ertekek: 1 = ALACSONY, 2 = KOZEPES, 3 = EROS.
set -uo pipefail

die() { echo "FAIL $*" >&2; exit 1; }

FL="${1:-}"; FH="${2:-}"; AL="${3:-}"; AH="${4:-}"; OUT="${5:-}"
[ -n "$OUT" ] || die "hasznalat: gauge-arc.sh <feny-tol> <feny-ig> <aramlas-tol> <aramlas-ig> <kimenet.png>"
for v in "$FL" "$FH" "$AL" "$AH"; do
  case "$v" in 1|2|3) ;; *) die "az ertekek csak 1, 2 vagy 3 lehetnek (kaptam: $v)" ;; esac
done
[ "$FL" -le "$FH" ] || die "a feny tartomany forditva van: $FL > $FH"
[ "$AL" -le "$AH" ] || die "az aramlas tartomany forditva van: $AL > $AH"

FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
[ -f "$FONT" ] || die "hianyzik a betutipus: $FONT"

W=1240; H=560
CX1=330; CX2=910; CY=330          # a ket felkor kozeppontja
RIN=132; ROUT=205                 # az iv belso es kulso sugara
GAPDEG=3                          # szogkoz a szakaszok kozott

# Szakasz-hatarok fokban, a jobb oldali vizszintestol merve (atan2 konvencio):
#   3. szakasz (EROS)     0-60      -> jobbra
#   2. szakasz (KOZEPES) 60-120
#   1. szakasz (ALACSONY) 120-180   -> balra
# Igy balrol jobbra novekszik, ahogy korall kototte.
seg_lo() { case "$1" in 1) echo 120;; 2) echo 60;; 3) echo 0;; esac; }
seg_hi() { case "$1" in 1) echo 180;; 2) echo 120;; 3) echo 60;; esac; }

# Egy szinkomponens kifejezese az egyik felkorre.
# on = a tartomanyba eso szakaszok szine, off = a tobbie.
chan_expr() {
  local cx="$1" lo="$2" hi="$3" on="$4" off="$5" expr=""
  local i a b col
  # A szakaszkozt CSAK ott hagyjuk meg, ahol a ket szomszedos szakasz NEM ugyanabba a
  # tartomanyba esik. korall eszrevetele (2026-08-16): egy ket szakaszt atfogo tartomany
  # a koz miatt ugy olvashato, mintha KET KULON lehetoseg lenne, nem folytonos sav --
  # pedig eppen az a lenyeg, hogy folytonos. Egy Discosoma (1-2) lapon ez azonnal latszik.
  local in_i in_prev in_next glo ghi
  for i in 1 2 3; do
    in_i=0;    [ "$i" -ge "$lo" ] && [ "$i" -le "$hi" ] && in_i=1
    in_prev=0; [ $((i-1)) -ge "$lo" ] && [ $((i-1)) -le "$hi" ] && in_prev=1
    in_next=0; [ $((i+1)) -ge "$lo" ] && [ $((i+1)) -le "$hi" ] && in_next=1
    # seg_lo oldalan a szomszed az i+1 (magasabb fokozat), seg_hi oldalan az i-1.
    glo="$GAPDEG"; ghi="$GAPDEG"
    if [ "$in_i" = 1 ] && [ "$in_next" = 1 ]; then glo=0; fi
    if [ "$in_i" = 1 ] && [ "$in_prev" = 1 ]; then ghi=0; fi
    a=$(( $(seg_lo "$i") + glo )); b=$(( $(seg_hi "$i") - ghi ))
    if [ "$in_i" = 1 ]; then col="$on"; else col="$off"; fi
    expr="${expr}if(between(ang,${a},${b}),${col},"
  done
  expr="${expr}BG)))"
  # ang es a gyuru-feltetel behelyettesitese
  printf 'if(between(hypot(X-%s,Y-%s),%s,%s)*lte(Y,%s), %s, BG)' \
    "$cx" "$CY" "$RIN" "$ROUT" "$CY" "$expr"
}

# A teljes csatorna-kifejezes: bal felkor VAGY jobb felkor, kulonben hatter.
full_expr() {
  local on="$1" off="$2" bg="$3"
  local left right
  left="$(chan_expr "$CX1" "$FL" "$FH" "$on" "$off")"
  right="$(chan_expr "$CX2" "$AL" "$AH" "$on" "$off")"
  # az `ang` valtozot minden felkornel a sajat kozeppontjara kell szamolni
  left="${left//ang/(atan2($CY-Y,X-$CX1)*180/PI)}"
  right="${right//ang/(atan2($CY-Y,X-$CX2)*180/PI)}"
  printf 'if(lte(hypot(X-%s,Y-%s),%s), %s, %s)' "$CX1" "$CY" "$ROUT" "$left" "$right" \
    | sed "s/BG/$bg/g"
}

R_EXPR="$(full_expr 22 217 255)"
G_EXPR="$(full_expr 34 224 255)"
B_EXPR="$(full_expr 112 247 255)"

txt() { printf 'drawtext=fontfile=%s:text=%s:x=%s:y=%s:fontsize=%s:fontcolor=0x162270,' \
  "$FONT" "$1" "$2" "$3" "$4"; }

LBL=""
LBL="${LBL}$(txt 'FÉNY'    "$((CX1 - 62))" "$((CY + 55))" 46)"
LBL="${LBL}$(txt 'ÁRAMLÁS' "$((CX2 - 118))" "$((CY + 55))" 46)"
# Fokozat-cimkek az ivek ala, mindket oldalon ugyanott.
for cx in "$CX1" "$CX2"; do
  LBL="${LBL}$(txt 'ALACSONY' "$((cx - 258))" "$((CY + 8))"  24)"
  LBL="${LBL}$(txt 'KÖZEPES'  "$((cx - 62))"  "$((CY - 250))" 24)"
  LBL="${LBL}$(txt 'ERŐS'     "$((cx + 178))" "$((CY + 8))"  24)"
done
LBL="${LBL%,}"

ffmpeg -y -loglevel error -f lavfi -i "color=c=white:s=${W}x${H}:d=1,format=rgb24" \
  -vf "geq=r='${R_EXPR}':g='${G_EXPR}':b='${B_EXPR}',${LBL},format=rgba,colorkey=white:0.02:0.0" \
  -frames:v 1 "$OUT" || die "az ffmpeg nem tudta eloallitani a kepet"

[ -s "$OUT" ] || die "a kimeneti fajl ures: $OUT"
echo "OK $OUT  (feny ${FL}-${FH}, aramlas ${AL}-${AH})"
