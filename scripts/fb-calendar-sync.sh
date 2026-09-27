#!/usr/bin/env bash
# Idozitett Facebook-posztok es hirdetesi kampanyok atvezetese az
# info@acropora.hu Google-naptaraba.
#
# Balazs kerese (Discord, "Google kapcsolatok" szal, 2026-08-21): a posztok es a
# hirdetesek kerüljenek be a naptarba, es ha az idozites valtozik, a bejegyzes a
# MEGFELELO HELYRE keruljon, ne szulessen belole egy masodik.
#
# EZERT AZ EGESZ SZKRIPT LELKE EGY AZONOSITO. Minden altalunk letrehozott
# naptar-bejegyzes visel egy `acropora_ref` jelolest (`fbpost:<id>` vagy
# `fbcampaign:<id>`) az extendedProperties.private mezoben. A kovetkezo futas
# ez alapjan MEGTALALJA es MODOSITJA a sajat korabbi bejegyzeset. E nelkul
# minden futas duplikalna, es harom nap alatt olvashatatlan lenne a naptar.
#
# Ugyanez a jeloles teszi biztonsagossa a torlest: CSAK olyan bejegyzest
# torlunk, amit MI hoztunk letre (van `acropora_ref` jelolese) es aminek a
# forrasa mar nincs meg a Facebook oldalan. Kezzel felvett naptar-bejegyzeshez
# a szkript soha nem nyul.
#
#   bash scripts/fb-calendar-sync.sh plan    -> megmutatja mit tenne, NEM ir
#   bash scripts/fb-calendar-sync.sh apply   -> vegrehajtja
#
# A `plan` az alapertelmezes: egy naptar-iro szkript ne induljon el attol, hogy
# valaki lefuttatta argumentum nelkul.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FCS_ROOT="$ROOT"
export FCS_MODE="${1:-plan}"

case "$FCS_MODE" in
  plan|apply) ;;
  *) echo "FAIL ismeretlen mod: '$FCS_MODE' -- plan | apply" >&2; exit 1 ;;
esac

python3 - <<'PYEOF'
import json, os, sys, time, urllib.parse, urllib.request, urllib.error
from datetime import datetime, timedelta, timezone

ROOT = os.environ["FCS_ROOT"]
MODE = os.environ["FCS_MODE"]
STORE = os.path.join(ROOT, "store")
GRAPH = "https://graph.facebook.com/v21.0"
CAL = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

# Mennyi multat vigyunk be. A kampany-lista 2021-ig visszamegy, es egy ot eve
# lezart kampany a naptarban nem informacio, hanem zaj. A hatart KIIRJUK a
# vegen, mert egy csendben levagott lista ugy olvasodik, mintha minden benne
# lenne.
PAST_DAYS = 7


def die(msg):
    print("FAIL " + msg, file=sys.stderr)
    raise SystemExit(1)


def rd(name):
    p = os.path.join(STORE, name)
    if not os.path.exists(p):
        die("hianyzik: store/" + name)
    v = open(p).read().strip()
    if not v:
        die("ures fajl: store/" + name)
    return v


def http(url, token, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
    })
    try:
        r = urllib.request.urlopen(req, timeout=30)
        raw = r.read().decode()
        return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        die("Google HTTP %s: %s" % (e.code, e.read().decode()[:300]))


def graph(path, params):
    q = urllib.parse.urlencode(params)
    try:
        return json.load(urllib.request.urlopen("%s/%s?%s" % (GRAPH, path, q), timeout=30))
    except urllib.error.HTTPError as e:
        die("Graph HTTP %s: %s" % (e.code, e.read().decode()[:300]))


def graph_probe(path, params):
    """Egyetlen objektum lekerdezese ugy, hogy a hianya NEM hiba.

    A graph() szandekosan megall minden HTTP hiban, mert ott egy hianyzo valasz
    a szinkron alapadatat vinne el. Itt viszont a HIANY maga az informacio: egy
    torolt poszt 404-et ad, es azt meg kell tudni kulonboztetni attol, hogy a
    hivas maga romlott el.
    """
    q = urllib.parse.urlencode(params)
    try:
        return json.load(urllib.request.urlopen("%s/%s?%s" % (GRAPH, path, q), timeout=30))
    except urllib.error.HTTPError as e:
        if e.code in (400, 404):
            return None
        die("Graph HTTP %s: %s" % (e.code, e.read().decode()[:300]))
    except Exception:
        return "ISMERETLEN"


