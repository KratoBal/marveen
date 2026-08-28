#!/usr/bin/env bash
# fleet-api.sh -- narrow, allowlist-friendly wrapper around the LOCAL dashboard API.
#
# WHY: the strict security profiles (marketer, researcher) intentionally withhold raw
# `curl` from sub-agents, because those agents read web content and are a prompt-injection
# surface -- a raw curl is an exfiltration primitive. But the very same agents are REQUIRED
# by their persona to save memory, post a daily-log entry and status their kanban cards.
# Without a way to do that they stop on a permission prompt mid-task and the session hangs
# (observed on the korall agent right after its first task).
#
# This wrapper is the middle ground: the target host is HARDCODED to the local dashboard,
# so approving `Bash(bash .../scripts/fleet-api.sh:*)` grants dashboard access WITHOUT
# granting arbitrary outbound HTTP. No URL is ever taken from the caller.
#
# Usage:
#   bash scripts/fleet-api.sh memory <agent> <category> "<content>" "<keywords>"
#   bash scripts/fleet-api.sh memory-search <agent> "<query>" [category]
#   bash scripts/fleet-api.sh daily-log <agent> "<content>"
#   bash scripts/fleet-api.sh daily-log-now <agent> "<tema>" "<szoveg>"   # a "## HH:MM --"
#         fejlecet a RENDSZERORA teszi ra; ezt hasznald, ne gepeld be az idopontot
#   bash scripts/fleet-api.sh daily-log-read <agent> [YYYY-MM-DD] [full]   # READ it back
#         (hossz + elso sor bejegyzesenkent; "full" a teljes szoveget irja ki)
#   bash scripts/fleet-api.sh kanban-list
#   bash scripts/fleet-api.sh kanban-new "<title>" <status> <assignee> <priority>
#   bash scripts/fleet-api.sh kanban-move <card_id> <status> [actor]
#   bash scripts/fleet-api.sh kanban-assign <card_id> <assignee>
#   bash scripts/fleet-api.sh kanban-comment <card_id> <author> "<content>"
#   bash scripts/fleet-api.sh kanban-comments <card_id>          # READ them back
#   bash scripts/fleet-api.sh message-read <id>       # a TELJES tartalom, vagas nelkul
#   bash scripts/fleet-api.sh message-status <id>
#   bash scripts/fleet-api.sh messages-sent <agent> [limit]
#   bash scripts/fleet-api.sh schedule-new <nev> <leiras> <prompt> <cron> <agent> [tipus]
#   bash scripts/fleet-api.sh approval-new <agent> <kategoria> <leiras>
#         (a lejarat a KATEGORIABOL jon, nem adhato meg hivaskor -- lasd a parancsnal)
#   bash scripts/fleet-api.sh approval-get <id>
#
# Any argument may be "-" to read that value from STDIN (for long/multi-line content).
# Output: the raw API response on success; "FAIL <reason>" + exit 1 otherwise.
# Env: MARVEEN_WEB_PORT (default 3420).
#
# For SENDING inter-agent messages use scripts/agent-msg.sh -- it has the retry + id check.
# For CHECKING whether they arrived, use `message-status` / `messages-sent` here. The two
# are not the same thing and the difference has cost us: agent-msg.sh printing `OK id=<n>`
# means the queue ACCEPTED the message, not that the recipient read it. Measured 2026-08-17:
# eight messages went to one agent, exactly one was delivered, six sat `pending` for up to
# 52 minutes (its context was full, and a saturated session stops draining its queue) --
# and the sender reported all eight as handed over. Before writing that someone "was told",
# check the status. Added because polip asked for it: the rule was unenforceable without
# a tool, and its profile has no raw curl.
set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${MARVEEN_WEB_PORT:-3420}"
API="http://localhost:${PORT}/api"
TOKEN_FILE="$BASE/store/.dashboard-token"

