#!/usr/bin/env bash
# bootstrap.sh - one-time (and slow-refresh) profile builder.
# Researches subject + anchor from their seeds and writes profile.draft.yaml
# for you to review. It deliberately does NOT touch profile.yaml - approving
# the draft is a human step (the governance gate).
set -euo pipefail

# Project root = parent of this script's bin/ dir.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# launchd/cron run with a minimal PATH; make `claude` reachable.
# (~/.npm-global is where your global npm packages live; /opt/homebrew for Apple Silicon.)
export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Shared helpers (config readers + email rendering/sending), also used by monitor.sh.
# shellcheck source=bin/config-lib.sh
. "$ROOT/bin/config-lib.sh"
# shellcheck source=bin/email-lib.sh
. "$ROOT/bin/email-lib.sh"

CONFIG="monitor-config.yaml"
PROMPT="bootstrap-prompt.md"
DRAFT="profile.draft.yaml"
SUMMARY="profile.draft.summary.md"   # human-readable digest the agent writes alongside

[ -f "$CONFIG" ] || { echo "missing $CONFIG" >&2; exit 1; }
[ -f "$PROMPT" ] || { echo "missing $PROMPT" >&2; exit 1; }

# Config knobs (shared cfg_get; no YAML library). Absent/blank -> empty string.
MODEL="$(cfg_get models bootstrap)"
EDITOR_MODEL="$(cfg_get models editor)"   # optional editorial polish of the summary
EMAIL_TO="$(cfg_get output email_to)"     # optional "draft ready for review" email
SUBJECT_NAME="$(cfg_get_text subject name)"
# Per-pass turn caps (budgets: block) - the cost lever for these claude calls.
# 0/absent/non-numeric -> the long-standing defaults.
BOOTSTRAP_MAX_TURNS="$(cfg_get budgets bootstrap_max_turns)"
EDITOR_MAX_TURNS="$(cfg_get budgets editor_max_turns)"
case "$BOOTSTRAP_MAX_TURNS" in ''|0|*[!0-9]*) BOOTSTRAP_MAX_TURNS=80 ;; esac
case "$EDITOR_MAX_TURNS"    in ''|0|*[!0-9]*) EDITOR_MAX_TURNS=15 ;; esac

# Fall back to the CLI default by omitting --model when the key is absent/blank.
# Print a notice so a typo'd config is visible rather than silently defaulting.
MODEL_ARGS=()
if [ -n "$MODEL" ]; then
  MODEL_ARGS=(--model "$MODEL")
else
  echo "[bootstrap] models.bootstrap not set in $CONFIG - using CLI default model" >&2
fi

# Fold in human calibration grades (thumbs up/down recorded via the review UI) so a
# re-bootstrap learns the user's taste. Optional; absent on a first run.
FEEDBACK="state/feedback.jsonl"
FEEDBACK_NOTE=""
if [ -s "$FEEDBACK" ]; then
  # The log is append-only, so a regrade leaves an older contradictory row. Collapse
  # to the latest verdict per id (skipping malformed lines) so bootstrap sees one
  # label per item. python3 is present wherever feedback exists (the review server is
  # Python); only the pathological both-tools-missing case falls back to the raw log.
  if command -v python3 >/dev/null 2>&1 && [ -f bin/dedupe-feedback.py ]; then
    FEEDBACK_DATA="$(python3 bin/dedupe-feedback.py "$FEEDBACK")"
  else
    FEEDBACK_DATA="$(cat "$FEEDBACK")"
    echo "[bootstrap] WARNING: python3/dedupe-feedback.py unavailable - feeding raw feedback (regrades not deduped)" >&2
  fi
  echo "[bootstrap] including $(printf '%s\n' "$FEEDBACK_DATA" | grep -c .) calibration grade(s) from $FEEDBACK" >&2
  FEEDBACK_NOTE="

