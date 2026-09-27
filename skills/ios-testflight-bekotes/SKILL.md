---
name: ios-testflight-bekotes
description: Meglevo Expo/EAS mobil app eljuttatasa TestFlightbe egy bongeszo nelkuli konteneres flottabol. Akkor hasznald, ha a gazda azt keri "tegyuk fel a TestFlightre", "kell egy iOS build", vagy ha egy eas submit hitelesitesi hibara fut. A munka nagy resze NEM fejlesztes, hanem portal-lepesek es titok-kezeles.
---

# iOS / TestFlight bekotes egy konteneres flottahoz

Testvere a `google-oauth-headless-bekotes` skillnek: ugyanaz a szerkezet, mas szolgaltato.
Vegigmerve 2026-08-18, Acropora OS (Expo 57, EAS, monorepo `apps/mobile`).

## Mikor hasznald

- Van mar Expo/EAS projekt es mukodo build, csak feltoltes nincs.
- A gazda TestFlightet ker, vagy elso App Store-os lepest.
- Egy `eas submit` hitelesitesi vagy kredencial-hibara fut.

## Eloszor MERD, ne kerdezz

A repobol kiolvashato minden, amivel a gazdat nem kell terhelni:

```bash
cd /home/marveen/marveen && T=$(cat store/.github-token)
curl -s -H "Authorization: Bearer $T" -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/<owner>/<repo>/contents/apps/mobile/app.config.js?ref=main"
```

Amit keresel: `ios.bundleIdentifier` (production!), `name`, `slug`, `updates.url`
(a vegen ott az EAS **projectId**), es `ITSAppUsesNonExemptEncryption`. Az `eas.json`-ban
pedig azt, hogy van-e `submit` szakasz -- tipikusan NINCS, es ez a hianyzo darab.

## A gazda harom portal-lepese (sorrend kotott)

A masodik csak azutan latja a bundle id-t, hogy az elso megvan.

1. **App ID**: developer.apple.com -> Certificates, Identifiers and Profiles -> Identifiers
   -> plusz -> App IDs -> App. Explicit bundle id, PONTOSAN a repobol kiolvasott ertek.
   **Push Notifications capability-t MOST pipald be**, ha az app `expo-notifications`-t
   hasznal -- utolag ujra vegig kell menni.
2. **App Store Connect app-rekord**: appstoreconnect.apple.com -> Apps -> plusz.
   A Name GLOBALISAN egyedi. Primary Language: a valodi nyelv (magyar boltnal magyar).
   SKU: belso azonosito, sosem lathato kivul.
3. **App Store Connect API kulcs**: Users and Access -> Integrations -> App Store Connect
   API -> Team Keys. Szerep: **App Manager**, Admin NEM kell. A `.p8` fajl **egyszer**
   tolthető le.

Ezutan negy ertek kell: Team ID, ASC app id (szam), Key ID, Issuer ID. Ezek AZONOSITOK,
nem titkok -- nyugodtan johetnek chatben. A `.p8` az egyetlen titok.

## Expo oldal: ROBOT, ne szemelyes token

Ha a projekt SZERVEZET alatt van, robot-felhasznalot hasznalj: sajat szerepe van, es
onalloan visszavonhato anelkul, hogy a gazda fiokja erintve lenne.

**A felulet valtozik.** 2026-08-18-an NINCS kulon "Robot users" menupont: a bal savban,
a CREDENTIALS resz alatt az **Access tokens** oldalon van egy "Add robot", es a robot
sorabol "Create token". Ha a leirasod mast mond, a felulet nyer -- kerj kepernyokepet.

Szerep: **Developer**. A token **egyszer** latszik.

## Titok a szerverre, chaten SOHA

A gazda gepe es a flotta gepe kulonbozik. Fajl (.p8): `scp` a szerverre, majd:

