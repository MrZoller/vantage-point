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

# Read a single scalar `key:` nested under a top-level YAML `block:` from a config
# file, dependency-light (no YAML lib). Prints the value (comment/quotes/space
# stripped) or nothing. Always returns 0, so `x="$(cfg_get ...)"` is safe under set -e.
cfg_get() {  # <block> <key> [file=$CONFIG]
  awk -v blk="$1" -v key="$2" '
    $0 ~ "^" blk ":[[:space:]]*(#.*)?$" { inblk=1; next }
    inblk && /^[^[:space:]#]/           { inblk=0 }
    inblk && $1 == key":" {
      line=$0
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  key: "
      sub(/[[:space:]]*#.*$/, "", line)                  # drop trailing comment
      gsub(/[[:space:]]/, "", line)                      # drop surrounding space
      gsub(/["\047]/, "", line)                          # drop quotes
      print line; exit
    }
  ' "${3:-$CONFIG}"
}

# Like cfg_get but PRESERVES internal spaces — for human-readable values such as
# subject.name. Trims ends, then unwraps surrounding quotes (taking the quoted text
# literally) or, if unquoted, drops a trailing "# comment".
cfg_get_text() {  # <block> <key> [file=$CONFIG]
  awk -v blk="$1" -v key="$2" '
    $0 ~ "^" blk ":[[:space:]]*(#.*)?$" { inblk=1; next }
    inblk && /^[^[:space:]#]/           { inblk=0 }
    inblk && $1 == key":" {
      line=$0
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", line)   # drop "  key: "
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line ~ /^".*"/)         { sub(/^"/, "", line); sub(/".*$/, "", line) }
      else if (line ~ /^\047.*\047/) { sub(/^\047/, "", line); sub(/\047.*$/, "", line) }
      else                        { sub(/[[:space:]]*#.*$/, "", line); sub(/[[:space:]]+$/, "", line) }
      print line; exit
    }
  ' "${3:-$CONFIG}"
}

# ---- config knobs (all optional; sane fallbacks) ----
MODEL="$(cfg_get models monitor)"
EMAIL_TO="$(cfg_get output email_to)"
SUBJECT_NAME="$(cfg_get_text subject name)"
RUN_TIMEOUT="$(cfg_get monitoring run_timeout_seconds)"
STATE_MAX_LINES="$(cfg_get monitoring state_max_lines)"
REFRESH_DAYS="$(cfg_get governance profile_refresh_days)"
case "$RUN_TIMEOUT"     in ''|*[!0-9]*) RUN_TIMEOUT=1800 ;; esac
case "$STATE_MAX_LINES" in ''|*[!0-9]*) STATE_MAX_LINES=5000 ;; esac
case "$REFRESH_DAYS"    in *[!0-9]*)    REFRESH_DAYS="" ;; esac   # blank/non-numeric -> skip check

# ---- single-run lock (shared across modes) ----
# daily and weekly share state/seen.jsonl, so ONE lock guards all modes — never two
# monitors at once, whatever the mode (so keep the daily/weekly schedules from
# overlapping; the defaults are 30 min apart). An overlapping or manual run just
# skips. A crashed run leaves a stale lock; it's reclaimed when its owner process is
# gone. We identify the owner by PID *and* start time, so a recycled PID (different
# start time) is correctly seen as stale and a live owner is never reclaimed — no
# matter how long it runs (claude + email/render), and regardless of whether a
# timeout is configured or enforceable.
LOCK="state/.lock"
LOCK_SETUP_GRACE=30   # secs a lock may sit without an owner token before its creator is assumed dead

proc_start() {  # normalized start time of pid $1 (empty if it isn't running)
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
  # — concurrent reclaimers can't both end up owning.
  mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null && rm -rf "$LOCK.stale.$$"
  mkdir "$LOCK" 2>/dev/null
}

if acquire_lock; then
  printf '%s %s\n' "$$" "$(proc_start "$$")" > "$LOCK/owner"
else
  echo "[monitor:$MODE] another run is in progress — skipping" >&2
  exit 0
fi

# Release the lock on exit, and surface a hard failure (a set -e abort — e.g. the
# claude run errored or timed out) that would otherwise vanish into the launchd log.
cleanup() {
  local rc=$?
  rm -rf "$LOCK" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    echo "[monitor:$MODE] run FAILED (exit $rc) — see kb/${TODAY}.${MODE}.err" >&2
  fi
  return 0
}
trap cleanup EXIT

# Pass --model only when set; otherwise omit it so the CLI default applies.
MODEL_ARGS=()
if [ -n "$MODEL" ]; then
  MODEL_ARGS=(--model "$MODEL")
else
  echo "[monitor:$MODE] models.monitor not set in $CONFIG — using CLI default model" >&2
fi

# Wall-clock bound on the claude run so a network stall can't hang the job forever.
# 0 disables it; needs timeout/gtimeout (coreutils) — skipped with a note if absent.
TIMEOUT_CMD=()
if [ "$RUN_TIMEOUT" != 0 ]; then
  if   command -v timeout  >/dev/null 2>&1; then TIMEOUT_CMD=(timeout  "$RUN_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD=(gtimeout "$RUN_TIMEOUT")
  else echo "[monitor:$MODE] note: no timeout/gtimeout — run is not time-bounded (brew install coreutils)" >&2
  fi
fi

# ---- prune state so seen.jsonl can't grow without bound (0 disables) ----
# Cap by line count: schema-agnostic and generous vs the dedup window, so this
# never drops anything still relevant. We hold the lock, so there's no concurrent
# writer. Prune before the run so claude reads a bounded file.
if [ "$STATE_MAX_LINES" -gt 0 ]; then
  cur_lines="$(wc -l < state/seen.jsonl)"
  if [ "$cur_lines" -gt "$STATE_MAX_LINES" ]; then
    tail -n "$STATE_MAX_LINES" state/seen.jsonl > state/seen.jsonl.tmp \
      && mv state/seen.jsonl.tmp state/seen.jsonl
    echo "[monitor:$MODE] pruned state/seen.jsonl: $cur_lines -> $STATE_MAX_LINES lines" >&2
  fi
fi

# ---- profile staleness (governance.profile_refresh_days) ----
# Anchors drift; a stale profile silently mis-scores. Warn (don't refuse) when the
# approved profile is older than the refresh window.
if [ -n "$REFRESH_DAYS" ] && [ "$REFRESH_DAYS" -gt 0 ]; then
  last_boot="$(cfg_get subject last_bootstrapped "$PROFILE")"
  case "$last_boot" in ''|null) last_boot="$(cfg_get anchor last_bootstrapped "$PROFILE")" ;; esac
  # GNU `date -d` and BSD `date -j -f` differ; try both, give up quietly if neither parses.
  boot_epoch="$(date -d "$last_boot" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$last_boot" +%s 2>/dev/null || true)"
  if [ -n "$boot_epoch" ]; then
    age_days=$(( ( $(date +%s) - boot_epoch ) / 86400 ))
    if [ "$age_days" -gt "$REFRESH_DAYS" ]; then
      echo "[monitor:$MODE] WARNING: profile is ${age_days}d old (> profile_refresh_days=$REFRESH_DAYS) — re-run bin/bootstrap.sh to refresh" >&2
    fi
  else
    echo "[monitor:$MODE] note: couldn't parse profile last_bootstrapped ('$last_boot') — skipping staleness check" >&2
  fi
fi

echo "[monitor:$MODE] model=${MODEL:-(CLI default)} $TODAY -> $REPORT"

# Clear only this run's scratch file (a leftover from an aborted earlier run).
# $REPORT itself is left untouched until claude succeeds.
rm -f "$RUN_REPORT"

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

# ---- email helpers ----
# Pick the first available markdown->HTML renderer (none -> empty string).
# Always returns 0 so `renderer="$(md_renderer)"` is safe under `set -e` when no
# renderer is installed (the common case).
md_renderer() {
  local r
  for r in pandoc cmark-gfm cmark; do
    command -v "$r" >/dev/null 2>&1 && { echo "$r"; return 0; }
  done
  return 0
}

# stdin: markdown -> stdout: HTML fragment. Returns nonzero if no renderer exists,
# so callers can fall back to plain text. Bare URLs become clickable where the
# renderer supports autolinking (pandoc gfm, cmark-gfm).
render_md_to_html() {
  case "$(md_renderer)" in
    pandoc)    pandoc -f gfm -t html ;;
    cmark-gfm) cmark-gfm -e autolink -e table -e strikethrough -e tagfilter ;;
    cmark)     cmark ;;
    *)         return 1 ;;
  esac
}

