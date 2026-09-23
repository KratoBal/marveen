#!/bin/bash
# PAROSITOTT-E EZ AZ AZONOSITO? -- egy kerdes, egy valasz, a lista nelkul.
#
# ELESITVE 2026-08-28 23:31, Balazs jovahagyasaval (Discord, fo csatorna).
# A sudoers sor kulon lepes, es a gazda teszi be a hostrol -- addig csak marveen hivhatja.
#
# AMIERT LETEZIK: ha ismeretlen kuldo ir egy sub-agensnek, az aranyszabaly szerint a fougenshez
# kell fordulnia, mert az allowFrom osszevetes csak ott lehetseges. 2026-08-28 este pont a
# fougens volt elerhetetlen, tehat az a lanc szunetelt, ami a kerdest eldontotte volna.
#
# AMIERT NEM A LISTAT ADJA ODA: a lista birtokaban minden agens ismeri az OSSZES parositott
# szemely azonositojat; a kerdes birtokaban csak azt az egyet, amire ravalaszoltunk. Kiszivargas
# eseten az elso a teljes kort viszi, a masodik egy sort.
#
# AMIT NEM CSINAL, SZANDEKOSAN:
#   - nem listaz, es nem irja ki a lista egyetlen elemet sem
#   - nem BOVITI az allowlistat (az Balazs es a fougens dolga)
#   - a NEM valasz utan nem dont: azt a kerdest tovabbra is a fougens kapja
#
# HASZNALAT (az agens a sajat felhasznalojaval hivja, sudo-n at):
#   sudo -n /home/marveen/marveen/scripts/is-paired.sh discord 1460588146113642655
#   -> PAROSITOTT   vagy   NEM PAROSITOTT
#
# A hozza tartozo sudoers sor (kulon jovahagyassal, ez a fajl onmagaban nem eleg):
#   agent-<nev> ALL=(marveen) NOPASSWD: /home/marveen/marveen/scripts/is-paired.sh
set -uo pipefail

CHANNELS_DIR="/home/marveen/.claude/channels"
AUDIT_LOG="/home/marveen/marveen/store/is-paired-audit.log"
# Riasztasi kuszob: hany KULONBOZO azonositora kerdezhet egy agens az ablakon belul, mielott
# a fougens ertesitest kap. Nem tilt, csak szol -- jogos sorozat is letezik (egy csoportos
# beszelgetes uj resztvevoi), es a kulonbseget ember latja, nem a szkript.
ALERT_DISTINCT=5
ALERT_WINDOW_MIN=60

usage() {
  echo "hasznalat: is-paired.sh <provider> <azonosito>" >&2
  echo "  provider: discord vagy telegram" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
PROVIDER="$1"
CANDIDATE="$2"

case "$PROVIDER" in
  discord|telegram) ;;
  *) echo "ismeretlen provider: $PROVIDER" >&2; usage ;;
esac

# Csak szamjegy: a csatorna-azonositok ilyenek, es igy semmilyen mintat nem lehet becsempeszni.
case "$CANDIDATE" in
  ''|*[!0-9]*) echo "az azonosito csak szamjegyekbol allhat" >&2; exit 2 ;;
esac

ACCESS="$CHANNELS_DIR/$PROVIDER/access.json"
if [ ! -r "$ACCESS" ]; then
  echo "NEM OLVASHATO: $ACCESS" >&2
  exit 3
fi

# A hivo az az agens-felhasznalo, aki a sudo-t inditotta. Ha nincs SUDO_USER (kozvetlen hivas),
# a sajat felhasznalonev all be -- igy a naplo sosem marad cimke nelkul.
CALLER="${SUDO_USER:-$(id -un)}"

ANSWER="$(ACCESS="$ACCESS" CANDIDATE="$CANDIDATE" python3 - <<'PY'
import json
import os
import sys

with open(os.environ["ACCESS"], encoding="utf-8") as fh:
    data = json.load(fh)

candidate = os.environ["CANDIDATE"]
allowed = set(data.get("allowFrom", []))
for group in (data.get("groups") or {}).values():
    allowed.update(group.get("allowFrom", []))

sys.stdout.write("PAROSITOTT" if candidate in allowed else "NEM PAROSITOTT")
PY
)"
RC=$?
if [ "$RC" -ne 0 ] || [ -z "$ANSWER" ]; then
  echo "a lista olvasasa nem sikerult" >&2
  exit 4
fi

# AUDIT. Ez nem kiegeszito elem, hanem a vedelem maga: egy igen/nem valasz EGY bitet ad ki, es
# a bitek osszeadodnak -- aki eleg sokszor kerdez, a listat epiti fel, csak lassabban. A
# szethordas ellen tehat nem a valasz szukossege ved, hanem az, hogy latszik.
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\t%s\t%s\t%s\t%s\n' "$STAMP" "$CALLER" "$PROVIDER" "$CANDIDATE" "$ANSWER" >> "$AUDIT_LOG"

DISTINCT="$(AUDIT_LOG="$AUDIT_LOG" CALLER="$CALLER" WINDOW="$ALERT_WINDOW_MIN" python3 - <<'PY'
import datetime
import os

path = os.environ["AUDIT_LOG"]
caller = os.environ["CALLER"]
window = int(os.environ["WINDOW"])
cutoff = datetime.datetime.now() - datetime.timedelta(minutes=window)

seen = set()
with open(path, encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 5:
            continue
        try:
            when = datetime.datetime.strptime(parts[0], "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
        if when >= cutoff and parts[1] == caller:
            seen.add(parts[3])
print(len(seen))
PY
)"

if [ "${DISTINCT:-0}" -ge "$ALERT_DISTINCT" ]; then
  # A fougens ertesitese: nem tiltas, jelzes. Ha ez maga is elbukik, a valasz akkor is megy.
  bash /home/marveen/marveen/scripts/agent-msg.sh "$CALLER" acrobot \
    "[IS-PAIRED FIGYELMEZTETES] $CALLER $DISTINCT kulonbozo azonositora kerdezett $ALERT_WINDOW_MIN percen belul. A naplo: $AUDIT_LOG" \
    >/dev/null 2>&1 || true
fi

echo "$ANSWER"
