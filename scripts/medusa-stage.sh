#!/usr/bin/env bash
# ANSWERS: Mi all a TESZT Medusaban (commerce-stage), es milyen alaku. CSAK OLVAS.
#
# Hasznalat:
#   medusa-stage.sh health                  -> el-e a szolgaltatas
#   medusa-stage.sh categories              -> a kategoriafa, teljes egeszeben
#   medusa-stage.sh products [limit]        -> termekek (alapertelmezes 10)
#   medusa-stage.sh variants [limit]        -> VALTOZATONKENT: handle, sku, barcode
#   medusa-stage.sh product-fields          -> EGY termek mezoneveinek listaja
#   medusa-stage.sh product <handle>        -> EGY termek mezoi: leiras, hossz, jelolok
#   medusa-stage.sh collections             -> gyujtemenyek
#   medusa-stage.sh counts                  -> csak a darabszamok, egy sorban
#   medusa-stage.sh exists <utvonal>        -> LETEZIK-E egy store vegpont (200/404)
#   medusa-stage.sh query <ut> [fields] [par ...] -> TETSZOLEGES /store lekerdezes, lapozva,
#                                              soronkent egy JSON objektum. A negyediktol
#                                              KEZDVE minden argumentum parameter, `&`-tel
#                                              fuzve -- egy sem vesz el.
#
# MIERT LETEZIK (2026-09-02): Balazs olvaso hozzaferest adott az agenseknek a teszt
# Medusahoz ("Kaphatnak", 18:22), hogy eldontheto legyen, milyen fogalmakat ismer a
# rendszer. A kulcsot NEM adjuk at senkinek: ez a szkript olvassa a store/ konyvtarbol,
# es a kimenetbe soha nem kerul bele.
#
# BIZTONSAG, es mindharom szerkezeti, nem igeret:
#   - A host HARDCODED (commerce-stage.acropora.hu). Nem valtoztathato at kifele
#     mutato csatornava.
#   - CSAK GET megy ki. Nincs POST/PUT/DELETE ag, es nincs olyan kapcsolo, ami irna.
#   - CSAK a /store utvonal. Az /admin vegpontok nem ezen a kulcson mennek.
#   - A kulcs sosem kerul a kimenetbe es a hibauzenetbe sem.
#
# EGY MERT CSAPDA, AMI MIATT AZ `exists` PARANCS CSAK STORE UTVONALRA JO:
# Hitelesites NELKUL az /admin utvonalak MINDEGYIKE 401-et ad -- egy SZANDEKOSAN kitalalt,
# nem letezo /admin utvonal IS. Vagyis a 401 nem mond semmit arrol, letezik-e a vegpont:
# a hitelesito reteg elobb sul el, mint a forgalomiranyito. Store oldalon viszont a
# publikalhato kulccsal a hitelesites teljesul, es ott a 404 mar VALODI nemleges valasz.
# (Ismert pozitiv kontroll a szkriptben: az `exists` egy nem letezo utvonalra 404-et vart
# es azt is kapott. Enelkul a mereseink "letezik" valaszt adtak volna mindenre.)
set -uo pipefail

H=https://commerce-stage.acropora.hu
# A KULCS KET HELYEN ALLHAT, ES EZ TUDATOS DONTES, NEM KENYELEM (acrobot, 2026-09-07).
#
# A store konyvtar szandekosan csak marveen szamara olvashato, es ez a szabaly MARAD:
# ott TITKOK allnak. Ez a kulcs viszont PUBLIKALHATO (x-publishable-api-key): a Medusa
# kirakata a bongeszo forrasaba teszi, tehat barki latja, aki megnyitja a boltot. Nem
# titok, hanem azonosito.
#
# MIERT KELLETT: 2026-09-07-en ket agens (nautilus, polip) allt meg ugyanitt, mert a
# store fajlt nem tudjak olvasni. A megoldas NEM a store konyvtar megnyitasa volt --
# az egy szabalyt bontana meg egy kivetel kedveert --, hanem egy MASODIK PELDANY azon
# a helyen, ahova a flotta amugy is olvashat.
#
# AMI EBBOL SOHA NEM KOVETKEZIK: ADMIN kulcsot NEM szabad igy kitenni. Ott a masolat
# maga a szivargas. Ha valaha admin hozzaferes kell egy agensnek, az kerdes, nem masolas.
KEYFILE=/home/marveen/marveen/store/.medusa-stage-key
[ -r "$KEYFILE" ] || KEYFILE=/home/marveen/marveen/exchange/medusa-stage-publishable-key.txt
[ -r "$KEYFILE" ] || { echo "FAIL: nincs olvashato kulcs (sem a store, sem az exchange helyen)" >&2; exit 1; }

