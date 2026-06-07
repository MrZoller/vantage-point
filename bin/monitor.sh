#!/usr/bin/env bash
# monitor.sh {daily|weekly} — the recurring agent.
# Sweeps sources, dedups against state, scores against the APPROVED profile,
# writes the report to kb/, and (optionally) delivers it.
set -euo pipefail

MODE="${1:-daily}"
case "$MODE" in
  daily|weekly) ;;
  *) echo "usage: monitor.sh {daily|weekly}" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

CONFIG="monitor-config.yaml"
PROFILE="profile.yaml"
PROMPT="monitor-prompt.md"
TODAY="$(date +%F)"
REPORT="kb/${TODAY}.${MODE}.md"
# This run writes here; we promote it to $REPORT only after claude exits 0, so a
# transient failure on a same-day rerun can't destroy an earlier good report.
RUN_REPORT="kb/.${TODAY}.${MODE}.partial.md"

# The review gate, enforced in code: refuse to run on an unapproved profile.
[ -f "$PROFILE" ] || {
  echo "no approved $PROFILE — run bin/bootstrap.sh and approve the draft first" >&2
  exit 1
}

mkdir -p state kb
touch state/seen.jsonl

# Read models.monitor from the live config with a dependency-light parse (no
# YAML library). awk walks the `models:` block and pulls the one key, stripping
# any inline comment and quotes. No match -> empty string (never aborts under
# set -e, since this is an assignment).
MODEL="$(awk '
  $0 ~ /^models:[[:space:]]*(#.*)?$/ { inblk=1; next }
  inblk && /^[^[:space:]#]/         { inblk=0 }
  inblk && $1 == "monitor:" {
    line=$0
    sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  monitor: "
    sub(/[[:space:]]*#.*$/, "", line)                  # drop trailing comment
    gsub(/[[:space:]]/, "", line)                      # drop surrounding space
    gsub(/["\047]/, "", line)                          # drop quotes
    print line; exit
  }
' "$CONFIG")"

# Fall back to the CLI default by omitting --model when the key is absent/blank.
# Print a notice so a typo'd config is visible rather than silently defaulting.
MODEL_ARGS=()
if [ -n "$MODEL" ]; then
  MODEL_ARGS=(--model "$MODEL")
else
  echo "[monitor:$MODE] models.monitor not set in $CONFIG — using CLI default model" >&2
fi

# Read output.email_to the same dependency-light way. Blank/absent -> empty
# string, which the delivery step below treats as "don't email".
EMAIL_TO="$(awk '
  $0 ~ /^output:[[:space:]]*(#.*)?$/ { inblk=1; next }
  inblk && /^[^[:space:]#]/          { inblk=0 }
  inblk && $1 == "email_to:" {
    line=$0
    sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  email_to: "
    sub(/[[:space:]]*#.*$/, "", line)                  # drop trailing comment
    gsub(/[[:space:]]/, "", line)                      # drop surrounding space
    gsub(/["\047]/, "", line)                          # drop quotes
    print line; exit
  }
' "$CONFIG")"

echo "[monitor:$MODE] model=${MODEL:-(CLI default)} $TODAY -> $REPORT"

# Clear only this run's scratch file (a leftover from an aborted earlier run).
# $REPORT itself is left untouched until claude succeeds.
rm -f "$RUN_REPORT"

# --output-format json so we can log per-run usage below. The agent still writes
# the report to $RUN_REPORT via the Write tool, so empty detection stays file-based
# (the JSON envelope goes to stdout, which we capture instead of the report text).
RUN_JSON="$(claude -p "$(cat "$PROMPT")

---
RUN MODE: $MODE
TODAY: $TODAY

Config (subject, anchor, seeds, scope, cadence, thresholds, output, governance):
\`\`\`yaml
$(cat "$CONFIG")
\`\`\`

Approved profile — YOUR GROUND TRUTH (derived blocks + relevance rubric):
\`\`\`yaml
$(cat "$PROFILE")
\`\`\`

Your state file is ./state/seen.jsonl. Append every newly-evaluated item (full
record for surfaced items, keys+score for dropped ones) so nothing is re-scored.
Write the $MODE report to ./$RUN_REPORT, following the report rules in the prompt
above — including the show_borderline / 'Considered (below threshold)' handling.
For a daily run, if those rules produce no report at all, write NOTHING to the
report file and print exactly NO_MATERIAL_ITEMS." \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
  --disallowedTools "Bash" \
  --permission-mode acceptEdits \
  --max-turns 40 \
  --output-format json \
  2> "kb/${TODAY}.${MODE}.err")"

# claude exited 0 (set -e would have aborted otherwise).
# ---- log per-run usage to state/runs.log ----
# NOTE: total_cost_usd from the CLI is an API-EQUIVALENT estimate. These runs
# authenticate against the Max subscription, so this is NOT your actual billing —
# it's a relative cost/usage signal for tuning run frequency and --max-turns.
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$RUN_JSON" | jq -c \
    --arg ts "$(date -u +%FT%TZ)" --arg mode "$MODE" --arg date "$TODAY" \
    '{timestamp:$ts, mode:$mode, date:$date,
      num_turns:.num_turns, duration_ms:.duration_ms, cost_usd:.total_cost_usd,
      input_tokens:.usage.input_tokens, output_tokens:.usage.output_tokens,
      cache_read_input_tokens:.usage.cache_read_input_tokens,
      cache_creation_input_tokens:.usage.cache_creation_input_tokens,
      session_id:.session_id}' >> state/runs.log \
    || echo "[monitor:$MODE] WARNING: could not parse run JSON; usage not logged" >&2
else
  echo "[monitor:$MODE] ERROR: jq not found — usage not logged. Install jq (brew install jq / apt install jq)." >&2
fi

# Promote this run's output to $REPORT only now — so a failed rerun never clobbers
# an earlier report.
# ---- deliver: plug in whatever channel you want ----
if [ -s "$RUN_REPORT" ]; then
  mv -f "$RUN_REPORT" "$REPORT"
  echo "[monitor:$MODE] report ready: $REPORT"
  # Email via msmtp when output.email_to is set (configure ~/.msmtprc — see README).
  # Failure to send never fails the run: the report is already safe in $REPORT.
  if [ -n "$EMAIL_TO" ]; then
    if command -v msmtp >/dev/null 2>&1; then
      if { printf 'Subject: [market-monitor] %s %s\n\n' "$MODE" "$TODAY"; cat "$REPORT"; } \
           | msmtp "$EMAIL_TO"; then
        echo "[monitor:$MODE] emailed report to $EMAIL_TO"
      else
        echo "[monitor:$MODE] WARNING: msmtp failed — report still in $REPORT" >&2
      fi
    else
      echo "[monitor:$MODE] output.email_to set but msmtp not found — skipping email (report in $REPORT)" >&2
    fi
  fi
  #
  # ...or push to Claude Code Channels / Telegram / Slack, or just read it from kb/.
else
  # Nothing material this run. Drop the empty scratch file; leave any existing
  # $REPORT from an earlier successful run today in place.
  rm -f "$RUN_REPORT"
  echo "[monitor:$MODE] nothing material — no report written (silence is correct)."
fi
