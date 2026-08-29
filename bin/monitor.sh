#!/usr/bin/env bash
# monitor.sh {daily|weekly} - the recurring agent.
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
# Append (not prepend) common install dirs so launchd's minimal PATH can still
# find claude/msmtp/etc., without overriding a PATH the caller set up first (e.g.
# the test stubs, or a user's own claude earlier in PATH).
export PATH="$PATH:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin"

# Shared helpers (config readers + email rendering/sending), also used by bootstrap.sh.
# shellcheck source=bin/config-lib.sh
. "$ROOT/bin/config-lib.sh"
# shellcheck source=bin/email-lib.sh
. "$ROOT/bin/email-lib.sh"

CONFIG="monitor-config.yaml"
PROFILE="profile.yaml"
PROMPT="monitor-prompt.md"
DEEPDIVE_PROMPT="deepdive-prompt.md"
EDITOR_PROMPT="editor-prompt.md"
TODAY="$(date +%F)"
REPORT="kb/${TODAY}.${MODE}.md"
# This run writes here; we promote it to $REPORT only after claude exits 0, so a
# transient failure on a same-day rerun can't destroy an earlier good report.
RUN_REPORT="kb/.${TODAY}.${MODE}.partial.md"
# Triage writes its highest-scoring survivors here; the optional deep-dive pass
# (stronger model) reads this queue and enriches those items in the report.
QUEUE="state/.deepdive.${MODE}.queue.jsonl"

# The review gate, enforced in code: refuse to run on an unapproved profile.
[ -f "$PROFILE" ] || {
  echo "no approved $PROFILE - run bin/bootstrap.sh and approve the draft first" >&2
  exit 1
}

mkdir -p state kb
touch state/observations.jsonl   # the dedup state file is touched once STATE_FILE is resolved

# ---- config knobs (all optional; sane fallbacks) ----
MODEL="$(cfg_get models monitor)"
DEEPDIVE_MODEL="$(cfg_get models deepdive)"   # unset -> no deep-dive pass (triage only)
EDITOR_MODEL="$(cfg_get models editor)"       # unset -> no editorial pass (deliver as-written)
EMAIL_TO=()                                    # output.email_to: scalar OR a YAML list
while IFS= read -r _addr; do
  [ -n "$_addr" ] && EMAIL_TO+=("$_addr")
