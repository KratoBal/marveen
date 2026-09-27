#!/usr/bin/env bash
# ANSWERS: Mi all TENYLEG egy elo bolti termeklap HTML forrasaban (beagyazott video, jelolok), markdownna alakitas nelkul.
#
# shop-oldal-nyers.sh <url-vagy-sefurl> [minta]
#
# WHY THIS EXISTS, measured 2026-09-01 22:05. Barracuda tried to decide whether the 27
# product descriptions that carry an embedded YouTube player actually show it on the
# live page. Every reading path available to him converts the page to markdown first,
# and that conversion DROPS the embed: the fetch returned the product's own text and
# the correct price, and not one of `iframe`, `youtube` or the video id -- although all
# three are provably in the export, in that same field. Two separate measurements of his
# stopped at this same wall in one day.
#
# The limit was never a permission: a wider grant would return the same empty result,
# because that surface never carried the markup. It is the fourth kind in our list --
# UNSUITABLE INSTRUMENT -- and the fix is a different instrument, not more access.
#
# Read-only: it GETs one public page and prints it. It never posts, and it never writes
# to the shop.
set -uo pipefail

BASE="https://shop.acropora.hu"

if [[ $# -lt 1 ]]; then
  echo "hasznalat: bash /home/marveen/marveen/scripts/shop-oldal-nyers.sh <url-vagy-sefurl> [minta]" >&2
  echo "  pelda:   bash /home/marveen/marveen/scripts/shop-oldal-nyers.sh sea10 iframe" >&2
  exit 2
fi

# A KAPCSOLOK BARHOL ALLHATNAK, a cel pedig az ELSO nem-kapcsolo argumentum.
# Merve 2026-09-09: az elso valtozatban a TARGET a ciklus ELOTT vette el a $1-et,
# tehat a `--head` elso helyen ALLT BE CELNAK, es a szkript a
# `https://shop.acropora.hu/--head` cimet hivta le -- 000-val, ami pontosan ugy
# nez ki, mint egy halozati hiba. Egy elgepelt cim es egy elerhetetlen hoszt
# ugyanazt a szamot adja, ezert a sorrend itt nem stilus-kerdes.
TARGET=""
PATTERN=""
SAVE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --save) SAVE="${2:-}"; shift 2 || shift ;;
    --head) HEAD_MODE=1; shift ;;
    *)      if [[ -z "$TARGET" ]]; then TARGET="$1"; else PATTERN="$1"; fi; shift ;;
  esac
done
[[ -n "$TARGET" ]] || { echo "shop-oldal-nyers.sh: nincs cel megadva" >&2; exit 2; }

