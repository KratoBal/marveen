#!/usr/bin/env python3
# ANSWERS: Hany vevonk van es milyen az adatuk allapota -- KIZAROLAG osszesitett szamokban, sor nelkul.
#
# MIERT LETEZIK, es miert IGY. Polip 2026-09-02 ota vart dontesre: kapjon-e PII-szuro eszkozt a
# vevo-mereshez. A valasz 2026-09-08 22:50-kor: nem eszkozt kap, hanem masik munkamegosztast.
# O megmondja, MIT kell tudni; a lekerdezest az futtatja, akinel a kulcs van; o OSSZESITETT
# szamokat kap vissza, soha nem sorokat.
#
# AZ INDOK NEM BIZALMI. Egy PII-szuro eszkoz attol PII-szuro, hogy ELOBB BEOLVASSA a PII-t,
# aztan kiszuri -- a sorok igy is atmennek a hivo kornyezeten. Polip mind a hat kerdese
# megvalaszolhato osszesitesbol, egyetlen nev, cim, telefon vagy email nelkul.
#
# EZERT A SZERKEZETI KIKOTES, AMI EBBEN A FAJLBAN VEGIG ALL:
#   - egyetlen vevo-sor SEM kerul lemezre, sem fajlba, sem naploba
#   - a kimenet KIZAROLAG szam
#   - az email cimek OSSZEHASONLITASA a duplikatum-kerdeshez lenyomatban tortenik, nem nyersen
#
# Csak olvas: a UNAS getCustomer vegpontjat hivja, ami a login jogosultsag-listajan szerepel.
import hashlib, os, sys, time, json, urllib.request
import xml.etree.ElementTree as ET

ROOT = "/home/marveen/marveen"
STORE = os.path.join(ROOT, "store")
HOST = "https://api.unas.eu/shop/"
PAGE = 500


def die(m):
    print("FAIL " + m, file=sys.stderr)
    raise SystemExit(1)


def post(endpoint, xml, token=None, timeout=180):
    if not (endpoint.startswith("get") or endpoint == "login"):
        die("csak olvaso vegpont hivhato, ez nem az: " + endpoint)
    h = {"Content-Type": "application/xml; charset=utf-8"}
    if token:
        h["Authorization"] = "Bearer " + token
    req = urllib.request.Request(HOST + endpoint, data=xml.encode("utf-8"), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read().decode("utf-8", "replace")
    except Exception as e:
        die("%s hiba: %s" % (endpoint, str(e)[:200]))


def login():
    cache = os.path.join(STORE, ".unas-token")
    try:
        d = json.load(open(cache))
        if d.get("expire", 0) > time.time() + 120:
            return d["token"]
    except Exception:
        pass
    key = open(os.path.join(STORE, ".unas-api-key")).read().strip()
    body = '<?xml version="1.0" encoding="UTF-8" ?><Params><ApiKey>%s</ApiKey></Params>' % key
    root = ET.fromstring(post("login", body, timeout=45))
    tok = root.findtext("Token")
    if not tok:
        die("a login nem adott tokent")
    return tok


def main():
    tok = login()
    # A szamlalok. TUDATOSAN nincs kozottuk egyetlen lista sem, ami sort tarolna.
    total = 0
    van_email = 0
    regisztralt = 0
    vendeg = 0
    cim_nelkul = 0
    cim_egy = 0
    cim_tobb = 0
    email_lenyomatok = {}
    rendelt_12ho = 0
    soha_nem_rendelt = 0
    hibas_datum = 0

    most = time.time()
    egy_ev = most - 365 * 24 * 3600

    start = 1
    while True:
        body = ('<?xml version="1.0" encoding="UTF-8" ?><Params>'
                '<LimitStart>%d</LimitStart><LimitNum>%d</LimitNum></Params>' % (start, PAGE))
        root = ET.fromstring(post("getCustomer", body, tok))
        rows = root.findall("Customer")
        if not rows:
            break
        for c in rows:
            total += 1
            email = (c.findtext("Email") or "").strip().lower()
            if email:
                van_email += 1
                # LENYOMAT, nem a cim maga. A duplikatum-szam igy is pontos.
                h = hashlib.sha256(email.encode("utf-8")).hexdigest()
                email_lenyomatok[h] = email_lenyomatok.get(h, 0) + 1
            # A regisztralt/vendeg megkulonboztetes a UNAS sajat jelzojebol
            tip = (c.findtext("Type") or "").strip().lower()
            jelszo = (c.findtext("Password") or "").strip()
            if jelszo or tip in ("registered", "reg"):
                regisztralt += 1
            else:
                vendeg += 1
            cimek = c.findall(".//Address") or c.findall(".//Contact")
            n = len(cimek)
            if n == 0:
                cim_nelkul += 1
            elif n == 1:
                cim_egy += 1
            else:
                cim_tobb += 1
            utolso = (c.findtext("LastOrderTime") or c.findtext("LastOrder") or "").strip()
            if not utolso:
                soha_nem_rendelt += 1
            else:
                try:
                    ts = float(utolso) if utolso.isdigit() else time.mktime(time.strptime(utolso[:10], "%Y.%m.%d"))
                    if ts >= egy_ev:
                        rendelt_12ho += 1
                except Exception:
                    hibas_datum += 1
        if len(rows) < PAGE:
            break
        start += PAGE

    tobbszor = sum(1 for v in email_lenyomatok.values() if v > 1)
    erintett = sum(v for v in email_lenyomatok.values() if v > 1)

    print("=== VEVO-OSSZESITO, %s ===" % time.strftime("%Y-%m-%d %H:%M"))
    print("A kimenet KIZAROLAG szam. Egyetlen vevo-sor sem kerult lemezre.")
    print()
    print("1. vevo osszesen                       %d" % total)
    print("2. regisztralt (van jelszo vagy jelzo) %d" % regisztralt)
    print("   vendeg                              %d" % vendeg)
    print("3. van kitoltott email cime            %d   (nincs: %d)" % (van_email, total - van_email))
    print("4. nincs cime                          %d" % cim_nelkul)
    print("   pontosan egy cime van               %d" % cim_egy)
    print("   tobb cime van                       %d" % cim_tobb)
    print("5. rendelt az utolso 12 honapban       %d" % rendelt_12ho)
    print("   soha nem rendelt                    %d" % soha_nem_rendelt)
    print("   ertelmezhetetlen datum              %d" % hibas_datum)
    print("6. egynel tobbszor szereplo email cim  %d   (erintett vevo-rekord: %d)" % (tobbszor, erintett))
    print()
    print("EGYEDI EMAIL LENYOMAT: %d  (a %d kitoltott cimbol)" % (len(email_lenyomatok), van_email))


if __name__ == "__main__":
    main()
