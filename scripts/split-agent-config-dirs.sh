#!/usr/bin/env bash
#
# Give every agent its OWN config `projects/` directory instead of the shared one.
#
# WHY: measured 2026-08-18 -- every agent's <config-dir>/projects is a SYMLINK to the same
# place, /home/marveen/.claude/projects. Not similar, the same directory (inode 571891).
# Two consequences:
#   1. every agent's conversation transcripts sit in one directory, readable by all of them;
#   2. the auto-memory store is keyed by PROJECT ROOT, not by cwd -- and all five agents live
#      under the same repo root -- so every agent's memories land in ONE store. Measured: the
#      only memory/ directory in there is the main agent's, holding 30 files, and polip wrote
#      into it at 16:31.
# Splitting the symlink fixes both: transcripts are already keyed per cwd, and once the parent
# differs, the same project key resolves to a different memory store per agent.
#
# WHAT THIS DOES NOT DO: separate uids. That is a later step. This one removes the shared
# path; it does not stop a process that runs as marveen from walking to another agent's dir.
#
# ================== EZ A SZKRIPT ONMAGABAN MA NEM ELEG ==================
# Merve 2026-08-18 17:23, eles futason: a szetvalasztas lefut, negy kulon mappa lesz,
# ES AZ AGENS-INDITAS VISSZACSINALJA, masodperceken belul. Az ok kod, nem konfiguracio:
# provisionIsolatedConfigDir() (src/web/agent-process.ts, ~488. sor) INDITASKOR minden
# top-level ~/.claude bejegyzest ujralinkel az izolalt config dirbe -- kiveve az
# ISOLATED_CONFIG_SKIP halmazt --, es ha VALODI mappat talal ott, ahol linket var, azt
# rmSync-cel LETORLI, majd linket tesz a helyere.
#
# TEHAT A SORREND: eloszor a 'projects' bejegyzest fel kell venni az ISOLATED_CONFIG_SKIP
# halmazba, npm run build, dashboard ujrainditas -- es CSAK EZUTAN erdemes ezt futtatni.
# Enelkul a szkript "sikeres" kimenetet ad, es a valtozas az elso agens-inditasnal eltunik.
#
# ES AZ ELLENORZES AZ INDITAS UTAN LEGYEN, ne elotte: az indulas elotti meres ebben a
# felallasban nem tud megbukni. A `--check` mod futtathato ujrainditas UTAN is, es akkor
# mond igazat.
# ========================================================================
#
# RUN THIS ONLY WHILE THE AGENTS ARE STOPPED. A live session appends to its transcript; if the
# path changes underneath it, today's tail can end up split across the old and the new copy.
# The script refuses to run if it finds a live agent tmux session, unless FORCE=1.
#
# Idempotent: an agent whose projects/ is already a real directory is skipped.
# Non-destructive: the shared directory is COPIED, never moved, and nothing is deleted. Removing
# the old copy is a separate, later decision once the agents have run a full day on the new one.
#
#   bash scripts/split-agent-config-dirs.sh --check   # report only, change nothing
#   bash scripts/split-agent-config-dirs.sh           # do it
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED="/home/marveen/.claude/projects"
MODE="${1:-run}"
FORCE="${FORCE:-0}"

AGENTS=()
for d in "$ROOT"/agents/*/; do
  [ -d "$d" ] && AGENTS+=("$(basename "$d")")
done

fail() { echo "FAIL $*" >&2; exit 1; }

[ -d "$SHARED" ] || fail "a kozos mappa nincs meg: $SHARED"

echo "=== allapot ==="
live=0
for a in "${AGENTS[@]}"; do
  cfg="$ROOT/agents/$a/.claude-config/projects"
  if [ -L "$cfg" ]; then
    state="symlink -> $(readlink "$cfg")"
  elif [ -d "$cfg" ]; then
    state="sajat mappa (mar kesz)"
  else
    state="NINCS"
  fi
  running="allo"
  if tmux has-session -t "agent-$a" 2>/dev/null; then running="FUT"; live=$((live+1)); fi
  printf '  %-12s %-8s %s\n' "$a" "$running" "$state"
done

if [ "$MODE" = "--check" ]; then
  echo "=== csak ellenorzes, nem valtoztattam semmit ==="
  exit 0
fi

if [ "$live" -gt 0 ] && [ "$FORCE" != "1" ]; then
  fail "$live agens FUT. Allitsd le oket elobb, vagy FORCE=1 ha tudod mit csinalsz. Ok: az elo session a transzkriptjebe ir, es ha kozben valtozik az utvonal, a mai vege ketfele kerul."
fi

for a in "${AGENTS[@]}"; do
  cfg="$ROOT/agents/$a/.claude-config/projects"
  key="-home-marveen-marveen-agents-$a"

  if [ -d "$cfg" ] && [ ! -L "$cfg" ]; then
    echo "SKIP $a: mar sajat mappaja van"
    continue
  fi
  [ -L "$cfg" ] || { echo "SKIP $a: nincs projects bejegyzes"; continue; }

  tmp="$cfg.uj.$$"
  mkdir -p "$tmp" || fail "$a: nem sikerult letrehozni $tmp"

  # Only the agent's OWN project directory travels. The main workspace's project dir
  # (transcripts and the shared memory store) stays with the main agent; an agent starts
  # its memory store empty rather than inheriting somebody else's notes.
  if [ -d "$SHARED/$key" ]; then
    cp -a "$SHARED/$key" "$tmp/$key" || fail "$a: masolas sikertelen"
    src_n="$(find "$SHARED/$key" -type f | wc -l)"
    dst_n="$(find "$tmp/$key" -type f | wc -l)"
    [ "$src_n" = "$dst_n" ] || fail "$a: fajlszam elter a masolas utan ($src_n vs $dst_n), NEM cserelek"
    echo "  $a: $src_n fajl atmasolva"
  else
    echo "  $a: nincs sajat project mappa a kozosben, ures indul"
  fi

  # Swap last, after the copy verified. The symlink is replaced, its target untouched.
  rm "$cfg" || fail "$a: a symlinket nem sikerult eltavolitani"
  mv "$tmp" "$cfg" || fail "$a: az uj mappat nem sikerult a helyere tenni"
  echo "OK $a"
done

echo
echo "=== utana ==="
bash "$0" --check
echo
echo "A kozos mappa ERINTETLEN: $SHARED"
echo "Ne toroljunk belole semmit, amig az agensek nem futottak legalabb egy teljes napot az uj mappan."
