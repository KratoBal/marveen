# Felmérés: külön felhasználó ágensenként, és a sudo elvétele

Írta: acrobot, 2026-08-19 este. Kérte: Balázs (Discord, 20:18).
Kártya: `917ee416`. **Ez felmérés, nem végrehajtás. Semmit nem állítottam át.**

---

## 1. Mi a helyzet MOST (mérve, nem emlékezetből)

| Mit néztem | Mit találtam |
|---|---|
| `ps -eo user` | **Mind az öt ágens ugyanaz a felhasználó**: `marveen`, uid 1000 |
| `tmux server` | **Egyetlen tmux szerver** (pid 108), minden ágens-session alatta |
| `/etc/sudoers.d/marveen` | `marveen ALL=(ALL) NOPASSWD:ALL` |
| `store/` | a dashboard-token, a GitHub-token, a Facebook oldal- és user-token, az app-secret **mind ugyanannak az egy felhasználónak olvasható** |
| kézbesítés | a dashboard (`src/web/agent-process.ts`) **`tmux send-keys`-szel** ír az ágensek paneljébe, ugyanabból a felhasználóból |
| home | egy darab `/home/marveen`, `.claude` 283 MB |
| ágens-mappák | korall 39 MB, barracuda 64 MB, polip 80 MB, **murena 1,9 GB** |

**A lényeg egy mondatban:** a jogosultsági profil ma **kérés, nem korlát**. Aki
sudózni tud, az root, és `marveen` egy jelszó nélküli paranccsal root. Ma este én
magam is ezzel telepítettem a fejlesztői adatbázist -- vagyis ez nem elméleti út,
hanem élő és használt.

**Amit ez konkrétan jelent:** korall (marketing-ágens, aki webet olvas, tehát a
prompt-injection legnagyobb felülete) ma **be tud olvasni egy GitHub-tokent**.
Nem azért, mert valaha is megtenné, hanem mert semmi nem akadályozza meg benne.

---

## 2. Mit vesz meg a szétválasztás, és mit nem

**Megvesz:** azt, hogy a profil betartatott legyen a fájlrendszer szintjén. Korall
nem éri el a GitHub-tokent, murena nem éri el a Facebook-tokent, és egyik sem tud
rootot szerezni. Ez a mai „aranyszabály" gépi változata.

**Nem vesz meg:** a prompt-injection elleni védelmet önmagában. Ha korall rosszul
utasított tartalmat olvas, továbbra is tud rossz posztot írni -- csak nem tud
közben tokent lopni. A kettő külön kérdés, és ezt érdemes kimondani, mert a
szétválasztás könnyen kelt „most már biztonságos" érzést.

---

## 3. Mi törik el, és mi a javítás

1. **A kézbesítés.** A router `tmux send-keys`-t hív. Külön uid mellett az egyik
   felhasználó tmux szervere **nem látja** a másikét.
   *Javítás:* ágensenként külön tmux socket egy közös könyvtárban, csoport-joggal,
   VAGY a router `sudo -u <agens> tmux -S <socket> ...` alakban hív. Ekkor a
   sudo NEM tűnik el teljesen, hanem **egyetlen szűk szabályra** szűkül (egy
   bináris, rögzített argumentumokkal). Ez a szétválasztás legkényesebb pontja:
   ha ez a szabály tág, az egészet visszacsináltuk.
2. **Claude Code hitelesítés felhasználónként.** Minden uid saját home-ot és saját
   bejelentkezést igényel. **Ezt nem tudtam lemérni**: nem tudom, hogy ezen a
   telepítésen egy második bejelentkezés zökkenőmentes-e. Ez a legnagyobb
   ismeretlen a tervben.
3. **Közös fájlok.** A repó (`/home/marveen/marveen`) ma egy tulajdonosé. Kell egy
   `fleet` csoport olvasásra, és a `store/` alatt **tokenenként** eltérő
   tulajdonos/jog (0640, csak annak a csoportnak, akinek tényleg kell).