CMD="${1:-}"

get() { /usr/bin/curl -s --max-time 20 -H "x-publishable-api-key: $(/bin/cat $KEYFILE)" "$H$1"; }

# LAPOZVA KER LE EGY GYUJTEMENYT, es minden lapot EGY sorkent ir ki.
#
# MIERT LETEZIK (mert 2026-09-07-en hamis nullat okozott): a `categories` parancs
# `limit=200`-zal hivott, a fejlecebe 219-et irt, es 200 sort listazott. A Medusa
# 200-nal vag. A "Korallok" EPP a levagott reszben allt: egy nev-kereses a kimeneten
# NULLA talalatot adott volna egy LETEZO kategoriara -- vagyis a csonkasag nem
# latszott, csak a kovetkezmenye.
getall() {
  local UT="$1" OFF=0 CNT=1
  while [ "$OFF" -lt "$CNT" ]; do
    local LAP
    LAP=$(get "${UT}?limit=100&offset=${OFF}")
    printf '%s\n' "$LAP"
    CNT=$(printf '%s' "$LAP" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("count") or 0)
except Exception: print(0)')
    OFF=$((OFF + 100))
    [ "$CNT" -gt 0 ] || break
  done
}
kod() { /usr/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
        -H "x-publishable-api-key: $(/bin/cat $KEYFILE)" "$H$1"; }

case "$CMD" in
  health)
    /usr/bin/curl -s -o /dev/null -w 'health: %{http_code}\n' --max-time 20 "$H/health"
    ;;
  counts)
    for R in products product-categories collections; do
      get "/store/$R?limit=1" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('$R: nem JSON valasz'); raise SystemExit
print('$R:', d.get('count'))
"
    done
    ;;
  categories)
    getall "/store/product-categories" | python3 -c "
import sys,json
elemek, cnt = [], None
for sor in sys.stdin:
    sor = sor.strip()
    if not sor: continue
    d = json.loads(sor)
    cnt = d.get('count')
    elemek += (d.get('product_categories') or [])
print('count:', cnt, ' listazva:', len(elemek))
if cnt is not None and len(elemek) != cnt:
    print('FIGYELEM: a lista CSONKA -- %d sor %d helyett' % (len(elemek), cnt))
for c in elemek:
    print('%-30s parent=%-28s external_id=%s' % (
        (c.get('name') or '')[:30], str(c.get('parent_category_id'))[:28], c.get('external_id')))
"
    ;;
  collections)
    getall "/store/collections" | python3 -c "
import sys,json
elemek, cnt = [], None
for sor in sys.stdin:
    sor = sor.strip()
    if not sor: continue
    d = json.loads(sor)
    cnt = d.get('count')
    elemek += (d.get('collections') or [])
print('count:', cnt, ' listazva:', len(elemek))
if cnt is not None and len(elemek) != cnt:
    print('FIGYELEM: a lista CSONKA -- %d sor %d helyett' % (len(elemek), cnt))
for c in elemek: print(' ', c.get('title'), '|', c.get('handle'))
"
    ;;
  products)
    # A HANDLE MAR NEM CSONKUL, ES EZ UGYANANNAK A HIBANAK A HARMADIK ELOFORDULASA
    # (nautilus merese, 2026-09-08). A kiiras `handle=%-30s` alakban vagott, o pedig
    # innen masolt ki egy handle-t, es a `product` ag "nincs ilyen handle" valaszt adott
    # egy LETEZO termekre. Ugyanaz, mint amit barracuda a `variants` agon megfogott
    # 2026-09-07-en (ott 22 karakteren vagott, es abbol lett 417 "hianyzo" termek).
    #
    # A KULONBSEG A KET MEZO KOZOTT NEM KOZOMBOS: a handle AZONOSITO, tehat csonkitva
    # SOHA nem talal egyezest, es a hiba nema. A cim ellenben olvasasra valo, ott a
    # rovidites megengedett -- de csak LATHATOAN, ezert kerult a vegere a harom pont.
    # Egy jeloletlenul levagott ertek az, ami hazudik; a megjelolt nem.
    LIM="${2:-10}"
    get "/store/products?limit=$LIM" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('count:', d.get('count'))
