#!/usr/bin/env bash
# Google Calendar + Gmail bekotes az info@acropora.hu fiokhoz, bongeszo nelkul.
#
# Ugyanaz a loopback-minta, mint a gdrive.sh: a jovahagyas EGY emberi kattintas,
# a tobbi innen megy. A kliens azonos a Drive/YouTube kliensevel (Desktop app,
# store/.yt-client-id es .yt-client-secret), tehat uj klienst nem kell csinalni.
#
# SCOPE-DONTES (Balazs, Discord, 2026-08-21): naptari esemeny irasa, level
# olvasasa, level kuldese. Torles es atiras NEM -- ezert nem `gmail.modify` es
# nem a teljes `calendar`, hanem a harom szuk scope.
#
# Miert `calendar.events` es nem `calendar`: meglevo naptart hasznalunk
# (info@acropora.hu), uj naptart nem kell letrehozni. A `calendar` a naptarak
# kezeleset is adna, ami itt felesleges jog.
#
#   bash scripts/gcal.sh auth-url                        -> jovahagyo link
#   bash scripts/gcal.sh auth-code <kod|teljes cimsor>   -> a kod bevaltasa
#   bash scripts/gcal.sh check                           -> mukodik-e, es melyik fiokkal
#   bash scripts/gcal.sh events [nap]                    -> a mai (vagy N napos) esemenyek
#   bash scripts/gcal.sh mail [ora]                      -> az elmult N ora levelei (alap: 12)
#
# MIERT KESON KERULT BE AZ UTOLSO KETTO: a hozzaferes 2026-08-21-en elkeszult, de
# lekerdezo parancs nem volt hozza, es a reggeli napindito NEGY egymast koveto reggelen
# (08-23, 08-24, 08-25, 08-26) ugyanazt a hianyt jelentette. A kettot nem szabad
# osszekeverni: a jogosultsag hianya napokig tarto akadaly, egy hianyzo parancs fel ora.
#
# A cimsor NEM fog betoltodni (http://localhost:8765/...), ez NEM hiba: a kodot
# onnan kell kimasolni. Ezt a gazdanak elore meg kell mondani.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GC_ROOT="$ROOT"

die() { echo "FAIL $*" >&2; exit 1; }

cmd="${1:-}"; shift || true

# TOBB FIOK, EGY SZKRIPT. A GC_ACCOUNT kornyezeti valtozo valasztja ki, melyik
# fiokrol van szo; alapertelmezesben az info@ cim, mert az volt itt eloszor.
#
# MIERT KELLETT: 2026-08-30-ig a refresh token EGYETLEN fix helyre ment
# (store/.gsuite-refresh-token). Ha egy MASODIK fiokot (ticket@) ugyanezzel a
# szkripttel engedelyeztunk volna, a mentes FELULIRJA az elsot, es masnap reggel
# a napindito email- es naptar-szakasza allt volna le. A hiba ott jelentkezett
# volna, ahol semmi koze nincs hozza: ez a legdragabb fajta.
GC_ACCOUNT="${GC_ACCOUNT:-info}"
export GC_ACCOUNT
case "$GC_ACCOUNT" in
  info) RT_PATH="$ROOT/store/.gsuite-refresh-token" ;;
  *)    RT_PATH="$ROOT/store/.gsuite-refresh-token-$GC_ACCOUNT" ;;
esac
export GC_RT_PATH="$RT_PATH"

case "$cmd" in
  auth-url|auth-code) ;;
  check|events|mail) [ -f "$RT_PATH" ] || die "nincs refresh token ehhez a fiokhoz ($GC_ACCOUNT): $RT_PATH. Eloszor: GC_ACCOUNT=$GC_ACCOUNT gcal.sh auth-url, majd auth-code <kod>" ;;
  *) die "ismeretlen parancs: '${cmd}' -- auth-url | auth-code | check | events | mail" ;;
esac

GC_CMD="$cmd" python3 - "$@" <<'PYEOF'
import json, os, sys, urllib.parse, urllib.request, urllib.error

