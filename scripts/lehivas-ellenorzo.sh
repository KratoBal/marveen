#!/usr/bin/env bash
# ANSWERS: Valodi-e egy kulso lehivas eredmenye, vagy kitalalt lista hiheto nevekkel es arakkal.
#
# lehivas-ellenorzo.sh <fajl> <vart-domain> [vart-tetelszam]
#
# MIERT LETEZIK, merve 2026-09-08 22:24 (barracuda). Egy quarantine-reader lehivas
# TIZENHAROM terméket adott vissza egy Tropus-kategoriara: magyar terméknevek (Aqua Medic
# Titan, Blue Marine Chiller), ar szerint novekvo sorrendben, a kategoriahoz illo kinalattal.
# Meresi eredmenynek nezett ki. MINDEN termek-URL `www.example.com` helyorzo volt, egyetlen
# valodi cim sem.
#
# EZ UJ FAJTA, NEM UJABB HIBA. Az eddigi buktatoink arrol szoltak, hogy a meres KEVESEBBET
# lat a valosagnal: nulla talalat, elveszett athuzott ar, csonka nev. Ez az elso, ahol a
# meres TOBBET ad, mint amit latott -- nem hianyzik semmi, hanem LETEZIK valami, ami nincs.
#
# ES A VEDELEM SEM UGYANAZ. A hianyra pozitiv kontroll valaszol. A kitalalasra csak olyan
# mezo, amit a modell nem tud helyesen eloallitani: a CIM. Egy nevet es egy arat ki lehet
# talalni hihetoen; egy letezo terméklap URL-jet nem.
#
# A KEREK SZAM CSAK GYANU, NEM BIZONYITEK. Barracuda elsore a negy azonos, kerek 1000000
# erteket is a hamisitas jelenek nevezte, majd VISSZAVONTA: egy masodik, fuggetlen lehivas
# ugyanazt a negy erteket adta, mas URL-alakkal. Ket fuggetlen lehivas egyezese eseten ez a
# lap sajat viselkedese, nem kitoltes.
#
# A LEHIVO SAJAT JELZESERE NE EPITS. Az adott esetben a sub-agens maga jelezte az `error`
# mezoben, hogy a tartalom megbizhatatlan -- ez a helyes mukodes, de a kovetkezo alkalommal
# lehet, hogy nem veszi eszre. A cim-ellenorzes a HIVO dolga.
#
# Csak olvas: egy helyi fajlt nez meg, semmit nem hiv es semmit nem ir.
set -uo pipefail

if [[ $# -lt 2 ]]; then
  echo "hasznalat: bash /home/marveen/marveen/scripts/lehivas-ellenorzo.sh <fajl> <vart-domain> [vart-tetelszam]" >&2
  echo "  pelda:    bash /home/marveen/marveen/scripts/lehivas-ellenorzo.sh koteg.json tropus-szeged.hu 13" >&2
  exit 2
fi

FAJL="$1"
DOMAIN="$2"
VART="${3:-}"

if [[ ! -f "$FAJL" ]]; then
  echo "FAIL a fajl nem letezik: $FAJL" >&2
  exit 1
fi

# A helyorzo-domainek listaja. Ezek egyike sem allhat egy valodi lehivasban.
HELYORZOK=(example.com example.org example.net "localhost" "your-domain" "domain.com" "site.com")

BAJT="$(wc -c < "$FAJL" | tr -d ' ')"
echo "fajl:    $FAJL ($BAJT bajt)"
echo "domain:  $DOMAIN"

GYANU=0

echo "--- helyorzo-cimek (mindnek NULLANAK kell lennie) ---"
for H in "${HELYORZOK[@]}"; do
  N="$(/bin/grep -o -i -F -- "$H" "$FAJL" | wc -l | tr -d ' ')"
  printf '  %-14s %s\n' "$H" "$N"
  if [[ "$N" != "0" ]]; then GYANU=1; fi
done

VALODI="$(/bin/grep -o -i -F -- "$DOMAIN" "$FAJL" | wc -l | tr -d ' ')"
echo "--- a vart domain ---"
printf '  %-14s %s\n' "$DOMAIN" "$VALODI"

# A NULLA ITT IS A KERDES TULAJDONSAGA LEHET: ha a domaint elgepelted, nulla jon egy
# tokeletes fajlra is. Ezert a szam mindig kiirodik, es a verdikt kulon mondatban all.
if [[ -n "$VART" ]]; then
  echo "  vart tetelszam: $VART"
  if [[ "$VALODI" -lt "$VART" ]]; then
    echo "  FIGYELEM: kevesebb valodi cim van, mint tetel. Nem minden tetelhez tartozik cim."
    GYANU=1
  fi
fi

echo "---"
if [[ "$GYANU" != "0" ]]; then
  echo "VERDIKT: GYANUS -- helyorzo-cim all a valaszban, VAGY kevesebb valodi cim van a tetelszamnal."
  echo "         Az adat KITALALT lehet, akarmilyen esszeru a tobbi mezo. NE hasznald mert adatkent."
  exit 1
fi
if [[ "$VALODI" == "0" ]]; then
  echo "VERDIKT: NEM DONTHETO EL -- nulla valodi cim, de helyorzo sincs."
  echo "         Ellenorizd, hogy a megadott domain helyes-e ($DOMAIN). Egy elgepelt domain"
  echo "         ugyanezt adja egy tokeletes fajlra is."
  exit 2
fi
echo "VERDIKT: ATMENT -- nincs helyorzo-cim, es $VALODI valodi cim all a valaszban."
