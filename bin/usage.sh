#!/usr/bin/env bash
# usage.sh [days] — summarize per-run usage from state/runs.log (default: last 30 days).
# monitor.sh appends one JSON line per run; this rolls them up so you can tune run
# frequency and --max-turns.
#
# NOTE: cost_usd is an API-EQUIVALENT estimate from the CLI, NOT your actual
# Max-subscription billing — treat it as a relative signal, not a bill.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOG="state/runs.log"
DAYS="${1:-30}"

case "$DAYS" in
  ''|*[!0-9]*) echo "usage: bin/usage.sh [days]   (days must be a positive integer)" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "jq not found — install it (brew install jq / apt install jq)" >&2; exit 1; }
[ -f "$LOG" ] || { echo "no $LOG yet — run bin/monitor.sh first" >&2; exit 0; }

# Slurp the log, keep runs within the window, and total the usage fields. Missing
# fields default to 0 so a partial line never breaks the rollup.
jq -rs --argjson days "$DAYS" '
  (now - ($days * 86400)) as $cutoff
  | map(select((.timestamp | fromdateiso8601) >= $cutoff))
  | "window:  last \($days) days",
    "runs:    \(length)",
    "by mode: " + ((group_by(.mode) | map("\(.[0].mode)=\(length)") | join(", ")) // "—"),
    "cost:    $\(((map(.cost_usd // 0) | add) * 100 | round) / 100) (API-equivalent estimate)",
    "turns:   \(map(.num_turns // 0) | add)",
    "tokens:  in \(map(.input_tokens // 0) | add), out \(map(.output_tokens // 0) | add), cache-read \(map(.cache_read_input_tokens // 0) | add)"
' "$LOG"
