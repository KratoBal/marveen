#!/usr/bin/env bash
# gauge.sh -- feny- es aramlas-igeny savok faj-bemutato lapokhoz (Luca Canva-sablonjahoz).
#
# WHY CODE AND NOT THE IMAGE GENERATOR: this graphic repeats per species, must be
# pixel-identical every time, and carries Hungarian accented labels (ALACSONY /
# KOZEPES / EROS). The image models get Hungarian accents wrong in a systematic way
# (KEZDO -> KEZDO with the wrong diacritic), and "almost the same" defeats the whole
# point of a comparison scale. So: ffmpeg drawbox + drawtext, DejaVuSans-Bold.
#
# SPEC (korall, 2026-08-16), and these are constraints, not defaults:
#   - Three levels, never five. Five would claim a precision we do not have.
#   - ALWAYS left-to-right increasing, for every species, or comparability is lost.
#   - FENY on top, ARAMLAS below, always in this order, always the same size.
#   - The marker is a BAND, not a point: a species' light need is a RANGE. A point
#     would read as a measurement; this is experience, not measurement.
#   - No numbers, no units (PAR, lux, l/h), no percentages. A number would be read
#     as measured, and would need a per-species source. Not worth it.
#   - No species drawing. The photo shows the species.
#
# Usage:
#   bash scripts/gauge.sh <feny-tol> <feny-ig> <aramlas-tol> <aramlas-ig> <kimenet.png>
#   Ertekek: 1 = ALACSONY, 2 = KOZEPES, 3 = EROS. A tol es ig lehet azonos (egy fokozat).
#
# Pelda (kozepes-eros feny, eros aramlas):
#   bash scripts/gauge.sh 2 3 3 3 /tmp/euphyllia.png
#
# Kimenet: 1240x430 PNG, ATLATSZO hattérrel, hogy Canvaban barmilyen alapra rakhato.
set -uo pipefail

die() { echo "FAIL $*" >&2; exit 1; }

FL="${1:-}"; FH="${2:-}"; AL="${3:-}"; AH="${4:-}"; OUT="${5:-}"
[ -n "$OUT" ] || die "hasznalat: gauge.sh <feny-tol> <feny-ig> <aramlas-tol> <aramlas-ig> <kimenet.png>"
for v in "$FL" "$FH" "$AL" "$AH"; do
  case "$v" in 1|2|3) ;; *) die "az ertekek csak 1, 2 vagy 3 lehetnek (kaptam: $v)" ;; esac
done
[ "$FL" -le "$FH" ] || die "a feny tartomany forditva van: $FL > $FH"
[ "$AL" -le "$AH" ] || die "az aramlas tartomany forditva van: $AL > $AH"

FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
[ -f "$FONT" ] || die "hianyzik a betutipus: $FONT"

# Luca palettajabol (MERT, 2026-08-16, a Canva-lapjairol):
NAVY="0x162270"      # szoveg es kitoltott sav
TRACK="0xD9E0F7"     # ures sav
ACCENT="0x68C7F9"    # nem hasznalt jelenleg, tartalek kiemelesnek

W=1240; H=430
SEGW=290; GAP=15; X0=300          # harom szakasz + kozok, a cimke utan kezdodik
BARH=54
Y_FENY=110; Y_ARAM=270
LABELY=$((Y_ARAM + BARH + 26))

seg_x() { echo $(( X0 + ($1 - 1) * (SEGW + GAP) )); }

# Egy sav: harom szakasz, a tartomanyba esok NAVY-val kitoltve, a tobbi TRACK.
bar_filters() {
  local y="$1" lo="$2" hi="$3" out=""
  for i in 1 2 3; do
    local x; x="$(seg_x "$i")"
    local col="$TRACK"
    if [ "$i" -ge "$lo" ] && [ "$i" -le "$hi" ]; then col="$NAVY"; fi
    out="${out}drawbox=x=${x}:y=${y}:w=${SEGW}:h=${BARH}:color=${col}:t=fill,"
  done
  printf '%s' "$out"
}

txt() {
  # txt <text> <x> <y> <size> <color> [align]
  printf 'drawtext=fontfile=%s:text=%s:x=%s:y=%s:fontsize=%s:fontcolor=%s,' \
    "$FONT" "$1" "$2" "$3" "$4" "$5"
}

FILTER=""
FILTER="${FILTER}$(bar_filters "$Y_FENY" "$FL" "$FH")"
FILTER="${FILTER}$(bar_filters "$Y_ARAM" "$AL" "$AH")"
FILTER="${FILTER}$(txt 'FÉNY'     30 "$((Y_FENY + 8))" 44 "$NAVY")"
FILTER="${FILTER}$(txt 'ÁRAMLÁS'  30 "$((Y_ARAM + 8))" 44 "$NAVY")"
# A fokozat-cimkek EGYSZER szerepelnek, a ket sav alatt -- mindkettore vonatkoznak.
FILTER="${FILTER}$(txt 'ALACSONY' "$(seg_x 1)" "$LABELY" 28 "$NAVY")"
FILTER="${FILTER}$(txt 'KÖZEPES'  "$(seg_x 2)" "$LABELY" 28 "$NAVY")"
FILTER="${FILTER}$(txt 'ERŐS'     "$(seg_x 3)" "$LABELY" 28 "$NAVY")"
FILTER="${FILTER%,}"

# A rajzolas OPAK feher vasznon tortenik, es a fehéret a vegen kulcsoljuk ki.
# Ok (mert, 2026-08-16): a `drawbox` egy teljesen atlatszo (alpha=0) RGBA vasznon
# NEM rajzol lathato dobozt -- a szoveg megjelenik, a doboz nem, es a hiba NEM ad
# hibauzenetet, csak egy fel-kesz kep jon ki. Feher alapon + colorkey mukodik.
ffmpeg -y -loglevel error -f lavfi -i "color=c=white:s=${W}x${H}:d=1" \
  -vf "${FILTER},format=rgba,colorkey=white:0.02:0.0" -frames:v 1 "$OUT" \
  || die "az ffmpeg nem tudta eloallitani a kepet"

[ -s "$OUT" ] || die "a kimeneti fajl ures: $OUT"
echo "OK $OUT  (feny ${FL}-${FH}, aramlas ${AL}-${AH})"