for p in (d.get('products') or []):
    cim = (p.get('title') or '')
    if len(cim) > 40: cim = cim[:39] + '…'
    print('%-40s handle=%s valtozat=%d' % (
        cim, p.get('handle') or '', len(p.get('variants') or [])))
"
    ;;
  variants)
    # VALTOZATONKENT egy sor: handle, sku, barcode. Az adat eddig is a valaszban volt
    # (a `products` ag meg is szamolta a valtozatokat), csak nem irtuk ki.
    #
    # MIERT KELLETT (barracuda merese, 2026-09-07): az azonosito-osszevetesnel a
    # Medusa-oszlop hianyzott, es ez NEM hozzaferes-kerdes volt, hanem a helper
    # kimenete. A ket eset a megallas pillanataban egyformanak latszik, a teendo
    # viszont mas: az egyikhez kulcs kell, a masikhoz egy ag a szkriptben.
    #
    # MIERT UJ AG ES NEM A `products` BOVITESE (barracuda indoklasa, szo szerint):
    # "egy meglevo parancs kimenetenek atalakitasa csendben tori el azt, aki eddig
    # hasznalta". A products kimenetet mashol is nezik; ha valtozatonkent kezdene
    # sorokat irni, minden korabbi hasznalat kimenete megvaltozna.
    #
    # ES AMIT EZ AZ AG SZANDEKOSAN NEM CSINAL (szinten barracuda):
    #   nem szuri ki az ures sku-t es barcode-ot -- epp azt a leletet tuntetne el,
    #     amiert az ag keszult (ma MIND az 1496 valtozat barcode mezoje ures)
    #   nem alakit szamma semmit -- egy EAN-13 vezeto nullaja szamma alakitva
    #     elveszik, es az a hiba CSENDES
    #
    # ES EGY HIBA, AMIT AZ ELSO VALTOZAT TARTALMAZOTT (barracuda fogta meg, 2026-09-07,
    # ugyanaznap este): a kiiras SZOKOZ-PADDOLT volt, `%-46s %-22s` alakban, tehat a
    # 22 karakternel hosszabb cikkszamot LEVAGTA. Egy csonkolt azonosito SOHA nem talal
    # egyezest: barracuda ebbol azt kapta, hogy 417 UNAS termek hianyzik a boltbol.
    # A szam a KIIRAS tulajdonsaga lett volna, nem a katalogusé -- es o nem adta le,
    # hanem megnezte a 16 nem-egyezot, amibol 14 PONTOSAN 22 karakter volt.
    #
    # EZERT TAB-ELVALASZTOTT ES VAGATLAN a kimenet. A fix szelesseg ket dolgot csinal:
    # vag, es pozicio szerinti feldolgozasra csabit. A tab mindkettot megszunteti.
    LIM="${2:-100}"
    get "/store/products?limit=$LIM&fields=handle,*variants" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('termek:', d.get('count'))
print('\t'.join(['handle','sku','barcode']))
n=0
for p in (d.get('products') or []):
    for v in (p.get('variants') or []):
        n+=1
        print('\t'.join([p.get('handle') or '', v.get('sku') or '', v.get('barcode') or '']))
print('valtozat a kiirasban:', n)
"
    ;;
  product)
    HND="${2:-}"
    [ -n "$HND" ] || { echo "usage: medusa-stage.sh product <handle>" >&2; exit 2; }
    # AZ EKEZETES HANDLE-T KODOLNI KELL, KULONBEN NEM "NINCS ILYEN", HANEM TRACEBACK
    # (nautilus merese, 2026-09-08: negyven mintabol ketto). A kodolatlan ekezet miatt a
    # valasz nem JSON, a `json.load` elszall, es aki handle-listan megy vegig, azt URES
    # eredmenynek konyveli el -- abbol pedig "nincs leirasa" lesz. Nema hiba, es a
    # RIASZTOBB irany fele teved: hianyt allit ott, ahol adat van.
    HND_ENC="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$HND")"
    get "/store/products?handle=$HND_ENC" | python3 -c "
import sys,json,re
d=json.load(sys.stdin)
p=(d.get('products') or [None])[0]
if not p:
    print('nincs ilyen handle -- a lista URES, ami NEM ugyanaz, mint a hiba')
    raise SystemExit
