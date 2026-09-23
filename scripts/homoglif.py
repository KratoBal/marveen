#!/usr/bin/env python3
# ANSWERS: Van-e LATIN BETUNEK LATSZO nem-latin betu a szovegben (cirill homoglif magyar szo kozepen), ami a kereses elol elrejti a szot. Irta: nautilus.
"""MEGKERESI (es kereskor kijavitja) a LATIN BETUNEK LATSZO nem-latin betuket.

MIERT LETEZIK (sajat meres, 2026-09-18, HAROM eset egy oran belul): a sajat
kimenetembe cirill betuk kerultek magyar szavak kozepere -- egyszer egy
forrasfajlba (`felulete`), egyszer egy memoria-bejegyzesbe, egyszer egy kimeno
uzenetbe (a `visszakereshető` szo `o` betujeben).

MIND A HAROM KAPU ATENGEDTE: a TypeScript fordul (a szo kommentben all), a
prettier zold (formailag helyes), es a szem nem latja. Amit elvisz, az a
KERESES: egy `grep "felulete"` nem talalja meg, es a nulla ugy nez ki, mint
hiany.

ES A MERO A SAJAT PELDAIT IS MERTE, AMIG AT NEM IRTAM: az elso alakomban a
tabla LITERALIS betukkel allt, tehat a `homoglif.py homoglif.py` hivas hatot
jelentett sajat magara -- es a `--javit` SAJAT MAGARA futtatva SZETVERTE volna a
tablat. Ezert all a tabla `\\uXXXX` alakban: a kizaras igy SZERKEZETI, nem egy
kezzel karbantartott fajlnev-lista, ami a kovetkezo peldanal ujra elcsuszna.

ES A HARMADIK MERT KAR, 2026-09-23: A DETEKTOR SZUKEBB VOLT, MINT A VILAG.
Nautilus egy uj CI-munkafolyamat kommentjebe ket cirill `\u0442` betu kerult
(`ag-elo<t>agon`, `meres/** elo<t>agon`). Ez az eszkoz "nincs homoglif"-et irt
ki rola, mert a `\u0442` EGYIK TABLABAN SEM SZEREPELT -- egy hatsoros, kezzel
irt ellenorzes viszont azonnal megtalalta mind a kettot.

UGYANAZ AZ OK, MINT A FENTI `\u043c` ESETNEL EGY NAPPAL KORABBAN, es ott a
javitas AZ VOLT, HOGY FELVETTUK A HIANYZO BETUT. Az nem a hibat javitotta,
hanem az egyik peldanyat: egy KEZZEL KARBANTARTOTT LISTA pontosan addig ved,
ameddig valaki eszreveszi, hogy bovitenie kell -- es a hianyt csak akkor veszi
eszre, ha egy masik uton MAR megtalalta a hibat.

EZERT A DETEKTOR MOSTANTOL SZERKEZETI: gyanus MINDEN nem-latin BETU, tablatol
fuggetlenul (`gyanus()`). A tablak megmaradtak, de mar CSAK a javitashoz: mit
lehet magatol atirni, mit nem. A ketto szetvalasztasa ugyanaz az elv, ami a
fenti ket esetbol jott, csak most a MASIK iranyban kellett: eddig a javitas
volt szukebb a detektornal, most a detektor volt szukebb a valosagnal.

A HAMIS NEGATIV ARA NAGYOBB, MINT A HAMIS POZITIVE: egy "nincs homoglif"
valasz LEZARJA a kerdest, es utana senki nem keres tovabb. Ezert a tagabb
detektor a helyes irany meg akkor is, ha nehany talalat kezi dontest igenyel.
(Merve: a magyar ekezetes betuk -- a, e, i, o, o, o, u, u, u es nagybetus
parjaik -- LATIN nevuek, tehat NEM riasztanak. Kulon teszteltem.)

ES AMIERT ESZKOZ LETT BELOLE, NEM SZABALY: a harmadik esetnel a sajat,
kezzel irt ellenorzesem MEGTALALTA a betut, a JAVITASOM viszont csak EGY
karakterre volt beirva (`\\u0435`), a talalat pedig egy masik volt
(`\\u043e`). A detektor tagabb volt, mint a javitas -- es ez a legrosszabb
alak, mert a kimenet ugy nez ki, mintha kezelve lenne.

HASZNALAT:
    python3 homoglif.py <fajl> [<fajl> ...]           csak jelent, nem ir
    python3 homoglif.py --javit <fajl> [<fajl> ...]   ki is javitja

KILEPESI KOD:
    0  nincs talalat, VAGY `--javit` mellett mindet at tudtam irni
    1  VAN talalat (jelentes modban), VAGY `--javit` mellett KETERTELMU betu
       maradt, amit nem szabad talalgatni
    2  a bemenetet nem tudtam elolvasni

A ketertelmu betu MIATTI egyes szandekos: egy `--javit`, ami nullaval ter vissza
ugy, hogy a szovegben romlott betu maradt, pontosan az az alak, amit ez a fajl
gyujt -- a muvelet "sikeres", es a hiba bent van.
"""

