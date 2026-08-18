#!/usr/bin/env bash
#
# Google Drive atadó-mappa helper. Az agens ide teszi ki azt, ami embernek szol,
# es csak a linket kuldi el.
#
# BIZTONSAG:
# - A host HARDCODED (googleapis.com), tehat ez nem valtoztathato at exfiltracios
#   csatornava egy utolag beszurt URL-lel.
# - A scope drive.file, NEM drive. Kovetkezmeny: CSAK azt latjuk es kezeljuk, amit
#   ez a kliens maga hozott letre. A fiok tobbi resze lathatatlan. Amit EMBER tesz
#   a mappaba, azt sem latjuk -- ez tudatos, nem hiba (lasd scripts/yt-stats.sh).
# - A token sosem kerul a kimenetbe.
#
# A Google KLIENS kozos a YouTube-bal (store/.yt-client-id / .yt-client-secret), de a
# JOVAHAGYAS es a refresh token KULON van: store/.gdrive-refresh-token.
# MIERT: lemerve 2026-08-16, a Google elutasitja a kozos jovahagyast ("This request contains
# scopes that cannot be requested together", 400 invalid_request), ha a yt-analytics.readonly
# es a drive.file egy kereesben van. Ket kulon jovahagyas kell, es ez igy is jobb: a Drive
# hozzaferes visszavonhato anelkul, hogy a YouTube meres elhalna.
#
# Hasznalat:
#   gdrive.sh auth-url                         -> jovahagyo link Balazsnak
#   gdrive.sh auth-code <code|teljes cimsor>   -> a kod bevaltasa, refresh token mentese
#   gdrive.sh mkdir <nev> [szulo_id]           -> letrehoz egy mappat, kiirja az id-t
#   gdrive.sh upload <fajl> <szulo_id> [nev]   -> feltolt, kiirja az id-t es a linket
#   gdrive.sh upload-doc <fajl.html|md> <szulo_id> [nev]
#                                              -> feltolt ES Google Dokumentumma alakit
#   gdrive.sh export <id> [kimeneti_fajl]       -> VISSZAOLVASSA a Drive-rol a szoveget
#                                                 (ez az egyetlen kulso ellenorzes a tartalomra)
#   gdrive.sh rename <id> <uj_nev>             -> atnevezes, a link es az id marad
#   gdrive.sh update <id> <fajl> [nev]         -> a MEGLEVO dokumentum tartalmat csereli,
#                                                 uj id nelkul (nem keletkezik duplikatum)
#   gdrive.sh share <id> <email> [reader|writer|commenter]
#   gdrive.sh ls [szulo_id]                    -> amit ez a kliens letrehozott
#   gdrive.sh link <id>
#
# Kimenet: sikernel a kert ertek; hiba eseten "FAIL <ok>" a stderr-en, exit 1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GD_ROOT="$ROOT"

die() { echo "FAIL $*" >&2; exit 1; }

py() { python3 -c "$1" "${@:2}"; }

cmd="${1:-}"; shift || true

# A jovahagyas emberi lepes, ezert az auth-* parancsok futhatnak token nelkul is.
case "$cmd" in
  auth-url|auth-code) ;;
  *) [ -f "$ROOT/store/.gdrive-refresh-token" ] || die "nincs Drive refresh token. Futtasd: gdrive.sh auth-url, es hagyasd jova Balazzsal, majd: gdrive.sh auth-code <kod>" ;;
esac