Human calibration grades - the user's thumbs up/down on past surfaced items
(\`verdict\`: up = should have been surfaced, down = not relevant). Treat these as
ground truth: tune \`relevance.rubric\` so it would score these correctly, and fold
the clearest cases into \`relevance.calibration\` (relevant / not_relevant) in your draft.
\`\`\`jsonl
$FEEDBACK_DATA
\`\`\`"
fi

echo "[bootstrap] model=${MODEL:-(CLI default)} researching subject + anchor -> $DRAFT"

claude -p "$(cat "$PROMPT")

---
Below is the config you are profiling. Read its subject, anchor, seeds, scope,
and any calibration examples, then research the public web. Write the filled
\`derived\` blocks and \`relevance.rubric\` as valid YAML to ./$DRAFT. Do NOT edit
$CONFIG. Mark low-confidence inferences inline.

ALSO write a short, human-readable Markdown review summary to ./$SUMMARY so a person
can review the draft from their inbox: lead with a one-line bottom line, then the
market map, the key players, the anchor, the scoring-rubric highlights, and a clearly
labelled list of your lowest-confidence inferences to check. Keep it scannable; this
summary is a digest of the draft, not a substitute for it.

\`\`\`yaml
$(cat "$CONFIG")
\`\`\`$FEEDBACK_NOTE" \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
  --disallowedTools "Bash" \
  --permission-mode acceptEdits \
  --max-turns "$BOOTSTRAP_MAX_TURNS" \
  --output-format text \
  2> bootstrap.err

echo
echo "[bootstrap] draft written to $DRAFT"

# ---- optional delivery: email the draft summary as a review aid ----
# Approval stays a deliberate LOCAL step (cp draft -> profile.yaml); this only
# notifies + summarizes. Both the editorial polish and the email are opt-in and
# fail-safe: a failure here never loses the draft, which is already on disk.
if [ -s "$SUMMARY" ]; then
  # Optional editorial polish on the editor model (same models.editor knob as the
  # monitor). Non-destructive: restore the unedited summary on failure/empty.
  if [ -n "$EDITOR_MODEL" ]; then
    echo "[bootstrap] editorial pass on the summary ($EDITOR_MODEL)" >&2
    cp "$SUMMARY" "$SUMMARY.pre-ed"
    if claude -p "You are an editor polishing a PROFILE-DRAFT SUMMARY for a human
reviewer who will decide whether to approve it. Lead with what matters, tighten the
prose, and keep it scannable. Do NOT add facts, invent figures, or drop any
low-confidence / uncertainty flag - faithfulness to the draft beats polish. Edit
./$SUMMARY in place and keep it valid Markdown." \
        --model "$EDITOR_MODEL" \
        --allowedTools "Read,Write,Edit" \
        --disallowedTools "Bash,WebSearch,WebFetch" \
        --permission-mode acceptEdits \
        --max-turns "$EDITOR_MAX_TURNS" \
        --output-format text \
        2>> bootstrap.err && [ -s "$SUMMARY" ]; then
      rm -f "$SUMMARY.pre-ed"
      echo "[bootstrap] editorial pass complete" >&2
    else
      mv -f "$SUMMARY.pre-ed" "$SUMMARY"
      echo "[bootstrap] WARNING: editorial pass failed/emptied the summary - kept the unedited one" >&2
    fi
  fi
  # Email the summary when output.email_to is set.
  if [ -n "$EMAIL_TO" ]; then
    if command -v msmtp >/dev/null 2>&1; then
      DELIVER="$(mktemp)"
      cat "$SUMMARY" > "$DELIVER"
      # shellcheck disable=SC2016  # backticks are literal Markdown; %s are printf placeholders
      printf '\n\n---\n\n**To approve:** review `%s`, edit if needed, then run `cp %s profile.yaml` on the host. Nothing is monitored until you do.\n' \
        "$DRAFT" "$DRAFT" >> "$DELIVER"
      VP_TITLE="${SUBJECT_NAME:-Market intelligence}"
      VP_SUBTITLE="Profile draft ready for review"
      VP_PREHEADER="$(email_preheader "$DELIVER")"
      VP_FOOTER="Generated by Vantage Point (bootstrap)"
      if send_email "$EMAIL_TO" "[Vantage Point: ${SUBJECT_NAME:-draft}] profile draft ready for review" "$DELIVER"; then
        echo "[bootstrap] emailed the draft summary to $EMAIL_TO"
      else
        echo "[bootstrap] WARNING: msmtp failed - draft is still in $DRAFT / $SUMMARY" >&2
      fi
      rm -f "$DELIVER"
    else
      echo "[bootstrap] output.email_to set but msmtp not found - skipping email (draft in $DRAFT)" >&2
    fi
  fi
else
  echo "[bootstrap] note: no $SUMMARY written - skipping email summary" >&2
fi

echo "[bootstrap] Review it, edit as needed, then APPROVE with:"
echo "             cp $DRAFT profile.yaml"
# Optional: copy the digest too so the portal's Profile tab shows it for the approved
# profile (it renders profile.summary.md like the bootstrap email; YAML stays the source).
[ -f "$SUMMARY" ] && echo "             cp $SUMMARY profile.summary.md   # optional: nicer Profile tab"
