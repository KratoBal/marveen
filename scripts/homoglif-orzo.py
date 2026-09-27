#!/usr/bin/env python3
"""ANSWERS: Van-e cirill (vagy mas nem-latin) homoglif a kimeno szovegben? Ha igen, MEGALL.

MIERT LETEZIK, ES MIERT SZKRIPT ES NEM SZOKAS (sajat meres, 2026-09-21 14:58):

A magyar szovegembe idonkent cirill betu kerul, ami a latinnal AZONOSAN nez ki (a, e, o,
c, p, x, т). A sajat lapomon all a szabaly, hogy kuldes elott meg kell nezni -- es ma
harom kulon uzenetnel meg is neztem, beagyazott `python3 -c` hivassal.

A NEGYEDIKNEL A NEZES MEGTORTENT, A VEDELEM MEGSEM MUKODOTT. A hivas megtalalta a
gyanus karaktert, kiirta, hogy MARADT 1 -- es a parancs `&&` lanca TOVABBMENT, mert a
python NULLAVAL tert vissza. Az ellenorzes beszelt, a kuldes pedig megtortent mellette.

Pontosan az a hibafajta, amit a sajat lapomon ugy hivok, hogy "egy orzo, ami szol, de nem
allit meg": a `&&` a KILEPESI KODOT nezi, nem a kiirt szoveget. Egy ellenorzes, ami
mindig nullat ad vissza, dekoracio.

EZERT: ez a szkript NEM NULLAVAL ter vissza, ha talalt valamit. Igy egy
  `python3 scripts/homoglif-orzo.py fajl && bash scripts/agent-msg.sh ...`
lancban a kuldes EL SEM INDUL.

MIT NEZ, ES MIT NEM:
  - minden karakter U+03FF felett (a gorog/cirill blokkoktol felfele). A magyar
    ekezetes betuk (á é í ó ö ő ú ü ű) mind U+0200 alatt vannak, tehat NEM riasztanak.
  - NEM nezi az emojikat kulon: azok is a hatar felett vannak, tehat egy emojis
    szoveg riasztani fog. Ez SZANDEKOS: a csatorna-uzenetekben hasznalunk emojit, de
    az inter-agent es a kartya-szovegekben nem -- es ez a szkript azokra valo.
    Ha valaha emojis szoveget kell atengedni, a `--emoji-ok` kapcsolo a helye,
    NEM a hatar felemelese.

HASZNALAT:
    python3 /home/marveen/marveen/scripts/homoglif-orzo.py <fajl>
    kilepesi kod 0 = tiszta, 1 = talalt (es kiirja, hol)
"""

import sys
import unicodedata

HATAR = 0x03FF

# A MAGYAR TIPOGRAFIA KARAKTEREI, AMIK A HATAR FOLOTT VANNAK, DE NEM HOMOGLIFEK.
#
# MIERT KELL EZ A LISTA, ES MIERT NEM ELEG A HATART FELJEBB VINNI: a hatar
# pontosan azert all a cirill blokk ALATT, hogy a `т` es tarsai fennakadjanak.
# A magyar idezojel (U+201E es U+201D) viszont VALODI, helyes karakter, es a
# sajat szovegeimben rendszeresen elofordul.
#
# ES AZ INDOK NEM KENYELEM, HANEM AZ ORZO ERTEKE (merve 2026-09-21): ha egy
# orzo minden magyar idezojelnel megall, akkor napi tobbszor kiabal olyankor,
# amikor nincs baj -- es aki ezt megszokja, az a VALODI talalatot is atlapozza.
# Egy orzo, ami folyamatosan szol, ugyanaz, mint egy orzo, ami sosem.
#
# AMI SZANDEKOSAN NINCS BENNE: a gondolatjel (U+2013, U+2014). Azt a hazirend
# tiltja a csatorna-uzenetekben, tehat ott a megallas HELYES viselkedes.
KIVETEL = {
    0x201A,  # SINGLE LOW-9 QUOTATION MARK
    0x201E,  # DOUBLE LOW-9 QUOTATION MARK   -- a magyar nyito idezojel
    0x2018,  # LEFT SINGLE QUOTATION MARK
    0x2019,  # RIGHT SINGLE QUOTATION MARK   -- aposztrof is
    0x201C,  # LEFT DOUBLE QUOTATION MARK
    0x201D,  # RIGHT DOUBLE QUOTATION MARK   -- a magyar zaro idezojel
    0x2026,  # HORIZONTAL ELLIPSIS
    0x00A0,  # NO-BREAK SPACE
}


def main() -> int:
    if len(sys.argv) < 2:
        print("hasznalat: homoglif-orzo.py <fajl>", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            szoveg = fh.read()
    except OSError as hiba:
        print(f"nem olvashato: {hiba}", file=sys.stderr)
        return 2

    talalt = []
    for i, karakter in enumerate(szoveg):
        if ord(karakter) > HATAR and ord(karakter) not in KIVETEL:
            kornyezet = szoveg[max(0, i - 24) : i + 12].replace("\n", " ")
            try:
                nev = unicodedata.name(karakter)
            except ValueError:
                nev = "(nincs neve)"
            talalt.append((hex(ord(karakter)), nev, kornyezet))

    if not talalt:
        return 0

    print(f"MEGALLOK: {len(talalt)} nem-latin karakter a szovegben.")
    for kod, nev, kornyezet in talalt:
        print(f"  {kod}  {nev}")
        print(f"      ...{kornyezet}...")
    print("A szo, amiben all, LATINNAK latszik -- keresd ki a fenti kornyezetbol,")
    print("es ird ujra a KEZEDDEL, ne cserevel: egy rossz codepointra celzott")
    print("csere csendben nem talal, es a szkript ujra megall rajta.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