[ -r "$TOKEN_FILE" ] || { echo "FAIL: no token file at $TOKEN_FILE"; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"

# "-" means: take this value from STDIN. Only the first such argument can be piped.
stdin_used=0
arg() {
  local v="${1-}"
  if [ "$v" = "-" ] && [ "$stdin_used" -eq 0 ]; then stdin_used=1; cat; else printf '%s' "$v"; fi
}

# ARGUMENTUM-SZAM ORZO, PARANCSONKENT. Ugyanaz a nema hiba, mint az agent-msg.sh-ban: ha egy
# szoveges argumentumban DUPLA IDEZOJEL all, es az egeszet dupla idezojelbe tesszuk a
# parancssorban, a bash az elso belso idezojelnel lezarja a stringet, a maradek kulon
# argumentumokka esik szet, es a felesleget a case ag CSENDBEN eldobja. Merve 2026-08-27
# (murena): egy hatvan szavas uzenetbol hat argumentum lett, es a hivas VEGIG zold maradt.
# Itt GLOBALIS felso hatar nem hasznalhato: a tizenot parancs arityja 1 es 7 kozott szor
# (kanban-list 1, memory 5, schedule-new 7), tehat egyetlen kozos szam HELYES hivast is
# elutasitana -- az a hamis pozitiv rosszabb, mint a hianyzo orzo. Ezert a hatar ott all,
# ahol az arity ugyis ki van irva: a sajat case againak elejen. A szam a SHIFT UTANI
# argumentumokra vonatkozik (a parancsszo mar le van valasztva).
argc_max() {
  local max="$1" got="$2" hint="$3"
  [ "$got" -le "$max" ] && return 0
  echo "FAIL: ${CMD}: ${got} argumentum erkezett, de a parancs legfeljebb ${max}-t ismer." >&2
  echo "  Ket oka lehet, es mindketto CSENDBEN dobta volna el a tobbit:" >&2
  echo "    (1) a szoveg szetesett egy dupla idezojelnel," >&2
  echo "    (2) eggyel tobb argumentumot adtal at, mint amennyit a parancs olvas." >&2
  echo "  A helyes alak: ${hint}" >&2
  exit 1
}

# Build a JSON object from alternating key/value pairs, without quoting pitfalls.
json_obj() {
  python3 -c '
import json,sys
a=sys.argv[1:]
print(json.dumps({a[i]: a[i+1] for i in range(0,len(a),2)}))' "$@"
}

# POST <path> <json-body>; prints the response, fails loudly on a non-2xx status.
post() {
  local path="$1" body="$2"
  local resp code json
  resp="$(curl -s -X POST "${API}${path}" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -d "$body" -w $'\n%{http_code}' 2>/dev/null || true)"
  code="$(printf '%s' "$resp" | tail -n1)"
  json="$(printf '%s' "$resp" | sed '$d')"
  case "$code" in
    200|201) printf '%s\n' "$json" ;;
    *) echo "FAIL http=${code:-?} path=${path} resp=$(printf '%s' "$json" | head -c 200)"; exit 1 ;;
  esac
}

get() {
  local path="$1"
  curl -s -H "Authorization: Bearer $TOKEN" "${API}${path}" || { echo "FAIL: GET ${path}"; exit 1; }
}

# PUT <path> <json-body>; same contract as post(). Kanban card fields (assignee,
# title, priority) are updated with PUT, not POST -- without this a sub-agent
# cannot hand a blocked card back to its delegator, because the strict profiles
# withhold raw curl. Observed 2026-08-15: polip wrote the hand-back comment and
# set waiting, but its own name stayed on the card, so the ownership change was
# invisible on the dashboard.
put() {
  local path="$1" body="$2"
  local resp code json
  resp="$(curl -s -X PUT "${API}${path}" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -d "$body" -w $'\n%{http_code}' 2>/dev/null || true)"
  code="$(printf '%s' "$resp" | tail -n1)"
  json="$(printf '%s' "$resp" | sed '$d')"
  case "$code" in
    200|201) printf '%s\n' "$json" ;;
    *) echo "FAIL http=${code:-?} path=${path} resp=$(printf '%s' "$json" | head -c 200)"; exit 1 ;;
  esac
}

CMD="${1:?command required}"; shift || true

