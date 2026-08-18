#!/usr/bin/env bash
#
# UNAS webshop OLVASO helper (shop.acropora.hu, ShopId 47679).
#
# MIERT LETEZIK: a termekadat eddig nem volt gepileg elerheto a flottanak, es emiatt
# minden keszlet- es termekkerdes emberi korkerdes volt (2026-08-16, otleteles: harom
# agens egymastol fuggetlenul ugyanezt a hianyt nevezte meg elso helyen).
#
# BIZTONSAG:
# - A host HARDCODED (api.unas.eu). Nem valtoztathato at exfiltracios csatornava.
# - CSAK get*/check* vegpont hivhato. A szkript megtagad minden mast, meg akkor is,
#   ha valaki kesobb odair egy set*-et. MERT: a kulcs maga is csak olvaso jogokat kapott
#   (lemerve 2026-08-16: 27 permission, mind get vagy check), de a ket vedelem egymastol
#   fuggetlen, es ez igy is marad.
# - A token es az API kulcs SOSEM kerul a kimenetbe.
#
# Hasznalat:
#   unas.sh login                       -> lejarat + jogosultsagok (token nelkul)
#   unas.sh count                       -> hany termek van
#   unas.sh dump <fajl.jsonl>           -> MINDEN termek, soronkent egy JSON objektum
#   unas.sh stock <fajl.jsonl>          -> keszletadatok
#   unas.sh categories [fajl]           -> kategoriafa, JSON (fajlnev nelkul stdout-ra)
#   unas.sh orders <fajl.jsonl> [--since EEEE.HH.NN] [--force]
#                                       -> rendelesek, SZEMELYES ADAT NELKUL (lasd lentebb)
#   unas.sh newsletter-stat             -> hirlevel-lista OSSZESITVE, cimek nelkul
#   unas.sh get <endpoint> [params.xml] -> nyers hivas, csak get*/check* endpointra
#
# SZEMELYES ADAT -- MIERT SZUR AZ `orders`:
# A getOrder nyers valasza tartalmazza a vevo nevet, e-mail cimet, telefonszamat, a szamlazasi
# es szallitasi cimet es az adoszamat. Ezek egy elemzeshez NEM KELLENEK, a lemezre irasuk
# viszont letrehoz egy szemelyesadat-halmazt egy olyan gepen, ahol tobb agens dolgozik, es
# ahol a fajl konnyen bekerul egy repoba. Ezert az `orders` parancs KIVAG mindent, ami
# szemelyhez kot, es csak azt tartja meg, ami a mereshez kell: datum, statusz, vegosszeg,
# fizetesi es szallitasi mod NEVE, es a tetelek (cikkszam, mennyiseg, ar).
# Ha valakinek valaha tenyleg kell a vevoadat, az legyen kulon parancs, kulon indoklassal --
# ne ennek a mellekhatasa. A `newsletter-stat` ugyanezert csak SZAMOKAT ad, egyetlen
# e-mail cimet sem ir ki.
#
# Kimenet: hiba eseten "FAIL <ok>" a stderr-en, exit 1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UNAS_ROOT="$ROOT"
die() { echo "FAIL $*" >&2; exit 1; }

[ -f "$ROOT/store/.unas-api-key" ] || die "nincs API kulcs: store/.unas-api-key"

cmd="${1:-}"; shift || true
case "$cmd" in
  login|count|dump|stock|categories|orders|newsletter-stat|get) ;;
  *) die "ismeretlen parancs: '${cmd}' -- login | count | dump | stock | categories | orders | newsletter-stat | get" ;;
esac

UNAS_CMD="$cmd" python3 - "$@" <<'PYEOF'
import json, os, re, sys, time, urllib.request
import xml.etree.ElementTree as ET

ROOT = os.environ["UNAS_ROOT"]
CMD = os.environ["UNAS_CMD"]
STORE = os.path.join(ROOT, "store")
HOST = "https://api.unas.eu/shop/"
PAGE = 500