print('handle:', p.get('handle'))
print('title:', (p.get('title') or '')[:70])
TAG = re.compile(r'<[a-zA-Z][^>]*>')
ESC = re.compile(r'&(?:lt|gt|amp|quot|#[0-9]+);')
for mezo in ('description', 'subtitle'):
    ertek = p.get(mezo)
    if ertek is None:
        print('%s: NINCS MEZO (None) -- ez MAS, mint az ures szoveg' % mezo)
        continue
    print('%s hossz: %d' % (mezo, len(ertek)))
    print('--- %s, az elso 400 karakter, NYERSEN ---' % mezo)
    print(ertek[:400])
    tagok = TAG.findall(ertek)
    escek = ESC.findall(ertek)
    print('--- verdikt (ALAKRA, nem mintara) ---')
    if tagok and escek:
        print('  KEVERT: %d nyers tag ES %d escape-elt jel. Ez a legrosszabb eset:' % (len(tagok), len(escek)))
        print('  valahol felúton escape-elodott, tehat EGYIK oldal javitasa sem eleg.')
    elif tagok:
        print('  NYERS HTML: %d nyito tag, nulla escape. A vetites rendben viszi at,' % len(tagok))
        print('  a KIRAKAT jeleniti meg szovegkent.')
    elif escek:
        print('  ESCAPE-ELT: %d jel, nulla nyers tag. A VETITES viszi at szovegkent.' % len(escek))
    else:
        print('  SIMA SZOVEG: se nyers tag, se escape. Nincs mit renderelni.')
    print('--- diagnozis: MELYIK jelolo all ott (nem ez dont, hanem a fenti) ---')
    nevek = {}
    for t in tagok:
        n = re.match(r'<([a-zA-Z0-9]+)', t).group(1).lower()
        nevek[n] = nevek.get(n, 0) + 1
    print('  tagnevek:', ', '.join('%s=%d' % (k, nevek[k]) for k in sorted(nevek)) or '(nincs)')
    ne = {}
    for e in escek:
        ne[e] = ne.get(e, 0) + 1
    print('  escape-ek:', ', '.join('%s=%d' % (k, ne[k]) for k in sorted(ne)) or '(nincs)')
"
    ;;
  product-fields)
    get "/store/products?limit=1" | python3 -c "
import sys,json
d=json.load(sys.stdin)
p=(d.get('products') or [None])[0]
if not p:
    print('nincs termek, tehat a mezoket sem lehet leolvasni'); raise SystemExit