```bash
cd /opt/marveen-docker/data/marveen && mkdir -p store/apple \
  && mv /tmp/AuthKey_XXXX.p8 store/apple/ \
  && chown -R 1000:1000 store/apple && chmod 600 store/apple/AuthKey_XXXX.p8 \
  && ls -l store/apple/
```

Egysoros titok (token) eseten NE fajlt masoltass, hanem olvastasd be ugy, hogy ne latszodjon
es ne kerüljön a parancs-elozmenyekbe:

```bash
cd /opt/marveen-docker/data/marveen && read -rsp "Token: " T && echo \
  && printf '%s' "$T" > store/.expo-token && unset T \
  && chown 1000:1000 store/.expo-token && chmod 600 store/.expo-token \
  && ls -l store/.expo-token
```

## eas.json submit-profil: a KEVESEBB a helyes

A tizenharom iOS-mezobol ketto kell:

```json
"submit": { "production": { "ios": { "appleTeamId": "...", "ascAppId": "..." } } }
```

- `ascApiKeyPath` / `ascApiKeyId` / `ascApiKeyIssuerId`: **NE**. A kulcs elhagyasa nem
  hianyossag, hanem a harmadik tamogatott forras valasztasa -- az `eas-cli` forrasaban
  `AscApiKeySourceType = path | prompt | credentialsService`, es a kulcs nelkul a
  credentials service ag fut.
- `appleId`: nem kell, ha ASC API-kulccsal megy a submit.
- `language`: hagyd ki. Nem tolunk fel metaadatot, tehat nem hat semmire -- egy ertek, ami
  nem hat semmire, kesobb felrevezet. DE ird a PR-be, hogy az ASC-ben mi az elsodleges
  nyelv, mert ha valaha metaadat megy fel, egyeznie kell.

## Build es submit: az utolso ket lepes

A build meg BELSO, a submit mar KIFELE megy -- ezt a hatart mondd ki a gazdanak, es a
submitot KULON kerdezd meg, ne csusszon bele a build utan.

```bash
# a gazda gepen, a mobil mappabol
cd <repo>/apps/mobile && npx eas-cli build --platform ios --profile production
cd <repo>/apps/mobile && npx eas-cli submit --platform ios --profile production --latest
```

A `--latest` a legutobbi buildet kuldi, igy nem kell azonositot masolni.

**A BUILD ELOTT frissitsd a repot a gazda gepen.** Ha regi agon all, olyan kodot buildel,
amiben meg nincs benne a mai munka. `git status --short` eloszor -- ha nem ures, allj meg.

**Az eredmenyt NE a parancs kimenetebol vedd at.** Merd le az EAS API-jarol a robot-tokennel:

```bash
T=$(cat store/.expo-token) && curl -s -H "Authorization: Bearer $T" \
  -H "Content-Type: application/json" -X POST https://api.expo.dev/graphql \
  -d '{"query":"query { app { byFullName(fullName: \"@<owner>/<slug>\") { builds(limit:1,offset:0){ status buildProfile appBuildVersion artifacts{applicationArchiveUrl} error{message} } } } }"}'
```

A submithoz a `submissions` mezo kell, es KOTELEZO neki a `filter: {}` argumentum -- enelkul
GRAPHQL_VALIDATION_FAILED jon.

Mert idok (2026-08-18, Expo 57, monorepo): build 6 perc, Apple-feldolgozas ~10 perc.

**A SUBMIT KET KULONBOZO IDO, ES EDDIG EGYBE VOLT MOSVA** (murena merese, 2026-08-27): a
`~2 perc` a PARANCS ideje -- ameddig az eas-cli feltolt es visszater. A SUBMISSION
vegallapota (FINISHED / ERRORED) ennel joval kesobb all be: 2026-08-26-an 23 perc
(19:17:35-tol 19:40:09-ig), 2026-08-27-en 20 percen tul is meg `IN_QUEUE`.
**Amiert szamit:** aki a parancs visszaterese utan azt mondja a gazdanak, hogy "kesz", az
huszperces tevedessel dolgozik, es ha kozben ERRORED lesz belole, mar elment a rossz mondat.
A parancs vege NEM a submit vege; a vegallapotot az API mondja meg.