ROOT = os.environ["GC_ROOT"]
CMD = os.environ["GC_CMD"]
STORE = os.path.join(ROOT, "store")
REDIRECT = "http://localhost:8765/"
ACCOUNT = os.environ.get("GC_ACCOUNT", "info")

# A JOGOSULTSAG FIOKONKENT KULONBOZIK, ES EZ SZANDEKOS.
# info@ : naptar + level olvasas + level kuldes, mert a napindito ezt hasznalja.
# minden mas fiok (ticket@) : CSAK OLVASAS. A hibajegy-ertesitesek kuldese a
# hibajegy-rendszer dolga lesz, sajat kulccsal, nem a miénkkel: aki olvas, annak
# nem kell tudnia irni is.
if ACCOUNT == "info":
    SCOPES = " ".join([
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
    ])
else:
    SCOPES = "https://www.googleapis.com/auth/gmail.readonly"

RT_PATH = os.environ.get("GC_RT_PATH") or os.path.join(STORE, ".gsuite-refresh-token")
RT_FILE = os.path.basename(RT_PATH)


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


def post(url, data):
    body = urllib.parse.urlencode(data).encode()
    try:
        return json.load(urllib.request.urlopen(url, body, timeout=30))
    except urllib.error.HTTPError as e:
        die("HTTP %s: %s" % (e.code, e.read().decode()[:300]))


def access_token():
    r = post("https://oauth2.googleapis.com/token", {
        "client_id": rd(".yt-client-id"),
        "client_secret": rd(".yt-client-secret"),
        "refresh_token": rd(RT_FILE),
        "grant_type": "refresh_token",
    })
    if "access_token" not in r:
        die("nem jott access token: " + json.dumps(r)[:200])
    return r["access_token"]


def get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        return json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        return {"__http": e.code, "__body": e.read().decode()[:300]}


a = sys.argv[1:]

if CMD == "auth-url":
    q = urllib.parse.urlencode({
        "client_id": rd(".yt-client-id"),
        "redirect_uri": REDIRECT,
        "response_type": "code",
        "scope": SCOPES,
        "access_type": "offline",   # enelkul NINCS refresh token, csak egy orasnyi hozzaferes
        "prompt": "consent",        # ismetelt jovahagyasnal is adjon UJ refresh tokent
    })
    print("https://accounts.google.com/o/oauth2/v2/auth?" + q)

elif CMD == "auth-code":
    if not a:
        die("hasznalat: gcal.sh auth-code <a code= ertek, vagy a teljes cimsor>")
    code = a[0]
    # A teljes atiranyitasi cimet is elfogadjuk: a kod kezi kivagasa az a pont,
    # ahol a kattintgatasba belefaradt ember hibazik, es a kod egyszer hasznalhato.
    if "code=" in code:
        code = (urllib.parse.parse_qs(urllib.parse.urlparse(code).query).get("code") or [""])[0]
    if not code:
        die("nem talalok code= erteket abban, amit kaptam")
    r = post("https://oauth2.googleapis.com/token", {
        "client_id": rd(".yt-client-id"),
        "client_secret": rd(".yt-client-secret"),
        "code": code,
        "redirect_uri": REDIRECT,
        "grant_type": "authorization_code",
    })
    if "refresh_token" not in r:
        die("jott access token, de refresh NEM -- hianyzik az access_type=offline, vagy a prompt=consent")
    p = os.path.join(STORE, RT_FILE)
    with open(p, "w") as f:
        f.write(r["refresh_token"])
    os.chmod(p, 0o600)
    print("OK refresh token mentve: store/" + RT_FILE)
    print("scope: " + r.get("scope", "(nem jott vissza)"))