run() {
  GD_CMD="$cmd" python3 - "$@" <<'PYEOF'
import json, os, sys, time, urllib.parse, urllib.request, uuid, mimetypes

ROOT = os.environ["GD_ROOT"]
CMD = os.environ["GD_CMD"]
STORE = os.path.join(ROOT, "store")
FOLDER_MIME = "application/vnd.google-apps.folder"
DOC_MIME = "application/vnd.google-apps.document"
SCOPE = "https://www.googleapis.com/auth/drive.file"
REDIRECT = "http://localhost:8765/"


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


def token():
    """Cache-elt access token, 60 masodperccel a lejarat elott frissitve."""
    cache = os.path.join(STORE, ".gdrive-access-token")
    try:
        d = json.load(open(cache))
        if d.get("expires_at", 0) > time.time() + 60:
            return d["token"]
    except Exception:
        pass
    body = urllib.parse.urlencode({
        "client_id": rd(".yt-client-id"),
        "client_secret": rd(".yt-client-secret"),
        "refresh_token": rd(".gdrive-refresh-token"),
        "grant_type": "refresh_token",
    }).encode()
    try:
        r = json.load(urllib.request.urlopen("https://oauth2.googleapis.com/token", body, timeout=30))
    except urllib.error.HTTPError as e:
        die("token frissites: " + e.read().decode()[:200])
    if "access_token" not in r:
        die("nem jott access token")
    with open(cache, "w") as f:
        json.dump({"token": r["access_token"], "expires_at": time.time() + r.get("expires_in", 3600)}, f)
    os.chmod(cache, 0o600)
    return r["access_token"]


def api(method, url, body=None, ctype="application/json", raw=False):
    data = body if raw else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": ctype})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            txt = r.read().decode()
            return json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        raw_err = e.read().decode()
        try:
            msg = json.loads(raw_err)["error"]["message"]
        except Exception:
            msg = raw_err[:300]
        # A drive.file leggyakoribb buktatoja: egy IDEGEN (nem altalunk letrehozott)
        # mappa id-jet kapja szulokent, es "File not found" jon vissza. Ez nem elgepeles.
        if e.code == 404:
            msg += "  [drive.file: csak azt latjuk, amit MI hoztunk letre -- ha ez egy kezzel keszitett mappa, azt nem erjuk el]"
        die("%s %s" % (e.code, msg))


def multipart(meta, path, mime):
    b = "b" + uuid.uuid4().hex
    body = b"".join([
        ("--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n" % b).encode(),
        json.dumps(meta).encode(), b"\r\n",
        ("--%s\r\nContent-Type: %s\r\n\r\n" % (b, mime)).encode(),
        open(path, "rb").read(), ("\r\n--%s--\r\n" % b).encode(),
    ])
    return body, "multipart/related; boundary=" + b


a = sys.argv[1:]
BASE = "https://www.googleapis.com/drive/v3"
UP = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true&fields=id,name,webViewLink"

if CMD == "auth-url":
    q = urllib.parse.urlencode({
        "client_id": rd(".yt-client-id"),
        "redirect_uri": REDIRECT,
        "response_type": "code",
        "scope": SCOPE,
        "access_type": "offline",   # enelkul egyaltalan nincs refresh token
        "prompt": "consent",        # ujra-jovahagyasnal is adjon friss refresh tokent
    })
    print("https://accounts.google.com/o/oauth2/v2/auth?" + q)

elif CMD == "auth-code":
    if not a:
        die("hasznalat: gdrive.sh auth-code <a code= ertek, vagy a teljes cimsor>")
    code = a[0]
    # Elfogadjuk a teljes atiranyitasi URL-t is: a kod kezi kivagasa ott az egy pont,
    # ahol a kattintgatasba belefaradt ember hibazik, es a kod egyszer hasznalhato.
    if "code=" in code:
        code = (urllib.parse.parse_qs(urllib.parse.urlparse(code).query).get("code") or [""])[0]
    if not code:
        die("nem talalok code= erteket abban amit kaptam")
    body = urllib.parse.urlencode({
        "client_id": rd(".yt-client-id"),
        "client_secret": rd(".yt-client-secret"),
        "code": code,
        "redirect_uri": REDIRECT,
        "grant_type": "authorization_code",
    }).encode()
    try:
        r = json.load(urllib.request.urlopen("https://oauth2.googleapis.com/token", body, timeout=30))
    except urllib.error.HTTPError as e:
        die("a kod bevaltasa nem sikerult (lejart? mar felhasznaltad?): " + e.read().decode()[:200])
    if "refresh_token" not in r:
        die("jott access token, de refresh nem -- hianyzik az access_type=offline?")
    p = os.path.join(STORE, ".gdrive-refresh-token")
    with open(p, "w") as f:
        f.write(r["refresh_token"])
    os.chmod(p, 0o600)
    for stale in (".gdrive-access-token",):
        try:
            os.remove(os.path.join(STORE, stale))
        except OSError:
            pass
    print("OK jovahagyva, a Drive refresh token elmentve")

elif CMD == "mkdir":
    if not a:
        die("hasznalat: gdrive.sh mkdir <nev> [szulo_id]")
    meta = {"name": a[0], "mimeType": FOLDER_MIME}
    if len(a) > 1 and a[1]:
        meta["parents"] = [a[1]]
    r = api("POST", BASE + "/files?fields=id,name,webViewLink", meta)
    print("%s\t%s\t%s" % (r["id"], r.get("name", ""), r.get("webViewLink", "")))

elif CMD in ("upload", "upload-doc"):
    if len(a) < 2:
        die("hasznalat: gdrive.sh %s <fajl> <szulo_id> [nev]" % CMD)
    path, parent = a[0], a[1]
    if not os.path.isfile(path):
        die("nincs ilyen fajl: " + path)
    name = a[2] if len(a) > 2 else os.path.basename(path)
    mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
    if path.endswith(".md"):
        mime = "text/markdown"
    meta = {"name": name, "parents": [parent]}
    if CMD == "upload-doc":
        # A Drive atalakitja Google Dokumentumma. HTML-bol a cimsorok, tablazatok es
        # listak megmaradnak, tehat olvashato marad, nem egy letoltendo fajl lesz.
        meta["mimeType"] = DOC_MIME
    body, ctype = multipart(meta, path, mime)
    r = api("POST", UP, body, ctype=ctype, raw=True)
    print("%s\t%s\t%s" % (r["id"], r.get("name", ""), r.get("webViewLink", "")))

elif CMD == "export":
    # A feltoltes sikere NEM bizonyitja, hogy a helyes tartalom all fent. Ez az egyetlen
    # kulso ellenorzes: visszaolvassuk a Drive-rol azt, amit az ember latni fog.
    if not a:
        die("hasznalat: gdrive.sh export <id> [kimeneti_fajl]  (alapertelmezetten a kepernyore)")
    url = BASE + "/files/%s/export?mimeType=text/plain" % a[0]
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token()})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            txt = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        msg = e.read().decode()[:300]
        if e.code == 403:
            msg += "  [export csak Google-formatumu fajlra megy -- egy feltoltott .md/.pdf nem exportalhato]"
        die("%s %s" % (e.code, msg))
    if len(a) > 1:
        with open(a[1], "w", encoding="utf-8") as f:
            f.write(txt)
        print("%s\t%d karakter" % (a[1], len(txt)))
    else:
        print(txt)