## Az Apple oldalan: KET allapot, ket kulonbozo ut

- **"Ready to Test"** a TestFlight fulon -- EZ kell nekunk. A build hasznalhato.
- **"Ready to Submit"** az App Store verzion -- ezt NE nyomd meg. Az a NYILVANOS kiadas utja,
  es oda leiras, kepernyokep, arazas es adatvedelmi nyilatkozat is kell.

Tesztelo-valasztas, es a koltseguk nem egyforma:
- **Belso tesztelo** (App Store Connect felhasznalo): azonnal megkapja, NINCS Apple-felulvizsgalat,
  max 100 fo. A gazdanak es a csapatnak ez eleg.
- **Kulso tesztelo**: barki e-maillel vagy linkkel, DE az elso ilyen buildhez **Beta App Review**
  fut, ami napokat vihet, es kell hozza teszt-leiras.

## KERDEZD MEG AZ APPLE-T, NE A FELTOLTO ESZKOZT

A build es a tesztelok allapotat **innentol kozvetlenul le lehet kerdezni**, es ez a
megbizhato forras. Minden osszetevo mar keznel van (memoria 464): kulcs
`store/apple/AuthKey_<KEYID>.p8`, Key ID, Issuer, app azonosito. Nulla uj fuggoseg: node,
ES256 JWT a `node:crypto` `createSign`-javal, **`dsaEncoding: 'ieee-p1363'`** (enelkul DER
alairas keletkezik es 401 jon), `aud: 'appstoreconnect-v1'`, `exp` legfeljebb 20 perc, majd
`fetch` a `https://api.appstoreconnect.apple.com` cimre Bearer fejleccel. Az egress atengedi.

Amit kerdezz, ebben a sorrendben:
- `/v1/builds?filter[app]=<APPID>&sort=-uploadedDate` -> `processingState` (a `VALID` a kesz),
  `usesNonExemptEncryption` (ha `false`, az export-nyilatkozat NEM all nyitva)
- `/v1/builds/<buildId>/buildBetaDetail` -> `internalBuildState` (`IN_BETA_TESTING` = a belso
  kor mar megkapta), `externalBuildState`
- `/v1/apps/<APPID>/betaGroups` -> a csoport neve, `isInternalGroup`, **`hasAccessToAllBuilds`**
- `/v1/betaGroups/<groupId>/betaTesters` -> ki a tag es milyen allapotban (`INSTALLED`)

**Ket vegpont 403-mal elszall, es ez NEM jogosultsagi hiany:** a
`/v1/builds/<id>/betaGroups` es a `/v1/apps/<id>/betaTesters` relacio csak CREATE/DELETE
muveletet enged. A tagsagot a CSOPORT felol kell olvasni, nem a build vagy az app felol.

## Ha a build sikerul, de az app INDULASKOR osszeomlik

Mert eset, 2026-08-18: az elso TestFlight-build feltelepult es azonnal elszallt. Az ok NEM a
buildben volt, hanem abban, ami hianyzott belole.

**AZ ELSO HELY, AHOL NEZNI KELL: az EAS kornyezeti valtozok KORNYEZETENKENT allnak.**

```bash
T=$(cat store/.expo-token) && curl -s -H "Authorization: Bearer $T" \
  -H "Content-Type: application/json" -X POST https://api.expo.dev/graphql \
  -d '{"query":"query { app { byFullName(fullName: \"@<owner>/<slug>\") { environmentVariables { name environments visibility value } } } }"}'
```

Az adott esetben mindket valtozo CSAK `['preview']`-hoz letezett, a `production`-hoz egyikhez
sem -- mikozben a production build-profil `"environment": "production"`-t hasznal. A build
ettol meg SIKERES: a valtozok futasidoben hianyoznak, nem forditaskor.