elif CMD == "check":
    t = access_token()
    # Ket fuggetlen ellenorzes: a naptar ES a levelezes oldal is valaszoljon.
    # Egy scope megleteert nem kezeskedik a masik: a token akkor is elfogadhat
    # egy hivast, ha a masik API nincs bekapcsolva a projektben.
    # FONTOS, es 2026-08-21-en meg is mertem: a `calendars/primary` VEGPONT
    # (naptar-metaadat) NEM fer bele a `calendar.events` scope-ba, 403-at ad
    # "insufficient authentication scopes" uzenettel. Ez NEM a bekotes hibaja:
    # az esemeny-vegpont ugyanazzal a tokennel mukodik. Ha az ellenorzes a
    # metaadatot nezi, egy MUKODO bekotest jelent hibasnak -- pont az a fajta
    # hamis negativ, ami miatt valaki ujra-jovahagyast kerne feleslegesen.
    # A NAPTART CSAK OTT NEZZUK, AHOL VAN RA JOGOSULTSAG. A ticket@ fiok
    # SZANDEKOSAN csak levelet olvashat, tehat ott a naptar-hivas 403-at adna, es
    # az ellenorzes minden korben pirosnak latszana egy TOKELETESEN mukodo
    # bekotesre. Egy orzo, ami a helyes allapotra panaszkodik, elobb-utobb
    # kikapcsoltatja magat, vagy ami rosszabb: valaki "megjavitja" a jogosultsagot
    # es kitagitja. (Merve 2026-08-30, a ticket@ bekotesekor.)
    if ACCOUNT == "info":
        cal = get("https://www.googleapis.com/calendar/v3/calendars/primary/events"
                  "?maxResults=1&singleEvents=true&orderBy=startTime", t)
        if cal.get("__http"):
            print("NAPTAR  HIBA %s: %s" % (cal["__http"], cal["__body"]))
        else:
            print("NAPTAR  OK | naptar: %s | idozona: %s" % (cal.get("summary"), cal.get("timeZone")))
    else:
        print("NAPTAR  KIHAGYVA | a(z) '%s' fiok szandekosan csak levelet olvashat" % ACCOUNT)
    prof = get("https://gmail.googleapis.com/gmail/v1/users/me/profile", t)
    if prof.get("__http"):
        print("GMAIL   HIBA %s: %s" % (prof["__http"], prof["__body"]))
    else:
        print("GMAIL   OK | fiok: %s | uzenetek: %s" % (prof.get("emailAddress"), prof.get("messagesTotal")))

elif CMD == "events":
    from datetime import datetime, timedelta, timezone
    days = int(a[0]) if a else 1
    t = access_token()
    now = datetime.now(timezone.utc)
    q = urllib.parse.urlencode({
        "timeMin": now.isoformat(),
        "timeMax": (now + timedelta(days=days)).isoformat(),
        "singleEvents": "true",
        "orderBy": "startTime",
        "maxResults": "50",
    })
    r = get("https://www.googleapis.com/calendar/v3/calendars/primary/events?" + q, t)
    if r.get("__http"):
        die("HTTP %s: %s" % (r["__http"], r["__body"]))
    items = r.get("items", [])
    if not items:
        print("(nincs esemeny)")
    for it in items:
        start = (it.get("start", {}).get("dateTime") or it.get("start", {}).get("date"))
        print("%s | %s" % (start, it.get("summary", "(cim nelkul)")))

elif CMD == "mail":
    from datetime import datetime, timedelta, timezone
    hours = int(a[0]) if a else 12
    t = access_token()
    after = int((datetime.now(timezone.utc) - timedelta(hours=hours)).timestamp())
    q = urllib.parse.urlencode({"q": "after:%d" % after, "maxResults": "50"})
    r = get("https://gmail.googleapis.com/gmail/v1/users/me/messages?" + q, t)
    if r.get("__http"):
        die("HTTP %s: %s" % (r["__http"], r["__body"]))
    msgs = r.get("messages", [])
    if not msgs:
        print("(nincs level)")
    for m in msgs:
        d = get("https://gmail.googleapis.com/gmail/v1/users/me/messages/%s"
                 "?format=metadata&metadataHeaders=From&metadataHeaders=Subject" % m["id"], t)
        h = {x["name"]: x["value"] for x in d.get("payload", {}).get("headers", [])}
        labels = d.get("labelIds", [])
        tag = "[PROMO] " if ("CATEGORY_PROMOTIONS" in labels or "SPAM" in labels) else ""
        print("%s%s | %s" % (tag, h.get("From", "?"), h.get("Subject", "(nincs targy)")))
PYEOF