done < <(cfg_get_list output email_to)
EMAIL_IMAGES="$(cfg_get_bool output email_images 0)"   # embed the logo in email headers; default off
LOGO_ASSET="$ROOT/assets/logo-email.png"               # brand logo used when EMAIL_IMAGES is on
WEBHOOK_URL="$(cfg_get output webhook_url)"
DASHBOARD="$(cfg_get output dashboard)"
STATE_FILE="$(cfg_get monitoring state_file)"      # dedup memory; honored, not hardcoded
[ -n "$STATE_FILE" ] || STATE_FILE="state/seen.jsonl"
STATE_FILE="${STATE_FILE#./}"                       # normalize so "./state/..." == default
mkdir -p "$(dirname "$STATE_FILE")"; touch "$STATE_FILE"
# How to name it to Claude (cwd is the checkout): a relative path is anchored with
# ./, an absolute path is handed over verbatim (never ".//abs").
case "$STATE_FILE" in
  /*) STATE_FILE_REF="$STATE_FILE" ;;
  *)  STATE_FILE_REF="./$STATE_FILE" ;;
esac
SUBJECT_NAME="$(cfg_get_text subject name)"
RUN_TIMEOUT="$(cfg_get monitoring run_timeout_seconds)"
STATE_MAX_LINES="$(cfg_get monitoring state_max_lines)"
OBS_MAX_LINES="$(cfg_get tracking observations_max_lines)"
DEEPDIVE_THRESHOLD="$(cfg_get monitoring deepdive_threshold)"
DEEPDIVE_MAX="$(cfg_get monitoring deepdive_max_items)"
REFRESH_DAYS="$(cfg_get governance profile_refresh_days)"
RECENT_GRADES="$(cfg_get relevance recent_grades)"
case "$RUN_TIMEOUT"     in ''|*[!0-9]*) RUN_TIMEOUT=1800 ;; esac
case "$STATE_MAX_LINES" in ''|*[!0-9]*) STATE_MAX_LINES=5000 ;; esac
case "$OBS_MAX_LINES"   in ''|*[!0-9]*) OBS_MAX_LINES=20000 ;; esac
case "$DEEPDIVE_MAX"    in ''|*[!0-9]*) DEEPDIVE_MAX=5 ;; esac
[ -n "$DEEPDIVE_THRESHOLD" ] || DEEPDIVE_THRESHOLD=0.85   # may be a decimal; agent applies it
case "$REFRESH_DAYS"    in *[!0-9]*)    REFRESH_DAYS="" ;; esac   # blank/non-numeric -> skip check
case "$RECENT_GRADES"   in ''|*[!0-9]*) RECENT_GRADES=20 ;; esac

# ---- forward radar (tracking.horizon; recording + checking ride the triage run) ----
# Record time-bounded expectations the sweep mentions (earnings dates, "GA in Q3",
# launch windows) to state/horizon.jsonl, re-check them as they come due, and render a
# weekly "Coming up" section. On by default when tracking is on; tracking.horizon: false
# (or tracking.enabled: false) turns the whole feature off. Knobs optional with defaults.
TRACKING_ENABLED="$(cfg_get_bool tracking enabled 1)"   # the trend layer; default on, like the example
HORIZON_ENABLED=""
[ -n "$TRACKING_ENABLED" ] && HORIZON_ENABLED="$(cfg_get_bool tracking horizon 1)"
HORIZON="state/horizon.jsonl"
HORIZON_MAX_LINES="$(cfg_get tracking horizon_max_lines)"
HORIZON_DAYS="$(cfg_get tracking horizon_upcoming_days)"
case "$HORIZON_MAX_LINES" in ''|*[!0-9]*) HORIZON_MAX_LINES=2000 ;; esac
case "$HORIZON_DAYS"       in ''|*[!0-9]*) HORIZON_DAYS=14 ;; esac

# ---- quiet detection (tracking.quiet; the dog that didn't bark) ----
# Each entity's sourced event history (observations.jsonl) gives it a normal rhythm;
# on WEEKLY runs, entities silent well past that baseline are injected as a QUIET
# ENTITIES block for the agent to verify against the sweep and surface under "Quiet
# on" - an absence is a finding when the entity's own history says it shouldn't be
# quiet. On by default when tracking is on; tracking.quiet: false turns it off.
# Flagged silences are remembered in state/quiet.jsonl so the same silence never
# re-alarms; the flag self-voids when the entity resumes (last_seen advances).
QUIET_ENABLED=""
[ -n "$TRACKING_ENABLED" ] && QUIET_ENABLED="$(cfg_get_bool tracking quiet 1)"
QUIET_STATE="state/quiet.jsonl"
QUIET_STATE_MAX_LINES=500   # one row per flagged silence; a constant, not a knob
QUIET_FACTOR="$(cfg_get tracking quiet_factor)"
QUIET_MIN_EVENTS="$(cfg_get tracking quiet_min_events)"
case "$QUIET_FACTOR"     in ''|*[!0-9.]*|*.*.*) QUIET_FACTOR=3 ;; esac
awk -v f="$QUIET_FACTOR" 'BEGIN{exit !(f > 0)}' || QUIET_FACTOR=3
# Accept decimal values containing at least one non-zero digit. This avoids Bash
# arithmetic's leading-zero/octal pitfall while making every spelling of zero use
# the documented default, just like portal.py.
case "$QUIET_MIN_EVENTS" in
  ''|*[!0-9]*) QUIET_MIN_EVENTS=4 ;;
  *[1-9]*) ;;
  *) QUIET_MIN_EVENTS=4 ;;
esac

# ---- run budgets (budgets: block; all optional with the long-standing defaults) ----
# On a Max subscription the spend is subscription headroom, not API billing, so the
# real cost levers are run frequency and these per-pass turn caps (each is passed to
# `claude --max-turns` for its pass). 0/absent/non-numeric -> the default cap.
MONITOR_MAX_TURNS="$(cfg_get budgets monitor_max_turns)"
DEEPDIVE_MAX_TURNS="$(cfg_get budgets deepdive_max_turns)"
EDITOR_MAX_TURNS="$(cfg_get budgets editor_max_turns)"
MONTHLY_COST_USD="$(cfg_get budgets monthly_cost_usd)"
case "$MONITOR_MAX_TURNS"  in ''|0|*[!0-9]*) MONITOR_MAX_TURNS=40 ;; esac
case "$DEEPDIVE_MAX_TURNS" in ''|0|*[!0-9]*) DEEPDIVE_MAX_TURNS=40 ;; esac
case "$EDITOR_MAX_TURNS"   in ''|0|*[!0-9]*) EDITOR_MAX_TURNS=15 ;; esac
case "$MONTHLY_COST_USD"   in ''|*[!0-9.]*|*.*.*) MONTHLY_COST_USD=0 ;; esac  # decimal USD; junk -> off

# The approved profile's vintage. Used twice: the staleness warning below, and to
# scope which operator grades count as "new" (recorded after this profile was built,
# so not yet folded into its rubric by a re-bootstrap).
LAST_BOOT="$(cfg_get subject last_bootstrapped "$PROFILE")"
case "$LAST_BOOT" in ''|null) LAST_BOOT="$(cfg_get anchor last_bootstrapped "$PROFILE")" ;; esac
case "$LAST_BOOT" in null) LAST_BOOT="" ;; esac

# ---- single-run lock (shared across modes) ----
# daily and weekly share state/seen.jsonl, so ONE lock guards all modes - never two
# monitors at once, whatever the mode (so keep the daily/weekly schedules from
# overlapping; the defaults are 30 min apart). An overlapping or manual run just
# skips. A crashed run leaves a stale lock; it's reclaimed when its owner process is
# gone. We identify the owner by PID *and* start time, so a recycled PID (different
# start time) is correctly seen as stale and a live owner is never reclaimed - no
# matter how long it runs (claude + email/render), and regardless of whether a
# timeout is configured or enforceable.
LOCK="state/.lock"
LOCK_SETUP_GRACE=30   # secs a lock may sit without an owner token before its creator is assumed dead

proc_start() {  # normalized start time of pid $1 (empty if it isn't running)
  # If ps lacks `-o lstart=` (rare), this is empty for every pid and the staleness
  # guarantee degrades to PID-only — still consistent (a live owner matches itself),
  # just without recycled-PID detection.
  ps -o lstart= -p "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//'
}

lock_age_secs() {  # age (s) of the lock dir; huge if it's gone
  local mtime
  mtime="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0)"
  echo "$(( $(date +%s) - mtime ))"
}

# Acquire the lock. Returns 0 (owned) or 1 (held by a live run / lost a reclaim race).
acquire_lock() {
  mkdir "$LOCK" 2>/dev/null && return 0   # uncontended
  local owner oldpid oldstart
  owner="$(cat "$LOCK/owner" 2>/dev/null || true)"
  if [ -z "$owner" ]; then
    # Lock dir exists but the owner token isn't written yet: another acquirer is
    # mid-setup (milliseconds). Treat as active only briefly; longer => it died there.
    if [ "$(lock_age_secs)" -lt "$LOCK_SETUP_GRACE" ]; then return 1; fi
  else
    oldpid="${owner%% *}"
    oldstart="${owner#* }"
    # Active iff that EXACT process is still alive: same PID and same start time.
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null && [ "$(proc_start "$oldpid")" = "$oldstart" ]; then
      return 1
    fi
  fi
  echo "[monitor:$MODE] reclaiming stale lock (owner ${oldpid:-unknown})" >&2
  # Reclaim race-safely: rename the inspected dir out of the way (only one renamer
  # of a given dir can win), then let the final mkdir be the sole ownership arbiter
  # - concurrent reclaimers can't both end up owning.
  mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$"
  mkdir "$LOCK" 2>/dev/null
}

if acquire_lock; then
  printf '%s %s\n' "$$" "$(proc_start "$$")" > "$LOCK/owner"
else
  echo "[monitor:$MODE] another run is in progress - skipping" >&2
  exit 0
fi

# Release the lock on exit, and surface a hard failure (a set -e abort - e.g. the
# claude run errored or timed out) that would otherwise vanish into the launchd log.
cleanup() {
  local rc=$?
  rm -rf "$LOCK" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    echo "[monitor:$MODE] run FAILED (exit $rc) - see kb/${TODAY}.${MODE}.err" >&2
  fi
  return 0
}
trap cleanup EXIT

# Pass --model only when set; otherwise omit it so the CLI default applies.
MODEL_ARGS=()
if [ -n "$MODEL" ]; then
  MODEL_ARGS=(--model "$MODEL")
else
  echo "[monitor:$MODE] models.monitor not set in $CONFIG - using CLI default model" >&2
fi
DEEPDIVE_MODEL_ARGS=()
[ -n "$DEEPDIVE_MODEL" ] && DEEPDIVE_MODEL_ARGS=(--model "$DEEPDIVE_MODEL")
DEEPDIVE_STATE=disabled
[ -n "$DEEPDIVE_MODEL" ] && DEEPDIVE_STATE=enabled
EDITOR_MODEL_ARGS=()
[ -n "$EDITOR_MODEL" ] && EDITOR_MODEL_ARGS=(--model "$EDITOR_MODEL")

# Wall-clock bound on the claude run so a network stall can't hang the job forever.
# 0 disables it; needs timeout/gtimeout (coreutils) - skipped with a note if absent.
TIMEOUT_CMD=()
if [ "$RUN_TIMEOUT" != 0 ]; then
  if   command -v timeout  >/dev/null 2>&1; then TIMEOUT_CMD=(timeout  "$RUN_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD=(gtimeout "$RUN_TIMEOUT")
  else echo "[monitor:$MODE] note: no timeout/gtimeout - run is not time-bounded (brew install coreutils)" >&2
  fi
fi

# ---- prune append-only state so it can't grow without bound (0 disables) ----
# Cap by line count: schema-agnostic and generous vs the dedup/trend window, so this
# never drops anything still relevant. We hold the lock, so there's no concurrent
# writer. Prune before the run so claude reads bounded files.
prune_state() {  # <file> <max_lines>
  [ "$2" -gt 0 ] || return 0
  local cur; cur="$(wc -l < "$1")"
  if [ "$cur" -gt "$2" ]; then
    tail -n "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
    echo "[monitor:$MODE] pruned $1: $cur -> $2 lines" >&2
  fi
}
prune_state "$STATE_FILE" "$STATE_MAX_LINES"
prune_state state/observations.jsonl "$OBS_MAX_LINES"
# The expectation log is created by the agent on first record; prune only if it exists.
[ -n "$HORIZON_ENABLED" ] && [ -f "$HORIZON" ] && prune_state "$HORIZON" "$HORIZON_MAX_LINES"
# The quiet-flag log is COMPACTED (latest row per entity/event_type), not tail-pruned:
# readers only ever use that latest row, so compaction loses nothing, while a line-
# count tail-prune could evict an old-but-still-active flag and re-alarm a silence
# that was already reported. Compaction only runs past the line bound (the file is
# one row per flagged silence, so it normally stays tiny); afterwards it is exactly
# as long as the number of distinct flagged silences.
if [ -n "$QUIET_ENABLED" ] && [ -f "$QUIET_STATE" ] \
   && [ "$(wc -l < "$QUIET_STATE")" -gt "$QUIET_STATE_MAX_LINES" ] \
   && command -v python3 >/dev/null 2>&1 && [ -f bin/cadence.py ]; then
  python3 bin/cadence.py compact "$QUIET_STATE" 2>/dev/null \
    && echo "[monitor:$MODE] compacted $QUIET_STATE (latest flag per entity/event_type)" >&2 \
    || echo "[monitor:$MODE] note: quiet-flag compaction failed (harmless)" >&2
fi

# ---- profile staleness (governance.profile_refresh_days) ----
# Anchors drift; a stale profile silently mis-scores. Warn (don't refuse) when the
# approved profile is older than the refresh window. The warning goes to stderr AND -
# via STALE_NOTE, appended to the report further down - to whoever actually reads the
# output: a warning that only ever lands in state/daily.err.log is a warning nobody
# sees, which is how a profile can sit 70 days past its refresh window unnoticed.
STALE_NOTE=""
if [ -n "$REFRESH_DAYS" ] && [ "$REFRESH_DAYS" -gt 0 ]; then
  # GNU `date -d` and BSD `date -j -f` differ; try both, give up quietly if neither parses.
  # An ABSENT date is rejected up front: GNU `date -d ""` succeeds and reports today, so
  # a profile with no last_bootstrapped would compute as 0d old and silently disable this
  # whole check on Linux. BSD already fails it; this makes both platforms agree.
  if [ -z "$LAST_BOOT" ]; then
    boot_epoch=""
    echo "[monitor:$MODE] note: profile has no last_bootstrapped - skipping staleness check" >&2
  else
    boot_epoch="$(date -d "$LAST_BOOT" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$LAST_BOOT" +%s 2>/dev/null || true)"
  fi
  if [ -n "$boot_epoch" ]; then
    age_days=$(( ( $(date +%s) - boot_epoch ) / 86400 ))
    # A future date parses but goes negative, which is never -gt the window, so it would
    # silently disable this warning for as long as the date stays ahead of the clock -
    # the same hole the absent-date guard above closes, reached a different way. Warn on
    # it explicitly rather than letting it read as "not stale yet".
    if [ "$age_days" -lt 0 ]; then
      echo "[monitor:$MODE] WARNING: profile last_bootstrapped ('$LAST_BOOT') is in the future - re-run bin/bootstrap.sh to refresh" >&2
      STALE_NOTE="dated in the future (\`$LAST_BOOT\`), so its age can't be trusted"
    elif [ "$age_days" -gt "$REFRESH_DAYS" ]; then
      echo "[monitor:$MODE] WARNING: profile is ${age_days}d old (> profile_refresh_days=$REFRESH_DAYS) - re-run bin/bootstrap.sh to refresh" >&2
      STALE_NOTE="${age_days}d old (\`governance.profile_refresh_days\` is $REFRESH_DAYS)"
    fi
  elif [ -n "$LAST_BOOT" ]; then
    echo "[monitor:$MODE] note: couldn't parse profile last_bootstrapped ('$LAST_BOOT') - skipping staleness check" >&2
  fi
fi

# ---- soft monthly budget (budgets.monthly_cost_usd; 0/absent = off) ----
# Compares the rolling 30-day API-EQUIVALENT cost estimate in state/runs.log against
# the cap and WARNS when it's crossed. It deliberately never skips the run: the
# estimate is not real Max-subscription billing, and silently stopping the watch
# would cost more than it saves. To actually spend less, lower the run frequency or
# the budgets.*_max_turns caps above. Checked twice - here (an already-over state
# warns before this run spends more) and again at the end of the run, after this
# run's own usage has been logged (so the run that CROSSES the cap warns too,
# instead of leaving the alert to the next scheduled run) - but warns at most once
# per invocation.
BUDGET_WARNED=""
check_budget() {
  [ -z "$BUDGET_WARNED" ] || return 0
  awk -v b="$MONTHLY_COST_USD" 'BEGIN{exit !(b > 0)}' || return 0
  [ -s state/runs.log ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "[monitor:$MODE] note: budgets.monthly_cost_usd set but jq not found - budget check skipped" >&2
    BUDGET_WARNED=1
    return 0
  fi
  local spent
  spent="$(jq -rs '
    (now - 30 * 86400) as $cutoff
    | [ .[] | select((((.timestamp // "") | fromdateiso8601?) // 0) >= $cutoff)
          | .cost_usd // 0 ]
    | (add // 0) * 100 | round / 100' state/runs.log 2>/dev/null || true)"
  if [ -n "$spent" ] && awk -v s="$spent" -v b="$MONTHLY_COST_USD" 'BEGIN{exit !(s >= b)}'; then
    echo "[monitor:$MODE] WARNING: est. 30-day spend \$$spent >= budgets.monthly_cost_usd \$$MONTHLY_COST_USD (API-equivalent estimate, not billing - see bin/usage.sh) - lower run frequency or budgets.*_max_turns to spend less" >&2
    BUDGET_WARNED=1
  fi
}
check_budget

# ---- live calibration: recent operator grades (relevance.recent_grades) ----
# Grades recorded via the Review tab only reshape the rubric at the next bootstrap +
# approval, which can lag by weeks. Bridge that lag: inject the newest POST-bootstrap
# grades (latest verdict per item, capped) into the triage prompt as worked examples,
# so a thumbs-down filters its lookalikes the very next run. Grades from before the
# profile was built are excluded -- the approved rubric already absorbed them.
# Fail-safe: any problem here skips the injection, never the run. 0 disables.
FEEDBACK_NOTE=""
if [ "$RECENT_GRADES" -gt 0 ] && [ -s state/feedback.jsonl ] \
   && command -v python3 >/dev/null 2>&1 && [ -f bin/dedupe-feedback.py ]; then
  fb_args=(state/feedback.jsonl --max "$RECENT_GRADES")
  [ -n "$LAST_BOOT" ] && fb_args+=(--since "$LAST_BOOT")
  FEEDBACK_DATA="$(python3 bin/dedupe-feedback.py "${fb_args[@]}" 2>/dev/null || true)"
  if [ -n "$FEEDBACK_DATA" ]; then
    n_fb="$(printf '%s\n' "$FEEDBACK_DATA" | grep -c . || true)"
    echo "[monitor:$MODE] live calibration: applying $n_fb recent grade(s) (relevance.recent_grades=$RECENT_GRADES)" >&2
    FEEDBACK_NOTE="

RECENT OPERATOR GRADES - live calibration. The user recorded these AFTER the current
rubric was approved (\`verdict\`: up = right to surface, down = should have been
filtered, missed = a relevant item the sweep never surfaced - the user reported its
URL), so the rubric does not reflect them yet. Treat them as ground truth layered on
top of the rubric: score an item that resembles a 'down' example below threshold, do
not drop one that resembles an 'up' example, and treat anything resembling a 'missed'
example as in-scope and material - and give its source sweep attention this run.
For anything they don't cover, the approved rubric governs unchanged.
\`\`\`jsonl
$FEEDBACK_DATA
\`\`\`"
  fi
fi

# ---- forward radar: due expectations (tracking.horizon) ----
# Inject the pending expectations whose stated date has arrived so the agent checks
# each against this run's sweep. The "what is due" arithmetic is deterministic (Python);
# the "did it actually happen" judgment is the agent's - the same division as trend
# detection. Fail-safe: any problem here skips the injection, never the run.
HORIZON_NOTE=""
if [ -n "$HORIZON_ENABLED" ] && [ -s "$HORIZON" ] \
   && command -v python3 >/dev/null 2>&1 && [ -f bin/horizon.py ]; then
  DUE="$(python3 bin/horizon.py due --as-of "$TODAY" "$HORIZON" 2>/dev/null || true)"
  if [ -n "$DUE" ]; then
    n_due="$(printf '%s\n' "$DUE" | grep -c . || true)"
    echo "[monitor:$MODE] forward radar: $n_due expectation(s) due as of $TODAY" >&2
    HORIZON_NOTE="

DUE EXPECTATIONS - forward radar. Each row is a previously-recorded expectation from
./state/horizon.jsonl whose stated date has arrived (\`overdue_days\` days past it;
\`past_grace\` true once it is overdue beyond its precision's grace). For EACH row,
judge it against THIS run's sweep and APPEND exactly one row to ./state/horizon.jsonl
under the SAME \`id\` (latest row per id wins). Each update row is a FULL record: carry
\`id\`/\`entity\`/\`event\`/\`due\`/\`due_precision\`/\`due_text\` forward and change only
what the transition changes - readers REPLACE the latest row whole, not merge, so a
sparse row loses the entity link and drops out of its dossier.
- MET - it happened (often it is in this very sweep): the full row with
  \`status\`:\"met\" and \`source\` set to the evidence URL; let the triggering item
  flow through scoring as usual.
- MOVED - a new date was announced: the full row with \`status\`:\"pending\", the new
  \`due\`/\`due_precision\`/\`due_text\`, and a note; the prior date stays in history.
- DUE but inside grace, no evidence yet (\`past_grace\` false): leave it - the weekly
  Coming up table shows it as due. Do NOT append a row.
- PAST GRACE, no evidence (\`past_grace\` true): the silent slip IS the signal - surface
  a finding (why -> what it suggests -> confidence, citing the original \`source\`) and
  append the full row with \`status\`:\"lapsed\" so it never re-alarms on later runs.
\`\`\`jsonl
$DUE
\`\`\`"
  fi
fi

# ---- quiet detection: cadence silences (tracking.quiet; weekly only) ----
# The deterministic half (baselines + who is past them) is bin/cadence.py; the agent
# judges each flagged silence against THIS run's sweep - the same division as the
# forward radar. Weekly only: a silence builds over weeks, and flagging it daily is
# noise. Fail-safe: any problem here skips the injection, never the run.
QUIET_NOTE=""
QUIET_ROWS=""
if [ "$MODE" = weekly ] && [ -n "$QUIET_ENABLED" ] && [ -s state/observations.jsonl ] \
   && command -v python3 >/dev/null 2>&1 && [ -f bin/cadence.py ]; then
  QUIET_ROWS="$(python3 bin/cadence.py quiet --as-of "$TODAY" --factor "$QUIET_FACTOR" \
      --min-events "$QUIET_MIN_EVENTS" state/observations.jsonl "$QUIET_STATE" 2>/dev/null || true)"
  if [ -n "$QUIET_ROWS" ]; then
    n_quiet="$(printf '%s\n' "$QUIET_ROWS" | grep -c . || true)"
    echo "[monitor:$MODE] quiet detection: $n_quiet entity(ies) silent past their baseline" >&2
    QUIET_NOTE="

QUIET ENTITIES - cadence baselines (the dog that didn't bark). Each row is a tracked
entity whose sourced event history in ./state/observations.jsonl shows a normal rhythm
(\`median_gap_days\` between its \`event_type\` events) that its current silence
(\`silence_days\` since \`last_seen\`) now exceeds. The arithmetic ran on recorded
history; you hold newer evidence - judge each row against THIS run's sweep:
- ACTIVITY FOUND (or an announced reason for the pause): record the observation as
  usual and do NOT flag the entity - the recorded history was simply behind.
- GENUINELY QUIET: add an entry to the weekly 'Quiet on' section citing the numbers
  (the baseline is the finding's credibility) and linking \`last_source\` as the last
  event's citation. The silence is the sourced fact; your interpretation of it is a
  judgment - mark its confidence accordingly.
A quiet entity never justifies surfacing an unrelated marginal item, and an empty
week stays empty - quiet entities only ADD to a weekly you were already writing.
\`\`\`jsonl
$QUIET_ROWS
\`\`\`"
  fi
fi

# ---- deterministic feed sweep (feeds: lists in the profile/config) ----
# Recall you can audit: pull candidates from the profile's RSS/Atom feeds with a
# plain fetcher BEFORE the agent runs, so "what was swept" is a recorded fact rather
# than whatever the agent happened to browse. The agent scores this list first and
# spends its own browsing budget only on ranked sources no feed covers. Opt-in by
# data (no feeds -> the agentic sweep alone, exactly as before) and fail-safe (a
# fetch problem is a note, never a failed run). monitoring.fetch_max_items=0 disables.
CANDIDATES="state/.candidates.${MODE}.jsonl"
rm -f "$CANDIDATES"
CANDIDATES_NOTE=""
FETCH_MAX="$(cfg_get monitoring fetch_max_items)"
case "$FETCH_MAX" in ''|*[!0-9]*) FETCH_MAX=200 ;; esac
LOOKBACK_HOURS="$(cfg_get monitoring lookback_hours)"
case "$LOOKBACK_HOURS" in ''|*[!0-9]*) LOOKBACK_HOURS=30 ;; esac
FETCH_HOURS="$LOOKBACK_HOURS"
[ "$MODE" = weekly ] && FETCH_HOURS=$(( 24 * 7 + LOOKBACK_HOURS ))

# ---- catch-up lookback (monitoring.catchup_max_hours; 0 = off) ----
# A slept-through or skipped run would otherwise lose its window forever: the next
# run still looks back only lookback_hours, so anything published in the gap is
# never swept. When the last logged run is older than this run's window, widen the
# window to cover the gap - capped at window + catchup_max_hours EXTRA hours (the
# cap bounds the widening, not the window, so the weekly mode - whose normal window
# already exceeds the default cap - can catch up too), so a long-dormant deployment
# can't trigger an unbounded sweep. The newest runs.log row of ANY mode is the right
# baseline: both modes run the same sweep against the shared seen.jsonl, so whatever
# ran last already covered its window. Applies to both the feed pre-sweep and the
# agent's own browsing.
CATCHUP_MAX="$(cfg_get monitoring catchup_max_hours)"
case "$CATCHUP_MAX" in ''|*[!0-9]*) CATCHUP_MAX=168 ;; esac
CATCHUP_NOTE=""
if [ "$CATCHUP_MAX" -gt 0 ] && [ -s state/runs.log ]; then
  # The catch-up baseline is the newest SWEEP. EXCLUDE bootstrap-family rows (all carry
  # "mode":"bootstrap" -- plan/facet/synthesis/challenge) so a re-bootstrap's rows, now
  # also in runs.log, can't masquerade as a sweep and make this run skip widening (losing
  # the gap between the last real sweep and the bootstrap). Excluding (rather than positive-
  # matching "pass":"triage") keeps LEGACY rows that predate per-pass logging and have no
  # `pass` field -- they're still real sweeps and must seed the baseline. runs.log rows are
  # jq-written with a fixed key order; no jq needed here. `|| true` so an all-bootstrap log
  # doesn't trip pipefail.
  last_ts="$(grep -v '"mode":"bootstrap"' state/runs.log 2>/dev/null | tail -n 1 | sed -n 's/.*"timestamp":[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
  last_epoch=""
  if [ -n "$last_ts" ]; then
    # GNU `date -d` vs BSD `date -j -u -f`; give up quietly if neither parses.
    last_epoch="$(date -u -d "$last_ts" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null || true)"
  fi
  if [ -n "$last_epoch" ]; then
    gap_hours=$(( ( $(date +%s) - last_epoch + 3599 ) / 3600 ))   # round up
    if [ "$gap_hours" -gt "$FETCH_HOURS" ]; then
      catchup_hours="$gap_hours"
      cap_hours=$(( FETCH_HOURS + CATCHUP_MAX ))
      [ "$catchup_hours" -gt "$cap_hours" ] && catchup_hours="$cap_hours"
      if [ "$catchup_hours" -gt "$FETCH_HOURS" ]; then
        echo "[monitor:$MODE] catch-up: last run was ~${gap_hours}h ago - widening the sweep window to ${catchup_hours}h (cap: ${FETCH_HOURS}h window + monitoring.catchup_max_hours=$CATCHUP_MAX)" >&2
        FETCH_HOURS="$catchup_hours"
        CATCHUP_NOTE="

CATCH-UP WINDOW: the previous run was ~${gap_hours}h ago (a missed or skipped run),
so this run's window is widened to the last ${catchup_hours} hours. Use that window
everywhere the procedure says to look back monitoring.lookback_hours, so the gap
between runs is covered. Dedup as usual - nothing already in your state file is new."
      fi
    fi
  fi
fi
if [ "$FETCH_MAX" -gt 0 ] && command -v python3 >/dev/null 2>&1 && [ -f bin/fetch.py ]; then
  # --health keeps per-feed sweep health in state/feedhealth.json (the portal's
  # Feed health card): a feed that 404s for weeks or stops publishing is visible
  # coverage rot, not a silently shrinking sweep.
  python3 bin/fetch.py --hours "$FETCH_HOURS" --max "$FETCH_MAX" \
    --seen "$STATE_FILE" --out "$CANDIDATES" --health state/feedhealth.json \
    "$PROFILE" "$CONFIG" 2>> "kb/${TODAY}.${MODE}.err" || true
  if [ -s "$CANDIDATES" ]; then
    n_cand="$(wc -l < "$CANDIDATES" | tr -d ' ')"
    echo "[monitor:$MODE] feed sweep: $n_cand candidate(s) queued in $CANDIDATES" >&2
    CANDIDATES_NOTE="

PRE-FETCHED CANDIDATES: ./$CANDIDATES holds $n_cand item(s) pulled deterministically
from the profile's \`feeds\` (already inside the lookback window and not in your
state file; one JSON object per line: title/url/published/source/feed). This IS the
sweep of those feeds: read it FIRST and dedup + score every item in it exactly like
swept items (fuzzy-title dedup still applies; record each one to the state file as
usual). Do NOT re-fetch those feeds yourself - spend your own browsing only on
ranked news_sources that no feed covers."
  fi
fi

echo "[monitor:$MODE] model=${MODEL:-(CLI default)}${DEEPDIVE_MODEL:+ deepdive=$DEEPDIVE_MODEL}${EDITOR_MODEL:+ editor=$EDITOR_MODEL} $TODAY -> $REPORT"

# Clear this run's scratch files (leftovers from an aborted earlier run).
# $REPORT itself is left untouched until claude succeeds.
rm -f "$RUN_REPORT" "$QUEUE"

# --output-format json so we can log per-run usage below. The agent still writes
# the report to $RUN_REPORT via the Write tool, so empty detection stays file-based
# (the JSON envelope goes to stdout, which we capture instead of the report text).
RUN_JSON="$(${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p "$(cat "$PROMPT")

---
RUN MODE: $MODE
TODAY: $TODAY

Config (subject, anchor, seeds, scope, cadence, thresholds, output, governance):
\`\`\`yaml
$(cat "$CONFIG")
\`\`\`

Approved profile - YOUR GROUND TRUTH (derived blocks + relevance rubric):
\`\`\`yaml
$(cat "$PROFILE")
\`\`\`

Your dedup/state file is $STATE_FILE_REF. Append every newly-evaluated item (full
record for surfaced items, keys+score for dropped ones) so nothing is re-scored.
Your observations file is ./state/observations.jsonl - your longitudinal metric/event
memory for trend detection. When tracking.enabled, read the recent observations for
the tracked entities, append this run's observations, and follow the 'Trend detection'
+ 'What changed' rules in the prompt above (driven by the tracking.* thresholds).
When the forward radar is on, ALSO record forward-dated, time-bounded expectations you
read in the sweep to ./state/horizon.jsonl per the 'Forward radar' rules in the prompt
above, and act on any DUE EXPECTATIONS block below.
Write the $MODE report to ./$RUN_REPORT, following the report rules in the prompt
above - including the show_borderline / 'Considered (below threshold)' handling.
For a daily run, if those rules produce no report at all (no items AND no changes),
write NOTHING to the report file and print exactly NO_MATERIAL_ITEMS.

DEEP-DIVE QUEUE: $DEEPDIVE_STATE. When enabled,
also append your highest-scoring surfaced items - those with score >= $DEEPDIVE_THRESHOLD,
at most $DEEPDIVE_MAX of them, highest first - to ./$QUEUE, one JSON object per line:
{\"url\":...,\"title\":...,\"signal\":...,\"score\":...,\"so_what\":...}. A separate
stronger agent will investigate these and enrich them in the report; you just queue
them. Do not write the queue when it's disabled.$CATCHUP_NOTE$CANDIDATES_NOTE$FEEDBACK_NOTE$HORIZON_NOTE$QUIET_NOTE" \
  ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
  --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
  --disallowedTools "Bash,AskUserQuestion" \
  --permission-mode acceptEdits \
  --max-turns "$MONITOR_MAX_TURNS" \
  --output-format json \
  2>> "kb/${TODAY}.${MODE}.err")"

# claude exited 0 (set -e would have aborted otherwise).
# ---- log per-pass usage to state/runs.log ----
# NOTE: total_cost_usd from the CLI is an API-EQUIVALENT estimate. These runs
# authenticate against the Max subscription, so this is NOT your actual billing -
# it's a relative cost/usage signal for tuning run frequency and --max-turns.
log_usage() {  # <pass-label> <run-json>
  command -v jq >/dev/null 2>&1 || {
    echo "[monitor:$MODE] ERROR: jq not found - usage not logged ($1). Install jq." >&2; return 0; }
  printf '%s' "$2" | jq -c \
    --arg ts "$(date -u +%FT%TZ)" --arg mode "$MODE" --arg date "$TODAY" --arg pass "$1" \
    '{timestamp:$ts, mode:$mode, date:$date, pass:$pass,
      num_turns:.num_turns, duration_ms:.duration_ms, cost_usd:.total_cost_usd,
      input_tokens:.usage.input_tokens, output_tokens:.usage.output_tokens,
      cache_read_input_tokens:.usage.cache_read_input_tokens,
      cache_creation_input_tokens:.usage.cache_creation_input_tokens,
      session_id:.session_id}' >> state/runs.log \
    || echo "[monitor:$MODE] WARNING: could not parse run JSON ($1); usage not logged" >&2
}
log_usage triage "$RUN_JSON"

# ---- deep-dive pass (optional; stronger model on triage's top survivors) ----
# Runs only when models.deepdive is set AND triage produced a report with queued
# candidates - so most days there's no second call and cost is unchanged.
if [ -n "$DEEPDIVE_MODEL" ] && [ "$DEEPDIVE_MAX" -gt 0 ] && [ -s "$RUN_REPORT" ] && [ -s "$QUEUE" ]; then
  # Enforce the cost guard in code: never investigate more than deepdive_max_items,
  # no matter what triage queued.
  head -n "$DEEPDIVE_MAX" "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
  n_dd="$(wc -l < "$QUEUE" | tr -d ' ')"
  echo "[monitor:$MODE] deep-dive: investigating $n_dd item(s) (cap $DEEPDIVE_MAX) on $DEEPDIVE_MODEL" >&2
  if [ -f "$DEEPDIVE_PROMPT" ]; then
    # The deep-dive enriches $RUN_REPORT in place and may append corroborating
    # observations. Back BOTH up first: a failed, timed-out, or report-emptying pass
    # must leave the valid triage report AND the trusted observations intact -
    # enrichment is optional and must be non-destructive.
    cp "$RUN_REPORT" "$RUN_REPORT.pre-dd"
    cp state/observations.jsonl state/observations.jsonl.pre-dd
    dd_rc=0
    DD_JSON="$(${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p "$(cat "$DEEPDIVE_PROMPT")

---
RUN MODE: $MODE
TODAY: $TODAY

Config (subject, anchor, scope, rubric context):
\`\`\`yaml
$(cat "$CONFIG")
\`\`\`

Approved profile - YOUR GROUND TRUTH:
\`\`\`yaml
$(cat "$PROFILE")
\`\`\`

Deep-dive queue (triage's top survivors) is ./$QUEUE, one JSON object per line.
The current report is ./$RUN_REPORT and your longitudinal memory is
./state/observations.jsonl. For each queued item, investigate per the prompt above
(fetch the primary source, corroborate across independent sources, deepen the
so-what with history/context), then EDIT ./$RUN_REPORT in place to enrich exactly
those items - add corroboration status and adjusted confidence, and DOWNGRADE or
flag anything you can't corroborate. Do not remove non-queued items or change the
report's structure." \
      ${DEEPDIVE_MODEL_ARGS[@]+"${DEEPDIVE_MODEL_ARGS[@]}"} \
      --allowedTools "Read,Write,Edit,WebSearch,WebFetch" \
      --disallowedTools "Bash,AskUserQuestion" \
      --permission-mode acceptEdits \
      --max-turns "$DEEPDIVE_MAX_TURNS" \
      --output-format json \
      2>> "kb/${TODAY}.${MODE}.err")" || dd_rc=$?
    if [ "$dd_rc" -eq 0 ] && [ -s "$RUN_REPORT" ]; then
      # Succeeded and left a non-empty report: keep the enrichment + its observations.
      log_usage deepdive "$DD_JSON"
      rm -f "$RUN_REPORT.pre-dd" state/observations.jsonl.pre-dd
      echo "[monitor:$MODE] deep-dive complete" >&2
    else
      # Failed, timed out, or emptied the report: restore the pristine triage report
      # AND observations, and carry on. The report still ships; it just isn't enriched.
      if [ "$dd_rc" -eq 0 ]; then log_usage deepdive "$DD_JSON"; fi   # it ran; account for spend
      mv -f "$RUN_REPORT.pre-dd" "$RUN_REPORT"
      mv -f state/observations.jsonl.pre-dd state/observations.jsonl
      if [ "$dd_rc" -eq 0 ]; then
        echo "[monitor:$MODE] WARNING: deep-dive left an empty report - restored the triage report" >&2
      else
        echo "[monitor:$MODE] WARNING: deep-dive failed (exit $dd_rc) - restored the triage report" >&2
      fi
    fi
  else
    echo "[monitor:$MODE] WARNING: $DEEPDIVE_PROMPT missing - skipping deep-dive (triage report stands)" >&2
  fi
fi
rm -f "$QUEUE" "$CANDIDATES"

# ---- editorial pass (optional; curate + polish the report before delivery) ----
# A dedicated editor runs ONLY when models.editor is set AND triage produced a report
# to deliver, so silent days cost nothing. It re-orders, cuts marginal items, and
# tightens prose to the house style - WITHOUT adding facts, changing figures, or
# dropping any item's source/confidence. Runs after deep-dive (it polishes the
# enriched report) and is non-destructive: a failed or report-emptying pass restores
# the pre-edit report and ships that.
if [ -n "$EDITOR_MODEL" ] && [ -s "$RUN_REPORT" ]; then
  if [ -f "$EDITOR_PROMPT" ]; then
    echo "[monitor:$MODE] editorial pass on $EDITOR_MODEL" >&2
    cp "$RUN_REPORT" "$RUN_REPORT.pre-ed"
    ed_rc=0
    ED_JSON="$(${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p "$(cat "$EDITOR_PROMPT")

---
RUN MODE: $MODE
TODAY: $TODAY

Config (subject, anchor, scope, rubric context):
\`\`\`yaml
$(cat "$CONFIG")
\`\`\`

Approved profile - YOUR GROUND TRUTH:
\`\`\`yaml
$(cat "$PROFILE")
\`\`\`

The drafted report to edit IN PLACE is ./$RUN_REPORT. Edit it per the prompt above:
lead with the single most important finding, order by importance, cut or merge
marginal items, and tighten to the house style. Keep the Markdown shape (bottom-line
blockquote, ## sections, item ids). Do NOT add facts, change any figure, or remove an
item's source link or confidence." \
      ${EDITOR_MODEL_ARGS[@]+"${EDITOR_MODEL_ARGS[@]}"} \
      --allowedTools "Read,Write,Edit" \
      --disallowedTools "Bash,WebSearch,WebFetch,AskUserQuestion" \
      --permission-mode acceptEdits \
      --max-turns "$EDITOR_MAX_TURNS" \
      --output-format json \
      2>> "kb/${TODAY}.${MODE}.err")" || ed_rc=$?
    if [ "$ed_rc" -eq 0 ] && [ -s "$RUN_REPORT" ]; then
      log_usage editor "$ED_JSON"
      rm -f "$RUN_REPORT.pre-ed"
      echo "[monitor:$MODE] editorial pass complete" >&2
    else
      if [ "$ed_rc" -eq 0 ]; then log_usage editor "$ED_JSON"; fi   # it ran; account for spend
      mv -f "$RUN_REPORT.pre-ed" "$RUN_REPORT"
      if [ "$ed_rc" -eq 0 ]; then
        echo "[monitor:$MODE] WARNING: editorial pass left an empty report - kept the unedited report" >&2
      else
        echo "[monitor:$MODE] WARNING: editorial pass failed (exit $ed_rc) - kept the unedited report" >&2
      fi
    fi
  else
    echo "[monitor:$MODE] WARNING: $EDITOR_PROMPT missing - skipping editorial pass (report stands)" >&2
  fi
fi

# ---- forward radar: append the weekly "Coming up" section (tracking.horizon) ----
# After the editor pass (so it can't be paraphrased away) and before the report is
# promoted/delivered: on a WEEKLY run, append a deterministic Coming up table when any
# pending expectation is due inside the horizon window. Appending to the report FILE
# means kb/, email, webhook, and the portal all carry it (unlike bootstrap's email-only
# diff fold). A silent weekly stays silent - the radar adds to a report, it never causes
# one. Fail-safe: any problem ships the report without the section.
if [ "$MODE" = weekly ] && [ -n "$HORIZON_ENABLED" ] && [ -s "$RUN_REPORT" ] \
   && [ -s "$HORIZON" ] && command -v python3 >/dev/null 2>&1 && [ -f bin/horizon.py ]; then
  UPCOMING="$(python3 bin/horizon.py upcoming --as-of "$TODAY" --days "$HORIZON_DAYS" "$HORIZON" 2>/dev/null || true)"
  if [ -n "$UPCOMING" ]; then
    printf '\n\n## Coming up\n\n%s\n' "$UPCOMING" >> "$RUN_REPORT" \
      && echo "[monitor:$MODE] forward radar: appended the Coming up section" >&2
  fi
fi

# ---- profile staleness: carry the warning into the report itself ----
# Same placement rule as the radar above: after the editor pass, so the caveat can't be
# polished away, and into the report FILE so kb/, email, webhook and the portal all
# carry it. Deliberately does NOT create a report - a silent run stays silent, exactly
# like the radar. (The monthly `bootstrap.sh --if-stale` agent is what covers an
# instance whose runs are mostly silent; this is what tells you why the ones that do
# arrive are getting thinner.)
if [ -n "$STALE_NOTE" ] && [ -s "$RUN_REPORT" ]; then
  # Which advice depends on whether a COMPLETE refresh draft is already waiting. After a
  # scheduled refresh succeeds, profile.yaml stays stale by design until a human approves,
  # so the profile is stale AND the work is already done - and telling the operator to run
  # bootstrap.sh there is actively harmful: a manual run is ungated, and its synthesis
  # overwrites the pending draft, discarding review edits and re-spending the research.
  # Same signal bootstrap.sh's --if-stale gate uses, for the same reason.
  if [ -f state/.draft-complete ] && [ -s profile.draft.yaml ] && [ profile.draft.yaml -nt "$PROFILE" ]; then
    # shellcheck disable=SC2016  # backticks are literal Markdown; %s is a printf placeholder
    printf '\n\n---\n\n> _**A refreshed profile is waiting for your approval** - the approved one is %s. The research is already done; do NOT run `./bin/bootstrap.sh` again, which would overwrite the draft. Review `profile.draft.yaml` on the host, then `cp profile.draft.yaml profile.yaml`._\n' \
      "$STALE_NOTE" >> "$RUN_REPORT" \
      && echo "[monitor:$MODE] appended the pending-draft approval notice to the report" >&2
  else
    # shellcheck disable=SC2016  # backticks are literal Markdown; %s is a printf placeholder
    printf '\n\n---\n\n> _**The approved profile is stale** - %s. Its rubric and source list are drifting from the market, so scores drop and relevant items get missed. Refresh with `./bin/bootstrap.sh` on the host, then approve the draft._\n' \
      "$STALE_NOTE" >> "$RUN_REPORT" \
      && echo "[monitor:$MODE] appended the profile-staleness notice to the report" >&2
  fi
fi

# ---- email delivery ----
# The escapers/renderer/template/sender live in bin/email-lib.sh (shared with
# bootstrap.sh); email_report just composes the monitor's chrome and hands off.
email_report() {  # <report-file> <recipient>...
  local report="$1"; shift
  local subject mode_disp
  # Name the monitored subject in the Subject line so several agents (different
  # configs) are distinguishable in one inbox; fall back to the bare tag if unset.
  if [ -n "${SUBJECT_NAME:-}" ]; then
    subject="[Vantage Point: ${SUBJECT_NAME}] $MODE $TODAY"
  else
    subject="[Vantage Point] $MODE $TODAY"
  fi
  case "$MODE" in daily) mode_disp="Daily" ;; weekly) mode_disp="Weekly" ;; *) mode_disp="$MODE" ;; esac
  local VP_TITLE VP_SUBTITLE VP_PREHEADER VP_FOOTER VP_LOGO=""
  VP_TITLE="${SUBJECT_NAME:-Market intelligence}"
  VP_SUBTITLE="${mode_disp} briefing - ${TODAY}"
  VP_PREHEADER="$(email_preheader "$report")"
  VP_FOOTER="Generated by Vantage Point - ${TODAY}"
  # Embed the brand logo in the header when output.email_images is on (send_email
  # degrades gracefully if the asset is missing). Guarded with :- for the test harness,
  # which sources this function without EMAIL_IMAGES/LOGO_ASSET defined.
  [ -n "${EMAIL_IMAGES:-}" ] && VP_LOGO="${LOGO_ASSET:-}"
  send_email "$subject" "$report" "$@"
}

# Promote this run's output to $REPORT only now - so a failed rerun never clobbers
# an earlier report.
# ---- deliver: plug in whatever channel you want ----
REPORT_SHIPPED=""
if [ -s "$RUN_REPORT" ]; then
  mv -f "$RUN_REPORT" "$REPORT"
  REPORT_SHIPPED=1
  echo "[monitor:$MODE] report ready: $REPORT"
  # Email via msmtp when output.email_to is set (configure ~/.msmtprc - see README).
  # Failure to send never fails the run: the report is already safe in $REPORT.
  if [ "${#EMAIL_TO[@]}" -gt 0 ]; then
    email_disp="$(IFS=', '; echo "${EMAIL_TO[*]}")"   # for log lines only
    if command -v msmtp >/dev/null 2>&1; then
      renderer="$(md_renderer)"
      if email_report "$REPORT" "${EMAIL_TO[@]}"; then
        if [ -n "$renderer" ]; then
          echo "[monitor:$MODE] emailed report to $email_disp (HTML via $renderer)"
        else
          echo "[monitor:$MODE] emailed report to $email_disp (plain text - install pandoc or cmark-gfm for HTML)"
        fi
      else
        echo "[monitor:$MODE] WARNING: msmtp failed - report still in $REPORT" >&2
      fi
    else
      echo "[monitor:$MODE] output.email_to set but msmtp not found - skipping email (report in $REPORT)" >&2
    fi
  fi
  # Webhook delivery (output.webhook_url): POST the report as JSON to any URL --
  # a generic receiver, or a Slack/Discord incoming webhook (bin/webhook.py sends
  # a payload each understands). Same fail-safe contract as email: a failed post
  # warns, the run succeeds, the report is already safe in $REPORT.
  if [ -n "$WEBHOOK_URL" ]; then
    if command -v python3 >/dev/null 2>&1 && [ -f bin/webhook.py ]; then
      if [ -n "${SUBJECT_NAME:-}" ]; then
        wh_heading="[Vantage Point: ${SUBJECT_NAME}] $MODE $TODAY"
      else
        wh_heading="[Vantage Point] $MODE $TODAY"
      fi
      if python3 bin/webhook.py "$WEBHOOK_URL" "$wh_heading" "$MODE" "$TODAY" < "$REPORT" 2>> "kb/${TODAY}.${MODE}.err"; then
        echo "[monitor:$MODE] posted report to webhook"
      else
        echo "[monitor:$MODE] WARNING: webhook post failed - report still in $REPORT" >&2
      fi
    else
      echo "[monitor:$MODE] output.webhook_url set but python3/bin/webhook.py not found - skipping webhook (report in $REPORT)" >&2
    fi
  fi
else
  # Nothing material this run. Drop the empty scratch file; leave any existing
  # $REPORT from an earlier successful run today in place.
  rm -f "$RUN_REPORT"
  echo "[monitor:$MODE] nothing material - no report written (silence is correct)."
fi

# ---- quiet detection: remember what was flagged so the same silence never re-alarms ----
# Only after a SHIPPED report, and only for entities the shipped report actually
# names (--report): a silence the agent left out of the report was never delivered,
# so it must re-inject next weekly rather than be suppressed unseen. If the agent
# found activity instead, the entity is in the report as a normal item - it gets
# marked, AND the fresh observation advanced last_seen, so the flag self-voids
# anyway. A failure here is harmless: the worst case is one repeated flag.
if [ -n "$QUIET_ROWS" ] && [ -n "$REPORT_SHIPPED" ]; then
  printf '%s\n' "$QUIET_ROWS" \
    | python3 bin/cadence.py mark --as-of "$TODAY" --report "$REPORT" "$QUIET_STATE" 2>/dev/null \
    || echo "[monitor:$MODE] note: quiet-flag bookkeeping failed (may re-flag next weekly)" >&2
fi

# Re-check the soft budget now that every pass's usage is in runs.log, so the run
# that crossed the cap is the one that warns (no-op if the pre-run check already did).
check_budget

# ---- refresh the kb/index.html portal snapshot (best-effort; never fails the run) ----
# Observations may have updated even on a quiet day, so regenerate every run unless
# output.dashboard is explicitly false. The live portal (bin/portal.sh) reads state on
# each request; this static export keeps a no-server artifact alongside the reports.
if [ "$DASHBOARD" != "false" ] && [ -f bin/portal.py ] && command -v python3 >/dev/null 2>&1; then
  python3 bin/portal.py --export || echo "[monitor:$MODE] WARNING: portal export failed (report is unaffected)" >&2
fi
