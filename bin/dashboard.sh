#!/usr/bin/env bash
# dashboard.sh -- regenerate kb/index.html: a browsable snapshot of the accumulated
# intelligence. Shows each tracked entity's latest metric with a sparkline of recent
# values, the most recent events, and links to recent reports. Reads
# state/observations.jsonl and kb/. Safe to run anytime; monitor.sh also calls it
# after each report. Needs jq; no-op (with a notice) otherwise.
#
# This file is deliberately pure ASCII (the sparkline block glyphs are built from
# their UTF-8 bytes at runtime) so it renders in git diffs and works on bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OBS="state/observations.jsonl"
OUT="kb/index.html"
mkdir -p kb

command -v jq >/dev/null 2>&1 || { echo "[dashboard] jq not found - skipping $OUT" >&2; exit 0; }

# Unicode sparkline from numeric args. awk scales (handles floats) and emits 0..7
# indices; bash maps them to block glyphs U+2581..U+2588, built from their UTF-8
# bytes (E2 96 81 .. E2 96 88) so the source stays ASCII.
spark() {
  local levels=() out="" idxs i pre
  pre="$(printf '\342\226')"                       # leading 2 bytes of U+258x
  for i in 201 202 203 204 205 206 207 210; do     # octal of the 3rd byte (0x81..0x88)
    levels+=("$pre$(printf '%b' "\\0$i")")
  done
  idxs="$(awk -v vals="$*" 'BEGIN{
    n=split(vals,a," "); if(n==0)exit;
    lo=a[1]; hi=a[1];
    for(i=1;i<=n;i++){ if(a[i]<lo)lo=a[i]; if(a[i]>hi)hi=a[i] }
    rng=hi-lo;
    for(i=1;i<=n;i++){ printf "%d ", (rng==0?0:int((a[i]-lo)/rng*7+0.5)) }
  }')"
  read -ra idxa <<<"$idxs"
  for i in ${idxa[@]+"${idxa[@]}"}; do out+="${levels[$i]}"; done
  printf '%s' "$out"
}

esc() {  # minimal HTML escaping for text we inject
  local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"
}

# ---- build the page ----
{
  cat <<'HTML_HEAD'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>market-monitor</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         line-height: 1.5; color: #1a1a1a; max-width: 820px; margin: 0 auto; padding: 24px; }
  h1 { font-size: 1.5em; margin: 0 0 0.2em; } h2 { font-size: 1.15em; margin: 1.6em 0 0.4em; }
  .meta { color: #777; font-size: 0.9em; margin-bottom: 1em; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border-bottom: 1px solid #eee; padding: 6px 10px; text-align: left; vertical-align: top; }
  th { color: #555; font-weight: 600; font-size: 0.85em; text-transform: uppercase; letter-spacing: 0.03em; }
  .spark { font-size: 1.1em; letter-spacing: 1px; color: #0b66c3; }
  .num { font-variant-numeric: tabular-nums; }
  .muted { color: #999; }
  ul { padding-left: 1.2em; } li { margin: 0.2em 0; }
  a { color: #0b66c3; }
</style>
</head>
<body>
HTML_HEAD

  printf '<h1>market-monitor</h1>\n'
  printf '<div class="meta">generated %s</div>\n' "$(esc "$(date '+%Y-%m-%d %H:%M %Z')")"

  # ---- tracked entities (numeric metrics) ----
  printf '<h2>Tracked entities</h2>\n'
  rows="$(jq -rRn '
    [ inputs | fromjson? ]                       # skip a malformed line, keep the rest
    | map(select(.metric != "event" and (.value | type == "number")))
    | group_by(.entity + "\t" + .metric)
    | map(sort_by(.timestamp)
          | { entity: .[0].entity, metric: .[0].metric, unit: (.[-1].unit // ""),
              latest: .[-1].value, last_ts: .[-1].timestamp,
              series: (map(.value) | .[-30:] | map(tostring) | join(" ")) })
    | sort_by(.entity)
    | .[] | [.entity, .metric, (.latest|tostring), .unit, (.last_ts[0:10]), .series] | @tsv
  ' "$OBS" 2>/dev/null || true)"
  if [ -n "$rows" ]; then
    printf '<table>\n<tr><th>Entity</th><th>Metric</th><th>Latest</th><th>Recent</th><th>As of</th></tr>\n'
    while IFS=$'\t' read -r entity metric latest unit last_ts series; do
      [ -n "$entity" ] || continue
      printf '<tr><td>%s</td><td>%s</td><td class="num">%s %s</td><td class="spark">%s</td><td class="muted">%s</td></tr>\n' \
        "$(esc "$entity")" "$(esc "$metric")" "$(esc "$latest")" "$(esc "$unit")" "$(spark "$series")" "$(esc "$last_ts")"
    done <<<"$rows"
    printf '</table>\n'
  else
    printf '<p class="muted">No numeric observations yet - they accumulate as the monitor runs.</p>\n'
  fi

  # ---- recent events ----
  events="$(jq -rRn '
    [ inputs | fromjson? ]                       # skip a malformed line, keep the rest
    | map(select(.metric == "event"))
    | sort_by(.timestamp) | reverse | .[0:12]
    | .[] | [(.timestamp[0:10]), .entity, (.event_type // "event"),
             (.note // (.value | strings) // "")] | @tsv
  ' "$OBS" 2>/dev/null || true)"
  if [ -n "$events" ]; then
    printf '<h2>Recent events</h2>\n<ul>\n'
    while IFS=$'\t' read -r ts entity etype note; do
      [ -n "$ts" ] || continue
      printf '<li class="muted">%s</li>\n' "$(esc "$ts | $entity | $etype: $note")"
    done <<<"$events"
    printf '</ul>\n'
  fi

  # ---- recent reports ---- (date-prefixed names, so reverse lexical = newest first)
  printf '<h2>Recent reports</h2>\n'
  shopt -s nullglob
  report_files=(kb/*.daily.md kb/*.weekly.md)
  shopt -u nullglob
  reports=""
  if [ ${#report_files[@]} -gt 0 ]; then
    reports="$(printf '%s\n' "${report_files[@]}" | sort -r | head -n 14)"
  fi
  if [ -n "$reports" ]; then
    printf '<ul>\n'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '<li><a href="%s">%s</a></li>\n' "$(esc "$(basename "$f")")" "$(esc "$(basename "$f")")"
    done <<<"$reports"
    printf '</ul>\n'
  else
    printf '<p class="muted">No reports yet.</p>\n'
  fi

  cat <<'HTML_FOOT'
</body>
</html>
HTML_FOOT
} > "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT"

echo "[dashboard] wrote $OUT"
