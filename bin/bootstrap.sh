#!/usr/bin/env bash
# bootstrap.sh - one-time (and slow-refresh) profile builder.
# Researches subject + anchor from their seeds and writes profile.draft.yaml
# for you to review. It deliberately does NOT touch profile.yaml - approving
# the draft is a human step (the governance gate).
set -euo pipefail

# Optional flags. --resume keeps any state/.research notes from an interrupted deep-
# research run and redoes only the missing facets (these runs are long + expensive);
# without it the scratch dir is cleared at start (stale-run hygiene).
RESUME=""
for _arg in "$@"; do
  case "$_arg" in
    --resume) RESUME=1 ;;
    *) echo "bootstrap.sh: unknown argument '$_arg' (only --resume)" >&2; exit 2 ;;
  esac
done

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
BACKTEST_PROMPT="backtest-prompt.md"   # optional rubric backtest at the refresh gate
PROFILE="profile.yaml"               # the currently-approved profile (absent on a first run)
DRAFT="profile.draft.yaml"
SUMMARY="profile.draft.summary.md"   # human-readable digest the agent writes alongside
DIFF_FILE="profile.draft.diff"       # on a refresh: what the draft changes vs the approved profile

[ -f "$CONFIG" ] || { echo "missing $CONFIG" >&2; exit 1; }
[ -f "$PROMPT" ] || { echo "missing $PROMPT" >&2; exit 1; }

# One clean stderr log per run; every pass below appends to it.
: > bootstrap.err

# Config knobs (shared cfg_get; no YAML library). Absent/blank -> empty string.
MODEL="$(cfg_get models bootstrap)"
EDITOR_MODEL="$(cfg_get models editor)"   # optional editorial polish of the summary
EMAIL_TO=()                               # optional "draft ready for review" email(s)
while IFS= read -r _addr; do              # output.email_to: scalar OR a YAML list
  [ -n "$_addr" ] && EMAIL_TO+=("$_addr")
done < <(cfg_get_list output email_to)
EMAIL_IMAGES="$(cfg_get_bool output email_images 0)"   # embed the logo in email headers; default off
LOGO_ASSET="$ROOT/assets/logo-email.png"               # brand logo used when EMAIL_IMAGES is on
SUBJECT_NAME="$(cfg_get_text subject name)"
# Per-pass turn caps (budgets: block) - the cost lever for these claude calls.
# 0/absent/non-numeric -> the long-standing defaults.
BOOTSTRAP_MAX_TURNS="$(cfg_get budgets bootstrap_max_turns)"
EDITOR_MAX_TURNS="$(cfg_get budgets editor_max_turns)"
BACKTEST_MAX_TURNS="$(cfg_get budgets backtest_max_turns)"     # rubric-backtest scoring pass
case "$BOOTSTRAP_MAX_TURNS" in ''|0|*[!0-9]*) BOOTSTRAP_MAX_TURNS=80 ;; esac
case "$EDITOR_MAX_TURNS"    in ''|0|*[!0-9]*) EDITOR_MAX_TURNS=15 ;; esac
case "$BACKTEST_MAX_TURNS"  in ''|0|*[!0-9]*) BACKTEST_MAX_TURNS=30 ;; esac
# How many newest graded items to replay under the draft rubric; 0 disables the
# backtest. Passed through to backtest.py prepare, which also enforces the 10-grade
# floor. Absent/blank -> the helper's own default (60).
BACKTEST_MAX_ITEMS="$(cfg_get relevance backtest_max_items)"
case "$BACKTEST_MAX_ITEMS" in *[!0-9]*) BACKTEST_MAX_ITEMS=60 ;; '') BACKTEST_MAX_ITEMS=60 ;; esac

# Model for the backtest scoring pass: the MONITOR model, because production scoring
# happens there -- backtesting on the bootstrap model would validate a rubric the
# production scorer may read differently. Fall back to the CLI default (omit --model).
BACKTEST_MODEL="$(cfg_get models monitor)"
BT_MODEL_ARGS=()
[ -n "$BACKTEST_MODEL" ] && BT_MODEL_ARGS=(--model "$BACKTEST_MODEL")

