#!/usr/bin/env bash
# Regenerate docs/PR-ALLAS.md -- the shared, machine-readable list of open pull
# requests for the acropora-os repo.
#
# WHY THIS EXISTS (measured 2026-08-27): the fleet's agents cannot see GitHub.
# `gh` is not installed and the GitHub MCP call answers "Requires
# authentication", so an agent that pushes a branch has no way to check whether
# a PR was opened for it. Only acrobot can. That asymmetry cost most of one
# afternoon: an agent reported the same "two of my branches have no PR" state
# four times in a row, each report already answered by a message sitting
# undelivered in its queue, because a busy agent's inbox only drains on an idle
# pane.
#
# A queue delivers once, late, and in order. A file can be read at any moment,
# by anyone, as many times as needed -- so the state lives in the file and the
# messages stop carrying it.
#
# The page carries its own expiry condition instead of a timestamp (nautilus's
# suggestion, same day): a reader compares `origin/main` against the head
# printed here. A timestamp tells you when it was written, which is not the
# question -- the question is whether anything has changed since, and the repo
# itself can answer that.
set -uo pipefail
ROOT=/home/marveen/marveen
REPO=KratoBal/acropora-os
OUT="$ROOT/docs/PR-ALLAS.md"
TOKEN_FILE="$ROOT/store/.github-token"
[ -r "$TOKEN_FILE" ] || { echo "FAIL: no github token at $TOKEN_FILE" >&2; exit 1; }

TOKEN="$(cat "$TOKEN_FILE")" REPO="$REPO" python3 - "$OUT" <<'PY'
import json, os, subprocess, sys
out_path = sys.argv[1]
tok, repo = os.environ["TOKEN"], os.environ["REPO"]

def api(path):
    r = subprocess.run(
        ["curl", "-s", "-H", "Authorization: Bearer " + tok,
         "https://api.github.com/repos/" + repo + path],
        capture_output=True, text=True)
    return json.loads(r.stdout)

main = api("/commits/main")
prs = api("/pulls?state=open&per_page=50")
if not isinstance(prs, list):
    print("FAIL: unexpected API answer", file=sys.stderr); sys.exit(1)

lines = [
    "# Nyitott pull requestek -- gepi allas", "",
    "Ezt a lapot ACROBOT irja, minden PR-muvelet utan. A flotta agensei NEM latjak a GitHubot",
    "(nincs gh es nincs hitelesitett MCP), ezert ez a fajl a KOZOS forras arrol, mi all nyitva.", "",
    "Ha egy agad NEM szerepel itt es nem is beolvadt, akkor NINCS hozza PR -- szolj.", "",
    "## Meddig ervenyes ez a lap", "",
    "Nincs benne idobelyeg, es ez SZANDEKOS: egy idopont nem mondja meg, elavult-e a tartalom.",
    "Ehelyett a lap a SAJAT lejarati feltetelet hordozza. Futtasd ezt:", "",
    "    git -C <a klonod> rev-parse --short origin/main", "",
    "Ha ugyanazt adja, mint a lenti sor, a lap FRISS. Ha MAST, akkor a fo ag azota mozdult,",
    "es a lap egy korabbi allapotot mutat -- olyankor szolj, es ujrafuttatom.", "",
    "A lap POZITIV iranyban bizonyit: ha az agad ITT VAN, akkor van hozza PR. Negativ iranyban",
    "csak JELEZ: ha nincs itt, az lehet, hogy csak meg nem irtam ki.", "",
    "main feje: `%s` -- %s" % (main["sha"][:8], main["commit"]["message"].splitlines()[0]), "",
    "| PR | ag | fej | allapot |", "|---|---|---|---|",
]
for p in sorted(prs, key=lambda x: x["number"]):
    lines.append("| #%d | `%s` | `%s` | %s |" % (
        p["number"], p["head"]["ref"], p["head"]["sha"][:8],
        "piszkozat" if p["draft"] else "nyitva"))
open(out_path, "w").write("\n".join(lines) + "\n")
print("OK %s (%d nyitott PR)" % (out_path, len(prs)))
PY
