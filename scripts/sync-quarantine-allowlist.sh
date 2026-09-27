#!/usr/bin/env bash
# Re-render the per-install domain block of every deployed quarantine-reader.md
# from store/egress-allowlist.json.
#
# Why this exists: the reader's own domain list is generated at agent SPAWN time.
# Editing store/egress-allowlist.json therefore has no effect on an already
# running fleet -- the main agent's WebFetch gate picks the change up instantly
# (it reads the file per call), but the sub-agents keep the list they were born
# with. Measured 2026-08-18: worms.org was approved and all five deployed copies
# still lacked it, so "route it through the quarantine reader" silently failed.
#
# Usage: sync-quarantine-allowlist.sh [--check]
#   --check  only report which copies are out of date, change nothing
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"

python3 - "$ROOT" "$MODE" <<'PY'
import json, sys, glob, os
root, mode = sys.argv[1], sys.argv[2]
domains = json.load(open(os.path.join(root, 'store', 'egress-allowlist.json'), encoding='utf-8'))['domains']
block = '\n'.join('- `%s`' % d for d in domains)
BEGIN = '<!-- BEGIN PER-INSTALL DOMAINS (from store/egress-allowlist.json) -->'
END = '<!-- END PER-INSTALL DOMAINS -->'

paths = glob.glob(os.path.join(os.path.expanduser('~'), '.claude', 'agents', 'quarantine-reader.md'))
paths += glob.glob(os.path.join(root, 'agents', '*', '.claude', 'agents', 'quarantine-reader.md'))

changed = stale = 0
for p in paths:
    s = open(p, encoding='utf-8').read()
    if BEGIN not in s or END not in s:
        print('KIHAGYVA (nincs jelolo):', p)
        continue
    head, rest = s.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    new = head + BEGIN + '\n' + block + '\n' + END + tail
    if new == s:
        print('naprakesz:', p)
        continue
    stale += 1
    if mode == '--check':
        print('ELAVULT:', p)
    else:
        open(p, 'w', encoding='utf-8').write(new)
        print('frissitve:', p)
        changed += 1
print('---')
print('fajl:', len(paths), '| elavult volt:', stale, '| frissitve:', changed, '| domain:', len(domains))
PY