**EZ A LENYEG: egy zold build nem bizonyitja, hogy az app elindul.** A build a csomagolast
meri, nem a mukodest. Ugyanaz a szerkezet, mint a CI-ben: a tesztek a kodot vizsgaljak, a
smoke test a futo rendszert.

**A MASODIK HELY: a kod hogyan viselkedik hianyzo ertekre.** Ha az `env.ts`-szeru konfigfajl
MODUL BETOLTESEKOR dob (`throw new Error("... is missing")`), akkor a hiba azonnali es
vegzetes -- semmi nem jelenik meg elotte. Ez JO tervezes (nem fut tovabb ertelmetlen
allapotban), de a tunet ijeszto.

**A HARMADIK: a crashlog megerositi, de NEM mondja ki.** iOS-en a verem igy nez ki:
`ErrorRecovery.tryRelaunchFromCache()` -> `runNextTask()` -> `crash()` ->
`StartupProcedure.throwException`. Ez az expo-updates hibakezeloje: a JS induláskor vegzetes
hibat dobott, megprobalt visszaesni egy gyorsitotarazott bundle-re, es elso inditasnal nincs
mire. A JS hibauzenet NINCS a logban -- a leallas a nativ retegben tortenik. Tehat a log azt
bizonyitja, hogy INDULASKOR volt vegzetes JS-hiba; hogy MI hianyzott, azt a masik ket
merestol tudod.

**JAVITAS:** vedd fel a valtozokat a hianyzo kornyezethez, es **ujra kell buildelni** -- a
meglevo build nem javithato, mert az ertekek beleepulnek. Mutacio a robot-tokennel:

```
mutation Create($appId: ID!, $data: CreateEnvironmentVariableInput!) {
  environmentVariable { createEnvironmentVariableForApp(appId: $appId, environmentVariableData: $data) { id name environments } }
}
```
`data`: `{name, value, environments: ["PRODUCTION"], visibility: "PUBLIC"}`.

**ES AMIT UTANA ELORE JELEZZ:** ha az app ezutan ELINDUL, de a bejelentkezesnel vagy az
adatok toltesenel akad meg, az MAS hiba -- akkor az a kerdes, hogy az API elerheto-e a
keszulekrol (VPN, tuzfal, belso halo). Ne keverjuk ossze a kettot.

## Buktatók

- **A FELTOLTO „KIHAGYOM EZT A LEPEST" SORA AZT MONDJA MEG, MIT NEM CSINALT O -- NEM AZT, HOGY
  AZ ALLAPOT HIANYZIK.** A ketto kozott pontosan egy kerdes van, es azt a CEL-RENDSZERTOL kell
  kerdezni. (Merve 2026-08-25/26: az `eas submit` kiirta, hogy nem teljesek az App Store
  Connect hitelesito adatok, ezert kihagyja a TestFlight beallitast. Ebbol azt a
  figyelmeztetest kuldtem a gazdanak, hogy a portalon, kezzel kell beallitania a teszteloket.
  Masnap reggel az ASC API-tol megkerdezve: a build allapota `IN_BETA_TESTING`, a belso csoport
  `hasAccessToAllBuilds`, a gazda mar tagja, `INSTALLED`. NULLA kezi lepes kellett.)
  **Az ok, ami altalanosithato:** a tesztelo-csoport EGYSZER all be, nem feltoltesenkent, tehat
  a kihagyott lepes egy MAR MEGLEVO allapotot allitott volna be ujra.
  **Es amiert ez nem semleges hiba:** egy hamis „ezt neked kell kezzel beallitanod" mondat
  munkat ad a gazdanak, es olyan iranyba kuldi (bongeszo, portal), ahol semmi dolga nincs. Egy
  elmaradt figyelmeztetes csak keslelet, egy hamis figyelmeztetes idot vesz el.
  A megoldas a fenti szakasz: egy lekerdezes, es a mondat elejere a TEENDO kerul, nem a
  levezetes.
