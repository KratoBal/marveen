# Követetlen scriptek átvilágítása -- 2026-08-18

Balázs kérdésére: bevehetők-e git alá a `scripts/` mappa követetlen fájljai.
A `fleet-api.sh` már bement (commit `948ec70`), ez a maradék **tizenkettőről** szól.

## Amit megmértem

| fájl | sorok | titok-minta | 32+ karakteres literál |
|---|---|---|---|
| `acropora-task.sh` | 131 | 0 | 0 |
| `barcode.sh` | 419 | 0 | 5 (elválasztó vonalak) |
| `dream-query.py` | 98 | 0 | 0 |
| `fb-insights.sh` | 229 | 0 | 1 (`page_actions_post_reactions_total`) |
| `gauge-arc.sh` | 120 | 0 | 0 |
| `gauge.sh` | 94 | 0 | 0 |
| `gdrive.sh` | 305 | 0 | 0 |
| `jsonl.sh` | 342 | 0 | 0 |
| `split-agent-config-dirs.sh` | 124 | 0 | 0 |
| `text-metrics.sh` | 123 | 0 | 0 |
| `unas.sh` | 307 | 0 | 0 |
| `yt-stats.sh` | 312 | 0 | 1 (elválasztó vonal) |

**Eredmény: egyetlen beégetett titok sincs egyikben sem.** A hét darab hosszú literál
mind ártalmatlan: elválasztó kötőjel-sorok és egy hosszú Facebook-metrikanév.

Négy script tokent használ, és mind a négy **fájlból** olvassa futásidőben
(`store/.*-token`), nem a kódból: `acropora-task.sh`, `fb-insights.sh`, `gdrive.sh`,
`yt-stats.sh`. Ez a helyes minta.

## Amit a mérés NEM zár ki

Két külön szűrő futott, és mindkettőnek megvan a vakfoltja:

1. **Titok-minta**: `(api_key|secret|token|password|passwd|bearer) = "12+ karakter"`.
   Ez azt találja meg, amit titok-nevű változóba írtak. **Nem** találja meg a nyersen
   URL-be írt kulcsot, sem a semmitmondó nevű változóba tett értéket.
2. **32+ karakteres összefüggő literál**: ez név nélkül is fog, de a 32-nél rövidebb
   kulcsokat átengedi.

Egyik sem nézte át a fájlokat **soronként, emberi olvasással** -- azt külön kell.

## Módszertani megjegyzés, mert számít

Az első futtatásomnál mind a tizenkét fájl 0-t adott, és **a szűrő volt rossz**: a minta
kis-nagybetű érzékeny volt, tehát az `API_KEY="..."` alakra sem illeszkedett. Egy
kontroll-fájlon derült ki, amiről tudtam, hogy IGENT kellene adnia. A `-i` kapcsolóval
a kontroll 1-et adott, és csak ezután lett a tizenkét nulla értelmezhető.

A második szűrőnél a kontroll-fájlom **nem** volt érvényes (a hamis kulcs 21 karakter,
a küszöb 32) -- ott az bizonyítja a működést, hogy hét valódi találatot adott, és
mind a hetet meg tudtam nevezni.

## Javaslat

A tizenkettő **bevehető**, de két csoportban érdemes nézni:

- **Mehet vita nélkül** (saját eszköz, tokent fájlból olvas vagy nem is használ):
  `fb-insights.sh`, `gdrive.sh`, `yt-stats.sh`, `acropora-task.sh`, `jsonl.sh`,
  `text-metrics.sh`, `gauge.sh`, `gauge-arc.sh`, `dream-query.py`
- **Előbb olvassuk el soronként**: `unas.sh`, `barcode.sh`, `split-agent-config-dirs.sh`
  -- ezek éles webshop-adatot és ágens-konfigurációt érintenek, tehát a tartalmuk
  többet számít, mint a titok-keresés eredménye.

A döntés Balázsé; ez a lap csak a mérés.