case "$CMD" in
  memory)
    argc_max 4 "$#" "fleet-api.sh memory <agent> <category> - < szoveg.txt \"kulcsszavak\""
    AGENT="$(arg "${1:?agent required}")"; CAT="$(arg "${2:?category required}")"
    CONTENT="$(arg "${3:?content required}")"; KEYWORDS="$(arg "${4-}")"
    post /memories "$(json_obj agent_id "$AGENT" category "$CAT" content "$CONTENT" keywords "$KEYWORDS")"
    ;;
  memory-search)
    argc_max 3 "$#" "fleet-api.sh memory-search <agent> \"kulcsszo\" [kategoria]"
    AGENT="$(arg "${1:?agent required}")"; Q="$(arg "${2:?query required}")"; CAT="${3-}"
    Q_ENC="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$Q")"
    P="/memories?agent=${AGENT}&q=${Q_ENC}"
    [ -n "$CAT" ] && P="${P}&category=${CAT}"
    get "$P"
    ;;
  daily-log)
    # A hatar KETTO, es ez pontosan az az ag, ahol 2026-08-27 este nautilus tizenot bejegyzese
    # csonkan ment el: negy szoval hivta (daily-log <agens> "Tema" "torzs"), a torzs elveszett,
    # es a valasz mind a tizenotszor {"ok":true} volt. Ott nem idezojel esett szet, hanem eggyel
    # tobb argumentumot adott at -- ezert ez arity-orzo, nem idezojel-orzo. Ha tema es torzs kell
    # kulon, a daily-log-now valo hozza (az a HH:MM fejlecet is meri).
    argc_max 2 "$#" "fleet-api.sh daily-log <agent> - < szoveg.txt   (tema+torzs: daily-log-now <agent> \"Tema\" - < szoveg.txt)"
    AGENT="$(arg "${1:?agent required}")"; CONTENT="$(arg "${2:?content required}")"
    post /daily-log "$(json_obj agent_id "$AGENT" content "$CONTENT")"
    ;;
  daily-log-now)
    # Same as daily-log, but the "## HH:MM -- " header is stamped from the SYSTEM CLOCK
    # instead of being typed into the text. Twice on 2026-08-18 a log entry carried a
    # header two to five minutes ahead of the real time, both times for the same reason:
    # `date` ran in the same call that wrote the entry, so the header was a guess made
    # before the measurement came back. An append-only log cannot be edited afterwards --
    # the fix is a correction entry, which is more noise than the entry was worth.
    # Pass the TOPIC as the second argument and the body as the third; the timestamp is
    # not yours to write.
    #   fleet-api.sh daily-log-now acrobot "Tema" "A szoveg"
    #   fleet-api.sh daily-log-now acrobot "Tema" - < body.txt
    argc_max 3 "$#" "fleet-api.sh daily-log-now <agent> \"Tema\" - < szoveg.txt"
    AGENT="$(arg "${1:?agent required}")"; TOPIC="$(arg "${2:?topic required}")"
    BODY="$(arg "${3:?content required}")"
    # NOT `date`: glibc here answers UTC (the Europe/Budapest zone file is an
    # empty read-only bind mount from the host), so `date` is two hours behind.
    # local-now.sh reads Node's tz data and fails rather than guessing.
    STAMP="$(bash "$BASE/scripts/local-now.sh")"
    [ -n "$STAMP" ] || { echo "FAIL local clock unmeasurable -- refusing a guessed header" >&2; exit 1; }
    post /daily-log "$(json_obj agent_id "$AGENT" content "## $STAMP -- ${TOPIC}
