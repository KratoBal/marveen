#!/usr/bin/env bash
#
# Instagram uzleti fiok OLVASO helper (@acroporabud).
#
# MIERT LETEZIK: 2026-08-23-an merve kiderult, hogy az Instagram-hozzaferes MAR MEGVOLT, csak
# senki nem hasznalta: a meglevo Meta page token scope-jai kozott ott all az `instagram_basic`
# es az `instagram_manage_insights`, es az oldalhoz kapcsolt egy uzleti fiok. A kartya 8 napig
# ugy allt, hogy "Instagram: nincs semmilyen token" -- ez nem volt igaz.
#
# MIERT NEM SAJAT TOKEN-KEZELES: ez a szkript a `fb-insights.sh raw` hivason keresztul dolgozik,
# tehat NEM masolja le a token-feloldast, a lejarat-kezelest es a GET-only kaput. Egy hely
# tudja, hol a kulcs, es egy hely dont arrol, hogy csak olvasni szabad. Ha a token-kezeles
# valaha valtozik, ez a fajl valtozatlan marad.
#
# BIZTONSAG:
# - Csak olvas. Minden hivas a `fb-insights.sh raw` alatt megy, ami GET-only.
# - A token SOSEM kerul a kimenetbe (a hivott szkript kezeli).
# - Az uzleti fiok azonositojat NEM egetjuk be: az oldalrol kerdezzuk le futasidoben, tehat egy
#   oldal-csere utan is a helyes fiokot olvassa.
#
# Hasznalat:
#   bash scripts/ig-insights.sh whoami                  # melyik fiokhoz vagyunk kotve
#   bash scripts/ig-insights.sh stats [since] [until]   # eleres, profilfelkeres, aktiv fiokok
#   bash scripts/ig-insights.sh top [n] [since] [until] # a legjobb bejegyzesek a szakaszban
#   bash scripts/ig-insights.sh raw <edge> [querystring]
#
# Datumok: EEEE-HH-NN. Alapertelmezett szakasz: az elmult 7 nap.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FB="$HERE/fb-insights.sh"

fail() { echo >&2 "MEGTAGADVA: $*"; exit 1; }

# `bash`-sal hivjuk, tehat OLVASHATO kell legyen, nem futtathato. A fb-insights.sh mode 644,
# es a hivasi konvencio a flottaban vegig "bash scripts/...". Egy -x kapu itt hamis nemet ad.
[ -r "$FB" ] || fail "nincs meg (vagy nem olvashato) a fb-insights.sh: $FB"
command -v python3 >/dev/null 2>&1 || fail "nincs python3 a gepen"

graph() { bash "$FB" raw "$1" "${2:-}"; }

# Az uzleti fiok azonositoja az OLDALROL jon, nem beegetve.
ig_user_id() {
  graph me "fields=instagram_business_account" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
acc=(d or {}).get("instagram_business_account") or {}
if not acc.get("id"):
    sys.exit(1)
print(acc["id"])
'
}

SINCE_DEFAULT="$(date -d '7 days ago' +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d)"
UNTIL_DEFAULT="$(date +%Y-%m-%d)"

CMD="${1:-}"
[ -n "$CMD" ] || { sed -n '25,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
shift || true

IG="$(ig_user_id)" || fail "nem talaltam az oldalhoz kapcsolt Instagram uzleti fiokot. A page token scope-jai kozott ott van az instagram_basic?"

case "$CMD" in
  whoami)
    graph "$IG" "fields=username,name,followers_count,follows_count,media_count" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("fiok:        @%s (%s)" % (d.get("username","?"), d.get("name","?")))
print("id:          %s" % d.get("id","?"))
print("koveto: %s | kovetett: %s | bejegyzes: %s" % (
    d.get("followers_count","?"), d.get("follows_count","?"), d.get("media_count","?")))
'
    ;;

  stats)
    SINCE="${1:-$SINCE_DEFAULT}"; UNTIL="${2:-$UNTIL_DEFAULT}"
    echo "szakasz: $SINCE .. $UNTIL"
    # Az eleres naponta jon; a tobbi metrika total_value alakot KOVETEL (a Graph API
    # kifejezetten visszautasitja period=day mellett metric_type nelkul).
    graph "$IG/insights" "metric=reach&period=day&since=$SINCE&until=$UNTIL" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=(d.get("data") or [{}])[0].get("values") or []
vals=[v.get("value",0) for v in rows]
print("eleres (napi osszeg): %s   napok: %d   legjobb nap: %s" % (
    sum(vals), len(vals), max(vals) if vals else 0))
'
    graph "$IG/insights" "metric=profile_views,accounts_engaged&metric_type=total_value&period=day&since=$SINCE&until=$UNTIL" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for m in d.get("data") or []:
    tv=(m.get("total_value") or {}).get("value")
    print("%-18s %s" % (m.get("name","?")+":", tv if tv is not None else "nincs adat"))
'
    ;;

  top)
    N="${1:-5}"; SINCE="${2:-$SINCE_DEFAULT}"; UNTIL="${3:-$UNTIL_DEFAULT}"
    graph "$IG/media" "fields=id,caption,media_type,timestamp,permalink,like_count,comments_count&limit=50" | python3 -c '
import json,sys,datetime
n=int(sys.argv[1]); since=sys.argv[2]; until=sys.argv[3]
d=json.load(sys.stdin)
def day(ts):
    return (ts or "")[:10]
items=[m for m in (d.get("data") or []) if since <= day(m.get("timestamp")) <= until]
if not items:
    print("nincs bejegyzes ebben a szakaszban (%s .. %s)" % (since, until))
    sys.exit(0)
items.sort(key=lambda m: (m.get("like_count") or 0) + (m.get("comments_count") or 0), reverse=True)
for m in items[:n]:
    cap=(m.get("caption") or "").replace("\n", " ")[:70]
    print("%s | %-5s | kedveles %-4s komment %-3s | %s" % (
        day(m.get("timestamp")), m.get("media_type","?"),
        m.get("like_count",0), m.get("comments_count",0), cap))
    print("   %s" % m.get("permalink",""))
' "$N" "$SINCE" "$UNTIL"
    ;;

  raw)
    EDGE="${1:-}"; [ -n "$EDGE" ] || fail "a raw utan meg kell adni egy eleet"
    QS="${2:-}"
    # Az "ig" alias a fiok azonositojara, hogy ne kelljen kezzel masolni.
    EDGE="${EDGE/#ig/$IG}"
    graph "$EDGE" "$QS"
    ;;

  *)
    fail "ismeretlen parancs: $CMD"
    ;;
esac
