---
name: dream-engine
description: Éjszakai analízis-loop az aznapi memóriákról, naplóról és kanban-állapotról. Generál 4 priorizált akció-javaslatot reggelre.
---

Te most a "Dream Engine" éjszakai analízis-loopot futtatod. 02:07-kor vagy, {{OWNER_NAME}} alszik, NE küldj üzenetet a beállított csatornára.

A cél: az aznapi tudást átkonszolidálni és reggelre (07:30 Reggeli Napindító) felkészülni 4 priorizált javaslattal.

## Mit kell csinálnod

Generálj egy `{{INSTALL_DIR}}/DREAM.md` fájlt az alábbi 5 bucket alapján. A formátum a fájl alján van.

### Bucket 1 — 💡 Skill-javaslatok (flotta-szintű)

Nézz végig MINDEN agent (a fő-ágens és az összes sub-agent) tegnapi (24h) memóriáit és napi naplóját. Kerítsd ki:
- Volt-e 3+ szor visszatérő, manuálisan ismételt művelet ami skill-be illeszthető?
- Új, NEM lefedett pattern amit érdemes lenne skillbe önteni?

SQL minta:
```bash
python3 {{INSTALL_DIR}}/scripts/dream-query.py memories-24h
```

Output: 0-2 konkrét skill-javaslat. Mindegyikhez: cím + 1 mondat indoklás + "flotta-szintű" vagy "agent: <név>".

### Bucket 2 — 🧹 Memória-egészség (NE delete, COLD-tier-be mozgatás)

```bash
# Tier-eloszlas (az "embeddelt" oszlop mindig 0, lasd lentebb -- ne jelentsd)
python3 {{INSTALL_DIR}}/scripts/dream-query.py memory-stats
# NE hívd a backfill endpointot, és NE jelentsd hibaként a hiányzó embeddingeket.
# Balázs döntése 2026-08-18: az Ollama nem kell nekünk, nincs telepítve (a 11434-es
# port nem válaszol), és nem is tervezzük. A vektorizálás hiánya tehát ELVÁRT állapot,
# nem lelet. Korábban minden éjjel bekerült a DREAM.md-be, és többször is felmerült.
# A kulcsszavas keresés enélkül is működik.

# Antikvált hot-tier (>7 napos hot, nem hivatkozott a memories_fts-en az elmúlt 24h-ban)
python3 {{INSTALL_DIR}}/scripts/dream-query.py stale-hot 7
python3 {{INSTALL_DIR}}/scripts/dream-query.py duplicates
```

**A TÖMEGES UPDATE ELŐTT KÖTELEZŐ:** először futtasd le a fenti `SELECT`-et, nézd meg a
DARABSZÁMOT és egy MINTÁT (a legfrissebb találat dátumát!), és az `UPDATE` PONTOSAN azon az
id-halmazon fusson (`WHERE id IN (...)`), ne a predikátumot ismételd meg. Ha a legfrissebb találat
a mai nap, a predikátum hibás -- állj meg. (ID-lista nélkül a művelet nem fordítható vissza
pontosan: 2026-07-31-én emiatt csak tartalmi mintára lehetett helyreállítani.)

Műveletek:
1. Vektorizálatlan memóriák: NE jelezd. Ollama nélkül minden memória vektorizálatlan, ez az elvárt állapot (lásd fent).
2. Antikvált hot/warm → COLD-tier-be PUT (UPDATE category='cold'). Sosem törlés.
3. Pontos dupla-content: jelezd, mozgass cold-ba.

A tier-mozgatast az API-n keresztul csinald, NE kozvetlen SQL-lel: a dashboardnak sajat
memoria-gyorsitotara van, es egy nyers UPDATE utan az meg a regi tiert adja vissza.
Kartyankent (memoria-azonositonkent) egy hivas:
```bash
curl -s -X PUT http://localhost:{{WEB_PORT}}/api/memories/<ID> \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat {{INSTALL_DIR}}/store/.dashboard-token)" \
  -d '{"content":"<a valtozatlan tartalom>","category":"cold"}'
```

**AZ UPDATE SIKERÉT NE A `changes()`-BŐL OLVASD (2026-08-07).** A `sqlite3 db "SELECT changes()"`
egy KÜLÖN kapcsolatot nyit, ott pedig a számláló mindig 0 -- akkor is, ha az UPDATE tökéletesen
lefutott. Nálam 14 sikeresen átmozgatott sorra írt ki `moved: 0`-t, és egy pillanatig úgy nézett ki,
hogy a művelet nem ment át. **A bizonyíték a predikátum ÚJRAMÉRÉSE** (a szűrő immár 0 találat) plusz
a tételes ID-lista visszaolvasása (`SELECT category, COUNT(*) ... WHERE id IN (...) GROUP BY category`).
Ugyanaz a család, mint a bucket többi mérési csapdája: a rossz műszer csendben hazudik, és itt
történetesen a PESSZIMISTA irányba -- ilyenkor a kísértés az, hogy feleslegesen újra lefuttasd.