${BODY}")"
    ;;
  daily-log-read)
    # A NAPLO VISSZAOLVASASA. Eddig CSAK IRNI lehetett, es 2026-08-27 este kiderult, hogy ez nem
    # elmeleti hiany: nautilus tizenot bejegyzese csonkan ment el (42 es 67 karakter kozott, csak
    # a temasor), mert a daily-log agat negy szoval hivta, es MIND A TIZENOTSZOR {"ok":true} jott
    # vissza. Aki ir, a sajat eredmenyet nem latta. Murena ugyanaznap kerte, hogy legyen olvaso:
    # o a daily-log-now agat hasznalta helyesen, de a szerkezetbol csak KOVETKEZTETNI tudott arra,
    # hogy a bejegyzesei epek -- merni nem.
    # Ezert a kimenet elso oszlopa a HOSSZ: az arulja el a csonkulast, nem a szoveg. A zaro sor
    # kulon kiirja a legrovidebb bejegyzest, es szol, ha barmelyik 120 karakter alatt van.
    argc_max 3 "$#" "fleet-api.sh daily-log-read <agent> [YYYY-MM-DD] [full]"
    AGENT="$(arg "${1:?agent required}")"; DATE="${2-}"; MODE="${3-}"
    P="/daily-log?agent=${AGENT}"
    [ -n "$DATE" ] && P="${P}&date=${DATE}"
    get "$P" | LOG_MODE="$MODE" python3 -c '
import json, os, sys
mode = os.environ.get("LOG_MODE", "")
rows = json.load(sys.stdin)
if not isinstance(rows, list) or not rows:
    print("nincs bejegyzes erre a napra"); raise SystemExit(0)
lens = []
for r in rows:
    c = r.get("content") or ""
    lens.append(len(c))
    if mode == "full":
        print("--- id %s | %d karakter" % (r.get("id"), len(c)))
        print(c); print()
    else:
        first = c.split("\n")[0]
        print("%5d kar | %s" % (len(c), first[:78]))
print()
print("%d bejegyzes | legrovidebb %d | leghosszabb %d karakter" % (len(rows), min(lens), max(lens)))
# A CSONKULAS JELE A HOSSZ. Egy csak-temasor bejegyzes 40 es 70 karakter kozott van.
short = [l for l in lens if l < 120]
if short:
    print("FIGYELEM: %d bejegyzes 120 karakter alatt van (%s)." % (len(short), ", ".join(str(x) for x in short)))
    print("          Ez a csonkulas jele: valoszinuleg csak a temasor ment el, a torzs elveszett.")
    print("          A daily-log KETTOT olvas (agens, tartalom); tema+torzs eseten daily-log-now valo.")