# ---- deep-research pipeline (models.researcher; the opt-in) ----
# Set models.researcher and the single linear research pass becomes Deep-Research-
# shaped: a PLAN pass writes a facet list, parallel FACET passes (on this model) write
# cited notes with fresh contexts, then the synthesis pass below (today's bootstrap
# prompt) builds the draft FROM those notes. Unset = today's single pass, byte-for-byte
# (the same guarantee models.deepdive gives the monitor). models.challenge is
# independent: it attacks any draft, so it works in single-pass mode too.
RESEARCHER_MODEL="$(cfg_get models researcher)"   # unset -> single-pass bootstrap
CHALLENGE_MODEL="$(cfg_get models challenge)"      # unset -> no adversarial pass
RESEARCH_PLAN_PROMPT="research-plan-prompt.md"
RESEARCH_FACET_PROMPT="research-facet-prompt.md"
RESEARCH_CHALLENGE_PROMPT="research-challenge-prompt.md"
RESEARCH_DIR="state/.research"
PLAN_JSON="$RESEARCH_DIR/plan.json"
NOTES_DIR="$RESEARCH_DIR/notes"
CHALLENGE_MD="profile.draft.challenge.md"   # adversarial verification report
FEEDCHECK_MD="profile.draft.feedcheck.md"   # deterministic draft-feed verification

# Per-pass caps for the pipeline (budgets: block; absent/0/non-numeric -> defaults).
PLAN_MAX_TURNS="$(cfg_get budgets plan_max_turns)"
FACET_MAX_TURNS="$(cfg_get budgets facet_max_turns)"
RESEARCH_MAX_FACETS="$(cfg_get budgets research_max_facets)"
RESEARCH_PARALLEL="$(cfg_get budgets research_parallel)"
CHALLENGE_MAX_TURNS="$(cfg_get budgets challenge_max_turns)"
FACET_TIMEOUT="$(cfg_get budgets facet_timeout_seconds)"   # per-facet wall-clock bound
case "$PLAN_MAX_TURNS"      in ''|0|*[!0-9]*) PLAN_MAX_TURNS=15 ;; esac
case "$FACET_MAX_TURNS"     in ''|0|*[!0-9]*) FACET_MAX_TURNS=25 ;; esac
case "$RESEARCH_MAX_FACETS" in ''|0|*[!0-9]*) RESEARCH_MAX_FACETS=6 ;; esac
case "$RESEARCH_PARALLEL"   in ''|0|*[!0-9]*) RESEARCH_PARALLEL=3 ;; esac
case "$CHALLENGE_MAX_TURNS" in ''|0|*[!0-9]*) CHALLENGE_MAX_TURNS=30 ;; esac
case "$FACET_TIMEOUT"       in ''|*[!0-9]*)   FACET_TIMEOUT=1200 ;; esac   # 0 = no bound

# Extended thinking for the judgment-heavy passes (plan/synthesis/challenge). Exported
# per-call as MAX_THINKING_TOKENS so it never leaks onto the facet/editor/backtest
# passes. Absent/non-numeric -> the CLI default (no override).
THINKING_TOKENS="$(cfg_get budgets thinking_tokens)"
case "$THINKING_TOKENS" in *[!0-9]*) THINKING_TOKENS="" ;; esac
THINK_ENV=()
[ -n "$THINKING_TOKENS" ] && THINK_ENV=(env "MAX_THINKING_TOKENS=$THINKING_TOKENS")

RESEARCHER_MODEL_ARGS=()
[ -n "$RESEARCHER_MODEL" ] && RESEARCHER_MODEL_ARGS=(--model "$RESEARCHER_MODEL")
CHALLENGE_MODEL_ARGS=()
[ -n "$CHALLENGE_MODEL" ] && CHALLENGE_MODEL_ARGS=(--model "$CHALLENGE_MODEL")