Output: rövid statisztika ("X memória cold-tier-be áthelyezve, Y vektorizálatlan rendezve").

### Bucket 3 — 🎯 Project-priorítás (top-3 holnapi javaslat)

```bash
# Nyitott kanban-kártyák project + priority szerint
python3 {{INSTALL_DIR}}/scripts/dream-query.py kanban-open
```

Csoportosíts project szerint. A daily naplóban (utolsó 7 nap) nézd hogy melyik projekten van aktív mozgás (commit, PR, kanban-átmozgás). Hozz ki egy TOP-3 holnapi javaslatot prioritás+aktivitás súlyozva.

**A NAPLÓ TÁBLA NEVE `daily_logs`, TÖBBES SZÁMBAN (2026-08-09 02:1x, saját elcsúszás).** A `daily_log` NEM létezik, és az arra futó lekérdezés `Error: in prepare, no such table` sorral elszáll. Ez azért veszélyes, mert a hiba a kör KÖZEPÉN jön, egy `head`-elt kimenet aljára, és a kör simán továbbmegy: aznap a top-3 az aktivitási adat NÉLKÜL állt össze, csak a kanban-prioritásból. A helyes lekérdezés (oszlopok: `agent_id`, `date`, `content`, `created_at`):

```bash
sqlite3 {{INSTALL_DIR}}/store/claudeclaw.db "SELECT agent_id, date, substr(content,1,120) FROM daily_logs WHERE created_at > CAST(strftime('%s','now','-7 days') AS INTEGER) ORDER BY created_at DESC"
```

**ELJÁRÁS: ha egy bucket lekérdezése HIBÁRA fut, az nem üres eredmény, hanem hiányzó bemenet.** Vagy javítsd és futtasd újra ugyanabban a körben, vagy a DREAM.md `## ⚠️ Hibák` szekciójában mondd ki, hogy az adott bucket csonka bemenetből dolgozott. Csendben továbbmenni a legrosszabb, mert a kimenet ugyanúgy magabiztosnak látszik.

Output: 3 sor, mindegyik formátum `<project>: <kártya cím / akció> — <indok 1 mondatban>`.

### Bucket 4 — 🌐 External opportunities (új skill-repo ajánlások)

Hetente 1-2 alkalommal (NEM minden éjszaka — kerüljük a zajos napi javaslatot) végezz WebSearch-öt új Claude Code / agentic AI / produktivitás-skillekért. Szűrés:
- GitHub stars >100
- Recent activity (utolsó 90 napban commit)
- README clarity (skill mit csinál, hogyan kell telepíteni)

Limitáció: ha az utolsó 7 napban már volt ajánlás, skip-eld. A mérvadó forrás a DREAM.md ELŐZŐ
éjszakai példánya (az "External opportunity" szekciója kimondja az utolsó futás dátumát), NEM egy
`.external-ops-last-run` markerfájl: a markert semmi nem írja, tehát önmagában minden éjjel
újrafuttatná a keresést (2026-07-27-én mérve: a marker 06-07-én megállt). Ha egyszer a markert
tesszük hivatalossá, akkor a bucket végén ÍRNI is kell (`date -u +%F > .external-ops-last-run`),
különben marad a DREAM.md archívum.

Output (max 1 ajánlás): repo URL + 1 mondat indok hogy MIÉRT releváns {{OWNER_NAME}}nak (figyelembe véve: AI tartalomgyártás, magyar piac, fejlesztési flotta menedzsment, marketing).

### Bucket 5 — 🛠 Skill-flotta health (csak NEM-pinned skillek)

```bash
# Hasznalati naplo. FIGYELEM: 2026-08-18-ig a skill_usage tabla URES volt (0 sor),
# tehat a "utolso hasznalat >30 nap" kriterium nem kiertekelheto. Ha most is ures,
# azt IRD KI leletkent, es ne javasolj skill-torlest -- adat nelkul az talalgatas.
python3 {{INSTALL_DIR}}/scripts/dream-query.py skill-usage

# Antikvált skillek: nincs use-log, vagy a frontmatterben pinned: false
ls ~/.claude/skills/ | head
# Mindegyik SKILL.md-ben grep -l "pinned: true" — ezek mind védettek
grep -L "^pinned:" ~/.claude/skills/*/SKILL.md  # azok a skillek ahol nincs pinned-flag (NEM gyári)
```

Pinned default (mindig védett): claude-video, frontend-design, docx, skill-creator, skill-factory, skill-install-from-git, init, review, security-review, simplify, fewer-permission-prompts, loop, schedule, claude-api, update-config, keybindings-help, telegram:configure, telegram:access.