'
    ;;
  kanban-list)
    get /kanban
    ;;
  kanban-new)
    argc_max 4 "$#" "fleet-api.sh kanban-new - < cim.txt [status] [assignee] [priority]"
    TITLE="$(arg "${1:?title required}")"; STATUS="${2:-planned}"; ASSIGNEE="${3:-}"; PRIORITY="${4:-normal}"
    post /kanban "$(json_obj title "$TITLE" status "$STATUS" assignee "$ASSIGNEE" priority "$PRIORITY")"
    ;;
  kanban-move)
    # `actor` is optional but should always be passed: it tells the board WHO moved
    # the card. Without it a self-pickup (an agent moving its OWN card to in_progress)
    # is indistinguishable from an assignment, and the dispatcher echoes the task back
    # at the agent that just started it. Upstream added the field to the raw-curl
    # instructions (v1.33.0); the helper has to carry it too, otherwise the agents that
    # cannot use raw curl silently lose the fix.
    argc_max 3 "$#" "fleet-api.sh kanban-move <card_id> <status> [actor]"
    CARD="${1:?card id required}"; STATUS="${2:?status required}"; ACTOR="$(arg "${3-}")"
    if [ -n "$ACTOR" ]; then
      post "/kanban/${CARD}/move" "$(json_obj status "$STATUS" actor "$ACTOR")"
    else
      post "/kanban/${CARD}/move" "$(json_obj status "$STATUS")"
    fi
    ;;
  kanban-assign)
    argc_max 2 "$#" "fleet-api.sh kanban-assign <card_id> <assignee>"
    CARD="${1:?card id required}"; ASSIGNEE="$(arg "${2:?assignee required}")"
    put "/kanban/${CARD}" "$(json_obj assignee "$ASSIGNEE")"
    ;;
  kanban-comment)
    argc_max 3 "$#" "fleet-api.sh kanban-comment <card_id> <author> - < szoveg.txt"
    CARD="${1:?card id required}"; AUTHOR="$(arg "${2:?author required}")"; CONTENT="$(arg "${3:?content required}")"
    post "/kanban/${CARD}/comments" "$(json_obj author "$AUTHOR" content "$CONTENT")"
    ;;
  kanban-comments)
    # READING a card's comments. This existed only as a WRITE (kanban-comment)
    # until 2026-08-27, and the gap cost four separate round trips in one day:
    # a card's title says what the work is, the DECIDING detail sits in a
    # comment, and an agent that cannot read comments has to ask the
    # orchestrator to copy them over. Twice that day an agent started -- or
    # nearly started -- work that a comment would have ruled out, and once it
    # measured the wrong system entirely because the title used our vocabulary
    # for someone else's model.
    #
    # Read-only, same endpoint the dashboard uses. The single-card GET
    # (/api/kanban/<id>) does NOT exist and answers 404; the comments path does.
    CARD="${1:?card id required}"
    get "/kanban/${CARD}/comments"
    ;;
  message-close)
    # EGY UZENET LEZARASA, ES A NYUGTA HOSSZANAK KAPUZASA.
    #
    # A `result` mezo NEM privat konyvelo sor: a szerver uj uzenetkent visszakuldi a KULDONEK,
    # es 500 karakternel elvagja (src/web/routes/messages.ts, RESULT_SUMMARY_LIMIT). A levagas
    # ota jelolt, tehat nem nema -- de a levagott resz ettol meg nem erkezik meg.
    #
    # AMIERT ESZKOZBE KERULT, ES NEM MARADT SZABALYNAK: 2026-08-27 este NEGYSZER futottam bele,
    # miutan a szabalyt magamnak MAR leirtam. A negyedik a tanulsagos: meg is szamoltam a
    # karaktereket, csak UGYANABBAN a parancsban, amelyik el is kuldte. A szam kiirodott (574),
    # es nem allitott meg semmit. Egy meres, ami nem kapuz, nem ellenorzes.
    #
    # Ezert ez az ag a hosszt MERI, es 500 folott NEM KULD: kiirja, mennyivel hosszabb, es hogy
    # a tartalom rendes uzenetbe valo. Ugyanaz a fajta orzo, mint az arity-orzo, csak a masik
    # iranyba: ott a tul sok argumentum, itt a tul hosszu nyugta.
    argc_max 2 "$#" "fleet-api.sh message-close <uzenet_id> - < nyugta.txt"
    ID="${1:?message id required}"; RESULT="$(arg "${2:?result required}")"
    LEN="$(RESULT="$RESULT" python3 -c 'import os; print(len(os.environ["RESULT"]))')"
    if [ "$LEN" -gt 500 ]; then
      echo "FAIL: a nyugta $LEN karakter, a hatar 500 -- $((LEN - 500)) karakterrel hosszabb." >&2
      echo "  A tulnyulo resz NEM erkezne meg a kuldohoz. Ket lehetoseg:" >&2
      echo "  (1) rovidits 500 ala, es akkor a nyugta viszi a valaszt;" >&2
      echo "  (2) kuldd rendes uzenetkent (agent-msg.sh), a nyugtaba pedig egy sor kerüljon arrol, hol a valasz." >&2
      exit 1
    fi
    put "/messages/${ID}" "$(json_obj status "done" result "$RESULT")"
    ;;
  message-read)
    # EGY UZENET TELJES TARTALMA, VAGAS NELKUL.
    #
    # AMIERT KELL: 2026-08-27 este murena ujraindult tele kontextussal, es a riportjahoz a
    # SAJAT hat lepes-jelenteset kellett volna visszaolvasnia. Azt tanacsoltam neki, hogy a
    # messages-sent paranccsal tegye. TEVEDTEM: az a lista 56 KARAKTERRE vagja a torzset, a
    # message-status pedig a NYUGTA szoveget adja vissza 300 karakteren. Egyik sem viszi
    # vissza a tartalmat. Az eloiras jo volt ("a potlas is meres legyen, ne visszaemlekezes"),
    # az UT nem letezett -- egy eszkoz NEVE nem bizonyitja, hogy az eszkoz odavisz.
    #
    # Ez az ag a nyers tartalmat adja, ahogy a szerver tarolja. Read-only.
    argc_max 1 "$#" "fleet-api.sh message-read <uzenet_id>"
    ID="${1:?message id required}"
    get "/messages?limit=500" | MSG_ID="$ID" python3 -c '
