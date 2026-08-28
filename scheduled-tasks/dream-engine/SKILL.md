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

Output: rövid statisztika ("X memória cold-tier-be áthelyezve, Y vektorizálatlan rendezve").

### Bucket 3 — 🎯 Project-priorítás (top-3 holnapi javaslat)

```bash
# Nyitott kanban-kártyák project + priority szerint
python3 {{INSTALL_DIR}}/scripts/dream-query.py kanban-open
```

Csoportosíts project szerint. A daily naplóban (utolsó 7 nap) nézd hogy melyik projekten van aktív mozgás (commit, PR, kanban-átmozgás). Hozz ki egy TOP-3 holnapi javaslatot prioritás+aktivitás súlyozva.

Output: 3 sor, mindegyik formátum `<project>: <kártya cím / akció> — <indok 1 mondatban>`.

### Bucket 4 — 🌐 External opportunities (új skill-repo ajánlások)

Hetente 1-2 alkalommal (NEM minden éjszaka — kerüljük a zajos napi javaslatot) végezz WebSearch-öt új Claude Code / agentic AI / produktivitás-skillekért. Szűrés:
- GitHub stars >100
- Recent activity (utolsó 90 napban commit)
- README clarity (skill mit csinál, hogyan kell telepíteni)

Limitáció: ha az utolsó 7 napban már volt ajánlás (nézd a DREAM.md utolsó 7 napos archívumát vagy egy `external-ops-last-run` markerfile-t), skip-eld.

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

- NE küldj üzenetet a csatornára. A DREAM.md a reggeli napindítóból kerül kiküldésre (07:30).
- A `Bash` és SQL műveletek mind helyiek — semmilyen external API hívás. Ollama-hívás sem.
- Ha akadály van (pl. DB lock), írd be a DREAM.md végére `## ⚠️ Hibák` szekciót — reggel látom. A hiányzó embedding-modell NEM akadály, azt ne írd be.
- Befejezésként, írd a DREAM.md végére: `*{{BOT_NAME}}, 02:XX -- most már alszom én is.*`