# Per-facet wall-clock bound (the monitor's TIMEOUT_CMD pattern): a stuck facet must
# not hang the whole run. 0 or no timeout/gtimeout binary -> facets run turn-bounded
# only (the monitor's stance), with a one-line note.
FACET_TIMEOUT_CMD=()
if [ "$FACET_TIMEOUT" != 0 ] && [ -n "$RESEARCHER_MODEL" ]; then
  if   command -v timeout  >/dev/null 2>&1; then FACET_TIMEOUT_CMD=(timeout  "$FACET_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then FACET_TIMEOUT_CMD=(gtimeout "$FACET_TIMEOUT")
  else echo "[bootstrap] note: no timeout/gtimeout - facets are turn-bounded only (brew install coreutils)" >&2
  fi
fi

# Per-pass usage accounting (the pipeline is a 4-10x bootstrap, so its spend must be
# visible). Mirrors the monitor's log_usage: one JSON row per pass to state/runs.log,
# so the soft monthly budget + bin/usage.sh see bootstrap spend automatically. jq
# missing -> a note, never a failed run.
log_usage() {  # <pass-label> <run-json>
  command -v jq >/dev/null 2>&1 || {
    echo "[bootstrap] note: jq not found - usage not logged ($1)" >&2; return 0; }
  mkdir -p state
  printf '%s' "$2" | jq -c \
    --arg ts "$(date -u +%FT%TZ)" --arg mode bootstrap --arg date "$(date +%F)" --arg pass "$1" \
    '{timestamp:$ts, mode:$mode, date:$date, pass:$pass,
      num_turns:.num_turns, duration_ms:.duration_ms, cost_usd:.total_cost_usd,
      input_tokens:.usage.input_tokens, output_tokens:.usage.output_tokens,
      cache_read_input_tokens:.usage.cache_read_input_tokens,
      cache_creation_input_tokens:.usage.cache_creation_input_tokens,
      session_id:.session_id}' >> state/runs.log \
    || echo "[bootstrap] WARNING: could not parse run JSON ($1); usage not logged" >&2
}

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