def die(m):
    print("FAIL " + m, file=sys.stderr)
    raise SystemExit(1)


def post(endpoint, xml, token=None, timeout=180):
    if not (endpoint.startswith("get") or endpoint.startswith("check") or endpoint == "login"):
        die("csak olvaso vegpont hivhato, ez nem az: " + endpoint)
    h = {"Content-Type": "application/xml; charset=utf-8"}
    if token:
        h["Authorization"] = "Bearer " + token
    req = urllib.request.Request(HOST + endpoint, data=xml.encode("utf-8"), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        die("%s %s: %s" % (endpoint, e.code, e.read().decode("utf-8", "replace")[:300]))
    except Exception as e:
        die("%s halozati hiba: %s" % (endpoint, e))


def login():
    """Token cache-elve a lejarat elott 120 masodpercig. A tokent sosem irjuk ki."""
    cache = os.path.join(STORE, ".unas-token")
    try:
        d = json.load(open(cache))
        if d.get("expire", 0) > time.time() + 120:
            return d["token"], d
    except Exception:
        pass
    key = open(os.path.join(STORE, ".unas-api-key")).read().strip()
    body = '<?xml version="1.0" encoding="UTF-8" ?><Params><ApiKey>%s</ApiKey></Params>' % key
    root = ET.fromstring(post("login", body, timeout=45))
    tok = root.findtext("Token")
    if not tok:
        die("a login nem adott tokent (lejart vagy visszavont kulcs?)")
    info = {"token": tok,
            "expire": int(root.findtext("ExpireTime") or 0),
            "expire_h": root.findtext("Expire"),
            "shop": root.findtext("ShopId"),
            "perms": [p.text for p in root.iter("Permission")]}
    with open(cache, "w") as f:
        json.dump(info, f)
    os.chmod(cache, 0o600)
    return tok, info


def x2d(el):
    """XML reszfa -> dict. Ismetlodo gyerek -> lista. Sosem dob el adatot."""
    kids = list(el)
    if not kids:
        return (el.text or "").strip()
    out = {}
    for k in kids:
        v = x2d(k)
        if k.tag in out:
            if not isinstance(out[k.tag], list):
                out[k.tag] = [out[k.tag]]
            out[k.tag].append(v)
        else:
            out[k.tag] = v
    return out


def paged(token, endpoint, item_tag, params_extra=""):
    """Lapozva kikeri az osszes tetelt. A UNAS LimitStart/LimitNum parost hasznal.

    A LimitStart 1-ALAPU, nem eltolas. Ez merve lett 2026-08-16: nulla kezdettel az
    elso ket lap ATFEDETT egyetlen tetellel (a 778843825 azonosito ketszer jott vissza,
    pontosan az 500-as hataron), mert a 0 es az 1 kezdet ugyanazt jelenti. Csak az ELSO
    hataron latszik, a kesobbieken nem -- vagyis egy felszines proba nem mutatja meg.
    """
    start, seen = 1, 0
    while True:
        body = ('<?xml version="1.0" encoding="UTF-8" ?><Params>'
                '<LimitStart>%d</LimitStart><LimitNum>%d</LimitNum>%s</Params>'
                % (start, PAGE, params_extra))
        root = ET.fromstring(post(endpoint, body, token))
        items = list(root.iter(item_tag))
        if not items:
            return seen
        for it in items:
            yield x2d(it)
            seen += 1
        if len(items) < PAGE:
            return seen
        start += PAGE


a = sys.argv[1:]

if CMD == "login":
    _, info = login()
    print("shop=%s lejarat=%s" % (info["shop"], info["expire_h"]))
    print("jogosultsagok (%d): %s" % (len(info["perms"]), " ".join(info["perms"])))
    write = [p for p in info["perms"] if not (p.startswith("get") or p.startswith("check"))]
    print("IRASI JOG: " + (", ".join(write) if write else "nincs -- a kulcs csak olvasni tud"))

elif CMD == "count":
    tok, _ = login()
    n = 0
    for _ in paged(tok, "getProduct", "Product", "<ContentType>minimal</ContentType>"):
        n += 1
    print(n)

elif CMD in ("dump", "stock"):
    if not a:
        die("hasznalat: unas.sh %s <kimeneti fajl.jsonl> [--force]" % CMD)
    # NEM IRUNK FELUL NEMAN. 2026-08-16 ejjel pontosan ez tortent: ujratoltottem a
    # dumpot ugyanarra a nevre, mikozben polip epp abbol dolgozott. A ket meres kozti
    # kulonbseg ugy nezett ki, mintha a boltban tortent volna valtozas. Egy meres, ami
    # nem reprodukalhato, rosszabb mint a hianyzo meres, mert ugy nez ki mint adat.
    force = "--force" in a[1:]
    target = a[0]
    if os.path.exists(target) and not force:
        stamp = time.strftime("%Y-%m-%d-%H%M", time.localtime(os.path.getmtime(target)))
        root, ext = os.path.splitext(target)
        die("mar letezik es nem irom felul: %s\n"
            "       A meglevo fajl %s-os. Vagy adj uj nevet (javaslat: %s-%s%s),\n"
            "       vagy ha tenyleg le akarod cserelni: --force" % (target, stamp, root, stamp, ext))
    tok, _ = login()
    # A getStock is <Product> elemeket ad vissza (Id, Sku, Stocks/Stock/Qty). Elsore a
    # <Stock> tagre iteraltam, es akkor a kimenetbol HIANYZOTT AZ AZONOSITO: csak a
    # mennyiseg jott, termekhez rendelni nem lehetett. polip vette eszre 2026-08-16.
    # Mellekhatas volt az is, hogy a sorszam (1898) nem egyezett a termekszammal, mert
    # egy termekhez tobb Stock sor is tartozhat.
    endpoint, tag, extra = (("getProduct", "Product", "<ContentType>full</ContentType>")
                            if CMD == "dump" else ("getStock", "Product", ""))
    n = 0
    with open(a[0], "w") as f:
        for item in paged(tok, endpoint, tag, extra):
            f.write(json.dumps(item, ensure_ascii=False) + "\n")
            n += 1
    print("%d sor -> %s" % (n, a[0]))

elif CMD == "categories":
    tok, _ = login()
    body = '<?xml version="1.0" encoding="UTF-8" ?><Params></Params>'
    root = ET.fromstring(post("getCategory", body, tok))
    cats = [x2d(c) for c in root.iter("Category")]
    if a:
        # A kategoriafa nagy, es stdout-ra ontve hasznalhatatlan. polip kerese, 2026-08-16.
        with open(a[0], "w", encoding="utf-8") as f:
            if a[0].endswith(".jsonl"):
                for c in cats:
                    f.write(json.dumps(c, ensure_ascii=False) + "\n")
            else:
                json.dump(cats, f, ensure_ascii=False, indent=1)
                f.write("\n")
        print("%d kategoria -> %s" % (len(cats), a[0]))
    else:
        print(json.dumps(cats, ensure_ascii=False, indent=1))

elif CMD == "orders":
    if not a:
        die("hasznalat: unas.sh orders <kimeneti fajl.jsonl> [--since EEEE.HH.NN] [--force]")
    target = a[0]
    force = "--force" in a[1:]
    since = None
    for i, v in enumerate(a):
        if v == "--since":
            if i + 1 >= len(a):
                die("a --since utan datum kell, EEEE.HH.NN alakban (pl. 2026.01.01)")
            since = a[i + 1]
    if since and not re.match(r"^\d{4}\.\d{2}\.\d{2}$", since):
        die("a --since alakja EEEE.HH.NN legyen (pl. 2026.01.01), ez nem az: " + since)
    if os.path.exists(target) and not force:
        stamp = time.strftime("%Y-%m-%d-%H%M", time.localtime(os.path.getmtime(target)))
        r_, e_ = os.path.splitext(target)
        die("mar letezik es nem irom felul: %s (%s-os). Adj uj nevet vagy --force." % (target, stamp))

    # A megtartott mezok LISTAJA, nem a kihagyottake. Igy ha a UNAS holnap uj mezot ad
    # vissza, az NEM kerul be automatikusan -- egy uj szemelyes mezo nem szivarog at azzal,
    # hogy valaki elfelejtette bovíteni a tiltolistat.
    KEEP = ("Key", "Id", "Date", "DateMod", "Currency", "Status", "StatusType",
            "SumPriceGross", "SumPriceNet", "Seen", "Lang")
    ITEM_KEEP = ("Id", "Sku", "Name", "Unit", "Quantity", "PriceNet", "PriceGross", "Vat")

    def clean(o):
        out = {k: o[k] for k in KEEP if k in o}
        for blk in ("Shipping", "Payment"):
            b = o.get(blk)
            if isinstance(b, dict) and b.get("Name"):
                out[blk] = b["Name"]          # csak a MOD neve, semmi cim
        inv = o.get("Invoice")
        if isinstance(inv, dict) and inv.get("Status"):
            out["InvoiceStatus"] = inv["Status"]
        items = (o.get("Items") or {}).get("Item")
        if isinstance(items, dict):
            items = [items]
        if isinstance(items, list):
            out["Items"] = [{k: it[k] for k in ITEM_KEEP if isinstance(it, dict) and k in it}
                            for it in items]
        return out

    tok, _ = login()
    extra = ("<DateStart>%s</DateStart>" % since) if since else ""
    n = 0
    with open(target, "w", encoding="utf-8") as f:
        for o in paged(tok, "getOrder", "Order", extra):
            f.write(json.dumps(clean(o), ensure_ascii=False) + "\n")
            n += 1
    print("%d rendeles -> %s%s" % (n, target, (" (%s ota)" % since) if since else ""))
    print("szemelyes adat NINCS a fajlban: nev, e-mail, telefon, cim es adoszam kimaradt.")

elif CMD == "newsletter-stat":
    # Szandekosan NEM ir fajlt es NEM ad ki egyetlen e-mail cimet sem. A kerdes, amire
    # valaszol ('milyen szegmensek vannak'), szamokkal megvalaszolhato.
    tok, _ = login()
    from collections import Counter
    total = 0
    by_type, by_auth, by_lang, by_year = Counter(), Counter(), Counter(), Counter()
    for s in paged(tok, "getNewsletter", "Subscriber", ""):
        total += 1
        by_type[s.get("Type") or "?"] += 1
        by_auth[s.get("Authorized") or "?"] += 1
        by_lang[s.get("Lang") or "?"] += 1
        try:
            by_year[time.strftime("%Y", time.localtime(int(s.get("Time") or 0)))] += 1
        except Exception:
            by_year["?"] += 1
    print("hirlevel-feliratkozo osszesen: %d" % total)
    print("\ntipus szerint:")
    for k, v in by_type.most_common():
        print("  %-12s %5d" % (k, v))
    print("\nmegerositve (Authorized):")
    for k, v in by_auth.most_common():
        print("  %-12s %5d" % (k, v))
    print("\nnyelv szerint:")
    for k, v in by_lang.most_common():
        print("  %-12s %5d" % (k, v))
    print("\nfeliratkozas eve szerint:")
    for k in sorted(by_year):
        print("  %-12s %5d" % (k, by_year[k]))
    print("\nEgyetlen e-mail cim sem hagyta el ezt a parancsot.")

elif CMD == "get":
    if not a:
        die("hasznalat: unas.sh get <endpoint> [params.xml]")
    tok, _ = login()
    body = open(a[1]).read() if len(a) > 1 else '<?xml version="1.0" encoding="UTF-8" ?><Params></Params>'
    print(post(a[0], body, tok))
PYEOF