import sys
import unicodedata

# KET TABLA, ES A SZETVALASZTAS EGY MERT KARBOL SZULETETT (2026-09-22).
#
# Az elso alak EGY tablat hasznalt, es a javitasa a LATSZATRA epult (a cirill
# `\u0440` ugy nez ki, mint egy latin `p`). A sajat romlasaim viszont NEM
# latszat szerint keletkeznek, hanem HANG szerint: a `harmat` szoba a cirill
# `\u0440` az `r` HELYERE kerult, nem a `p` helyere.
#
# MERVE, a valodi romlasomon: a `h<a><r><m>at` alak `hap<m>at`-ra "javult".
# A szo latinul olvashato lett es HAMIS -- vagyis az eszkoz egy MEG
# MEGTALALHATO hibat alakitott at egy lathatatlanra. Pontosan az, ami ellen a
# fenti fejlec ervel.
#
#     JAVITHATO   ahol a LATSZAT es a HANG UGYANAZ a latin betut adja
#     CSAK JELZES ahol ELTERNEK -- ott nem talalgatunk, hanem szolunk
#
# A `\u043c` (em) 2026-09-22-ig HIANYZOTT, es epp az volt a harmadik betu a
# ket mai romlasomban: a mero "2 javitva"-t irt ki, es a szoveg romlott maradt.
JAVITHATO = {
    "\u0430": "a",  # CYRILLIC SMALL LETTER A    -- latszat a, hang a
    "\u0435": "e",  # CYRILLIC SMALL LETTER IE   -- latszat e, hang e
    "\u043e": "o",  # CYRILLIC SMALL LETTER O    -- latszat o, hang o
    "\u043c": "m",  # CYRILLIC SMALL LETTER EM   -- latszat m, hang m
    "\u0410": "A",
    "\u0415": "E",
    "\u041e": "O",
    "\u041c": "M",
    "\u03bf": "o",  # GREEK SMALL LETTER OMICRON
    "\u0391": "A",  # GREEK CAPITAL LETTER ALPHA
    "\u039f": "O",
}

# Ezeket MEGTALALJA, de SOHA nem irja at: a latszat es a hang ket KULONBOZO
# latin betut adna, es a valasztas a szovegtol fugg, nem a karaktertol.
CSAK_JELZES = {
    "\u0440": "p vagy r",  # CYRILLIC SMALL LETTER ER
    "\u0441": "c vagy s",  # CYRILLIC SMALL LETTER ES
    "\u0443": "y vagy u",  # CYRILLIC SMALL LETTER U
    "\u0445": "x vagy h",  # CYRILLIC SMALL LETTER HA
    "\u0420": "P vagy R",
    "\u0421": "C vagy S",
    "\u0423": "Y vagy U",
    "\u0425": "X vagy H",
}

LEKEPEZES = {**JAVITHATO, **{k: None for k in CSAK_JELZES}}


def gyanus(ch):
    """Nem-latin BETU-e. SZERKEZETI teszt, nem egy kezzel karbantartott lista.

    A magyar es az angol szoveg latin irasjegyekbol all, tehat BARMELY nem-latin
    BETU gyanus, akkor is, ha soha senki nem vette fel egy tablaba. A szamjegy,
    az irasjel es a szokoz nem betu, tehat nem esik ide.
    """
    if not ch.isalpha():
        return False
    return not unicodedata.name(ch, "").startswith("LATIN")


