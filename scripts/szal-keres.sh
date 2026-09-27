#!/usr/bin/env bash
# ANSWERS: Megbeszeltuk-e mar? A DISCORD SZALAK elozmenyeben keres, ekezettol fuggetlenul.
#
# MIERT LETEZIK (sajat hiba, merve 2026-09-03). Ketszer kerdeztem meg Balazstol egy nap
# alatt olyat, amit mar eldontott (a hosszu leiras mezoje, es a kepek kulon taroloja).
# Mindketszer megkerestem a sajat emlekeimet, es azt jelentettem, hogy "sehol nincs
# rogzitve". O EGY PERC alatt megtalalta -- a Discord szalban, ahol elhangzott.
#
# AZ OK NEM FELEDEKENYSEG, HANEM A TAROLOK LISTAJA. Az automatikus visszakereses
# (scripts/hooks/prior-art-recall.py) NEGY helyet nez: emlek, napi naplo, kartya, komment.
# A CSATORNA-ELOZMENY nincs kozottuk -- pedig a dontesek OTT hangzanak el eloszor.
#
# Es nem is volt kepesseg-hiany: a bot token megvan, a Discord API valaszol. Sosem
# probaltam. Ez a szkript ezt a lyukat zarja be.
#
# HASZNALAT:
#   bash scripts/szal-keres.sh "hosszu leiras"            # a fo csatorna plusz a fontos szalak
#   bash scripts/szal-keres.sh "hosszu leiras" --mind     # MINDEN ismert szal
#   bash scripts/szal-keres.sh "kep tarolo" 1542865300565790850   # egy konkret szal
#
# A NULLA TALALAT ITT IS KIIRJA, MIT KERESTEL -- ugyanaz a szabaly, mint a keres.sh-nal:
# a nulla lehet a kerdes tulajdonsaga, nem a vilage.
#
# A HATARA, ES EZT TUDNI KELL: a Discord bot API NEM ad keresest, csak elozmenyt. Ez a
# szkript szalankent az utolso 300 uzenetet nezi at (harom lapozas). Ami annal regebbi,
# azt NEM latja -- es a kimenet ezt kiirja, hogy a nulla hatokore latszodjon.
set -uo pipefail

ENVF="$HOME/.claude/channels/discord/.env"
[ -r "$ENVF" ] || { echo "FAIL: nem olvashato: $ENVF" >&2; exit 1; }
TOK="$(/bin/grep -oP '(?<=^DISCORD_BOT_TOKEN=).*' "$ENVF" | tr -d '"'"'" )"
[ -n "$TOK" ] || { echo "FAIL: nincs DISCORD_BOT_TOKEN a $ENVF fajlban" >&2; exit 1; }

MINTA="${1:-}"
[ -n "$MINTA" ] || { echo "HASZNALAT: szal-keres.sh <minta> [--mind | <chat_id>]" >&2; exit 2; }
MODE="${2:-fontos}"

# A szalak a CLAUDE.md tablajabol. Ha uj szal jon, ide is fel kell venni.
FONTOS="1538522302277353505:Fo_csatorna
1540270627926183997:Eldontendo_dolgok
1542865300565790850:UNAS_Medusa_migracio
1541477372245835786:Commerce_fejlesztes
1543527864190902292:Commerce_frontend
1543587794444750868:Product_Master"
MIND="$FONTOS
1538564799175331903:Acropora_OS
1538617128066883666:Luca_tartalom
1540314224503427192:Canva
1540331536887451731:Google
1540399184052621472:Mobilalkalmazas
1540429953034756187:Munkalap_folyamatok
1541098404522893372:OS_weboldal
1541513491700252764:Veletek_kapcsolatos
1541811508692918402:AI_feladatok
1541878396013912105:Szervizpartnerek
1542238835537346570:Mobil_Android
1542478178898157588:Szerviz_eszkoznyilvantartas
1542484792044691606:Szerviz_ticketing
1542556954088444075:Biztonsag
1542600944871546970:Luca_Balazs_Acrobot
1544365768014176306:Codex
1544377064680071288:API_vagy_elofizetes
1544578417456980060:Acrobot_fejlesztes
1544587063234396202:Staging_es_Eles
1544707009545240657:Megrendelesek_frontend
1544644461152178226:Matricak_QR"

case "$MODE" in
  --mind)  LISTA="$MIND" ;;
  fontos)  LISTA="$FONTOS" ;;
  *)       LISTA="$MODE:megadott_szal" ;;
esac

echo "--- szal-keres: '$MINTA' ---"
TOK="$TOK" MINTA="$MINTA" LISTA="$LISTA" python3 - <<'PY'
import json, os, subprocess, sys, unicodedata, datetime

tok   = os.environ["TOK"]
minta = os.environ["MINTA"]
lista = [l for l in os.environ["LISTA"].split("\n") if l.strip()]

def fold(s):
    s = unicodedata.normalize("NFD", s or "")
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    return s.lower()

needle = fold(minta)

def fetch(chan, before=None):
    url = "https://discord.com/api/v10/channels/%s/messages?limit=100" % chan
    if before: url += "&before=" + before
    r = subprocess.run(["curl", "-s", "-H", "Authorization: Bot " + tok, url],
                       capture_output=True, text=True)
    try:
        d = json.loads(r.stdout)
        return d if isinstance(d, list) else []
    except Exception:
        return []

osszes_hit = 0
legregebbi = {}
for sor in lista:
    chan, nev = sor.split(":", 1)
    msgs, before = [], None
    for _ in range(3):                      # 300 uzenet szalankent
        batch = fetch(chan, before)
        if not batch: break
        msgs += batch
        before = batch[-1]["id"]
        if len(batch) < 100: break
    if msgs:
        legregebbi[nev] = msgs[-1].get("timestamp", "?")[:16].replace("T", " ")
    for m in msgs:
        tartalom = m.get("content") or ""
        if needle not in fold(tartalom): continue
        ts  = (m.get("timestamp") or "")[:16].replace("T", " ")
        ki  = (m.get("author") or {}).get("username", "?")
        # a talalt sor kornyezete
        for line in tartalom.split("\n"):
            if needle in fold(line):
                print("  [%s] %s @ %s" % (ts, ki, nev))
                print("      %s" % line.strip()[:400])
                osszes_hit += 1
                break

print()
if osszes_hit == 0:
    print("TALALAT: 0")
    print("A NULLA MELLE, hogy a kovetkezo olvaso ellenorizhesse a KERDEST:")
    print("  a beirt minta       : '%s'" % minta)
    print("  osszehajtott alakja : '%s'" % needle)
    print("  Ekezet- es kis-nagybetu-fuggetlen volt. Ha a nulla megis meglepo, NEM az")
    print("  irasmod a magyarazat -- keress mas SZORA, vagy --mind kapcsoloval tobb szalban.")
else:
    print("TALALAT: %d" % osszes_hit)
print()
print("A LATOHATAR (szalankent az utolso 300 uzenet; ennel regebbit NEM lat):")
for nev, ts in legregebbi.items():
    print("  %-28s eddig: %s" % (nev, ts))
PY