import json, os, sys, time
mid = int(os.environ["MSG_ID"])
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else d.get("messages", d.get("data", []))
m = next((r for r in rows if r.get("id") == mid), None)
if m is None:
    oldest = min((r.get("id", 0) for r in rows), default=0)
    print("FAIL: nincs %d azonositoju uzenet az utolso %d-ban (a legregebbi benne: %d)."
          % (mid, len(rows), oldest))
    print("      Ennel REGEBBI uzenet ezen az uton nem erheto el.")
    raise SystemExit(1)
print("%d | %s -> %s | %s | %s" % (
    m["id"], m.get("from_agent"), m.get("to_agent"), m.get("status"),
    time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(m.get("created_at", 0)))))
print("-" * 78)
print(m.get("content") or "(ures)")
r = m.get("result")
if r:
    print("-" * 78)
    print("EREDMENY (a lezaraskor irt nyugta, teljes szoveg):")
    print(r)
'
    ;;
  message-status)
    ID="${1:?message id required}"
    # A cimzett letezese az EGYETLEN gepileg ellenorizheto megkulonbozteto jel egy
    # `done` uzenetnel: a status maga nem arulja el, hogy a cimzett dolgozta-e fel,
    # vagy valaki mas vonta vissza. (Korall merte 2026-08-18: a figyelmezteto szoveg
    # onmagaban minden done-ra kiirodik, tehat par het alatt hattérzaj lesz -- ez a
    # sor viszont CSAK akkor szolal meg, ha tenyleg baj van.)
    AGENTS_JSON="$(curl -s -H "Authorization: Bearer $TOKEN" "${API}/agents" 2>/dev/null || true)"
    get "/messages?limit=500" | MSG_ID="$ID" AGENTS_JSON="$AGENTS_JSON" MAIN_AGENT="${MAIN_AGENT_ID:-acrobot}" python3 -c '
import json, os, sys, time
mid = int(os.environ["MSG_ID"])
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else d.get("messages", d.get("data", []))
m = next((r for r in rows if r.get("id") == mid), None)
if m is None:
    print("FAIL: nincs %d azonositoju uzenet az utolso %d-ban" % (mid, len(rows)))
    raise SystemExit(1)
print("%d | %s -> %s | %s | letrehozva %s" % (
    m["id"], m.get("from_agent"), m.get("to_agent"), m.get("status"),
    time.strftime("%H:%M:%S", time.localtime(m.get("created_at", 0)))))
# A status a lenyeg, ezert kulon is kimondjuk, mit jelent.
s = m.get("status")
print({"pending":   "MEG NEM ALL RAJTA A KEZBESITES. Frissen kuldott uzenetnel varj fel percet es kerdezd ujra:\n           a router elobb beirja a cimzett sessionjebe, a statuszt csak utana allitja at.\n           Ha percek mulva is pending: a cimzett foglalt, engedelykeresen all, vagy betelt a kontextusa.",
       "delivered": "MEGKAPTA. Ez az, amire hivatkozni lehet.",
       "done":      "LEZARVA -- de NEM feltetlenul a cimzett zarta le. A `done`-t barki\n           beallithatja a PUT /api/messages/<id> hivassal (a fougens is, pl. ha\n           visszavon egy elavult vagy kezbesithetetlen uzenetet). Ha van alatta\n           EREDMENY sor, azt olvasd el: az mondja meg, ki es miert zarta le.",
       "failed":    "NEM KAPTA MEG, es a probalkozas veget ert."}.get(s, "ismeretlen statusz: %s" % s))