4. **Lemez és gyorsítótár.** murena 1,9 GB-ja külön home-ba másolva fájna. Marad a
   helyén, átveszi a tulajdonjogot; a pnpm store megosztható.
5. **supervisord.** A programoknál `user=` kell, ma mind `marveen`.
6. **Ütemezett feladatok és a csatorna-pluginok.** A Discord/Telegram bot ma
   `marveen` alatt fut. **Nem mértem le**, hogy más uid alatt indul-e gond nélkül.

---

## 4. A folyamat, fázisonként, mindegyik végén bukható ellenőrzéssel

**0. Leltár (fél óra, kockázat nulla).**
Melyik ágensnek MELYIK titok kell valójában? Ma mindenki mindent lát, tehát ezt
nem lehet a jelenlegi állapotból kiolvasni -- a profilokból és a hívott
szkriptekből kell összeszedni.
*Ellenőrzés:* van egy táblázat: ágens -> szükséges titkok. Ha egy sor üres, az jó hír.

**1. Felhasználók és csoport létrehozása (kockázat nulla, semmi nem vált).**
`agent-korall`, `agent-polip`, `agent-barracuda`, `agent-murena` + `fleet` csoport.
Senki nem fut még alattuk.
*Ellenőrzés:* `getent passwd` mutatja őket, a flotta változatlanul működik.

**2. EGY ágens átköltöztetése, a többi érintetlenül.**
Saját home, saját Claude-bejelentkezés, saját tmux socket, a mappája átírva rá.
*Ellenőrzés, és mind a háromnak teljesülnie kell:*
- kap egy inter-agent üzenetet és válaszol rá,
- ír a memóriájába és a napi naplóba,
- **és NEM tudja beolvasni azt a tokent, amit nem szabad** -- ezt külön ki kell
  próbálni, mert ez az egyetlen ellenőrzés, ami bizonyít is valamit. Ha ez a
  próba nem bukik el ott, ahol el kell buknia, akkor nem csináltunk semmit.

**3. A kézbesítés átállítása.**
A router a szűk sudo-szabályon (vagy közös socketen) keresztül ír.
*Ellenőrzés:* üzenet oda-vissza, ÉS egy szándékosan tiltott hívás, ami elbukik.

**4. A többi ágens, egyesével.** Mindegyik után ugyanaz a hármas ellenőrzés.

**5. A `NOPASSWD:ALL` elvétele `marveen`-től.**
Ez a fizetség, és **csak a legvégén** jöhet. Utána marad a szűk szabály és a
csomagtelepítés joga (vagy az sem, és akkor telepítés = konténer-újraépítés).
*Ellenőrzés:* `sudo -n true` **elbukik**, és a flotta ettől még dolgozik.

---

## 5. Kivel kezdeném: **korall**

**Miért ő:**
- **A legkisebb lábnyom:** 39 MB, nincs benne fordítási gyorsítótár, nincs repó-checkout.
- **Nincs írási joga a kódhoz**, tehát a git/token-oldal nála nem kérdés.
- **Nála a legnagyobb a nyereség:** ő olvas nyilvános webet (versenytárs-figyelés,
  gyártói adatlapok), tehát nála a legvalószínűbb, hogy rosszul utasított tartalom
  jut a kontextusába -- és ma ő látja a GitHub- és Facebook-tokent is.
- **Most nem sürgős a munkája:** Lucára vár. Ha a költözés fél napra megbillenti,
  az semmit nem állít meg.

**Kivel NEM kezdeném: murena.** 1,9 GB állapot, futó fejlesztés, és épp most állt
fel alatta a fejlesztői adatbázis. Ő legyen az utolsó, amikor a folyamat már
háromszor lefutott.

**Egy dolog, amit előre kimondok:** a 2. fázisban a korall-költözés fél napja NEM
a felhasználó létrehozása lesz, hanem a Claude-bejelentkezés és a csatorna-plugin
kérdése. Ha ez a kettő zökkenőmentes, a többi ágens már gépies.