- **„Terjunk at a Metrorol Xcode Cloudra" -- a kerdes maga rejt egy felreertest, es ezt KI KELL
  MONDANI, mielott valaszolsz.** A Metro a JavaScript-csomagolo, ami a build KOZBEN fut; az
  Xcode Cloud egy CI, ami buildel es szallit. Nem alternativai egymasnak: a Metro mindket
  esetben megmarad. Amirol valojaban szo van: EAS Build helyett Xcode Cloud. (Mert eset
  2026-08-19, Balazs kerdese.)
- **Managed Expo projektnel NINCS `ios/` mappa a repoban**, mert a nativ projektet a buildkor
  generalja a pluginekbol. Barmilyen kulso iOS CI (Xcode Cloud is) **Xcode-projektet var**,
  tehat vagy be kell tenni az `ios/`-t (onnantol te tartod karban a podokat, entitlementeket,
  Info.plist-et, es az Expo-frissitesek nem alkalmazzak magukat), vagy egy klonozas utani
  szkriptnek kell generalnia minden buildnel. **Mielott valaszolsz, MERD LE:** van-e
  `apps/mobile/ios`, `android`, `ci_scripts` a repoban, es mi all az `eas.json`-ben.
- **Az OTA-frissites nem koltozik a build-rendszerrel.** A csatornak es a `runtimeVersion` az
  Expo frissites-rendszerehez tartoznak; egy nativ CI JS-frissitest nem szallit. Rendszercsere
  utan tehat KETTOT uzemeltetsz, nem egyet -- hacsak a gazda le nem mond az OTA-rol. Ezt a
  koltseget mondd ki, mert a „valtsunk at" szo egyet sugall.
- **A „No credentials set up yet!" NEM azt jelenti, hogy nincs tanusitvanyod.** Azt jelenti,
  hogy ehhez a PROJEKT adott profiljahoz nincs hozzarendelve. Mert 2026-08-18: ebbol azt
  vezettem le, hogy a build majd generalni fog egyet, es ezt mondtam a gazdanak -- aztan a
  build kiirta, hogy van egy husz napos, 2027-ig ervenyes distribution certificate, amit MAR
  ez a projekt hasznal. Helyesbitenem kellett.
- **MEGLEVO KREDENCIALT UJRAHASZNALJ, NE GENERALJ MASIKAT.** Ez harom helyen jon elo egy
  bekotes alatt, es mindharomnal ugyanaz a valasz:
  - „Generate a new App Store Connect API Key?" -> **n** (van sajat .p8-unk)
  - „Reuse this distribution certificate?" -> **Y**
  - „Reuse this Push Key?" -> **Y**
  Nem kenyelmi kerdes: az Apple KORLATOZZA, hany distribution tanusitvanyod es hany APNs
  kulcsod lehet egyszerre. Egy felesleges uj kesobb arra kenyszerit, hogy a regit vonjuk
  vissza -- es az elrontja a vele keszult korabbi buildeket.
  A KIVETEL: provisioning profil. Abbol nyugodtan keszuljon uj, az nem korlatos es
  projektenkent/profilonkent kell.
- **„No, don't ask again (preference will be saved to eas.json)" -- EZT NE.** A push-kerdesnel
  felkinalt harmadik opcio BELEIR a verziokezelt `eas.json`-ba. Egy nem szandekos, at nem
  nezett repo-valtozas keletkezne belole. Yes vagy No, de a harmadik soha.
- **Az Issuer ID-t az `eas credentials` MAGATOL kitalalja** a feltoltott kulcsbol (`Detected
  Issuer ID: ...`). Keszitsd elo, de ne lepodj meg, ha nem keri.
- **Nezd meg, INDIVIDUAL vagy ORGANIZATION az Apple-fiok.** A kimeneten ott all, pl.
  `9B88PTQUQY (Balazs Kratochwilll (Individual))`. TestFlighthez es belso teszthez mindegy,
  DE nyilvanos App Store-megjelenesnel az eladó neve a SZEMELY neve lesz, nem a cege. Ceges
  nevhez Organization fiok kell, ahhoz D-U-N-S szam, es a valtas nem egy kattintas. Ezt a
  bekoteskor mondd ki, ne a kiadasnal derüljön ki.