# A result mezo az egyetlen hely, ahol a lezaras INDOKA all. `done`-nal ez donti el,
# hogy a cimzett dolgozta-e fel, vagy valaki mas vonta vissza. (Korall merte 2026-08-18:
# a "MEGKAPTA es lezarta" szoveg egy kezbesithetetlen uzenetre is kiirodott.)
r = m.get("result")
if r:
    _r = str(r).replace("\n", " ")
    if len(_r) > 300:
        print("EREDMENY (LEVAGVA: %d karakterbol az elso 300 latszik): %s" % (len(_r), _r[:300]))
        print("           A TELJES SZOVEG NEM EZEN AZ UTON JON. Kerd el a kuldotol uzenetben,")
        print("           vagy olvasd ki a GET /api/messages valaszabol a result mezot.")
    else:
        print("EREDMENY: %s" % _r)
# Gepileg ellenorizheto jel: letezik-e egyaltalan a cimzett. Ha nem, a status
# BARMI is, az uzenet SOHA nem jutott el emberi/agens olvasohoz.
try:
    _a = json.loads(os.environ.get("AGENTS_JSON") or "[]")
    _a = _a if isinstance(_a, list) else _a.get("agents", [])
    known = [str(x.get("name") or x.get("id")) for x in _a if (x.get("name") or x.get("id"))]
except Exception:
    known = []
# A fougens sosem szerepel az /api/agents listaban (pull-modellel kapja az uzeneteit),
# ezert kezzel hozza kell venni, kulonben minden neki szolo uzenetre hamisan riasztunk.
if known:
    known.append(os.environ.get("MAIN_AGENT") or "acrobot")
to = m.get("to_agent")
if known and to and to not in known:
    print("FIGYELEM: a cimzett (%s) NEM letezo agens. Az ismertek: %s." % (to, ", ".join(known)))
    print("          Ez az uzenet nem jutott el senkihez, fuggetlenul a statusztol.")
    print("          Ami EMBERNEK szol (Balazs, Luca), azt a fougensnek kell kuldeni, megnevezve a cimzettet.")
'
    ;;
  messages-sent)
    AGENT="$(arg "${1:?agent required}")"; LIMIT="${2:-10}"
    get "/messages?limit=500" | MSG_AGENT="$AGENT" MSG_LIMIT="$LIMIT" python3 -c '
import json, os, sys, time
agent = os.environ["MSG_AGENT"]; limit = int(os.environ["MSG_LIMIT"])
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else d.get("messages", d.get("data", []))
mine = [r for r in rows if r.get("from_agent") == agent]
mine.sort(key=lambda r: r.get("id", 0), reverse=True)
# A lista SZANDEKOSAN rovidit, de a rovidites LATSZODJON: egy jeloletlen levagas
# felbehagyott mondatnak nez ki, es az olvaso azt hiszi, ennyi volt az uzenet.
# (Murena merte 2026-08-25 a result mezon: a csonkolast elhallgatasnak olvasta.)
def _cut(s, n):
    return s if len(s) <= n else s[:n - 3] + "..."
mine = mine[:limit]
if not mine:
    print("nincs kimeno uzenet ettol: %s" % agent); raise SystemExit(0)
for m in mine:
    print("%5d | -> %-12s | %-9s | %s | %s" % (
        m["id"], m.get("to_agent"), m.get("status"),
        time.strftime("%H:%M", time.localtime(m.get("created_at", 0))),
        _cut((m.get("content") or "").replace("\n", " "), 56)))
pend = [m["id"] for m in mine if m.get("status") == "pending"]
print()
print("kezbesitetlen (pending): %d %s" % (len(pend), pend if pend else ""))
if pend:
    print("EZEKET NEM KAPTA MEG A CIMZETT. Ne jelentsd oket atadottkent.")
# A LATOHATAR KIIRASA. A lekerdezes limit=500-at ker, de a szerver ennel kevesebbet is adhat,
# es a szures a KAPOTT ablakon belul fut. Ami az ablak ELE esik, az egyszeruen nem latszik --
# jelzes nelkul. Murena merte 2026-08-27: a helper 41 sajat uzenetet mutatott neki, a
# legregebbi lathato 5227-es azonositoval, holott aznap a 5118-cal kezdett. Aki egy REGEBBI
# uzenetrol akarja megtudni, elment-e, HAMIS NEGATIVOT kap: nem latja, es azt hiszi, nincs.
# Ezert a lista vegen ott all, meddig lat vissza. A szam nem korlatozza a valaszt, csak
# megnevezi, mire vonatkozik.
if rows:
    oldest = min(r.get("id", 0) for r in rows)
    print()
    print("LATOHATAR: ez a lista a rendszer utolso %d uzenetet nezte at, a legregebbi benne: %d."
          % (len(rows), oldest))
    print("           Ennel REGEBBI sajat uzenet NEM latszik itt, es a hianya nem bizonyitek.")
    print("           Egy konkret regebbi uzenetet a message-status <id> paranccsal kerdezz le.")