for k in sorted(p.keys()): print(k)
"
    ;;
  query)
    # TETSZOLEGES /store LEKERDEZES VALASZTOTT `fields`-SZEL, LAPOZVA.
    #
    # MIERT KELLETT (nautilus merese, 2026-09-08): HAROM kartya allt ugyanezen az egy
    # hianyon -- kategoria-tagsag (`*categories`), keszlet (`*variants.inventory_quantity`)
    # es jelolok (`+metadata`). A kilenc meglevo parancs egyikeben sincs `fields` kapcsolo,
    # egyetlen helyen all beegetve. O maga elobb azt irta, hogy egy ag "tobbet erintene,
    # mint az az egy kartya" -- aztan lemerte, es az erve alulbecslesnek bizonyult.
    #
    # A MEGKULONBOZTETES, AMIT EZ AZ AG ROGZIT: a "meretlen" es az "egy hianyzo szkript-ag
    # miatt meretlen" NEM ugyanaz. Az elso azt sugallja, hogy senki nem nezte meg.
    #
    # HAROM DOLGOT SZANDEKOSAN NEM CSINAL:
    #   nem formaz es nem paddol -- soronkent NYERS JSON megy ki. A fix szeleseg
    #     vag es pozicio szerinti feldolgozasra csabit (a `variants` agon ez 417 hamis
    #     "hianyzo" termeket okozott, a `products` agon egy nem letezo handle-t).
    #   nem szur ki ures erteket -- epp az a lelet tunne el, amiert a meres keszul.
    #   nem engedi at a `limit`/`offset` parametert -- azt a lapozo birtokolja. Aki
    #     sajat limitet ad, a csonkasagot hozza vissza, amit ez az ag kizar.
    #
    # A BIZTONSAGI GARANCIAK VALTOZATLANOK: a host beegetve, csak GET, csak /store.
    # Az utvonal-ellenorzes ugyanaz, mint az `exists` agon.
    #
    # EGY MERT CSAPDA A `fields` SZINTAXISABAN (acrobot, 2026-09-08, mar EZZEL az aggal):
    # a keszlet-meresre elsore `*variants.inventory_quantity` alakot irtam. A valasz 200
    # volt, 1492 termek jott vissza, valtozatokkal -- es MINDEN valtozat minden mezoje
    # None lett, a `manage_inventory` is, ami amugy True. Vagyis nem hibat kaptam, hanem
    # HIHETO NULLAT: ugy nezett ki, mint egy ures keszlet-nyilvantartas.
    #   ROSSZ:  fields=*variants.inventory_quantity      -> a valtozat MINDEN mezoje None
    #   ROSSZ:  fields=+variants.inventory_quantity      -> egyaltalan nincs valtozat
    #   JO:     fields=*variants,+variants.inventory_quantity
    # A `*` kibontja a relaciot, a `+` egy nem-alapertelmezett mezot VESZ HOZZA.
    # A KETTOT egy kifejezesbe olvasztva egyik sem tortenik meg, es a Medusa nem szol.
    #
    # DE A "ROSSZ" SOR CSAK ERRE A MEZORE ALL (barracuda merese, 2026-09-08 16:05).
    # Ugyanez az alak MAS mezovel MUKODIK:
    #   fields=id,*variants.calculated_price   -> 3400 huf, helyes ertek
    #   fields=*variants.inventory_quantity    -> minden mezo None
    # Ugyanaz a szintaxis, ket ellentetes eredmeny, tehat a viselkedes MEZOFUGGO. Ha a
    # lapra ugy kerulne fel, hogy "a `*variants.<mezo>` alak nem mukodik", az egy MUKODO
    # utat venne el. Amit KI LEHET mondani: a mezot kerni kell, sem a `*variants`, sem az
    # alapertelmezes nem hozza. Amit NEM: hogy az alak onmagaban jo vagy rossz.
    # [BECSLES, barracuda] a `calculated_price` szamitott ertek, az `inventory_quantity` a
    # valtozat sajat mezoje -- masik uton kerulnek a valaszba. Nem merte vissza a kodbol.
    #
    # ES A CSAPDA TAGABB, MINT EGY AL-MEZO (barracuda merese, 2026-09-08 16:35): A CSUPASZ
    # NEV FELULIRJA AZ ALAPERTELMEZETT HALMAZT, A `*` ES A `+` HOZZAAD.
    #   fields=*variants.calculated_price,+tags        -> az alapertelmezett termek-mezok
    #                                                     MEGMARADNAK (description, subtitle,
    #                                                     thumbnail, status, weight)
    #   fields=id,handle,title,*variants               -> az alapertelmezes LECSERELODIK
    #                                                     erre a harom mezore
    # Ket kulon exportbol ezert johet ket ELLENTETES szam ugyanarra a mezore, es MIND A KETTO
    # helyes lehet. Mert eset: ugyanaz a Grotech termek `description`-je az egyik fajlban
    # 1545 karakteres angol szoveg, a masikban null -- a masodik lekerdezes csupasz neveket
    # sorolt fel.
    # A VEDEKEZES: ha az alapertelmezett mezok is kellenek, a sajat mezoidet is `+` jellel
    # kerd (`+id,+handle,+title`). Es mielott egy exportbol NULLAT allitasz a vilagrol, nezd
    # meg, hogy a fajlban benne van-e egyaltalan az a mezo MASIK termeken.
    # A VEDEKEZES nem a szintaxis megjegyzese, hanem egy ISMERT POZITIV: kerj le egyetlen
    # terméket, es nezd meg, all-e benne az az ertek, aminek allnia kell. Ha a mezo None,
    # elobb a kerdesre gyanakodj, ne a vilagra.
    # A TOBBLET ARGUMENTUM NEM VESZHET EL NEMAN (nautilus merese, 2026-09-08, az ag
    # ELSO hasznalatan). Az elso valtozat `PAR="${4:-}"` alakban EGY parametert
    # olvasott, es aki igy hivta:
    #
    #   query /store/products "id" "id[]=A" "id[]=B" "id[]=C"
    #
    # `count 1`-et kapott -- ami ugy nezett ki, mintha a bolt nem tamogatna a
    # tobbertekes szurot. HAMIS LELET, epp arra a kerdesre, amit merni akart. O egy
    # megkulonbozteto probaval fogta meg (a nem letezo azonositot ELORE tette: `count 0`),
    # tehat kiderult, hogy nem a bolt szur rosszul, hanem a szkript dobja el a tobbit.
    #
    # A JAVITAS a `fleet-api.sh` arity-orzojenek szelleme, csak megengedo iranyban: ott
    # a tobblet argumentum MEGALLITJA a parancsot, itt HASZNALJUK. Mind a ketto ugyanazt
    # zarja ki -- hogy egy argumentum csendben eltunjon.
    UT="${2:-}"
    MEZOK="${3:-}"
    [ -n "$UT" ] || { echo "usage: medusa-stage.sh query /store/<eroforras> [fields] [par ...]" >&2; exit 2; }
    shift 3 2>/dev/null || shift $#
    # A PARAMETER ERTEKET KODOLNI KELL, A KULCSOT NEM (murena merese, 2026-09-08 14:45).
    #
    # Az `q=ragasztó` alak NULLA talalatot adott, es majdnem abbol lett egy jelentes, hogy a
    # magyar bolt keresoje ekezetes szora nem mukodik. Nem arrol van szo: kodolva 27 talalat
    # jon (`q=ragaszt%C3%B3`), a `q=só` 268-at, a `q=kétkomponensű` 12-t.
    #
    # AMIERT EZ A LEGROSSZABB FAJTA: a hivas nem hibazik. 200-at ad, ep JSON-t, es CSENDBEN
    # mast keres. Es a nulla melle epp egy magas, ekezet nelkuli talalatszam all (`q=korall`
    # 539), ami MEGNYUGTAT, hogy "a kereses mukodik" -- tehat a gyanu a bolt fele fordul, nem
    # a sajat hivas fele. Harom kartya epulhetett volna ra.
    #
    # A `product <handle>` ag ezt mar 2026-09-08 reggel ota kodolja (nautilus merese az
    # ekezetes handle-okrol). Ugyanaz a hiba-osztaly, ket agon, es a masodik ket honapig allt
    # javitatlanul, mert az elso javitasa nem kerdezte meg, hol MEG fordulhat elo.
    #
    # A KULCS SZANDEKOSAN MARAD NYERSEN: az `id[]=A` alak szogletes zarojelei a szuro reszei,
    # es a `limit=`/`offset=` orzo alattuk fut. Csak az elso `=` UTANI resz megy at a kodolon.
    PAR=""
    for _P in "$@"; do
      [ -n "$_P" ] || continue
      _P_ENC="$(printf '%s' "$_P" | python3 -c '