def talalatok(szoveg):
    """Hol all homoglif, es melyik. Sor- es oszlopszammal, hogy megtalalhato legyen."""
    ki = []
    for sorszam, sor in enumerate(szoveg.splitlines(), 1):
        for oszlop, ch in enumerate(sor, 1):
            if gyanus(ch):
                ki.append((sorszam, oszlop, ch, unicodedata.name(ch, "?")))
    return ki


def javit(szoveg):
    """CSAK a JAVITHATO tablat csereli -- a ketertelmu betuket ERINTETLENUL hagyja.

    A detektor (`talalatok`) TAGABB, mint a javitas, es ez SZANDEKOS: a
    `CSAK_JELZES` betuit megtalalja, de nem talalgat helyettuk. A fejlecben allo
    mert eset mutatja, miert -- egy rossz iranyba "javitott" szo latinul
    olvashato lesz, tehat a kovetkezo kereses sem talalja meg.

    ES A FUGGVENY MEG IS MONDJA, HA MARADT: a hivo a visszateresi ertekbol latja,
    hany talalatot NEM irt at. Egy nema reszleges javitas ugyanaz az alak, mint
    az orzo, ami szol de a muvelet vegigmegy.
    """
    for rossz, jo in JAVITHATO.items():
        szoveg = szoveg.replace(rossz, jo)
    # A maradekot UJRAMERJUK a detektorral, nem a CSAK_JELZES tablabol szamoljuk.
    # A ket szam 2026-09-23-ig ugyanaz volt, es epp ezert nem latszott, hogy a
    # tablabol szamolas CSAK a tablat ismeri: egy ISMERETLEN nem-latin betu
    # nullat adott volna, tehat a javitas "teljesnek" latszott volna.
    maradt = len(talalatok(szoveg))
    return szoveg, maradt


def main(argv):
    javitsunk = "--javit" in argv
    utak = [a for a in argv if a != "--javit"]
    if not utak:
        sys.stderr.write("HASZNALAT: homoglif.py [--javit] <fajl> [<fajl> ...]\n")
        return 2

    osszes = 0
    kezi = 0
    for ut in utak:
        try:
            with open(ut, encoding="utf-8") as f:
                szoveg = f.read()
        except OSError as hiba:
            sys.stderr.write(f"FAIL: {ut}: {hiba}\n")
            return 2

        talalt = talalatok(szoveg)
        osszes += len(talalt)
        for sorszam, oszlop, ch, nev in talalt:
            if ch in CSAK_JELZES:
                cimke = f"  -> NEM JAVITOM MAGAMTOL ({CSAK_JELZES[ch]})"
            elif ch in JAVITHATO:
                cimke = f"  -> javithato: {JAVITHATO[ch]!r}"
            else:
                cimke = "  -> ISMERETLEN nem-latin betu, NEM JAVITOM MAGAMTOL"
            print(f"{ut}:{sorszam}:{oszlop}  {ch!r}  {nev}{cimke}")
        if javitsunk and talalt:
            ujszoveg, maradt = javit(szoveg)
            with open(ut, "w", encoding="utf-8") as f:
                f.write(ujszoveg)
            print(f"{ut}: {len(talalt) - maradt} javitva, {maradt} ERINTETLEN")
            kezi += maradt

    if osszes == 0:
        print(f"nincs homoglif ({len(utak)} fajlban keresve)")
        return 0
    if javitsunk and kezi:
        sys.stderr.write(
            f"FAIL: {kezi} betu MARADT -- kezzel kell javitani. Ket ok lehet:\n"
            "  KETERTELMU  a latszat es a hang ket kulonbozo latin betut adna, es a\n"
            "              valasztas a szovegtol fugg, nem a karaktertol.\n"
            "  ISMERETLEN  nem-latin betu, amit egyik tabla sem ismer. A detektor\n"
            "              SZERKEZETI, a javitas tablas -- tehat tobbet TALAL, mint\n"
            "              amennyit at mer irni. Ez szandekos.\n"
            "Lasd a fajl fejlecet a mert esetekkel.\n"
        )
        return 1
    return 0 if javitsunk else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