'
    ;;
  # 2026-08-23: azert kerult ide, hogy a store/ mappa olvasasat MEG LEHESSEN tiltani az
  # agenseknek. Amig az utemezes es a jovahagyas csak nyers curl-lel ment, minden agens
  # CLAUDE.md-je eloirta a token kozvetlen felolvasasat, tehat a tiltas nem szabalyt hozott
  # volna, hanem torest. Egy tiltas, ami a normal mukodest vagja el, nem vedelem.
  schedule-new)
    argc_max 6 "$#" "fleet-api.sh schedule-new <nev> \"leiras\" - < prompt.txt \"<cron>\" <agent> [type]"
    NAME="$(arg "${1:?name required}")"; DESC="$(arg "${2:?description required}")"
    PROMPT="$(arg "${3:?prompt required}")"; CRON="$(arg "${4:?cron required}")"
    AGENT="$(arg "${5:?agent required}")"; TYPE="${6:-heartbeat}"
    BODY="$(NAME="$NAME" DESC="$DESC" PROMPT="$PROMPT" CRON="$CRON" AGENT="$AGENT" TYPE="$TYPE" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["NAME"], "description": os.environ["DESC"],
    "prompt": os.environ["PROMPT"], "schedule": os.environ["CRON"],
    "agent": os.environ["AGENT"], "type": os.environ["TYPE"],
}))')"
    post "/schedules" "$BODY"
    ;;
  # A LEJARAT NEM ADHATO MEG HIVASKOR, es ezert nincs is ilyen argumentum. Merve 2026-08-23:
  # a szerver (src/web/routes/approvals.ts, getTimeoutAt) a lejaratot a KATEGORIABOL veszi, a
  # store/autonomy-config.json timeout_minutes mezojebol; a torzsben kuldott timeout_seconds
  # erteket FIGYELMEN KIVUL HAGYJA. Ha a kategoria nincs a configban, a timeout_at NULL lesz,
  # tehat a keres soha nem jar le magatol. Egy argumentum, ami nem hat, rosszabb a hianyanal:
  # azt sugallja, hogy allitottunk egy hatarido, holott nem.
  approval-new)
    argc_max 3 "$#" "fleet-api.sh approval-new <agent> <kategoria> - < leiras.txt"
    AGENT="$(arg "${1:?agent required}")"; CATEGORY="$(arg "${2:?category required}")"
    DESC="$(arg "${3:?action_description required}")"
    BODY="$(AGENT="$AGENT" CATEGORY="$CATEGORY" DESC="$DESC" python3 -c '
import json, os
print(json.dumps({
    "agent_id": os.environ["AGENT"], "category": os.environ["CATEGORY"],
    "action_description": os.environ["DESC"],
}))')"
    post "/approvals" "$BODY"
    ;;
  approval-get)
    ID="$(arg "${1:?approval id required}")"
    get "/approvals/${ID}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print("id: %s | status: %s" % (d.get("id"), d.get("status")))
if d.get("decided_at"):
    print("dontes ideje: %s" % d.get("decided_at"))
if d.get("action_description"):
    print("mit kert: %s" % d.get("action_description"))
'
    ;;
  *)
    echo "FAIL: unknown command '$CMD' (memory|memory-search|daily-log|daily-log-now|daily-log-read|kanban-list|kanban-new|kanban-move|kanban-assign|kanban-comment|kanban-comments|message-status|messages-sent|schedule-new|approval-new|approval-get|message-close|message-read)"
    exit 1
    ;;
esac