import sys, urllib.parse
nyers = sys.stdin.read()
kulcs, jel, ertek = nyers.partition("=")
sys.stdout.write(kulcs + jel + urllib.parse.quote(ertek, safe="") if jel else nyers)
')"
      [ -z "$PAR" ] && PAR="$_P_ENC" || PAR="$PAR&$_P_ENC"
    done
    case "$UT" in
      /store/*) ;;
      *) echo "CSAK /store utvonal megy. Az /admin nem ezen a kulcson fut." >&2; exit 2 ;;
    esac
    # AZ UTVONALBA IRT QUERY-STRING MEGALLIT (nautilus merese, 2026-09-08 14:50).
    #
    # O igy hivta:   query "/store/products?id[]=A,B" "id,handle"
    # a dokumentalt alak:  query /store/products "id" "id[]=A" "id[]=B"
    #
    # Az elso alak NEM hibazott: lefutott, es `count 1`-et adott ket azonositora. Ebbol o
    # majdnem azt jelentette, hogy egy frissen kalibralt javitas (a parameter-kodolas)
    # elrontotta a tobbertekes szurot -- vagyis egy nem letezo regresszio keresese indult
    # volna el a masik oldalon.
    #
    # AMIERT ORZO KELL ES NEM CSAK DOKUMENTACIO: a szkript a sajat `?limit=&offset=` reszet
    # a vegere fuzi, tehat egy utvonalba irt query-string utan MASODIK kerdojel keletkezik.
    # Az eredmeny nem hibauzenet, hanem egy MASIK lekerdezes -- pontosan az a fajta csendes
    # elteres, amit ma tobbszor gyujtottunk.
    case "$UT" in
      *\?*)
        echo "A query-string NEM az utvonalba megy. Kulon argumentumokban add:" >&2
        echo "  ROSSZ: query \"/store/products?id[]=A&id[]=B\" \"id\"" >&2
        echo "  JO:    query /store/products \"id\" \"id[]=A\" \"id[]=B\"" >&2
        exit 2 ;;
    esac
    # ES A KIMENET MEGNEVEZI, MIT KERDEZTUNK (murena javaslata, 2026-09-08 17:13).
    #
    # AMIERT KELL: a fejlec eddig csak a TALALATOT irta ki (`kulcs / count / listazva`).
    # Ha a kodolas valaha ujra elromlik, vagy egy shell elnyeli a mintat (backtick, `$`,
    # idezojel), a kimenet UGYANIGY nez ki, es egy HIHETO szamot ad. Nem nulla jon, hanem
    # MASIK szam -- es azon nem gyanakszik az ember.
    # Ez ma haromszor allt elo (a `*variants.inventory_quantity`, a `description` mezo az
    # exportban, es a `*variants.sku`), mindharomszor ertelmes szammal.
    # A vedelem ezert nem emlekezeten mulik, hanem a kimeneten: a parameter ott all,
    # ahogy BEIRTAD es ahogy KIMENT.
    if [ -n "$PAR" ]; then
      printf '%s' "$PAR" | python3 -c '
import sys, urllib.parse
nyers = sys.stdin.read()
for elem in nyers.split("&"):
    kulcs, jel, ertek = elem.partition("=")
    if jel:
        print("kerdes: %s = %s   (kimeno alak: %s)" % (kulcs, urllib.parse.unquote(ertek), ertek))
    else:
        print("kerdes: %s" % elem)
'
    fi
    case "$UT$PAR" in
      *limit=*|*offset=*)
        echo "A limit/offset a lapozoe. Add meg a szurot nelkulle, es MINDEN lapot megkapsz." >&2
        exit 2 ;;
    esac
    QS=""
    [ -n "$MEZOK" ] && QS="&fields=$MEZOK"
    [ -n "$PAR" ] && QS="$QS&$PAR"
    OFF=0; CNT=1
    while [ "$OFF" -lt "$CNT" ]; do
      LAP=$(get "${UT}?limit=100&offset=${OFF}${QS}")
      printf '%s\n' "$LAP"
      CNT=$(printf '%s' "$LAP" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("count") or 0)
except Exception: print(0)')
      OFF=$((OFF + 100))
      [ "$CNT" -gt 0 ] || break
    done | python3 -c "
import sys, json
sorok, cnt, kulcs = [], None, None
for sor in sys.stdin:
    sor = sor.strip()
    if not sor: continue
    try:
        d = json.loads(sor)
    except Exception:
        print('NEM JSON VALASZ -- a lekerdezes elszallt, NEM ures eredmeny:', file=sys.stderr)
        print(sor[:300], file=sys.stderr)
        raise SystemExit(1)
    if d.get('message') or d.get('type'):
        print('A SZOLGALTATAS HIBAT ADOTT, nem adatot:', d.get('message') or d.get('type'), file=sys.stderr)
        raise SystemExit(1)
    cnt = d.get('count')
    # az eroforras kulcsa vegpontonkent mas (products, product_categories, collections),
    # ezert NEM talalgatunk: az elso lista erteku kulcs az.
    if kulcs is None:
        for k, v in d.items():
            if isinstance(v, list): kulcs = k; break
    if kulcs: sorok += d.get(kulcs) or []
print('kulcs:', kulcs, ' count:', cnt, ' listazva:', len(sorok))
if cnt is not None and len(sorok) != cnt:
    print('FIGYELEM: a lista CSONKA -- %d sor %d helyett' % (len(sorok), cnt))
# Egy head-be vezetett kimenet lezarja a csovet, es a kiiras BrokenPipeError-ral
# szall el. (A parancsot itt NEM irom backtickkel: ez a python blokk bash-ben
# DUPLA idezojelben all, tehat a backtick FUTNA. Mert: az elso valtozat ezt a
# kommentet tartalmazta, es a szkript syntax errort irt ki minden hivasnal.) Az OLVASO
# agon ez artalmatlan, de egy traceback ugy nez ki, mint egy elbukott meres -- es a
# kovetkezo olvaso a SZAMOT is gyanusnak fogja tartani miatta.
try:
    for s in sorok:
        print(json.dumps(s, ensure_ascii=False))
    sys.stdout.flush()
except BrokenPipeError:
    import os
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
"
    ;;
  get)
    # EGYETLEN /store GET, LAPOZAS NELKUL, NYERS JSON (barracuda kerese, 2026-09-28).
    # A `query` ag limit/offset parametert fuz hozza, es ket vegpont ezt 400-zal
    # elutasitja: /store/payment-options es /store/carts/<id> ("Unrecognized fields:
    # 'limit, offset'"). Az adat megvolt, a parancs nem.
    # Hasznalat: get /store/<utvonal> ["kulcs=ertek&kulcs2=ertek2"]
    # Ugyanazok a hatarok: a host beegetve, csak GET, csak /store, az utvonal
    # szegmensenkent kodolva, a query-string kulon argumentumban, kodolva.
    P="${2:-}"; Q="${3:-}"
    case "$P" in
      /store/*) ;;
      *) echo "usage: medusa-stage.sh get /store/<utvonal> [\"k=v&k2=v2\"]" >&2; exit 2 ;;
    esac
    case "$P" in *\?*|*\&*) echo "a query-string a HARMADIK argumentumba megy, nem az utvonalba" >&2; exit 2 ;; esac
    URL="$(P="$P" Q="$Q" python3 -c '
import os, urllib.parse
p = "/".join(urllib.parse.quote(s, safe="") for s in os.environ["P"].split("/"))
q = urllib.parse.urlencode(urllib.parse.parse_qsl(os.environ["Q"], keep_blank_values=True))
print(p + ("?" + q if q else ""))
')"
    get "$URL"; echo
    ;;
  exists)
    P="${2:-}"
    [ -n "$P" ] || { echo "usage: medusa-stage.sh exists /store/<valami>" >&2; exit 2; }
    case "$P" in
      /store/*) ;;
      *) echo "CSAK /store utvonalra ad ertelmes valaszt. Az /admin MINDENRE 401-et ad," >&2
         echo "meg a nem letezo utvonalakra is -- lasd a fejlecet." >&2; exit 2 ;;
    esac
    # ES A QUERY-STRING SEM MEHET AT (barracuda merese, 2026-09-08 16:08). A kodolas
    # bevezetese utan a `?` mar nem szakitja szet a lekerdezest -- helyette `%3F` lesz
    # belole, es a valasz 404. Ez HTTP-ben helyes, a HIVONAK viszont hazudik: ez az az
    # ag, ami a sajat szovegeben hitelesnek nevezi a 404-et, tehat a hivo a VILAGROL
    # vonna le kovetkeztetest egy sajat elgepelesbol.
    #   nema rossz lekerdezes  ->  nema rossz valasz. Kisebb kar, ugyanaz a fajta.
    # Nulla valodi hivast erint: ebben az API-ban nincs ervenyes utvonal-szegmens
    # kerdojellel vagy `&` jellel.
    case "$P" in
      *\?*|*\&*)
        echo "A query-string NEM az utvonalba megy, es itt a 404 megteveszto lenne." >&2
        echo "  ROSSZ:  exists \"/store/products?x=1\"" >&2
        echo "  JO:     query /store/products \"id\" \"x=1\"" >&2
        exit 2 ;;
    esac
    # AZ UTVONAL UTOLSO SZEGMENSE IS KODOLAST KAP (barracuda merese, 2026-09-08 15:40).
    #
    # Ez volt az utolso ag, ahol felhasznaloi bemenet kodolatlanul kerult az URL-be. A
    # `product <handle>` ag ma reggel ota kodol (nautilus), a `query` ma delutan ota
    # (murena) -- es barracuda vegigmerte a TOBBIT is, hogy ne maradjon negyedik.
    #
    # AMIERT EPP ITT A LEGMEGTEVESZTOBB, holott a kockazat kisebb: ez az ag maga
    # dokumentalja, hogy nala "a 404 VALODI nemleges". Vagyis pontosan az a felulet, ahol
    # egy kodolasi hiba a legmeggyozobben latszik leletnek -- a hivo azt olvasna ki, hogy
    # az eroforras nem letezik.
    #
    # A SZEGMENSEK KOZOTTI `/` NEM MEHET AT a kodolon: az az utvonal szerkezete, nem
    # tartalom. Ezert szegmensenkent kodolunk, es ugy fuzzuk vissza.
    P_ENC="$(printf '%s' "$P" | python3 -c '
import sys, urllib.parse
ut = sys.stdin.read()
sys.stdout.write("/".join(urllib.parse.quote(sz, safe="") for sz in ut.split("/")))
')"
    echo "$(kod "$P_ENC")  $P    (200/404 dont; a 404 itt VALODI nemleges)"
    ;;
  *)
    # A SUGO EDDIG FIX SORTARTOMANYT IRT KI (`2,9p`), es ettol MAGA IS CSONKA VOLT:
    # kilenc parancs letezett, hatot mutatott. Ugyanaz a hiba, amit ez a szkript
    # harom helyen is dokumental -- csak itt a sajat sugojan. Mostantol a jelolokig
    # olvas, tehat egy uj parancs a felvetel pillanataban megjelenik benne.
    /bin/sed -n '/^# Hasznalat:/,/^#$/p' "$0"
    exit 2
    ;;
esac
