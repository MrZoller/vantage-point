#!/usr/bin/env bash
# usage.sh [days] - summarize per-run usage from state/runs.log (default: last 30 days).
# monitor.sh appends one JSON line per run; this rolls them up so you can tune run
# frequency and --max-turns.
#
# NOTE: cost_usd is an API-EQUIVALENT estimate from the CLI, NOT your actual
# Max-subscription billing - treat it as a relative signal, not a bill.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LOG="state/runs.log"
DAYS="${1:-30}"

case "$DAYS" in
  ''|*[!0-9]*) echo "usage: bin/usage.sh [days]   (days must be a positive integer)" >&2; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || { echo "jq not found - install it (brew install jq / apt install jq)" >&2; exit 1; }
[ -f "$LOG" ] || { echo "no $LOG yet - run bin/monitor.sh first" >&2; exit 0; }

# Read the JSONL as raw text so a crash-truncated row cannot prevent valid rows
# from being rolled up. A run can log multiple pass rows (triage + deepdive);
# count runs from triage/legacy rows only (so deep-dive doesn't inflate the
# count), but sum cost/turns across all rows. Missing fields default to 0.
jq -Rrs --argjson days "$DAYS" '
  split("\n") | map(fromjson? | select(type == "object"))
  |
  (now - ($days * 86400)) as $cutoff
  | map(select((((.timestamp? // "") | fromdateiso8601?) // 0) >= $cutoff)) as $all
  | ($all | map(select((.pass // "triage") == "triage")))                 as $runs
  | "window:  last \($days) days",
    "runs:    \($runs | length)",
    "by mode: " + (if ($runs | length) == 0 then "-"
                   else ($runs | group_by(.mode) | map("\(.[0].mode)=\(length)") | join(", ")) end),
    "passes:  " + (if ($all | length) == 0 then "-"
                   else ($all | group_by(.pass // "triage") | map("\(.[0].pass // "triage")=\(length)") | join(", ")) end),
    "cost:    $\(((((($all | map(.cost_usd // 0) | add) // 0)) * 100) | round) / 100) (API-equivalent estimate)",
    "turns:   \(($all | map(.num_turns // 0) | add) // 0)",
    "tokens:  in \(($all | map(.input_tokens // 0) | add) // 0), out \(($all | map(.output_tokens // 0) | add) // 0), cache-read \(($all | map(.cache_read_input_tokens // 0) | add) // 0)"
' "$LOG"
