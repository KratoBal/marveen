#!/usr/bin/env bash
# text-metrics.sh -- character/word counts for text fields, without giving an agent a shell.
#
# WHY: the strict profiles (marketer, researcher) give no python3, no jq and no awk. An agent
# writing SEO fields still has to check hard limits (meta title <= 60, meta description <= 155),
# so it reaches for `awk`/heredoc pipelines -- which the permission checker cannot analyse
# statically ("Parser skipped input between top-level statements"), and the agent stalls on an
# approval prompt mid-task (observed on the polip agent, 2026-08-15).
#
# This helper takes a FILE PATH (never a shell snippet) and reports per-line metrics. The agent
# already has Write access to its own directory, so the flow is: write the candidate fields to a
# file, then measure it.
#
# Usage:
#   bash scripts/text-metrics.sh <file>                 # per-line: number, char count, text
#   bash scripts/text-metrics.sh <file> <limit>         # same + OK/OVER against <limit>
#   bash scripts/text-metrics.sh --seo <file>           # odd lines vs 60 (title), even vs 155 (desc)
#   bash scripts/text-metrics.sh --count <file> <text>  # how many lines contain <text>, and how many times in total
#   bash scripts/text-metrics.sh --rows <file>          # markdown table stats: data rows, separators, headers
#
# The --count and --rows modes exist for the same reason as the rest of this script: a report must
# never contain a number the agent guessed. Counting placeholders ("KITÖLTENDŐ") or field rows used
# to require `grep | wc -l`, and a pipeline is exactly what the permission checker cannot analyse.
# Pass a file path and a plain substring instead -- no pipes, no quoting traps (polip, 2026-08-15).
#
# Character counts are UTF-8 aware (á, é, ő, ű count as one), which matters for Hungarian copy.
# Output is plain text; exit 1 only on a usage/IO error, never on an OVER-limit line.
set -uo pipefail

MODE="lines"
case "${1-}" in
  --seo)   MODE="seo";   shift ;;
  --count) MODE="count"; shift ;;
  --rows)  MODE="rows";  shift ;;
esac

FILE="${1:?usage: text-metrics.sh [--seo|--count|--rows] <file> [limit|text]}"
LIMIT="${2-}"

[ -r "$FILE" ] || { echo "FAIL: cannot read file: $FILE"; exit 1; }

# LC_ALL with a UTF-8 locale makes ${#line} count characters, not bytes.
export LC_ALL="${LC_ALL:-C.UTF-8}"

# --count: substring occurrences. Reported two ways, because they answer different questions:
# "how many rows are still open" (lines) vs "how many placeholders are left" (total).
if [ "$MODE" = "count" ]; then
  PAT="${2-}"
  [ -n "$PAT" ] || { echo "FAIL: --count needs a search text: text-metrics.sh --count <file> <text>"; exit 1; }
  plen=${#PAT}
  lines=0; hits=0; total=0
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines+1))
    stripped="${line//"$PAT"/}"
    # Each removed occurrence shortens the line by exactly the pattern length.
    n=$(( (${#line} - ${#stripped}) / plen ))
    if [ "$n" -gt 0 ]; then hits=$((hits+1)); total=$((total+n)); fi
  done < "$FILE"
  echo "fajl: $FILE"
  echo "minta: $PAT"
  echo "talalt sor: $hits / $lines"
  echo "osszes elofordulas: $total"
  exit 0
fi

# --rows: markdown table geometry. A separator row (|---|---|) and the header above it are not data,
# so a raw "count the lines starting with |" overstates the field count by 2 per table block.
if [ "$MODE" = "rows" ]; then
  pipes=0; seps=0; hdrs=0; prev_pipe=0
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      \|*)
        pipes=$((pipes+1))
        # Separator = only pipes, dashes, colons and spaces.
        case "$trimmed" in
          *[!\|\ :-]*) is_sep=0 ;;
          *) is_sep=1 ;;
        esac
        if [ "$is_sep" -eq 1 ]; then
          seps=$((seps+1))
          [ "$prev_pipe" -eq 1 ] && hdrs=$((hdrs+1))
        fi
        prev_pipe=1
        ;;
      *) prev_pipe=0 ;;
    esac
  done < "$FILE"
  echo "fajl: $FILE"
  echo "tablazat-sor osszesen: $pipes"
  echo "elvalaszto: $seps"
  echo "fejlec: $hdrs"
  echo "adatsor: $((pipes - seps - hdrs))"
  exit 0
fi

n=0
over=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n+1))
  len=${#line}
  case "$MODE" in
    seo)
      # Convention: odd line = meta title (60), even line = meta description (155).
      if [ $((n % 2)) -eq 1 ]; then lim=60; kind="title"; else lim=155; kind="desc "; fi
      if [ "$len" -le "$lim" ]; then st="OK  "; else st="OVER"; over=$((over+1)); fi
      printf '%3d %s %s %3d/%3d  %s\n' "$n" "$kind" "$st" "$len" "$lim" "$line"
      ;;
    *)
      if [ -n "$LIMIT" ]; then
        if [ "$len" -le "$LIMIT" ]; then st="OK  "; else st="OVER"; over=$((over+1)); fi
        printf '%3d %s %3d/%3d  %s\n' "$n" "$st" "$len" "$LIMIT" "$line"
      else
        printf '%3d %3d  %s\n' "$n" "$len" "$line"
      fi
      ;;
  esac
done < "$FILE"

echo "---"
echo "sorok: $n"
[ "$MODE" = "seo" ] || [ -n "$LIMIT" ] && echo "limit felett: $over"
exit 0
