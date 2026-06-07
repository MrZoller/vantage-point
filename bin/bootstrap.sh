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

# Read models.bootstrap from the live config with a dependency-light parse (no
# YAML library). awk walks the `models:` block and pulls the one key, stripping
# any inline comment and quotes. No match -> empty string (never aborts under
# set -e, since this is an assignment).
MODEL="$(awk '
  $0 ~ /^models:[[:space:]]*(#.*)?$/ { inblk=1; next }
  inblk && /^[^[:space:]#]/         { inblk=0 }
  inblk && $1 == "bootstrap:" {
    line=$0
    sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  bootstrap: "
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
  echo "[bootstrap] models.bootstrap not set in $CONFIG — using CLI default model" >&2
fi

echo "[bootstrap] model=${MODEL:-(CLI default)} researching subject + anchor -> $DRAFT"

claude -p "$(cat "$PROMPT")

---
Below is the config you are profiling. Read its subject, anchor, seeds, scope,
and any calibration examples, then research the public web. Write the filled
\`derived\` blocks and \`relevance.rubric\` as valid YAML to ./$DRAFT — and ONLY
to that file. Do NOT edit $CONFIG. Mark low-confidence inferences inline.

\`\`\`yaml
$(cat "$CONFIG")
\`\`\`" \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
  --disallowedTools "Bash" \
  --permission-mode acceptEdits \
  --max-turns 80 \
  --output-format text \
  2> bootstrap.err

echo
echo "[bootstrap] draft written to $DRAFT"
echo "[bootstrap] Review it, edit as needed, then APPROVE with:"
echo "             cp $DRAFT profile.yaml"