case "$TARGET" in
  http://*|https://*) URL="$TARGET" ;;
  /*)                 URL="${BASE}${TARGET}" ;;
  *)                  URL="${BASE}/${TARGET}" ;;
esac

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

# --head: CSAK a statuszkodot kerdezi le, a testet nem tolti le. Merve 2026-09-09:
# a 3438 sajat kep-fajl letezes-vizsgalata GET-tel 80-120 megabajt sajat forgalom
# lenne az elo boltunk ellen, HEAD-del toredek. A kimenet alakja valtozatlan marad
# (url / http / bajt), mert a hivo szkriptek arra epulnek.
#
# JAVITVA 2026-09-09 20:18, barracuda merese alapjan. ITT EREDETILEG AZ ALLT, hogy
# HEAD-nel a bajtszam NULLA lesz, es hogy ezt ki kell mondani, nehogy valaki ures
# valasznak nezze. A SZAM NEM NULLA: a `curl -I -o "$BODY"` a VALASZ FEJLECET irja a
# fajlba, tehat a bajt a fejlec-blokk merete. Merve: 200-nal 286 bajt, 404-nel 335.
# Ugyanaz a cim --head NELKUL 41488 bajt, tehat a kapcsolo tenyleg mast csinal.
#
# ES A ROSSZ MEGJEGYZES DRAGABB VOLT, MINT A HIANYA: aki azt olvassa, hogy "0 lesz",
# es 286-ot lat, azt fogja hinni, hogy a szkript MEGIS letoltotte a testet. Ugyanaz a
# csalad, mint egy dokumentum, ami egy megvaltozott orzot ir le.
#
# A HELYES OLVASAT: HEAD-nel a bajtszam a valasz FEJLECE, nem a tartalom -- nem nulla,
# es a --head nelkuli merettel NEM osszevetheto. A letezes-kerdest a HTTP-kod donti el,
# nem a bajt (merve: 404 is 335 bajtot ad, tehat a nem-nulla bajt nem jelent talalatot).
if [[ "${HEAD_MODE:-0}" == "1" ]]; then
  CODE="$(curl -sS -L -I -o "$BODY" -w '%{http_code}' --max-time 30 "$URL")"
else
  CODE="$(curl -sS -L -o "$BODY" -w '%{http_code}' --max-time 30 "$URL")"
fi
RC=$?
SIZE="$(wc -c < "$BODY" | tr -d ' ')"

echo "url:    $URL"
echo "http:   $CODE (curl kilepesi kod: $RC)"
echo "bajt:   $SIZE"

# A NULLA TALALAT ITT IS A KERDES TULAJDONSAGA LEHET, ezert a szamok mindig kimennek,
# meg akkor is, ha egyik sem nulla. Egy ures kimenet nem tudna megkulonboztetni azt,
# hogy nincs benne, attol, hogy el sem jutottunk a lapig.
for NEEDLE in iframe youtube youtu.be "video"; do
  N="$(/bin/grep -o -i -- "$NEEDLE" "$BODY" | wc -l | tr -d ' ')"
  printf '  %-10s %s\n' "$NEEDLE" "$N"
done

if [[ -n "$PATTERN" ]]; then
  echo "--- a keresett minta soronkent ($PATTERN):"
  /bin/grep -n -i -- "$PATTERN" "$BODY" | head -20
fi

if [[ -n "$SAVE" ]]; then
  # MIERT VAN EZ, merve 2026-09-02: a delta-korok sor-szintu alapvonala azert nem maradt
  # meg egyetlen koron sem, mert a markdownos lehivo OSSZEFOGLALT szoveget ad, es abbol a
  # neveket KEZZEL kellene atirni -- az pedig egy masodik zajforras, amit utana nem lehet
  # szetvalasztani a lehivo sajat elteresetol. Ha a nyers torzs fajlba kerul, a sorok
  # gepileg kinyerhetok, atiras nincs, tehat masodik zajforras sincs.
  # A mentes NEM valtoztat a lehivason: ugyanaz az egy GET, ugyanannyi keres.
  # A SIKER-UZENET CSAK AKKOR MEHET KI, HA A MASOLAS TENYLEG MEGTORTENT.
  # Merve 2026-09-02 (barracuda): ha a celmappa nem letezik, a cp elhasal, es a szkript
  # ettol fuggetlenul kiirta, hogy "mentve: <fajl> (N bajt)". Nema siker: a hivo azt hiszi,
  # fajlja van, es a kovetkezo lepes egy nem letezo fajlt olvasna.
  # ES A MASODIK ORZO, MERVE 2026-09-07 (barracuda, kulso kep-mentes): a --save AKKOR IS
  # letrehozta a fajlt, ha a valasz nem 200. Ot cim HTTP 500-at adott, es ot 544 bajtos
  # HTML hibaoldal keletkezett PNG neven, betüre azonos tartalommal. A FIGYELMEZTETES
  # KIMENT (lentebb, a status-blokkban), es a fajl IS elkeszult -- ugyanaz a csalad, mint
  # a fenti nema siker, csak forditva: itt az orzo szol, es a muvelet megis vegigmegy.
  #
  # A GUARD ITT ALL, NEM A BLOKK ELOTT, ES EZ TUDATOS (barracuda indoklasa): ha a teljes
  # --save blokkot a status-ellenorzes MOGE tennenk, akkor a PATTERN kimenet is elveszne
  # nem-200-nal, pedig epp az mondja meg, mit adott vissza a szerver.
  if [[ "$CODE" != "200" ]]; then
    echo "FAIL a mentes NEM tortent meg: a valasz $CODE, nem 200 ($SAVE)" >&2
    exit 1
  fi
  if cp "$BODY" "$SAVE" 2>/dev/null && [[ -s "$SAVE" ]]; then
    echo "mentve: $SAVE ($SIZE bajt)"
  else
    echo "FAIL a mentes NEM tortent meg: $SAVE (letezik a mappa?)" >&2
    exit 1
  fi
fi

if [[ "$CODE" != "200" ]]; then
  echo "FIGYELEM: a valasz nem 200, a fenti szamok nem a termeklaprol szolnak." >&2
  exit 1
fi