Output: 0-3 javaslat: "skill <név> antikvált (utolsó használat >30 nap), törlés vagy frissítés javasolt".

## Output formátum (DREAM.md)

```markdown
# 💭 Dream Engine — 2026-05-12 02:07

## 💡 Skill-javaslatok
- (vagy "Nincs új javaslat")

## 🧹 Memória-egészség
5 hot→cold mozgatva, 0 duplikátum. (Vektorizálás: NE szerepeljen, lásd Bucket 2.)

## 🎯 Top-3 holnapi javaslat
1. <project>: <akció> — <indok>
2. ...
3. ...

## 🌐 External opportunity
- (vagy "Skip — heti limit elérte" / "Nincs releváns új repo")

## 🛠 Skill-flotta health
- (vagy "Minden skill aktív vagy pinned")
```

## Szabályok

- **A DREAM.md-t ELŐSZÖR OLVASD BE, csak utána írd felül (2026-08-15 02:1x, minden éjjel egy elvesztegetett hívás).** A fájl minden éjjel felülíródik, a Write viszont visszautasítja azt a fájlt, amit ebben a menetben nem olvastál (`File has not been read yet`). Amúgy is olvasni kell: az External opportunity szekció ELŐZŐ példánya a mérvadó forrás arra, mikor futott utoljára a keresés. Tehát egy Read a kör elején két dolgot ad meg egyszerre, és megspórol egy bukott írást.
- NE küldj üzenetet a csatornára. A DREAM.md a reggeli napindítóból kerül kiküldésre (07:30).
- A `Bash` és SQL műveletek mind helyiek — semmilyen external API hívás. Ollama-hívás sem.
- Ha akadály van (pl. DB lock), írd be a DREAM.md végére `## ⚠️ Hibák` szekciót — reggel látom. A hiányzó embedding-modell NEM akadály, azt ne írd be.
- **GONDOLATJEL-KAPU A FÁJL LEZÁRÁSA ELŐTT, ÉS A KAPU AKADÁLYOZZA MEG AZ ÍRÁST, ne csak jelentsen (2026-08-08, elkapva)**: a DREAM.md NEM belső jegyzet, hanem KIMENŐ szöveg -- a reggeli napindító viszi a csatornára. A gazda álló szabálya (nincs gondolatjel, soha) tehát rá is áll, csak ez eddig sehol nem volt kimondva ebben a taskban, és a 2026-08-08-i futásban HAT gondolatjel került a fájlba. A tanulság általánosabb, és aznap este már két másik felületen is elsült: **egy kimenő kapu nem a szöveg TÍPUSÁHOZ tartozik, hanem a PUBLIKÁLÁS aktusához** -- ha csak az egyik útvonalon építetted be, a másik csendben átengedi.
  ```bash
  N=$(grep -oE '—|–|―' DREAM.md | wc -l | tr -d ' '); echo "dash=$N"
  [ "$N" = "0" ] || { echo "STOP: gondolatjel a DREAM.md-ben, javitsd mielott lezarod"; }
  ```
  Javítás Python-nal (` — ` -> ` -- `, majd a maradék bármely hosszú kötőjel -> `--`), utána OLVASD VISSZA és futtasd újra a grepet.
- **ÉS A KAPU MEGISMÉTELTE MAGÁT, MERT A LEMEZRE ÍRÁS NEM ÉLESÍT (2026-08-11, ugyanaz a hat gondolatjel)**: a fenti kapu 08-08-án ide, a LEMEZRE került, a futó kör viszont a REGISZTRÁLT promptot kapja, és abban nincs benne. Mérve: a lemezen 9142 bajt és egy `GONDOLATJEL-KAPU` találat, a `/api/schedules`-ban 8147 bajt és NULLA. Vagyis a kapu a megírása óta egyszer sem futott le, és a 08-11-i DREAM.md ugyanúgy hat gondolatjellel készült el. **A tanulság nem a gondolatjelről szól: egy ütemezett task bármely, ide beírt buktatója NEM LÉTEZIK, amíg a regisztrált prompt nem tud róla** (`project_scheduled_task_rules`: a fájl nem a regisztráció). Ezért a kaput a kör NE csak innen várja -- futtasd le a `DREAM.md` lezárása előtt akkor is, ha a kapott promptban nem szerepel. Szinkronizálni a helyes úton kell (a lemezen `{{BOT_NAME}}` placeholder van, a regisztráltban a név beégetve, tehát a nyers bemásolás elrontaná); a nyitott tétel a `TASKSYNC811` kártyán ül.
- Befejezésként, írd a DREAM.md végére: `*{{BOT_NAME}}, 02:XX -- most már alszom én is.*`
