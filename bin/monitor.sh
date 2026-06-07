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
  local subject="[market-monitor] $MODE $TODAY"
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
