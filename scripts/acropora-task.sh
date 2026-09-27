#!/usr/bin/env bash
# acropora-task.sh -- narrow, allowlist-friendly wrapper around ONE Acropora OS endpoint:
# POST /tasks/ingest (machine task creation on the /feladataim board).
#
# WHY: the sub-agents deliberately have no read access to store/ (every key lives there:
# dashboard, Facebook, YouTube, fal.ai, GitHub) and the strict profiles have no raw curl,
# because those agents read web content and a raw curl is an exfiltration primitive.
# This wrapper is the same middle ground as fleet-api.sh: the HOST and the PATH are
# hardcoded, so approving `Bash(bash .../scripts/acropora-task.sh:*)` grants exactly one
# capability -- "put a task on Balazs's board" -- and nothing else. No URL, no header and
# no token ever comes from the caller.
#
# The service token is per agent (ADR-015): the server prefixes the stored sourceRef with
# the token's own slug, so two agents cannot collide and cannot write in each other's name.
# The token is read from disk at call time and never printed, not even on failure.
#
# Usage:
#   bash scripts/acropora-task.sh <agent> "<title>" "<description>" "<reference>" [link_url]
#   ACROPORA_ASSIGNEE=luca@acropora.hu bash scripts/acropora-task.sh ...   (mas felelosnek)
#
# <agent>       acrobot | polip   (decides WHICH token file is used)
# <reference>   stable, caller-chosen key. Re-sending the same reference returns the
#               EXISTING task (created:false) instead of creating a duplicate, so a
#               restarted agent is safe to re-run. Make it descriptive and stable,
#               e.g. "required-inputs#1.3", not "task-1".
#
# Any argument may be "-" to read that value from STDIN (for long/multi-line text).
# Output on success: the API response plus a human line saying whether it was created.
# Output on failure: "FAIL <reason>" and exit 1.
#
# Assignee: defaults to Balazs, overridable with ACROPORA_ASSIGNEE. The endpoint REQUIRES a
# valid, active user e-mail (a missing one is a 400, an unknown one a 422). The override was
# added 2026-08-17: the fleet no longer has exactly one human -- Luca is logged in as
# luca@acropora.hu and owns the webshop/marketing decisions, so tasks about stock, pricing,
# content and images belong on HER board, not on Balazs's. Sending them to him made him a
# relay for questions he is not the answer to.
set -uo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="https://api.acropora.hu/tasks/ingest"
# Override with ACROPORA_ASSIGNEE=luca@acropora.hu (or another active user).
ASSIGNEE="${ACROPORA_ASSIGNEE:-balazs@acropora.hu}"

agent="${1-}"; shift || true
case "$agent" in
  acrobot) TOKEN_FILE="$BASE/store/.acropora-service-token.json" ;;
  polip)   TOKEN_FILE="$BASE/store/.acropora-service-token-polip.json" ;;
  *) echo "FAIL: ismeretlen agens: '${agent}'. Ervenyes: acrobot, polip"; exit 1 ;;
esac

[ -r "$TOKEN_FILE" ] || { echo "FAIL: nincs olvashato token: $TOKEN_FILE"; exit 1; }

# "-" means: take this value from STDIN. Only the first such argument can be piped.
stdin_used=0
arg() {
  local v="${1-}"
  if [ "$v" = "-" ] && [ "$stdin_used" -eq 0 ]; then stdin_used=1; cat; else printf '%s' "$v"; fi
}

title="$(arg "${1-}")"
description="$(arg "${2-}")"
reference="$(arg "${3-}")"
link_url="$(arg "${4-}")"

[ -n "$title" ]     || { echo "FAIL: a cim kotelezo"; exit 1; }
[ -n "$reference" ] || { echo "FAIL: a reference kotelezo (ez teszi biztonsagossa az ujrakuldest)"; exit 1; }

TOKEN_FILE="$TOKEN_FILE" ASSIGNEE="$ASSIGNEE" API="$API" \
TITLE="$title" DESCRIPTION="$description" REFERENCE="$reference" LINK_URL="$link_url" \
python3 <<'PY'
import json, os, sys, urllib.request, urllib.error

# The token never reaches the shell, an argv list or the log: it is read here and used once.
try:
    token = json.load(open(os.environ["TOKEN_FILE"]))["token"]
except Exception as exc:
    print("FAIL: a token fajl olvashatatlan vagy nincs benne 'token' mezo: %s" % exc)
    sys.exit(1)

payload = {
    "title": os.environ["TITLE"],
    "assigneeEmail": os.environ["ASSIGNEE"],
    "reference": os.environ["REFERENCE"],
}
if os.environ.get("DESCRIPTION"):
    payload["description"] = os.environ["DESCRIPTION"]
if os.environ.get("LINK_URL"):
    payload["linkUrl"] = os.environ["LINK_URL"]

req = urllib.request.Request(
    os.environ["API"],
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
)
try:
    resp = urllib.request.urlopen(req, timeout=30)
    body = resp.read().decode()
    code = resp.status
except urllib.error.HTTPError as exc:
    body = exc.read().decode()
    code = exc.code
except Exception as exc:
    print("FAIL: a keres nem ment ki: %s" % exc)
    sys.exit(1)

# A 2xx alone is not proof: the response must carry a task id, the same rule as agent-msg.sh.
try:
    data = json.loads(body)
except Exception:
    data = {}

if code >= 400 or not data.get("id"):
    hint = {
        400: " (hianyzo vagy hibas mezo -- a reference es a cim kotelezo)",
        401: " (ervenytelen vagy visszavont token)",
        422: " (a felelos e-mail cim ismeretlen vagy inaktiv az Acropora OS-ben)",
        429: " (napi felviteli plafon, tokenenkent 200)",
    }.get(code, "")
    print("FAIL: HTTP %s%s -- %s" % (code, hint, body))
    sys.exit(1)

print(body)
print(
    "OK id=%s status=%s -- %s"
    % (
        data["id"],
        data.get("status"),
        "uj feladat letrejott" if data.get("created") else "mar letezett ezzel a hivatkozassal, nem duplikaltam",
    )
)
PY
