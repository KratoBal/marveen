#!/bin/bash
# Skill Index Generator
# Generates a Level 0 index of all available skills (name + description only)
# This keeps token usage low while making all skills discoverable
#
# Usage: skill-index.sh [AGENT_DIR]
#   Without arg: generates global index at ~/.claude/skills/.skill-index.md
#   With AGENT_DIR: generates merged index (global + agent-specific) at
#                   <AGENT_DIR>/.claude/skills/.skill-index.md
#                   (backward-compatible format for no-arg callers)

GLOBAL_SKILLS_DIR="$HOME/.claude/skills"

if [ $# -ge 1 ]; then
  AGENT_DIR="$1"
  AGENT_SKILLS_DIR="$AGENT_DIR/.claude/skills"
  OUTPUT="$AGENT_SKILLS_DIR/.skill-index.md"
  MERGED=1
  mkdir -p "$AGENT_SKILLS_DIR"
else
  AGENT_DIR=""
  AGENT_SKILLS_DIR=""
  OUTPUT="$GLOBAL_SKILLS_DIR/.skill-index.md"
  MERGED=0
fi

if [ ! -d "$GLOBAL_SKILLS_DIR" ]; then
  echo "No global skills directory found at $GLOBAL_SKILLS_DIR"
  exit 0
fi

echo "# Skill Index (Level 0)" > "$OUTPUT"
echo "" >> "$OUTPUT"

if [ "$MERGED" = "1" ]; then
  echo "Ez az ágensspecifikus skill index: globális (~/.claude/skills) és ágensspecifikus (.claude/skills) skilleket egyaránt tartalmaz." >> "$OUTPUT"
  echo "Ha egy skill releváns, olvasd be a teljes SKILL.md-t (Level 1)." >> "$OUTPUT"
  echo "Ha segédfájlokra is szükség van, nézd meg a scripts/ és references/ mappákat (Level 2)." >> "$OUTPUT"
  echo "" >> "$OUTPUT"
  echo "| Skill | Leírás | Scope |" >> "$OUTPUT"
  echo "|-------|--------|-------|" >> "$OUTPUT"
else
  echo "Ez az összes elérhető skill rövid indexe. Csak a nevet és leírást tartalmazza (Level 0)." >> "$OUTPUT"
  echo "Ha egy skill releváns, olvasd be a teljes SKILL.md-t (Level 1)." >> "$OUTPUT"
  echo "Ha segédfájlokra is szükség van, nézd meg a scripts/ és references/ mappákat (Level 2)." >> "$OUTPUT"
  echo "" >> "$OUTPUT"
  echo "| Skill | Leírás |" >> "$OUTPUT"
  echo "|-------|--------|" >> "$OUTPUT"
fi

SKILL_COUNT=0

index_skills_dir() {
  local dir="$1"
  local scope="$2"  # only used when MERGED=1
  for skill_dir in "$dir"/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_md="$skill_dir/SKILL.md"
    [ -f "$skill_md" ] || continue

    local name
    name=$(grep -m1 "^name:" "$skill_md" 2>/dev/null | sed 's/^name: *//' | tr -d '"' | tr -d "'")
    if [ -z "$name" ]; then
      name=$(basename "$skill_dir")
    fi

    # A csonkolás KARAKTER-alapú, nem bájt-alapú. A `cut -c1-120` bájtokat vág, ami egy
    # magyar ékezetes karakter közepén elmetszi a több bájtos UTF-8 szekvenciát -- az
    # index ettől érvénytelen UTF-8 lesz, a grep binárisnak látja, és a skill-keresés
    # NÉMÁN nem talál semmit (mért eset 2026-08-16: az external-company-research sora
    # törte el a fájlt). A python3 mindig elérhető, a `cut` viszont nem multibyte-helyes.
    # A LEIRAS TOBB SOROS IS LEHET, es a `grep -m1 "^description:"` ezt NEMAN elrontja.
    # Mert eset 2026-09-23 05:0x: a `description: >-` (YAML folded block) alaku skilleknel
    # a grep az elso sort hozta, amin a szoveg helyett a `>-` jel all -- az indexbe
    # harom skillnel szo szerint `>-` kerult leirasnak. Az index igy pont azt vesztette
    # el, amiert letezik: a Level 0 leiras az EGYETLEN, ami akkor is hat, ha nem keresed.
    # Ezert a kinyeres a teljes frontmattert olvassa, es a folytato sorokat osszefuzi.
    #
    # A hatar 120-rol 400-ra nott ugyanabban a korben, majd 2026-09-23 06:2x-kor
    # TELJESEN ELTUNT. A tortenete azert all itt, mert a ket csonkolas UGYANAZT a sort
    # vagta el, csak egyre kesobb, es mindketszer a MEGOLDAS eleve maradt kint:
    #
    #   120 karakter   a bash-hivas-alakja sora a "Contains simple_" szonal allt meg
    #   400 karakter   ugyanaz a sor a "PR torzsben" szonal allt meg
    #
    # A masodik csonkolas ara MERT: 2026-09-23 ejjel barracuda tizennegyszer allt meg
    # ugyanazon a parancs-alakon (ciklusvaltozo plusz $(...) egy for ciklusban), es a
    # megoldas -- a `grep -o -F -f minta.txt CELFAJL | sort | uniq -c` egy-hivasos alak --
    # pont a 400. karakter UTAN all a leirasban. Az indexe tehat megmondta neki, hogy VAN
    # baja, es azt nem, hogy mi a kiut. Egy kivalto jel megoldas nelkul rosszabb a
    # semminel: megallitja az olvasot, de nem inditja el.
    #
    # A TELJES leiras ara az EGESZ indexre 2492 karakter (20599 a 18107 helyett, 56
    # skillnel, ebbol 9 volt 400 felett). Az index nem automatikusan betoltott fajl,
    # keresre olvassak `cat`-tel, tehat ez a 12 szazalek nem terheli a kontextust minden
    # korben -- a csonkolas viszont pont akkor tunt el, amikor szukseg lett volna ra.
    # HA VALAHA UJRA HATART TENNEL IDE: eloszor mérd le, MELYIK skill sora hol vagodik el,
    # es mi marad kint. Egy szamnak onmagaban nincs jelentese.
    local desc
    desc=$(python3 - "$skill_md" <<'PYDESC'
import sys, re
try:
    txt = open(sys.argv[1], encoding='utf-8', errors='replace').read()
except Exception:
    sys.exit(0)
m = re.match(r'^---\n(.*?)\n---', txt, re.S)
fm = m.group(1) if m else txt
lines = fm.split('\n')
out = []
for i, line in enumerate(lines):
    if not line.startswith('description:'):
        continue
    first = line[len('description:'):].strip()
    if first in ('>-', '>', '|-', '|', '>+', '|+'):
        for cont in lines[i+1:]:
            if cont.strip() and not cont.startswith((' ', '\t')):
                break
            out.append(cont.strip())
    else:
        out.append(first)
        for cont in lines[i+1:]:
            if cont.strip() and not cont.startswith((' ', '\t')):
                break
            out.append(cont.strip())
    break
d = ' '.join(x for x in out if x)
d = d.replace('"', '').replace("'", '').replace('|', '/')
sys.stdout.write(' '.join(d.split()))
PYDESC
)
    if [ -z "$desc" ]; then
      desc="(nincs leírás)"
    fi

    if [ "$MERGED" = "1" ]; then
      echo "| \`$name\` | $desc | $scope |" >> "$OUTPUT"
    else
      echo "| \`$name\` | $desc |" >> "$OUTPUT"
    fi
    SKILL_COUNT=$((SKILL_COUNT + 1))
  done
}

index_skills_dir "$GLOBAL_SKILLS_DIR" "global"

if [ "$MERGED" = "1" ] && [ -d "$AGENT_SKILLS_DIR" ]; then
  index_skills_dir "$AGENT_SKILLS_DIR" "agent"
fi

echo "" >> "$OUTPUT"
echo "_${SKILL_COUNT} skill indexelve. Generálva: $(date '+%Y-%m-%d %H:%M')_" >> "$OUTPUT"

echo "Skill index generated: $OUTPUT ($SKILL_COUNT skills)"