- **Ha egy menuponthoz nem tudod BIZTOSAN, mit csinal, ne tippelj a gazda gepen.** Az
  „Add a new API Key" jelentheti a feltoltest ES az Apple-nel valo letrehozast is. Kerd el a
  kovetkezo kepernyot, es abbol dontsd el. Egy rossz valasztas itt az Apple oldalan csinal
  valamit, amit nem lehet csendben visszavonni.


- **A `.p8`-bol ket peldany keletkezik.** A gazda letolti a gepere, aztan atmasoljuk a
  szerverre -- masoljuk, nem mozgatjuk. A letoltesek mappajaban felejtett privatkulcs evekig
  ott marad. Mondd ki: szandekosan tartja-e ott (mert o is submitolna), vagy torolje.
- **Ellenorizz, ne higgy.** A fajl megletet ES a mukodest kulon merd:
  ```bash
  cd /home/marveen/marveen && T=$(cat store/.expo-token) && curl -s -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer $T" -H "Content-Type: application/json" -X POST \
    https://api.expo.dev/graphql -d '{"query":"{ meActor { __typename ... on Robot { firstName } } }"}'
  ```
  A valasz mondja meg, hogy ROBOT all-e mogotte es melyik -- nem eleg, hogy 200.
- **Sorvegi ujsor a tokenben.** A leggyakoribb oka annak, hogy "megvan a token, megis 401".
  A fenti `printf '%s'` ezt eleve elkeruli; ha maskepp keszult, ellenorizd.
- **Project ID egyezes.** A nev es a slug egyezhet veletlenul is. Az azonosito nem. Az Expo
  feluleten a projekt Overview-jan, a "Project details" panelen van (Slug / ID / Owner) --
  a General oldal aljan NINCS ott.
- **Ne kattints az "App Store Connect app: Connect" gombra** a projekt Connections listajaban,
  ha az API-kulcsos uton mesz. Masik hitelesitesi folyamatot indit.
- **Ha a felulet uj projekt letrehozasat ajanlja, NE fogadd el.** A projekt letezik; egy
  ilyen kattintas szetvalasztana az appot a sajat build-elozmenyeitol.

## Amit a bekotes kozben ERDEMES eszrevenni (biztonsag)

Ezek nem a feladat reszei, de a felulet megmutatja oket, es kesobb dragak:

- **"Unauthenticated access to internal distribution builds"**: ha be van kapcsolva, a belso
  buildek oldalat barki eleri, akinek megvan a linkje. A cim veletlen azonositot tartalmaz es
  nem indexelt, de a link maga a kulcs, es visszavonni csak a kapcsoloval lehet.
  ELLENORIZD, van-e mar build -- ha igen, ez MAI allapot, nem jovobeli.
- **2FA a tulajdonos fiokon**: a Members oldalon latszik. Ez a fiok viszi az appot az App
  Store-ba; masodik faktor nelkul a jelszo az egyetlen akadaly.
- **"Enhanced security for push notifications"**: ertelmes, de NE most kapcsold be. Bekapcsolva
  minden kuldesnek tokent kell vinnie, es ha a hatterrendszer nincs kesz, az ertesitesek NEM
  hibat dobnak, hanem CSENDBEN elmaradnak. Sorrend: mukodo build -> bekapcsolas -> AZONNALI
  teszt-ertesites.

## Ellenőrzés

- `ls -l store/apple/*.p8` -> `-rw-------`, uid 1000; `git check-ignore` fogja.
- A token-hivas ROBOT-ot ad vissza, a vart nevvel.
- Az `eas.json`-ban nincs kulcs es nincs utvonal.
- A submit ELOTT: a build kulon lepes, es az elso feltoltes KULON dontes -- az mar az Apple
  fele megy ki, es nem vonhato vissza csendben.
