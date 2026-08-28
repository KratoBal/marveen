#!/usr/bin/env bash
# Print the current Europe/Budapest wall-clock time, and refuse to print a wrong one.
#
# Why this exists: `date` here answers from glibc, which reads
# /usr/share/zoneinfo/Europe/Budapest. That path is a read-only bind mount from
# the host, and between 2026-08-20 12:04 and 2026-08-21 08:57 the host file was
# EMPTY (0 bytes). glibc does not error on an empty zone file: it silently falls
# back to UTC while still printing the zone name, so `date` showed +0000 and
# every human-facing timestamp landed two hours behind. The host file is fixed
# (verified from inside 2026-08-21 09:00: `date +%z` -> +0200, 2368 bytes), but
# this script still takes the time from node's own bundled ICU tz data, which
# was correct throughout and does not depend on that mount.
#
# Usage:
#   local-now.sh            -> HH:MM
#   local-now.sh full       -> YYYY-MM-DD HH:MM:SS
#   local-now.sh date       -> YYYY-MM-DD
#
# Exits non-zero and prints nothing usable if it cannot establish the zone.
set -u

ZONE="${LOCAL_NOW_ZONE:-Europe/Budapest}"
MODE="${1:-hhmm}"

OUT="$(ZONE="$ZONE" MODE="$MODE" node -e '
const zone = process.env.ZONE;
const mode = process.env.MODE;
const p = Object.fromEntries(
  new Intl.DateTimeFormat("en-GB", {
    timeZone: zone,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false,
  }).formatToParts(new Date()).map((x) => [x.type, x.value])
);
if (!p.year || !p.hour) { process.exit(3); }
const day = `${p.year}-${p.month}-${p.day}`;
const time = `${p.hour}:${p.minute}:${p.second}`;
if (mode === "full") process.stdout.write(`${day} ${time}`);
else if (mode === "date") process.stdout.write(day);
else process.stdout.write(`${p.hour}:${p.minute}`);
' 2>/dev/null)"

if [ -n "$OUT" ]; then
  printf '%s' "$OUT"
  exit 0
fi

# Fallback, only if node is missing: use glibc, but ONLY through a zone file that
# is actually present and non-empty. The -s test is the whole point -- an empty
# zone file does not fail, it silently reads as UTC, which is how this script
# came to exist. Budapest first, since that is the zone we actually want; Vienna
# second, because it is a different file that shares Budapest's CET/CEST rules
# for every modern date. If the Vienna branch fires, the printed time is
# Vienna's own record, not Budapest's.
for FALLBACK_ZONE in Europe/Budapest Europe/Vienna; do
  [ -s "/usr/share/zoneinfo/$FALLBACK_ZONE" ] || continue
  case "$MODE" in
    full) TZ="$FALLBACK_ZONE" date '+%Y-%m-%d %H:%M:%S' | tr -d '\n' ;;
    date) TZ="$FALLBACK_ZONE" date '+%Y-%m-%d' | tr -d '\n' ;;
    *)    TZ="$FALLBACK_ZONE" date '+%H:%M' | tr -d '\n' ;;
  esac
  exit 0
done

echo "FAIL: no usable Europe/Budapest clock (node missing, and no non-empty zone file for Budapest or Vienna)" >&2
exit 1
