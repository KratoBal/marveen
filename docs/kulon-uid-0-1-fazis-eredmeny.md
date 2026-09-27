# Külön felhasználó: a 0. és 1. fázis eredménye

acrobot, 2026-08-19 21:15. Balázs indította el (Discord, 21:12: „Akkor kezdjük el a külön
felhasználó beállítást"). A terv: `docs/felmeres-kulon-uid-agensenkent.md`.

**Ebben a két fázisban semmi nem változott meg abból, ahogy a flotta ma működik.**
Négy felhasználó és egy csoport LÉTEZIK, de senki nem fut alattuk.

---

## 0. fázis: titok-leltár (mérve, nem emlékezetből)

A `store/` alatt **26 titok-fájl** van, mind `-rw-------`, mind ugyanazé az egy
felhasználóé. Amit mértem: melyik szkript olvassa őket, és melyik ágensnek van
egyáltalán dolga azzal a szkripttel.

| Titok | Melyik szkript olvassa | Kinek kell valójában |
|---|---|---|
| `.dashboard-token` | `fleet-api.sh`, `agent-msg.sh`, `watchdog.sh` | **mind a négy ágensnek** (üzenet, memória, napló) |
| `.github-token` | (közvetlenül a parancsokban) | murena, acrobot |
| `.fb-page-token`, `.fb-user-token`, `.fb-app-secret`, `.fb-page-tokens.json` | `fb-insights.sh`, `fb-schedule-post.sh` | **csak acrobot** |
| `.unas-api-key`, `.unas-token` | `unas.sh` | polip |
| `.gdrive-*`, `.yt-*` | `gdrive.sh`, `yt-stats.sh` | acrobot (és korall a Drive-átadáshoz) |
| `.fal-key` | képgenerálás | acrobot |
| `.expo-token` | EAS | murena |
| `.vault-key` | `db.ts`, `vault.ts`, `pre-modify-backup.sh` | **a dashboard, nem ágens** |
| `.claude-oauth-token` | `channels.sh`, `auth.sh` | a futtató réteg, nem ágens |
| `.acropora-service-token*.json` | `acropora-task.sh` | polip (saját tokene van) |

**A leltár legfontosabb sora:** a négy ágensből **egynek sem kell** a Facebook-, a
Google- vagy a YouTube-titok, murenán kívül **senkinek** a GitHub-token, és polipon kívül
senkinek az UNAS-kulcs. Ma mind a négy mindegyiket olvashatja.

Amire mindenkinek szüksége van, az **egyetlen** fájl: a `.dashboard-token`. Ez helyi,
csak a `localhost:3420`-at nyitja, és a flotta belső kommunikációja épül rá.

## 1. fázis: felhasználók és csoport (kész)

```
fleet:x:1001:agent-korall,agent-polip,agent-barracuda,agent-murena
uid=1001(agent-korall)   uid=1002(agent-polip)
uid=1003(agent-barracuda) uid=1004(agent-murena)
```
`marveen` is tagja a `fleet` csoportnak, hogy a közös repót később csoportjoggal lehessen
megosztani.

**Ellenőrzés, ami bukni tudott volna:** `ps -eo user | sort -u` -> `marveen`, `postgres`,
`root`. **Egyetlen processz sem fut az új felhasználók alatt** -- vagyis a flotta pontosan
úgy működik, ahogy öt perccel ezelőtt.

Visszavonás, ha kell: `sudo userdel -r agent-<nev>` és `sudo groupdel fleet`.

---

## Ami a 2. fázis előtt ELDÖNTENDŐ (és amit még nem tudok)

1. **Claude Code bejelentkezés a második felhasználónak.** Ez a terv legnagyobb ismeretlenje.
   A `store/.claude-oauth-token` a futtató rétegé; hogy egy másik uid alatt indított
   ágens ezzel felhitelesít-e, azt **ki kell próbálni**, nem megjósolni.
2. **A kézbesítés.** A router `tmux send-keys`-szel ír. Külön uid mellett vagy közös
   socket kell csoportjoggal, vagy egy szűk `sudo -u ... tmux` szabály.
3. **A Discord/Telegram plugin.** Ma `marveen` alatt fut; más uid alatt nem próbáltuk.

**Javaslat a következő lépésre:** ne korall átköltöztetésével kezdjünk, hanem az 1. pont
kipróbálásával egy **eldobható** ágensen -- mert ha a hitelesítés nem megy, minden más
munka felesleges volt. Egy uid, egy home, egy indítás, és a kérdés eldől.