def google_token():
    body = urllib.parse.urlencode({
        "client_id": rd(".yt-client-id"),
        "client_secret": rd(".yt-client-secret"),
        "refresh_token": rd(".gsuite-refresh-token"),
        "grant_type": "refresh_token",
    }).encode()
    try:
        r = json.load(urllib.request.urlopen("https://oauth2.googleapis.com/token", body, timeout=30))
    except urllib.error.HTTPError as e:
        die("a Google token frissitese nem sikerult: " + e.read().decode()[:200])
    if "access_token" not in r:
        die("nem jott Google access token")
    return r["access_token"]


def first_line(s, n=60):
    s = (s or "").strip().replace("\n", " ")
    return (s[:n] + "...") if len(s) > n else (s or "(nincs szoveg)")


# ---------------------------------------------------------------- FORRAS: FB
fb_token = rd(".fb-page-token")
page_id = rd(".fb-page-id")
ad_account = rd(".fb-ad-account")   # a fajl MAR tartalmazza az `act_` elotagot

wanted = {}   # acropora_ref -> naptar-esemeny torzs

posts = graph("%s/scheduled_posts" % page_id, {
    "fields": "id,message,scheduled_publish_time",
    "limit": 100,
    "access_token": fb_token,
}).get("data", [])

for p in posts:
    ts = p.get("scheduled_publish_time")
    if not ts:
        continue
    start = datetime.fromtimestamp(int(ts), timezone.utc).astimezone()
    ref = "fbpost:" + p["id"]
    wanted[ref] = {
        "summary": "FB poszt: " + first_line(p.get("message")),
        # A poszt egy pillanat, nem idoszak. Fel ora csak azert kell, hogy a
        # naptarban legyen magassaga es olvashato maradjon.
        "start": {"dateTime": start.isoformat(), "timeZone": "Europe/Budapest"},
        "end": {"dateTime": (start + timedelta(minutes=30)).isoformat(), "timeZone": "Europe/Budapest"},
        "description": "Idozitett Facebook-poszt.\nAzonosito: %s\nA bejegyzest az Acropora OS tartja karban, kezzel ne modositsd." % p["id"],
        "extendedProperties": {"private": {"acropora_ref": ref}},
    }

cutoff = datetime.now(timezone.utc) - timedelta(days=PAST_DAYS)
campaigns = graph("%s/campaigns" % ad_account, {
    "fields": "id,name,effective_status,start_time,stop_time",
    "limit": 100,
    "access_token": fb_token,
}).get("data", [])

skipped_old = 0
for c in campaigns:
    st, sp = c.get("start_time"), c.get("stop_time")
    if not st:
        continue
    start = datetime.fromisoformat(st)
    end = datetime.fromisoformat(sp) if sp else start + timedelta(days=1)
    if end < cutoff:
        skipped_old += 1
        continue
    ref = "fbcampaign:" + c["id"]
    # A kampany napokon at tart, ezert EGESZ NAPOS bejegyzes. A Google a
    # `date` vegpontot KIZAROLAG kezeli, ezert egy nappal tovabb kell adni,
    # kulonben az utolso nap lemarad a naptarbol.
    wanted[ref] = {
        "summary": "FB hirdetes: %s (%s)" % (first_line(c.get("name"), 40), c.get("effective_status")),
        "start": {"date": start.date().isoformat()},
        "end": {"date": (end.date() + timedelta(days=1)).isoformat()},
        "description": "Facebook hirdetesi kampany.\nAllapot: %s\nAzonosito: %s\nA bejegyzest az Acropora OS tartja karban, kezzel ne modositsd." % (c.get("effective_status"), c["id"]),
        "extendedProperties": {"private": {"acropora_ref": ref}},
    }

# ------------------------------------------------------------ CEL: a naptar
gt = google_token()

# A Google csak PONTOS kulcs=ertek parra tud szurni: nem tud listazni "minden
# acropora_ref jelolessel ellatott" esemenyt. Ezert ket kulon kor kell -- a
# sajat halmazunkat ref szerint kerdezzuk vissza, az elarvultakat pedig egy
# szeles idoablak atnezesevel talaljuk meg.
existing = {}

# 1) a mienk, ref szerint: pontos lekerdezes mindegyikre
for ref in list(wanted.keys()):
    q = urllib.parse.urlencode({
        "privateExtendedProperty": "acropora_ref=" + ref,
        "maxResults": 5,
        "showDeleted": "false",
    })
    items = http(CAL + "?" + q, gt).get("items", [])
    if items:
        existing[ref] = items[0]

