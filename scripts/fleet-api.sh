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
#   bash scripts/fleet-api.sh kanban-list
#   bash scripts/fleet-api.sh kanban-new "<title>" <status> <assignee> <priority>
#   bash scripts/fleet-api.sh kanban-move <card_id> <status> [actor]
#   bash scripts/fleet-api.sh kanban-assign <card_id> <assignee>
#   bash scripts/fleet-api.sh kanban-comment <card_id> <author> "<content>"
#   bash scripts/fleet-api.sh message-status <id>
#   bash scripts/fleet-api.sh messages-sent <agent> [limit]
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
    AGENT="$(arg "${1:?agent required}")"; CAT="$(arg "${2:?category required}")"
    CONTENT="$(arg "${3:?content required}")"; KEYWORDS="$(arg "${4-}")"
    post /memories "$(json_obj agent_id "$AGENT" category "$CAT" content "$CONTENT" keywords "$KEYWORDS")"
    ;;
  memory-search)
    AGENT="$(arg "${1:?agent required}")"; Q="$(arg "${2:?query required}")"; CAT="${3-}"
    Q_ENC="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$Q")"
    P="/memories?agent=${AGENT}&q=${Q_ENC}"
    [ -n "$CAT" ] && P="${P}&category=${CAT}"
    get "$P"
    ;;
  daily-log)
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
    AGENT="$(arg "${1:?agent required}")"; TOPIC="$(arg "${2:?topic required}")"
    BODY="$(arg "${3:?content required}")"
    post /daily-log "$(json_obj agent_id "$AGENT" content "## $(date '+%H:%M') -- ${TOPIC}
${BODY}")"
    ;;
  kanban-list)
    get /kanban
    ;;
  kanban-new)
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
    CARD="${1:?card id required}"; STATUS="${2:?status required}"; ACTOR="$(arg "${3-}")"
    if [ -n "$ACTOR" ]; then
      post "/kanban/${CARD}/move" "$(json_obj status "$STATUS" actor "$ACTOR")"
    else
      post "/kanban/${CARD}/move" "$(json_obj status "$STATUS")"
    fi
    ;;
  kanban-assign)
    CARD="${1:?card id required}"; ASSIGNEE="$(arg "${2:?assignee required}")"
    put "/kanban/${CARD}" "$(json_obj assignee "$ASSIGNEE")"
    ;;
  kanban-comment)
    CARD="${1:?card id required}"; AUTHOR="$(arg "${2:?author required}")"; CONTENT="$(arg "${3:?content required}")"
    post "/kanban/${CARD}/comments" "$(json_obj author "$AUTHOR" content "$CONTENT")"
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
    print("EREDMENY: %s" % str(r).replace("\n", " ")[:300])
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
mine = mine[:limit]
if not mine:
    print("nincs kimeno uzenet ettol: %s" % agent); raise SystemExit(0)
for m in mine:
    print("%5d | -> %-12s | %-9s | %s | %s" % (
        m["id"], m.get("to_agent"), m.get("status"),
        time.strftime("%H:%M", time.localtime(m.get("created_at", 0))),
        (m.get("content") or "").replace("\n", " ")[:56]))
pend = [m["id"] for m in mine if m.get("status") == "pending"]
print()
print("kezbesitetlen (pending): %d %s" % (len(pend), pend if pend else ""))
if pend:
    print("EZEKET NEM KAPTA MEG A CIMZETT. Ne jelentsd oket atadottkent.")
'
    ;;
  *)
    echo "FAIL: unknown command '$CMD' (memory|memory-search|daily-log|kanban-list|kanban-new|kanban-move|kanban-assign|kanban-comment|message-status|messages-sent)"
    exit 1
    ;;
esac