Human calibration grades - the user's verdicts on past output (\`verdict\`: up =
should have been surfaced, down = not relevant, missed = a relevant item the monitor
NEVER surfaced; the user reported its URL). Treat these as ground truth: tune
\`relevance.rubric\` so it would score these correctly, and fold the clearest cases
into \`relevance.calibration\` (relevant / not_relevant) in your draft. For \`missed\`
items, also fix the recall side: make sure their sources are ranked appropriately in
\`news_sources\` (with feeds where they exist) so items like them get swept at all.
\`\`\`jsonl
$FEEDBACK_DATA
\`\`\`"
fi

# One researcher pass over a single facet. Runs as a background job in the facet
# batch, so it must NEVER abort the parent: it captures its own failure, writes either
# real notes or a clearly-labelled stub note, and returns 0. Its run-JSON is stashed
# for the parent to log serially after the batch (no concurrent runs.log writers).
run_facet() {  # <facet-id> <facet-json>
  local fid="$1" fjson="$2"
  local note="$NOTES_DIR/$fid.md" errf="$RESEARCH_DIR/$fid.err" jsonf="$RESEARCH_DIR/$fid.json"
  local rc=0 out
  out="$(${FACET_TIMEOUT_CMD[@]+"${FACET_TIMEOUT_CMD[@]}"} claude -p "$(cat "$RESEARCH_FACET_PROMPT")

---
YOUR FACET (research only this; teammates cover the rest):
\`\`\`json
$fjson
\`\`\`

Config for context (subject, anchor, seeds, scope):
\`\`\`yaml
$(cat "$CONFIG")
\`\`\`

Write your notes as valid Markdown to ./$note (the schema is in the prompt above)." \
    ${RESEARCHER_MODEL_ARGS[@]+"${RESEARCHER_MODEL_ARGS[@]}"} \
    --allowedTools "Read,Write,WebSearch,WebFetch" \
    --disallowedTools "Bash" \
    --permission-mode acceptEdits \
    --max-turns "$FACET_MAX_TURNS" \
    --output-format json \
    2> "$errf")" || rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$note" ]; then
    printf '%s' "$out" > "$jsonf"
  else
    printf '# Facet: %s\n\nFACET FAILED - synthesis must treat this area as UNRESEARCHED (the researcher produced no notes; rc=%s). Cover it from the open web if you can, and flag it in the provenance block.\n' "$fid" "$rc" > "$note"
    : > "$jsonf"
    printf '%s\n' "$fid" >> "$RESEARCH_DIR/.failed"
  fi
}

# ---- deep-research pipeline (models.researcher): plan -> parallel facets -> notes ----
# Sets NOTES_NOTE, the manifest the synthesis pass grounds itself in. Every failure mode
# leaves NOTES_NOTE empty, so synthesis falls back to today's full-web single pass -- a
# broken pipeline must never cost the user a draft.
NOTES_NOTE=""
if [ -n "$RESEARCHER_MODEL" ]; then
  if command -v python3 >/dev/null 2>&1 && [ -f bin/research.py ] \
     && [ -f "$RESEARCH_PLAN_PROMPT" ] && [ -f "$RESEARCH_FACET_PROMPT" ]; then
    if [ -n "$RESUME" ]; then
      mkdir -p "$NOTES_DIR"
      echo "[bootstrap] deep research: --resume (keeping existing notes under $NOTES_DIR)" >&2
    else
      rm -rf "$RESEARCH_DIR"; mkdir -p "$NOTES_DIR"
    fi
    rm -f "$RESEARCH_DIR/.failed"

    # [1] PLAN pass (bootstrap model) -> plan.json. Reused on --resume if already present.
    if [ -n "$RESUME" ] && [ -s "$PLAN_JSON" ]; then
      echo "[bootstrap] deep research: reusing existing plan $PLAN_JSON" >&2
    else
      echo "[bootstrap] deep research: planning the investigation (model=${MODEL:-CLI default})" >&2
      PLAN_RUN_JSON="$(${THINK_ENV[@]+"${THINK_ENV[@]}"} claude -p "$(cat "$RESEARCH_PLAN_PROMPT")

---
Config to plan the research over:
\`\`\`yaml
$(cat "$CONFIG")
\`\`\`$FEEDBACK_NOTE" \
        ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
        --allowedTools "Read,Write,WebSearch,WebFetch" \
        --disallowedTools "Bash" \
        --permission-mode acceptEdits \
        --max-turns "$PLAN_MAX_TURNS" \
        --output-format json \
        2>> bootstrap.err)" && log_usage research-plan "$PLAN_RUN_JSON" \
        || echo "[bootstrap] WARNING: plan pass failed - will try to validate any plan it wrote" >&2
    fi

    # [2] validate-plan: clamp to research_max_facets, slugify + de-dup ids. A missing /
    # unparseable / empty plan yields no facets -> single-pass fallback below.
    FACETS="$(python3 bin/research.py validate-plan --max "$RESEARCH_MAX_FACETS" "$PLAN_JSON" 2>> bootstrap.err || true)"
    if [ -z "$FACETS" ]; then
      echo "[bootstrap] WARNING: no usable research plan - falling back to single-pass bootstrap" >&2
    else
      FACET_LINES=()
      while IFS= read -r _l; do [ -n "$_l" ] && FACET_LINES+=("$_l"); done <<EOF
$FACETS
EOF
      n_facets="${#FACET_LINES[@]}"
      echo "[bootstrap] deep research: $n_facets facet(s), $RESEARCH_PARALLEL at a time (model=$RESEARCHER_MODEL)" >&2

      # [2] FACET passes, batched research_parallel at a time (bash 3.2 has no wait -n:
      # fill a batch of background jobs, wait for it, launch the next).
      running=0
      for _line in ${FACET_LINES[@]+"${FACET_LINES[@]}"}; do
        IFS=$'\t' read -r fid fgoal fjson <<<"$_line"
        # Resume skips a facet only if its notes are non-empty, newer than the plan, AND
        # not a FACET FAILED stub -- a stub from a transient failure must be retried, not
        # treated as done (else a resume could synthesize from failed notes).
        if [ -n "$RESUME" ] && [ -s "$NOTES_DIR/$fid.md" ] && [ "$NOTES_DIR/$fid.md" -nt "$PLAN_JSON" ] \
           && ! grep -q '^FACET FAILED' "$NOTES_DIR/$fid.md"; then
          echo "[bootstrap]   facet $fid: resume - keeping existing notes" >&2
          continue
        fi
        run_facet "$fid" "$fjson" &
        running=$((running + 1))
        if [ "$running" -ge "$RESEARCH_PARALLEL" ]; then wait; running=0; fi
      done
      wait

      failed_count=0
      [ -f "$RESEARCH_DIR/.failed" ] && failed_count="$(wc -l < "$RESEARCH_DIR/.failed" | tr -d ' ')"
      # Log each facet's spend serially now the batch is done.
      for _line in ${FACET_LINES[@]+"${FACET_LINES[@]}"}; do
        IFS=$'\t' read -r fid _g _j <<<"$_line"
        [ -s "$RESEARCH_DIR/$fid.json" ] && log_usage "research-facet:$fid" "$(cat "$RESEARCH_DIR/$fid.json")"
      done

      if [ "$failed_count" -ge "$n_facets" ]; then
        echo "[bootstrap] WARNING: every facet failed - synthesis runs with full web (single-pass behavior)" >&2
      else
        manifest=""
        for _line in ${FACET_LINES[@]+"${FACET_LINES[@]}"}; do
          IFS=$'\t' read -r fid fgoal _j <<<"$_line"
          tag=""
          grep -q '^FACET FAILED' "$NOTES_DIR/$fid.md" 2>/dev/null && tag="  - FAILED (treat as unresearched)"
          manifest="$manifest
- ./$NOTES_DIR/$fid.md  (goal: $fgoal)$tag"
        done
        echo "[bootstrap] deep research: $((n_facets - failed_count))/$n_facets facet(s) produced notes" >&2
        NOTES_NOTE="

RESEARCH NOTES - a team of researchers investigated this market in parallel; their
compressed notes below are the PRIMARY input for your synthesis (you do NOT see the raw
pages they read - only these digests). Read each via Read and GROUND every derived block
+ the rubric in them, citing from them. Use the web only to fill gaps a note marks LOW or
thin, or where a facet FAILED. Notes manifest:$manifest

ALSO add a \"How this draft was researched\" provenance block to the review summary: the
facets run, which (if any) FAILED / are unresearched, the main sources consulted, and what
a human should double-check. Honesty about coverage beats a tidy-looking draft."
      fi
    fi
  else
    echo "[bootstrap] WARNING: models.researcher set but research tooling is missing (python3 / bin/research.py / prompts) - single-pass bootstrap" >&2
  fi
fi

echo "[bootstrap] model=${MODEL:-(CLI default)} synthesizing the draft -> $DRAFT${NOTES_NOTE:+ (from research notes)}"

SYNTH_RUN_JSON="$(${THINK_ENV[@]+"${THINK_ENV[@]}"} claude -p "$(cat "$PROMPT")

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
\`\`\`$FEEDBACK_NOTE$NOTES_NOTE" \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
  --disallowedTools "Bash" \
  --permission-mode acceptEdits \
  --max-turns "$BOOTSTRAP_MAX_TURNS" \
  --output-format json \
  2>> bootstrap.err)"
log_usage bootstrap "$SYNTH_RUN_JSON"

echo
echo "[bootstrap] draft written to $DRAFT"

# ---- challenge pass: attack the draft's weakest claims (models.challenge) ----
# An adversary with web access tries to BREAK the draft's highest-stakes, lowest-
# confidence claims (missing player? defunct "competitor"? stale pricing? wrong source
# rank?) before a human approves it. Works in either mode (it takes any draft). Non-
# destructive like the deep-dive: the draft is backed up first and restored if the pass
# fails or empties it; the report is folded into the review email after the diff/backtest.
rm -f "$CHALLENGE_MD"
if [ -n "$CHALLENGE_MODEL" ] && [ -s "$DRAFT" ] && [ -f "$RESEARCH_CHALLENGE_PROMPT" ]; then
  echo "[bootstrap] challenge pass on $CHALLENGE_MODEL" >&2
  cp "$DRAFT" "$DRAFT.pre-challenge"
  ch_rc=0
  CH_RUN_JSON="$(${THINK_ENV[@]+"${THINK_ENV[@]}"} claude -p "$(cat "$RESEARCH_CHALLENGE_PROMPT")

---
The draft profile to attack is ./$DRAFT. If the deep-research pipeline ran, the team's
notes are under ./$NOTES_DIR/ (read them for what was and wasn't researched).

Config for context:
\`\`\`yaml
$(cat "$CONFIG")
\`\`\`

Write your findings to ./$CHALLENGE_MD per the prompt above, and apply ONLY evidenced
corrections to ./$DRAFT (downgrade, don't delete, what you can't verify)." \
    ${CHALLENGE_MODEL_ARGS[@]+"${CHALLENGE_MODEL_ARGS[@]}"} \
    --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
    --disallowedTools "Bash" \
    --permission-mode acceptEdits \
    --max-turns "$CHALLENGE_MAX_TURNS" \
    --output-format json \
    2>> bootstrap.err)" || ch_rc=$?
  if [ "$ch_rc" -eq 0 ] && [ -s "$DRAFT" ]; then
    log_usage challenge "$CH_RUN_JSON"
    rm -f "$DRAFT.pre-challenge"
    if [ -s "$CHALLENGE_MD" ]; then
      echo "[bootstrap] challenge report written to $CHALLENGE_MD"
    else
      echo "[bootstrap] note: challenge pass found nothing to report" >&2
    fi
  else
    if [ "$ch_rc" -eq 0 ]; then log_usage challenge "$CH_RUN_JSON"; fi   # it ran; account for spend
    mv -f "$DRAFT.pre-challenge" "$DRAFT"
    rm -f "$CHALLENGE_MD"
    echo "[bootstrap] WARNING: challenge pass failed/emptied the draft - restored the draft, no challenge report" >&2
  fi
fi

# ---- deterministic feed verification (fetch.py --verify) ----
# A guessed feed URL otherwise only surfaces weeks later via feed health (Phase 16). At
# the gate, fetch every subject.derived.feeds URL in the DRAFT and report which actually
# serve a parseable feed -- folded into the review email. An aid, never a gate: any
# trouble is a note and the draft is untouched. Runs in single-pass mode too.
rm -f "$FEEDCHECK_MD"
if [ -s "$DRAFT" ] && command -v python3 >/dev/null 2>&1 && [ -f bin/fetch.py ]; then
  if python3 bin/fetch.py --verify --out "$FEEDCHECK_MD" "$DRAFT" 2>> bootstrap.err \
     && [ -s "$FEEDCHECK_MD" ]; then
    echo "[bootstrap] draft feed check written to $FEEDCHECK_MD"
  else
    rm -f "$FEEDCHECK_MD"
    echo "[bootstrap] note: no draft feeds to verify (or verification skipped)" >&2
  fi
fi

# ---- refresh diff: what this draft changes vs the approved profile ----
# On a refresh the review gate should be a skim of WHAT CHANGED (what your grades
# re-ranked, which sources moved) rather than a re-read of the whole profile. Write
# a unified diff alongside the draft and fold it into the review email below.
# First bootstrap (no approved profile), an identical draft, or no diff tool ->
# skipped with a note, never a failure.
rm -f "$DIFF_FILE"
if [ -f "$PROFILE" ] && [ -s "$DRAFT" ]; then
  if command -v diff >/dev/null 2>&1; then
    diff_rc=0
    diff -u "$PROFILE" "$DRAFT" > "$DIFF_FILE" || diff_rc=$?
    if [ "$diff_rc" -ge 2 ]; then     # 0 = identical, 1 = differs, >= 2 = trouble
      echo "[bootstrap] WARNING: diff failed (exit $diff_rc) - no $DIFF_FILE written" >&2
      rm -f "$DIFF_FILE"
    elif [ -s "$DIFF_FILE" ]; then
      echo "[bootstrap] refresh diff written to $DIFF_FILE (draft vs approved $PROFILE)"
    else
      rm -f "$DIFF_FILE"
      echo "[bootstrap] note: the draft is identical to the approved $PROFILE" >&2
    fi
  else
    echo "[bootstrap] note: no diff tool found - skipping $DIFF_FILE" >&2
  fi
fi

# ---- rubric backtest: how the DRAFT rubric scores items you already graded ----
# The diff above shows WHAT changed; this shows WHAT EFFECT it has. Replay the
# user's graded items (state/feedback.jsonl) under the draft rubric -- blind, on the
# MONITOR model (the production scorer), numbers computed deterministically -- and
# fold an agreement report into the review email + portal draft view. Runs only on a
# refresh (profile.yaml exists), only when the draft was written, only when there are
# enough up/down grades. Every failure mode warns and skips; the draft is never at risk.
BACKTEST_JSONL="profile.draft.backtest.jsonl"   # the agent's {id, draft_score} scores
BACKTEST_MD="profile.draft.backtest.md"         # the rendered agreement report
rm -f "$BACKTEST_JSONL" "$BACKTEST_MD"          # stale-run hygiene, like rm -f "$DIFF_FILE"
if [ -f "$PROFILE" ] && [ -s "$DRAFT" ] && [ -s "$FEEDBACK" ] \
   && [ -f "$BACKTEST_PROMPT" ] && command -v python3 >/dev/null 2>&1 \
   && [ -f bin/dedupe-feedback.py ] && [ -f bin/backtest.py ]; then
  EVAL_SET="$(python3 bin/dedupe-feedback.py "$FEEDBACK" \
              | python3 bin/backtest.py prepare --max "$BACKTEST_MAX_ITEMS")" || EVAL_SET=""
  if [ -n "$EVAL_SET" ]; then
    echo "[bootstrap] backtest: re-scoring graded items under the draft rubric (model=${BACKTEST_MODEL:-CLI default})" >&2
    # Persist the prepared (blind) eval set so render's universe is exactly what the
    # scorer was asked about -- a capped run must not report capped-out grades as
    # "not scored". Materialize the whole prompt now (draft + eval inline) so the pass
    # needs no repo files at all.
    BT_EVAL="$(mktemp)"
    printf '%s\n' "$EVAL_SET" > "$BT_EVAL"
    BT_PROMPT="$(cat "$BACKTEST_PROMPT")

---
DRAFT profile YAML (the rubric under review):
\`\`\`yaml
$(cat "$DRAFT")
\`\`\`

Evaluation set (one JSON object per line; verdicts withheld on purpose):
\`\`\`jsonl
$EVAL_SET
\`\`\`"
    # Run the scorer in a throwaway scratch dir: with Read denied AND cwd isolated, an
    # injected or misbehaving pass can only write inside the scratch dir -- it cannot
    # reach (let alone silently clobber) the draft/summary/diff we tell the reviewer are
    # unaffected. We copy only the scores file back.
    BT_SCRATCH="$(mktemp -d)"
    if ( cd "$BT_SCRATCH" && claude -p "$BT_PROMPT" \
          ${BT_MODEL_ARGS[@]+"${BT_MODEL_ARGS[@]}"} \
          --allowedTools "Write" \
          --disallowedTools "Read,Bash,WebSearch,WebFetch" \
          --permission-mode acceptEdits \
          --max-turns "$BACKTEST_MAX_TURNS" \
          --output-format text \
          2>> "$ROOT/bootstrap.err" ) \
       && [ -s "$BT_SCRATCH/$BACKTEST_JSONL" ]; then
      mv -f "$BT_SCRATCH/$BACKTEST_JSONL" "$BACKTEST_JSONL"
      if python3 bin/backtest.py render --draft "$DRAFT" --approved "$PROFILE" \
           --feedback "$FEEDBACK" --eval "$BT_EVAL" --scores "$BACKTEST_JSONL" --out "$BACKTEST_MD"; then
        echo "[bootstrap] backtest report written to $BACKTEST_MD"
      else
        rm -f "$BACKTEST_MD"
        echo "[bootstrap] WARNING: backtest render failed - skipping (draft unaffected)" >&2
      fi
    else
      echo "[bootstrap] WARNING: backtest scoring pass failed/empty - skipping (draft unaffected)" >&2
    fi
    rm -rf "$BT_SCRATCH"; rm -f "$BT_EVAL"
  else
    echo "[bootstrap] note: too few up/down grades to backtest (or backtest disabled) - skipping" >&2
  fi
fi

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
  # The summary is written by synthesis; a later challenge pass may have CORRECTED the
  # draft after it, so the digest the email + portal lead with can contradict the
  # corrected draft. Append an honest staleness caveat (after the editorial pass so it
  # can't be polished away; it lands in both the file the portal reads and the email
  # body built below). Deterministic - no re-summarize cost.
  if [ -s "$CHALLENGE_MD" ]; then
    # shellcheck disable=SC2016  # backticks are literal Markdown; %s is a printf placeholder
    printf '\n\n---\n\n> _An adversarial **challenge pass** ran after this summary was written and may have corrected the draft. Where this digest and `%s` differ, the draft and the Challenge report below are authoritative._\n' \
      "$DRAFT" >> "$SUMMARY"
  fi
  # Email the summary when output.email_to is set (one address or a list).
  if [ "${#EMAIL_TO[@]}" -gt 0 ]; then
    email_disp="$(IFS=', '; echo "${EMAIL_TO[*]}")"
    if command -v msmtp >/dev/null 2>&1; then
      DELIVER="$(mktemp)"
      cat "$SUMMARY" > "$DELIVER"
      # On a refresh, the diff vs the approved profile is the real review surface --
      # appended AFTER the (possibly editor-polished) summary, never edited itself.
      if [ -s "$DIFF_FILE" ]; then
        {
          printf '\n\n---\n\n## What changed vs the approved profile\n\n```diff\n'
          head -n 200 "$DIFF_FILE"
          if [ "$(wc -l < "$DIFF_FILE")" -gt 200 ]; then
            printf '... (truncated - the full diff is in %s)\n' "$DIFF_FILE"
          fi
          printf '```\n'
        } >> "$DELIVER"
      fi
      # The rubric backtest -- what EFFECT the draft has -- appended after the diff,
      # also post-editor so the editorial pass can never touch the numbers.
      if [ -s "$BACKTEST_MD" ]; then
        printf '\n\n---\n\n' >> "$DELIVER"
        cat "$BACKTEST_MD" >> "$DELIVER"
      fi
      # Deterministic draft-feed verification, then the adversarial challenge report --
      # both appended after the backtest, post-editor so neither is paraphrased away.
      if [ -s "$FEEDCHECK_MD" ]; then
        printf '\n\n---\n\n' >> "$DELIVER"
        cat "$FEEDCHECK_MD" >> "$DELIVER"
      fi
      if [ -s "$CHALLENGE_MD" ]; then
        printf '\n\n---\n\n' >> "$DELIVER"
        cat "$CHALLENGE_MD" >> "$DELIVER"
      fi
      # shellcheck disable=SC2016  # backticks are literal Markdown; %s are printf placeholders
      printf '\n\n---\n\n**To approve:** review `%s`, edit if needed, then run `cp %s profile.yaml` on the host. Nothing is monitored until you do.\n' \
        "$DRAFT" "$DRAFT" >> "$DELIVER"
      VP_TITLE="${SUBJECT_NAME:-Market intelligence}"
      VP_SUBTITLE="Profile draft ready for review"
      VP_PREHEADER="$(email_preheader "$DELIVER")"
      VP_FOOTER="Generated by Vantage Point (bootstrap)"
      VP_LOGO=""   # brand logo in the header when output.email_images is on
      [ -n "${EMAIL_IMAGES:-}" ] && VP_LOGO="${LOGO_ASSET:-}"
      if send_email "[Vantage Point: ${SUBJECT_NAME:-draft}] profile draft ready for review" "$DELIVER" "${EMAIL_TO[@]}"; then
        echo "[bootstrap] emailed the draft summary to $email_disp"
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
[ -s "$DIFF_FILE" ] && echo "             (what changed vs the approved profile: $DIFF_FILE)"
[ -s "$BACKTEST_MD" ] && echo "             (how the draft rubric scores your graded items: $BACKTEST_MD)"
[ -s "$FEEDCHECK_MD" ] && echo "             (which draft feeds actually serve a feed: $FEEDCHECK_MD)"
[ -s "$CHALLENGE_MD" ] && echo "             (adversarial challenge of the draft's claims: $CHALLENGE_MD)"
# Optional: copy the digest too so the portal's Profile tab shows it for the approved
# profile (it renders profile.summary.md like the bootstrap email; YAML stays the source).
[ -f "$SUMMARY" ] && echo "             cp $SUMMARY profile.summary.md   # optional: nicer Profile tab"