# 2) elarvult bejegyzesek: a jelen es a jovo egy szeles ablakaban minden
#    esemeny, aminek van acropora_ref jelolese, de a forrasa mar nincs meg.
orphans = []
tmin = (datetime.now(timezone.utc) - timedelta(days=PAST_DAYS)).isoformat()
tmax = (datetime.now(timezone.utc) + timedelta(days=400)).isoformat()
q = urllib.parse.urlencode({
    "timeMin": tmin, "timeMax": tmax, "maxResults": 2500,
    "singleEvents": "true", "showDeleted": "false",
})
for ev in http(CAL + "?" + q, gt).get("items", []):
    ref = ((ev.get("extendedProperties") or {}).get("private") or {}).get("acropora_ref")
    if ref and ref.startswith(("fbpost:", "fbcampaign:")) and ref not in wanted:
        orphans.append((ref, ev))

# ------------------------------------------------------------------ MUVELET
created = updated = unchanged = deleted = 0


def differs(ev, body):
    if ev.get("summary") != body["summary"]:
        return True
    for side in ("start", "end"):
        a, b = ev.get(side) or {}, body[side]
        if a.get("date") != b.get("date"):
            return True
        # A Google a sajat formajara normalizalja az idot, ezert a nyers
        # sztringet nem szabad osszehasonlitani -- ido-ertekre kell hozni.
        if b.get("dateTime"):
            if not a.get("dateTime"):
                return True
            if datetime.fromisoformat(a["dateTime"]) != datetime.fromisoformat(b["dateTime"]):
                return True
        elif a.get("dateTime"):
            return True
    return False


for ref, body in sorted(wanted.items()):
    ev = existing.get(ref)
    if ev is None:
        print("LETREHOZ  %s | %s" % (ref, body["summary"]))
        if MODE == "apply":
            http(CAL, gt, "POST", body)
        created += 1
    elif differs(ev, body):
        old = (ev.get("start") or {}).get("dateTime") or (ev.get("start") or {}).get("date")
        new = body["start"].get("dateTime") or body["start"].get("date")
        print("MODOSIT   %s | %s -> %s" % (ref, old, new))
        if MODE == "apply":
            http(CAL + "/" + ev["id"], gt, "PATCH", body)
        updated += 1
    else:
        unchanged += 1

# EGY PUBLIKALT POSZT UGYANUGY KIESIK AZ IDOZITETTEK LISTAJABOL, MINT EGY TOROLT,
# es sokaig mind a kettot ugyanaz az egy mondat jelentette ("a forrasa mar nincs
# meg"). Az egyik siker, a masik veszteseg. Merve 2026-08-25: egy poszt kikerult az
# oldalra, a szinkron torlest jelentett, es csak a Facebook kulon megkerdezese
# dontotte el, hogy nem baleset tortent. Ezert a torles oka MOST MAR mert adat, nem
# az olvaso feltevese.
published_gone = 0
for ref, ev in orphans:
    reason = "a forrasa mar nincs meg"
    if ref.startswith("fbpost:"):
        post = graph_probe(ref.split(":", 1)[1], {
            "fields": "id,is_published,created_time",
            "access_token": fb_token,
        })
        if post is None:
            reason = "TOROLVE a Facebookon"
        elif post == "ISMERETLEN":
            reason = "a Facebook nem valaszolt, az ok ISMERETLEN"
        elif post.get("is_published"):
            reason = "MEGJELENT %s" % (post.get("created_time") or "")
            published_gone += 1
        else:
            reason = "mar nem idozitett, de nem is publikalt"
    print("TOROL     %s | %s (%s)" % (ref, ev.get("summary"), reason))
    if MODE == "apply":
        http(CAL + "/" + ev["id"], gt, "DELETE")
    deleted += 1

print("")
print("MOD: %s" % ("VEGREHAJTVA" if MODE == "apply" else "CSAK TERV, semmi nem valtozott"))
print("forras: %d idozitett poszt, %d kampany a %d napos ablakban (%d regi kampany kihagyva)"
      % (len(posts), len(campaigns) - skipped_old, PAST_DAYS, skipped_old))
print("letrehoz: %d | modosit: %d | valtozatlan: %d | torol: %d" % (created, updated, unchanged, deleted))
if deleted:
    print("ebbol MEGJELENT: %d (nem veszteseg) | egyeb ok: %d" % (published_gone, deleted - published_gone))
PYEOF