elif CMD == "rename":
    if len(a) < 2:
        die("hasznalat: gdrive.sh rename <id> <uj_nev>")
    r = api("PATCH", BASE + "/files/%s?supportsAllDrives=true&fields=id,name,webViewLink" % a[0],
            {"name": a[1]})
    print("%s\t%s\t%s" % (r["id"], r.get("name", ""), r.get("webViewLink", "")))

elif CMD == "update":
    # Ugyanaz az id, ugyanaz a link, csak mas tartalom. Ez a javito ut: ujra-feltoltessel
    # ket dokumentum allna a mappaban, es az olvaso nem tudna melyik az ervenyes.
    if len(a) < 2:
        die("hasznalat: gdrive.sh update <id> <fajl> [nev]")
    fid, path = a[0], a[1]
    if not os.path.isfile(path):
        die("nincs ilyen fajl: " + path)
    mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
    if path.endswith(".md"):
        mime = "text/markdown"
    # PATCH-nel a parents NEM mehet a metadataban (arra addParents/removeParents valo),
    # a nev viszont igen -- igy egy hivasban javithato a tartalom es a cim is.
    meta = {"name": a[2]} if len(a) > 2 else {}
    body, ctype = multipart(meta, path, mime)
    r = api("PATCH", "https://www.googleapis.com/upload/drive/v3/files/%s"
            "?uploadType=multipart&supportsAllDrives=true&fields=id,name,webViewLink" % fid,
            body, ctype=ctype, raw=True)
    print("%s\t%s\t%s" % (r["id"], r.get("name", ""), r.get("webViewLink", "")))

elif CMD == "share":
    if len(a) < 2:
        die("hasznalat: gdrive.sh share <id> <email> [reader|writer|commenter]")
    role = a[2] if len(a) > 2 else "writer"
    if role not in ("reader", "writer", "commenter"):
        die("ismeretlen szerep: " + role)
    # sendNotificationEmail=false: ne kuldjon a Google levelet a nevunkben. Az ertesites
    # a mi dolgunk azon a csatornan, ahol a beszelgetes folyik.
    api("POST", BASE + "/files/%s/permissions?sendNotificationEmail=false&fields=id" % a[0],
        {"type": "user", "role": role, "emailAddress": a[1]})
    print("OK %s -> %s (%s)" % (a[0], a[1], role))

elif CMD == "ls":
    q = "trashed=false"
    if a and a[0]:
        q += " and '%s' in parents" % a[0]
    r = api("GET", BASE + "/files?" + urllib.parse.urlencode(
        {"q": q, "fields": "files(id,name,mimeType,modifiedTime,webViewLink)",
         "orderBy": "folder,name", "pageSize": "200"}))
    for f in r.get("files", []):
        kind = "DIR " if f["mimeType"] == FOLDER_MIME else "    "
        print("%s%s\t%s\t%s" % (kind, f["id"], f["name"], f.get("webViewLink", "")))

elif CMD == "link":
    if not a:
        die("hasznalat: gdrive.sh link <id>")
    r = api("GET", BASE + "/files/%s?fields=id,name,webViewLink" % a[0])
    print(r.get("webViewLink", ""))

else:
    die("ismeretlen parancs: '%s' -- mkdir | upload | upload-doc | export | rename | update | share | ls | link" % CMD)
PYEOF
}

case "$cmd" in
  auth-url|auth-code|mkdir|upload|upload-doc|export|rename|update|share|ls|link) run "$@" ;;
  *) die "ismeretlen parancs: '${cmd}' -- auth-url | auth-code | mkdir | upload | upload-doc | export | rename | update | share | ls | link" ;;
esac
