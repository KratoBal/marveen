# Külön felhasználó: az eldobható ágens próbája

acrobot, 2026-08-19 21:20. Balázs engedélyével (Discord, 21:18: „Mehet az eldobható agens
proba"). Cél: eldönteni a terv **két legnagyobb ismeretlenjét**, mielőtt bárkit költöztetünk.

**Mindkettőre megvan a válasz, és egyik sem tippelés: lefuttattam.**

---

## 1. Be tud-e jelentkezni a Claude egy másik felhasználó alatt? IGEN.

**A hitelesítés nem felhasználóhoz kötött bejelentkezés, hanem egy környezeti változó.**
A `scripts/channels.sh` a `CLAUDE_CODE_OAUTH_TOKEN`-t exportálja (a `.env`-ből, vagy a
`store/.claude-oauth-token`-ből), a konfigot pedig a `CLAUDE_CONFIG_DIR` külön mappába
irányítja. Vagyis nincs szükség új bejelentkezési folyamatra: **elég, ha az adott
felhasználó hozzáfér a tokenhez.**

A próba (`agent-proba`, uid 1005, saját home, saját config-mappa, saját token-másolat
`0400`-zal):

```
claude -p "Valaszolj egyetlen szoval: mukodik"
-> Működik
CLAUDE EXIT: 0
```

**Ez a terv legnagyobb kockázata, és megszűnt.**

## 2. Elér-e a router egy másik felhasználó tmux-át? CSAK `sudo -u`-VAL.

Két utat mértem, és a kényelmesebb **elbukott**:

**(a) Közös socket, csoportjoggal -- NEM MŰKÖDIK.**
A socketet `srw-rw---- agent-proba fleet` jogokkal hoztam létre egy `2770`-es, `fleet`
csoportú könyvtárban, és a csatlakozó felhasználó tagja a csoportnak. A tmux mégis
elutasítja:

```
error connecting to /opt/fleet-tmux/proba.sock (Permission denied)
majd a helyes csoporttal:  access not allowed
```

A tmux tehát **nem a fájljogot nézi, hanem a csatlakozó felhasználó azonosságát**.
Ezt az utat el lehet felejteni.

**(b) `sudo -u <agens> tmux -S <socket> send-keys ...` -- MŰKÖDIK.**

```
sudo -u agent-proba tmux -S /opt/fleet-tmux/proba.sock send-keys -t proba "..." Enter
-> a parancs lefutott a másik felhasználó paneljében
```

**Következmény a tervre:** a sudo nem tűnik el a rendszerből, hanem **egyetlen, szűk
szabállyá** válik: a router felhasználója futtathat `tmux`-ot a négy ágens nevében, és
semmi mást. Ez a szabály a szétválasztás legkényesebb pontja -- ha tágra sikerül (pl.
`ALL=(agent-korall) NOPASSWD: ALL`), akkor a mai `NOPASSWD:ALL`-t cseréltük négy darab
kicsire.

---

## Egy mellékes, de fontos lelet: a csoporttagság nem visszamenőleges

A `usermod -aG fleet marveen` után az `id marveen` már mutatta a `fleet` csoportot, a
**futó processzeim viszont nem**: `id -G` -> csak `1000`. A folyamat a csoportjait
indításkor kapja. Ez a gyakorlatban azt jelenti, hogy **a dashboardot és a routert újra
kell indítani**, különben a csoport-alapú jogok némán nem érvényesülnek rájuk.

## Amit a próba NEM döntött el

- **A Discord/Telegram plugin** más felhasználó alatt: nem próbáltam, mert ahhoz egy
  valódi csatorna-session kellene. A fő ágens marad `marveen` alatt, tehát ez a kérdés
  csak akkor éles, ha valaha egy sub-ágensnek saját csatornát adnánk.
- **A közös repó jogai** (`/home/marveen/marveen`): a `fleet` csoportnak olvasnia kell
  majd, és a `store/` alatt titkonként kell eldönteni, ki látja. Ez a 3. fázis.

## Takarítás

Az `agent-proba` felhasználó, a `/opt/fleet-tmux/proba.sock` és a token-másolata
eldobható: `sudo userdel -r agent-proba`. A `/opt/fleet-bin/claude` (a megosztott,
minden felhasználó által futtatható bináris) viszont **maradjon** -- a valódi
költöztetésnek is szüksége lesz rá, mert a `/home/marveen` `0700`, tehát a mai
`claude` bináris más felhasználó számára elérhetetlen.

---

## 4. fázis első fele: a szűk sudo-szabály (kész, és izoláltan bizonyítva)

`/etc/sudoers.d/fleet-tmux`:

```
marveen ALL=(agent-korall) NOPASSWD: /usr/bin/tmux
```

**Az első ellenőrzésem semmit nem bizonyított, és ezt ki kell mondani.** Lefuttattam a
három próbát `marveen` alatt, és mind a három "átment" -- köztük azok is, amelyeknek
BUKNIUK kellett volna. Az ok: `marveen`-nek ott van a `NOPASSWD:ALL` szabálya, tehát a
szűk szabály semmit nem korlátoz rajta. Egy ellenőrzés, ami nem tud bukni, nem ellenőrzés.

**Ezért egy olyan felhasználóval mértem újra, akinek NINCS általános sudo joga**
(`agent-proba`, ideiglenes szabállyal), és így a négy eset a helyes választ adta:

| próba | várt | mért |
|---|---|---|
| `tmux` **korall** nevében | menjen | `tmux 3.3a` |
| `tmux` **murena** nevében | bukjon | `sudo: a password is required` |
| **más parancs** (`id`) korall nevében | bukjon | `sudo: a password is required` |
| **root** | bukjon | `sudo: a password is required` |

Az ideiglenes próba-szabály (`/etc/sudoers.d/zz-proba-tmux`) a próbafelhasználóval együtt
eldobható.

## 4. fázis második fele: a router kódja -- MÉRVE, NEM ma éjjel

A becslésem („egy elágazás") **túl optimista volt**, és ezt a mérés mutatta meg:

- A `buildTmuxInvocation`-ben az új ág tényleg **egy sor**: `host == null && runAsUser`
  esetén `{ file: 'sudo', args: ['-n', '-u', user, tmuxBin, ...tmuxArgs] }`.
- **De az ágens azonosságát el kell juttatni odáig.** Ma a `runTmux` / `captureTmux` és
  a rájuk épülő exportált segédfüggvények (`sessionExistsOnHost`,
  `dismissSurveyModalIfPresent`, `dismissResumeSummaryModalIfPresent`,
  `dismissModelConsentDialogIfPresent` és társaik) **csak a `host: string | null`
  értéket viszik**. A hívások száma 33; a módosítandó szignatúrák száma ennél kevesebb,
  de nagyságrendileg tíz-tizenöt.

Ez nem nehéz munka, de **futó routeren, éjfél előtt nem érdemes** -- és a dashboard
újraindítása nélkül úgysem lépne életbe. Egy fókuszált óra, nem egy esti toldás.
