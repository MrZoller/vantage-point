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

# The review gate, enforced in code: refuse to run on an unapproved profile.
[ -f "$PROFILE" ] || {
  echo "no approved $PROFILE — run bin/bootstrap.sh and approve the draft first" >&2
  exit 1
}

mkdir -p state kb
touch state/seen.jsonl

echo "[monitor:$MODE] $TODAY -> $REPORT"

# Clear any stale report from an earlier run today, so the empty-run check below
# ([ -s "$REPORT" ]) reflects THIS run — not a leftover file.
rm -f "$REPORT"

claude -p "$(cat "$PROMPT")

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
Write the $MODE report to ./$REPORT. If MODE is daily and nothing clears the
threshold, write NOTHING to the report file and print exactly NO_MATERIAL_ITEMS." \
  --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
  --permission-mode acceptEdits \
  --max-turns 40 \
  --output-format text \
  2> "kb/${TODAY}.${MODE}.err"

# ---- deliver: plug in whatever channel you want ----
if [ -s "$REPORT" ]; then
  echo "[monitor:$MODE] report ready: $REPORT"
  # Email via msmtp (configure ~/.msmtprc against Google Workspace SMTP):
  # { printf 'Subject: [market-monitor] %s %s\n\n' "$MODE" "$TODAY"; cat "$REPORT"; } \
  #   | msmtp "you@zoller.ai"
  #
  # ...or push to Claude Code Channels / Telegram / Slack, or just read it from kb/.
else
  echo "[monitor:$MODE] nothing material — no report written (silence is correct)."
fi
