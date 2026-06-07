#!/usr/bin/env bash
# bootstrap.sh — one-time (and slow-refresh) profile builder.
# Researches subject + anchor from their seeds and writes profile.draft.yaml
# for you to review. It deliberately does NOT touch profile.yaml — approving
# the draft is a human step (the governance gate).
set -euo pipefail

# Project root = parent of this script's bin/ dir.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# launchd/cron run with a minimal PATH; make `claude` reachable.
# (~/.npm-global is where your global npm packages live; /opt/homebrew for Apple Silicon.)
export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

CONFIG="monitor-config.yaml"
PROMPT="bootstrap-prompt.md"
DRAFT="profile.draft.yaml"

[ -f "$CONFIG" ] || { echo "missing $CONFIG" >&2; exit 1; }
[ -f "$PROMPT" ] || { echo "missing $PROMPT" >&2; exit 1; }

echo "[bootstrap] researching subject + anchor -> $DRAFT"

claude -p "$(cat "$PROMPT")

---
Below is the config you are profiling. Read its subject, anchor, seeds, scope,
and any calibration examples, then research the public web. Write the filled
\`derived\` blocks and \`relevance.rubric\` as valid YAML to ./$DRAFT — and ONLY
to that file. Do NOT edit $CONFIG. Mark low-confidence inferences inline.

\`\`\`yaml
$(cat "$CONFIG")
\`\`\`" \
  --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
  --permission-mode acceptEdits \
  --max-turns 80 \
  --output-format text \
  2> bootstrap.err

echo
echo "[bootstrap] draft written to $DRAFT"
echo "[bootstrap] Review it, edit as needed, then APPROVE with:"
echo "             cp $DRAFT profile.yaml"
