#!/usr/bin/env bash
# findfiles.sh -- name-based file lookup for fleet agents whose profile cannot
# grant `find` directly.
#
# WHY THIS EXISTS, AND WHY IT IS A SCRIPT AND NOT AN ALLOWLIST ENTRY:
# `find` is not a read-only tool. Its `-delete` and `-exec` actions write, and
# they appear AFTER the paths on the command line, so the profile's prefix
# patterns (`Bash(cmd flag:*)`) cannot exclude them the way `Bash(sed -i:*)`
# excludes in-place editing. Granting `Bash(find:*)` would therefore silently
# undo the deny entries that block `rm` under three spellings.
# This wrapper gives the capability without the actions: it builds the command
# itself, and no caller argument can become a find action.
#
# Usage:
#   findfiles.sh <dir> <name-glob> [max]
#   findfiles.sh --changed-since <YYYY-MM-DD> <dir> <name-glob> [max]
#
#   dir        must resolve under /home/marveen/marveen
#   name-glob  case-insensitive, matched against the file NAME (e.g. '*MERCE*')
#   max        optional, default 100, 1..2000
#
# A --changed-since AZERT VAN, MERT A FLOTTA LEGGYAKORIBB ELLENORZO KERDESE NEM
# AZ, HOGY MI VAN, HANEM HOGY MI NEM TORTENT (barracuda, 2026-08-31, tizenkilenc
# perc allas egy engedelykeresen). "A mai korom hozzanyult-e a regi
# alapvonalakhoz?" -- erre a valasz akkor jo, ha NULLA, es epp ezert kell hozza
# eszkoz: enelkul a nyers `find -newermt` marad, ami nincs a listakon.
# A datum alakja kotott (YYYY-MM-DD), es a nap 00:00-jatol szamit.
#
# Measured 2026-08-31: barracuda sat on a `find` permission prompt for 59
# minutes, and an agent parked on a prompt cannot receive inter-agent messages
# either -- so the cost is not the command, it is the hour of silence.

set -uo pipefail

ROOT=/home/marveen/marveen

die() { echo "findfiles: $*" >&2; exit 2; }

SINCE=""
if [ "${1:-}" = "--changed-since" ]; then
  [ "$#" -ge 2 ] || die "--changed-since utan datum kell (YYYY-MM-DD)"
  SINCE=$2
  case "$SINCE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
    *) die "a datum alakja YYYY-MM-DD legyen, ez jott: $SINCE" ;;
  esac
  shift 2
fi

# Arity guard, house rule: a helper that reads fixed positions must refuse
# extra arguments instead of silently dropping them.
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  die "usage: findfiles.sh [--changed-since YYYY-MM-DD] <dir> <name-glob> [max]  (got $# positional arguments)"
fi

DIR=$1
GLOB=$2
MAX=${3:-100}

# No argument may start with a dash: that is the only way a caller could turn
# an argument into a find action or an option.
case "$DIR"  in -*) die "dir must not start with a dash" ;; esac
case "$GLOB" in -*) die "name-glob must not start with a dash" ;; esac
case "$MAX"  in -*) die "max must not start with a dash" ;; esac

case "$MAX" in
  ''|*[!0-9]*) die "max must be a number" ;;
esac
[ "$MAX" -ge 1 ] && [ "$MAX" -le 2000 ] || die "max must be between 1 and 2000"

[ -d "$DIR" ] || die "not a directory: $DIR"

# Resolve symlinks before the containment check, so a link cannot lead out.
REAL=$(readlink -f "$DIR") || die "cannot resolve: $DIR"
case "$REAL" in
  "$ROOT"|"$ROOT"/*) : ;;
  *) die "dir must be under $ROOT (resolved to $REAL)" ;;
esac

# Only -type f and -iname. No -exec, no -delete, no -printf: the action list is
# fixed here and cannot be extended from the outside.
#
# A KILEPESI KOD ELSO VALTOZATA HAZUDOTT (barracuda merte, 2026-08-31, es a
# diagnozisa MAS lett, mint a sejtese). O azt latta, hogy a limittel levagott
# hivas 1-et ad, a szukebb pedig 0-t, es a limit-vagasra gyanakodott.
# Visszamerve: NEM a limit. A `find` 1-gyel lep ki, ha akar EGY konyvtarat sem
# tud olvasni (mas agens mappaja), a `2>/dev/null` pedig a HIBAUZENETET nyeli el,
# nem az allapotot -- a `pipefail` aztan ezt vitte tovabb. Ezert adott az agents
# fan MINDEN hivas 1-et, meg a teljes lista is, es a sajat mappajan 0-t.
#
# Egy hazudo kilepesi kod rosszabb, mint a hianya: aki ra epit, a talalatot is
# bukasnak veszi. De az ellenkezo javitas (mindig 0) meg rosszabb lenne, mert
# akkor egy NULLA TALALAT ugy nezne ki, mint egy teljes kereses -- holott lehet,
# hogy csak nem lattunk oda. A ket eset kulon kodot kap.
#
#   0  a kereses TELJES volt (minden konyvtar olvashato)
#   3  a kereses RESZLEGES (volt olvashatatlan konyvtar; a szamuk a stderr-en)
#   2  hasznalati vagy orzo-hiba
#
# A talalatok mind a ket sikeres esetben kiirodnak.

ERRLOG="$(mktemp)"
trap 'rm -f "$ERRLOG"' EXIT

if [ -n "$SINCE" ]; then
  RESULTS="$(find "$REAL" -type f -iname "$GLOB" -newermt "$SINCE 00:00" -print 2>"$ERRLOG" | sort)"
else
  RESULTS="$(find "$REAL" -type f -iname "$GLOB" -print 2>"$ERRLOG" | sort)"
fi
DENIED="$(grep -c 'Permission denied' "$ERRLOG" 2>/dev/null || true)"
[ -n "$DENIED" ] || DENIED=0

[ -n "$RESULTS" ] && printf '%s\n' "$RESULTS" | head -n "$MAX"

FOUND=0
[ -n "$RESULTS" ] && FOUND="$(printf '%s\n' "$RESULTS" | wc -l)"
if [ "$FOUND" -gt "$MAX" ]; then
  echo "findfiles: $FOUND talalat, ebbol $MAX kiirva (a limitet a harmadik argumentum allitja)" >&2
fi

if [ "$DENIED" -gt 0 ]; then
  echo "findfiles: RESZLEGES kereses -- $DENIED konyvtarba nem lattunk bele (jogosultsag)." >&2
  echo "           Egy nulla vagy alacsony talalatszam itt a KERESES korlatja is lehet, nem a fae." >&2
  exit 3
fi
exit 0
