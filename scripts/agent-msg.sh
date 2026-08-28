#!/usr/bin/env bash
# agent-msg.sh -- reliable inter-agent message send for the Marveen fleet.
#
# WHY: the common `curl -s ... >/dev/null && echo sent` pattern is DANGEROUS -- curl exits 0 even when
# the server REJECTED the request (401/400/5xx), producing a SILENT send failure: the recipient never
# gets the message and two agents can wait on each other forever. The /api/messages router itself is
# fine (HTTP 200 + a message id); the bug is that the SENDER never checks the result. This helper checks
# the HTTP status AND the returned message id, and RETRIES on failure. A message counts as sent only
# when an id came back.
#
# Usage:  bash scripts/agent-msg.sh <from> <to> "<content>"
#   content: plain text (quotes / newlines OK) -- the body is built with json.dumps (no quoting pitfalls).
#   large / multi-line content may come from STDIN when the 3rd arg is "-":
#     echo "<long text>" | bash scripts/agent-msg.sh <from> <to> -
# Output: success -> "OK id=<n>"; failure -> "FAIL <reason>" + a line in store/agent-msg-failures.log, exit 1.
# Env: MARVEEN_WEB_PORT (default 3420).
set -uo pipefail

# base dir = the parent of this script's dir (scripts/..), so it works from any CWD / any install
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${MARVEEN_WEB_PORT:-3420}"
TOKEN_FILE="$BASE/store/.dashboard-token"
URL="http://localhost:${PORT}/api/messages"
LOG="$BASE/store/agent-msg-failures.log"

# ARGUMENTUM-SZAM ORZO. A helper a HARMADIK argumentumot viszi tartalomkent, a tobbit eddig
# CSENDBEN eldobta. Ez azert veszelyes, mert van egy gyakori mod, ahogy egy ep uzenet TOBB
# argumentumra esik szet: ha a szovegben DUPLA IDEZOJEL all, es az egeszet dupla idezojelbe
# tesszuk a parancssorban, a bash az elso belso idezojelnel LEZARJA a stringet. Merve
# 2026-08-27 (murena): egy hatvan szavas uzenetbol hat argumentum lett, es a cimzett ennyit
# kapott: "elso resz, aztan a te". A kuldes kozben VEGIG zold maradt -- HTTP 200, OK id=5305,
# delivered allapot --, mert a helper a kezbesitest ellenorzi, a TARTALMAT nem, es nem is
# tudhatja, mit szantak neki. A jel viszont gepileg mereheto: TOBB MINT HAROM ARGUMENTUM.
# A helyes hivasokat nem erinti, azok mind harommal mennek. (nautilus javaslata, ugyanaznap.)
# ES A CSALAD TAGABB, MINT AZ IDEZOJEL: ugyanezen az estén nautilus tizenot naplobejegyzese
# ugy veszett el, hogy az idezojelei RENDBEN voltak, csak eggyel tobb argumentumot adott at,
# mint amennyit a parancs olvas. Ezert ez ARITY-orzo, nem idezojel-orzo: barmely helper, ami
# rogzitett poziciokat olvas, csendben eldobja a tobbit, es a jel mindket okra ugyanaz.
# ES AMI TULMEGY AZ ORZO HATARAN, hogy ne higgyuk tobbnek, mint ami: ez CSONKULAST fog meg,
# BEHELYETTESITEST nem. Ha a szovegben ${VALTOZO} vagy backtick all, az argumentumszam NEM no,
# tehat itt semmi nem szolal meg -- a cimzett teljes, ertelmes mondatot kap, csak MASIKAT.
# Merve 2026-08-27 (murena leletebol, visszamerve): "az utvonal ${BASE}/owners alakban all"
# ugy erkezett meg, hogy "az utvonal /home/marveen/marveen/owners alakban all". Technikai
# szoveget ezert akkor is STDIN-rol kell kuldeni, ha rovid es nincs benne idezojel.
if [ "$#" -gt 3 ]; then
  echo "FAIL: $# argumentum erkezett, de az agent-msg.sh harmat ismer (from, to, content)." >&2
  echo "  Ket oka lehet, es mindketto CSENDBEN dobta volna el a tobbit:" >&2
  echo "    (1) a szoveg szetesett egy dupla idezojelnel," >&2
  echo "    (2) eggyel tobb argumentumot adtal at, mint amennyit a helper olvas." >&2
  echo "  A helyes alak: bash scripts/agent-msg.sh <from> <to> - < uzenet.txt" >&2
  exit 1
fi

FROM="${1:?from required}"; TO="${2:?to required}"; C="${3:?content required (or - for STDIN)}"
[ "$C" = "-" ] && C="$(cat)"
# HALASZTAS-SZURO. Balazs allo szabalya: nincs olyan, hogy "majd holnap". Ha valami tenyleg
# nem mehet most, akkor NEM napszakot nevezunk meg, hanem a VALODI AKADALYT (mire varunk, kitol,
# mi hianyzik). A szabaly dokumentumban allt, es 2026-08-19 estejen igy is elhangzott tobbszor --
# ezert kerult eszkozbe. Nem tilt: figyelmeztet, es a stderr-en nevesiti a talalt szot, hogy a
# kuldo lassa, mit irt le. Kikapcsolas egy adott uzenetre: MSG_ALLOW_DEFER=1.
if [ "${MSG_ALLOW_DEFER:-0}" != "1" ]; then
  DEFER_HIT="$(printf '%s' "$C" | /bin/grep -oiE 'majd holnap|holnap reggel|reggel csinal|reggel nezz|friss fejjel|kipihen|holnapra hagy' | head -3 | tr '\n' ' ')"
  if [ -n "$DEFER_HIT" ]; then
    echo "FIGYELEM (halasztas-szuro): az uzenetben halaszto fordulat van -> ${DEFER_HIT}" >&2
    echo "  Ha tenyleg nem mehet most, nevezd meg az AKADALYT (kire/mire vartok), ne a napszakot." >&2
    echo "  Ha szandekos: MSG_ALLOW_DEFER=1 elotaggal kuldd ujra." >&2
  fi
fi

[ -r "$TOKEN_FILE" ] || { echo "FAIL: no token file at $TOKEN_FILE"; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"

BODY="$(FROM="$FROM" TO="$TO" C="$C" python3 -c 'import json,os; print(json.dumps({"from":os.environ["FROM"],"to":os.environ["TO"],"content":os.environ["C"]}))')"

attempt=0; max=3; CODE=""; ID=""
while [ "$attempt" -lt "$max" ]; do
  attempt=$((attempt+1))
  RESP="$(curl -s -X POST "$URL" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "$BODY" -w $'\n%{http_code}' 2>/dev/null || true)"
  CODE="$(printf '%s' "$RESP" | tail -n1)"
  JSON="$(printf '%s' "$RESP" | sed '$d')"
  ID="$(printf '%s' "$JSON" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("id","") if isinstance(d,dict) else "")
except Exception:
  print("")' 2>/dev/null)"
  if { [ "$CODE" = "200" ] || [ "$CODE" = "201" ]; } && [ -n "$ID" ]; then
    echo "OK id=$ID"; exit 0
  fi
  sleep 1
done
echo "FAIL from=$FROM to=$TO http=${CODE:-?} id='$ID' (after $max tries)"
printf '%s\tFAIL\tfrom=%s\tto=%s\thttp=%s\tresp=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$FROM" "$TO" "${CODE:-?}" "$(printf '%s' "${JSON:-}" | head -c 200)" >> "$LOG" 2>/dev/null || true
exit 1