# stdin: HTML fragment -> stdout: full styled HTML document. A <style> block (not
# inline styles) is enough for the clients this tool targets; keeps it readable.
wrap_html() {
  cat <<'HTML_HEAD'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
         line-height: 1.5; color: #1a1a1a; max-width: 680px; margin: 0 auto; padding: 16px; }
  h1, h2, h3 { line-height: 1.25; margin: 1.2em 0 0.4em; }
  h1 { font-size: 1.5em; } h2 { font-size: 1.25em; } h3 { font-size: 1.05em; }
  a { color: #0b66c3; }
  ul, ol { padding-left: 1.4em; } li { margin: 0.2em 0; }
  code { background: #f2f2f2; padding: 0.1em 0.3em; border-radius: 3px; }
  pre { background: #f6f8fa; padding: 12px; border-radius: 6px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  blockquote { border-left: 3px solid #ddd; margin: 0.6em 0; padding-left: 12px; color: #555; }
  hr { border: none; border-top: 1px solid #e3e3e3; margin: 1.5em 0; }
  table { border-collapse: collapse; } th, td { border: 1px solid #ddd; padding: 6px 10px; }
</style>
</head>
<body>
HTML_HEAD
  cat
  cat <<'HTML_FOOT'
</body>
</html>
HTML_FOOT
}

# Email the report. Sends multipart/alternative (markdown text + rendered HTML)
# when a renderer is available; otherwise a utf-8 plain-text message. The report
# itself is unchanged on disk. Returns msmtp's exit status.
email_report() {
  local to="$1" report="$2"
  # Name the monitored subject in the Subject line so several agents (different
  # configs) are distinguishable in one inbox; fall back to the bare tag if unset.
  local subject
  if [ -n "${SUBJECT_NAME:-}" ]; then
    subject="[market-monitor: ${SUBJECT_NAME}] $MODE $TODAY"
  else
    subject="[market-monitor] $MODE $TODAY"
  fi
  local html
  if html="$(render_md_to_html < "$report" 2>/dev/null)" && [ -n "$html" ]; then
    local boundary="mm-${TODAY}-$$"
    {
      printf 'To: %s\n' "$to"
      printf 'Subject: %s\n' "$subject"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$boundary"
      printf -- '--%s\n' "$boundary"
      printf 'Content-Type: text/plain; charset=utf-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'
      cat "$report"; printf '\n'
      printf -- '--%s\n' "$boundary"
      printf 'Content-Type: text/html; charset=utf-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'
      printf '%s\n' "$html" | wrap_html
      printf '\n--%s--\n' "$boundary"
    } | msmtp "$to"
  else
    # No renderer (or render failed): plain text, but declare utf-8 so the
    # bullets/arrows/em-dashes in reports don't get mangled.
    {
      printf 'To: %s\n' "$to"
      printf 'Subject: %s\n' "$subject"
      printf 'MIME-Version: 1.0\n'
      printf 'Content-Type: text/plain; charset=utf-8\n'
      printf 'Content-Transfer-Encoding: 8bit\n\n'
      cat "$report"
    } | msmtp "$to"
  fi
}

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
      renderer="$(md_renderer)"
      if email_report "$EMAIL_TO" "$REPORT"; then
        if [ -n "$renderer" ]; then
          echo "[monitor:$MODE] emailed report to $EMAIL_TO (HTML via $renderer)"
        else
          echo "[monitor:$MODE] emailed report to $EMAIL_TO (plain text — install pandoc or cmark-gfm for HTML)"
        fi
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
