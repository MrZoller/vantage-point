#!/usr/bin/env bash
# init.sh - guided config interview. Asks the operator a few questions and writes a
# ready-to-bootstrap monitor-config.yaml by substituting the answers into a chosen
# template (a samples/ config or the annotated monitor-config.example.yaml). The
# template's comments and empty `derived:` blocks are preserved, never regenerated -
# they carry the documentation and the profile shape bootstrap and the cfg readers
# rely on. The interview itself is deterministic bash and works fully offline;
# `claude` is used only for ONE optional review step at the end, whose suggestions
# are shown as a diff and applied only on an explicit yes - a failed review never
# loses the assembled draft. Fail-safe: refuses to overwrite an existing config
# without --force, assembles in a temp file, and moves it into place atomically, so
# a failure leaves no partial config behind.
set -euo pipefail

# Make ${var//pat/repl} a strictly literal replace on every bash. Bash 5.2 otherwise
# treats '&' in the replacement as the matched text (patsub_replacement), which would
# corrupt answers containing '&'. No-op on bash < 5.2.
shopt -u patsub_replacement 2>/dev/null || true

# Project root = parent of this script's bin/ dir.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Same PATH export as the agents, so `claude` resolves for the optional review step.
export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Shared config readers (cfg_get / cfg_get_text) - the same parsers the agents use,
# so "does my answer read back?" is checked against the real consumers.
# shellcheck source=bin/config-lib.sh
. "$ROOT/bin/config-lib.sh"

CONFIG="monitor-config.yaml"
DRAFT=".init.draft.yaml"        # assembled here; moved into place at the very end
SUGGEST=".init.suggested.yaml"  # the optional review pass writes its proposal here
EXAMPLE="monitor-config.example.yaml"
NL=$'\n'
FORCE=0

usage() {
  cat <<'EOF'
usage: bin/init.sh [--force]

Guided interview that writes a ready-to-bootstrap monitor-config.yaml from a
template (samples/ or monitor-config.example.yaml). A blank answer keeps the
template's value. Offline-safe: claude is only used for one optional review
step at the end, and its suggestions apply only if you approve them.

  --force   overwrite an existing monitor-config.yaml
EOF
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[init] unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -f "$CONFIG" ] && [ "$FORCE" -ne 1 ]; then
  echo "[init] $CONFIG already exists - re-run with --force to overwrite it" >&2
  exit 1
fi
[ -f "$EXAMPLE" ] || { echo "[init] missing $EXAMPLE" >&2; exit 1; }

# Leave no partial state behind, whatever happens (the final mv is the only step
# that touches $CONFIG).
trap 'rm -f "$DRAFT" "$DRAFT.tmp" "$DRAFT.pre-review" "$SUGGEST"' EXIT

die()  { echo "[init] ERROR: $1" >&2; exit 1; }
note() { echo "[init] $1" >&2; }

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# ask <prompt> [default] -> sets ANSWER. Blank input (or EOF, when answers are
# piped in) falls back to the default, so the wizard never hangs or aborts mid-way.
ANSWER=""
ask() {
  local def="${2:-}" line=""
  if [ -n "$def" ]; then
    printf '%s\n  [default: %s]\n  > ' "$1" "$def"
  else
    printf '%s\n  > ' "$1"
  fi
  IFS= read -r line || line=""
  line="$(trim "$line")"
  if [ -n "$line" ]; then ANSWER="$line"; else ANSWER="$def"; fi
}

ask_yn() {  # <prompt> -> 0 on yes; anything else (incl. blank/EOF) is no
  local line=""
  printf '%s [y/N]: ' "$1"
  IFS= read -r line || line=""
  line="$(trim "$line" | tr '[:upper:]' '[:lower:]')"
  case "$line" in y|yes) return 0 ;; *) return 1 ;; esac
}

# YAML double-quoted scalar: escape only `"` (cfg_get_text unescapes \" and keeps
# backslashes literal, so this is the encoding that round-trips through the repo's
# readers for names containing & / ' / " / #).
yaml_quote() {
  local s="$1"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

esc_dq() { printf '%s' "${1//\"/\\\"}"; }   # escape `"` for text inside quotes

# flow_list <comma-separated phrases> -> `"a", "b", "c"` (each item yaml-quoted)
flow_list() {
  local out="" item
  set -f
  local IFS=','
  for item in $1; do
    item="$(trim "$item")"
    [ -n "$item" ] || continue
    out="$out${out:+, }$(yaml_quote "$item")"
  done
  set +f
  printf '%s' "$out"
}

# comp_item <csv> <n> -> the nth comma-separated item, trimmed ("" if absent)
comp_item() {
  printf '%s\n' "$1" | awk -F',' -v n="$2" '
    { if (n <= NF) { s = $n; gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s); print s } }'
}

# ---- template substitution (same block/key walk as cfg_get, so what we write is
#      exactly what the readers will find) ----

# has_key <block> <key> - does the draft have `key:` anywhere inside `block:`?
has_key() {
  awk -v blk="$1" -v key="$2" '
    /^[^[:space:]#]/ { inblk = ($0 ~ "^" blk ":[[:space:]]*(#.*)?$") }
    inblk && $1 == key":" { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$DRAFT"
}

# subst <mode> <block> <key> <replacement> - replace one `key:` entry inside a
# top-level `block:`, preserving its indentation (first match wins, like cfg_get).
#   scalar    - replace the value on the key line
#   folded    - replace a `key: >` folded scalar and its continuation lines
#   blocklist - replace a block sequence (replacement = newline-separated items)
#   flowlist  - replace a `[...]` flow list, even one spanning lines (replacement =
#               pre-quoted, comma-joined items)
subst() {
  local mode="$1" blk="$2" key="$3"
  if ! REPL="$4" awk -v mode="$mode" -v blk="$blk" -v key="$key" '
    {
      if (skipflow) { if (index($0, "]")) skipflow = 0; next }
      if (skipdeep) {                       # old folded/list continuation lines
        if ($0 ~ /^[[:space:]]*$/) next
        match($0, /^[[:space:]]*/)
        if (RLENGTH > keyind) next
        skipdeep = 0
      }
      if ($0 ~ /^[^[:space:]#]/) inblk = ($0 ~ "^" blk ":[[:space:]]*(#.*)?$")
      if (inblk && !done && $1 == key":") {
        match($0, /^[[:space:]]*/)
        keyind = RLENGTH
        ind = substr($0, 1, RLENGTH)
        if (mode == "scalar") {
          # Keep any trailing comment on the line (template values never
          # contain a space-then-hash), so the annotations survive.
          cmt = ""
          if (match($0, /[[:space:]]+#/)) cmt = substr($0, RSTART)
          printf "%s%s: %s%s\n", ind, key, ENVIRON["REPL"], cmt
        } else if (mode == "folded") {
          printf "%s%s: >\n%s  %s\n", ind, key, ind, ENVIRON["REPL"]
          skipdeep = 1
        } else if (mode == "blocklist") {
          print ind key ":"
          n = split(ENVIRON["REPL"], items, "\n")
          for (i = 1; i <= n; i++) if (items[i] != "") print ind "  - " items[i]
          skipdeep = 1
        } else {                            # flowlist
          printf "%s%s: [%s]\n", ind, key, ENVIRON["REPL"]
          if (index($0, "]") == 0) skipflow = 1
        }
        done = 1
        next
      }
      print
    }
    END { exit done ? 0 : 3 }
  ' "$DRAFT" > "$DRAFT.tmp"; then
    rm -f "$DRAFT.tmp"
    die "could not find $blk.$key in the template to fill in"
  fi
  mv "$DRAFT.tmp" "$DRAFT"
}

# insert_scalar <block> <key> <value> - add `key: value` as the block's first child
# (for knobs a lean sample omits, e.g. output.webhook_url).
insert_scalar() {
  if ! REPL="$3" awk -v blk="$1" -v key="$2" '
    { print }
    !done && $0 ~ "^" blk ":[[:space:]]*(#.*)?$" {
      printf "  %s: %s\n", key, ENVIRON["REPL"]; done = 1
    }
    END { exit done ? 0 : 3 }
  ' "$DRAFT" > "$DRAFT.tmp"; then
    rm -f "$DRAFT.tmp"
    die "template has no top-level $1: block"
  fi
  mv "$DRAFT.tmp" "$DRAFT"
}

set_or_insert() {  # <block> <key> <value>
  if has_key "$1" "$2"; then subst scalar "$1" "$2" "$3"; else insert_scalar "$1" "$2" "$3"; fi
}

# insert_deployment <quoted instance> - a real deployment block right after the
# `version:` line (the commented example in the template stays as documentation).
insert_deployment() {
  if ! REPL="$1" awk '
    { print }
    !done && /^version:/ {
      printf "\ndeployment:\n  instance: %s\n", ENVIRON["REPL"]; done = 1
    }
    END { exit done ? 0 : 3 }
  ' "$DRAFT" > "$DRAFT.tmp"; then
    rm -f "$DRAFT.tmp"
    die "template has no version: line to anchor the deployment block"
  fi
  mv "$DRAFT.tmp" "$DRAFT"
}

# current_block_list <block> <key> - print the template's list items (display aid)
current_block_list() {
  awk -v blk="$1" -v key="$2" '
    /^[^[:space:]#]/ { inblk = ($0 ~ "^" blk ":[[:space:]]*(#.*)?$"); inkey = 0 }
    inblk && !inkey && $1 == key":" { match($0, /^[[:space:]]*/); keyind = RLENGTH; inkey = 1; next }
    inkey {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= keyind) { inkey = 0; next }
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      if (line != "" && line !~ /^[[:space:]]*#/) print line
    }
  ' "$DRAFT"
}

# ---- validation ----

# roundtrip_text/_plain <block> <key> <expected> - what we wrote must read back
# EXACTLY through the same readers the agents use, or we refuse to ship the config.
roundtrip_text() {
  local got
  got="$(cfg_get_text "$1" "$2" "$DRAFT")"
  [ "$got" = "$3" ] || die "$1.$2 does not round-trip through the config readers (wrote [$3], read back [$got]) - avoid backslashes in this value"
}
roundtrip_plain() {
  local got
  got="$(cfg_get "$1" "$2" "$DRAFT")"
  [ "$got" = "$3" ] || die "$1.$2 does not round-trip through the config readers (wrote [$3], read back [$got])"
}

# validate_config <file> - the structural checks every shippable config must pass
# (the same ones tests/run.sh applies to the samples). Prints why on failure.
validate_config() {
  local f="$1" blk missing=""
  [ -s "$f" ] || { echo " file is empty"; return 1; }
  [ -n "$(cfg_get models monitor "$f")" ]      || missing="$missing models.monitor"
  [ -n "$(cfg_get_text subject name "$f")" ]   || missing="$missing subject.name"
  [ -n "$(cfg_get_text anchor name "$f")" ]    || missing="$missing anchor.name"
  [ -n "$(cfg_get relevance threshold "$f")" ] || missing="$missing relevance.threshold"
  for blk in budgets subject anchor relevance monitoring tracking output governance; do
    grep -q "^$blk:" "$f" || missing="$missing $blk:"
  done
  [ -z "$missing" ] || { echo "$missing"; return 1; }
}

# ---- optional claude review (suggestions only; never silently applied) ----
# Model follows the repo's models.<pass> convention, read from the draft itself
# (init runs before monitor-config.yaml exists, so the draft IS the config):
# models.init -> models.bootstrap -> CLI default, each fallback with a stderr note.
run_review() {
  local model turns review_rc=0 model_args=()
  model="$(cfg_get models init "$DRAFT")"
  if [ -z "$model" ]; then
    note "models.init not set in the draft - falling back to models.bootstrap"
    model="$(cfg_get models bootstrap "$DRAFT")"
  fi
  if [ -n "$model" ]; then
    model_args=(--model "$model")
  else
    note "models.bootstrap not set either - using CLI default model"
  fi
  turns="$(cfg_get budgets init_max_turns "$DRAFT")"
  case "$turns" in ''|0|*[!0-9]*) turns=15 ;; esac
  if ! command -v claude >/dev/null 2>&1; then
    note "claude not found on PATH - skipping the review (the wizard needs no model)"
    return 1
  fi
  rm -f "$SUGGEST"
  note "review pass (model=${model:-CLI default}) - suggestions only; nothing applies without your yes"
  # The review agent has Write access, so snapshot the draft and restore it
  # unconditionally afterwards: $SUGGEST is the ONLY channel for its output, and a
  # direct edit to the draft can never slip past the apply-on-yes gate below.
  cp "$DRAFT" "$DRAFT.pre-review"
  # stdin from /dev/null so the review can never swallow the interview's answers.
  claude -p "You are reviewing a freshly assembled Vantage Point monitor-config.yaml
draft before its operator runs the bootstrap research pass. Read ./$DRAFT. Suggest
improvements ONLY to the human-authored fields: sharper subject scope phrasing (the
in/out lists), better or missing seed URLs, missed competitors or watch entities, and
a crisper subject description. Write a complete improved copy of the config to
./$SUGGEST, preserving every comment, all structure, and the empty derived: blocks
exactly as they are - change only values you are improving, keep every value readable
by simple line-based YAML readers (double-quote scalars containing special
characters), and do NOT touch $CONFIG or any other file. Then print a short bulleted
summary of what you changed and why, for the operator to judge." \
      ${model_args[@]+"${model_args[@]}"} \
      --allowedTools "Read,Write,WebSearch,WebFetch" \
      --disallowedTools "Bash" \
      --permission-mode acceptEdits \
      --max-turns "$turns" \
      --output-format text \
      < /dev/null 2> init.err || review_rc=$?
  mv -f "$DRAFT.pre-review" "$DRAFT"
  if [ "$review_rc" -ne 0 ]; then
    note "WARNING: review pass failed (see init.err) - keeping your draft unchanged"
    rm -f "$SUGGEST"
    return 1
  fi
  rm -f init.err
  if [ ! -s "$SUGGEST" ]; then
    note "WARNING: review produced no suggested config - keeping your draft unchanged"
    return 1
  fi
  local why
  if ! why="$(validate_config "$SUGGEST")"; then
    note "WARNING: the suggested config failed validation (missing:$why) - keeping your draft unchanged"
    rm -f "$SUGGEST"
    return 1
  fi
  return 0
}

# ============================== the interview ==============================

echo "Vantage Point - guided setup"
echo "============================"
echo "This interview writes $CONFIG. A blank answer keeps the template's value."
echo

# ---- pick a starting template ----
TPL_FILES=("$EXAMPLE")
TPL_DESCS=("Blank slate - the fully annotated reference template")
TAB=$'\t'
SAMPLES_TSV=""
if [ -f samples/README.md ]; then
  # The samples table: `| [\`file.yaml\`](file.yaml) | Use case... | ... |`
  SAMPLES_TSV="$(awk -F'|' '/^\|[[:space:]]*\[`/ {
      f = $2; sub(/[^`]*`/, "", f); sub(/`.*/, "", f)
      d = $3; gsub(/^[[:space:]]+/, "", d); gsub(/[[:space:]]+$/, "", d)
      printf "%s\t%s\n", f, d
    }' samples/README.md)"
fi
if [ -n "$SAMPLES_TSV" ]; then
  while IFS="$TAB" read -r f d; do
    [ -f "samples/$f" ] || continue
    TPL_FILES+=("samples/$f")
    TPL_DESCS+=("$d")
  done <<< "$SAMPLES_TSV"
fi
# Any sample the README table missed still gets offered, by filename.
for s in samples/*.yaml; do
  [ -f "$s" ] || continue
  LISTED=0
  for t in "${TPL_FILES[@]}"; do
    if [ "$t" = "$s" ]; then LISTED=1; fi
  done
  if [ "$LISTED" -eq 0 ]; then
    TPL_FILES+=("$s")
    TPL_DESCS+=("$(basename "$s")")
  fi
done

echo "Starting templates (pick the closest fit; everything is editable afterwards):"
i=0
while [ "$i" -lt "${#TPL_FILES[@]}" ]; do
  printf '  %d) %s\n       (%s)\n' "$((i + 1))" "${TPL_DESCS[$i]}" "${TPL_FILES[$i]}"
  i=$((i + 1))
done
while :; do
  ask "Start from which template? (number)" "1"
  case "$ANSWER" in
    *[!0-9]*) note "please answer with a number from the list"; continue ;;
  esac
  if [ "$ANSWER" -ge 1 ] && [ "$ANSWER" -le "${#TPL_FILES[@]}" ]; then break; fi
  note "please answer with a number from the list"
done
TPL="${TPL_FILES[$((ANSWER - 1))]}"
cp "$TPL" "$DRAFT"
note "starting from $TPL"

# ---- subject: WHAT to watch ----
echo
echo "--- Subject: WHAT to watch (the market) ---"
CUR="$(cfg_get_text subject name "$DRAFT")"
ask "Subject name (subject.name) - the market/space to monitor" "$CUR"
SUBJECT_NAME="$ANSWER"
[ -n "$SUBJECT_NAME" ] || die "subject.name must not be empty"

ask "One-or-two-sentence subject description (blank keeps the template's)" ""
SUBJECT_DESC="$ANSWER"

echo
echo "Seed URLs - trusted starting points the agent expands outward from."
echo "The template currently seeds:"
current_block_list subject seeds | sed 's/^/    /'
echo "Enter one http(s) URL per line; finish with a blank line. A blank first"
echo "line keeps the template's seeds."
SEEDS=""
while :; do
  printf '  seed> '
  LINE=""
  IFS= read -r LINE || LINE=""
  LINE="$(trim "$LINE")"
  [ -n "$LINE" ] || break
  case "$LINE" in
    *' '*|*'"'*|*"'"*) note "a seed URL cannot contain spaces or quotes - ignored: $LINE" ;;
    http://*|https://*) SEEDS="$SEEDS$LINE$NL" ;;
    *) note "not an http(s) URL - ignored: $LINE" ;;
  esac
done

ask "Scope IN - what counts, as comma-separated phrases (blank keeps the template's)" ""
SCOPE_IN="$ANSWER"
ask "Scope OUT - what to filter, as comma-separated phrases (blank keeps the template's)" ""
SCOPE_OUT="$ANSWER"

# ---- anchor: WHOSE interests define relevance ----
echo
echo "--- Anchor: WHOSE interests define relevance ---"
CUR="$(cfg_get_text anchor name "$DRAFT")"
ask "Anchor name (anchor.name) - the org/team/person the briefs are for" "$CUR"
ANCHOR_NAME="$ANSWER"
[ -n "$ANCHOR_NAME" ] || die "anchor.name must not be empty"

CUR="$(cfg_get anchor type "$DRAFT")"
while :; do
  ask "Anchor type: organization / individual / persona" "$CUR"
  ANCHOR_TYPE="$(printf '%s' "$ANSWER" | tr '[:upper:]' '[:lower:]')"
  case "$ANCHOR_TYPE" in
    organization|individual|persona) break ;;
    *) note "please answer organization, individual, or persona" ;;
  esac
done

CUR="$(cfg_get_text anchor relationship_to_subject "$DRAFT")"
ask "Anchor's relationship to the subject (competitor / builder / buyer / investor / regulator / ...)" "$CUR"
ANCHOR_REL="$ANSWER"
[ -n "$ANCHOR_REL" ] || die "anchor.relationship_to_subject must not be empty"

COMPETITORS=""
if has_key anchor competitors; then
  ask "Competitors you measure against, comma-separated (blank keeps the template's placeholders)" ""
  COMPETITORS="$ANSWER"
fi

# ---- delivery & deployment ----
echo
echo "--- Delivery & deployment ---"
CUR="$(cfg_get output email_to "$DRAFT")"
EMAIL="$CUR"
while :; do
  ask "Email reports to (output.email_to; blank = no email, read from kb/)" "$CUR"
  EMAIL="$ANSWER"
  [ -z "$EMAIL" ] && break
  case "$EMAIL" in
    *' '*) note "an email address cannot contain spaces" ;;
    *@*) break ;;
    *) note "that does not look like an email address" ;;
  esac
done

CUR="$(cfg_get output webhook_url "$DRAFT")"
WEBHOOK="$CUR"
while :; do
  ask "Webhook URL (output.webhook_url; Slack/Discord/generic; blank = off)" "$CUR"
  WEBHOOK="$ANSWER"
  [ -z "$WEBHOOK" ] && break
  case "$WEBHOOK" in
    *' '*) note "a webhook URL cannot contain spaces" ;;
    http://*|https://*) break ;;
    *) note "a webhook URL must start with http:// or https://" ;;
  esac
done

INSTANCE=""
while :; do
  ask "deployment.instance - only for SEVERAL clones on one machine (blank = single deployment)" ""
  INSTANCE="$ANSWER"
  [ -z "$INSTANCE" ] && break
  SLUG="$(printf '%s' "$INSTANCE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
  case "$SLUG" in
    *[a-z0-9]*) break ;;
    *) note "the instance name needs at least one letter or digit" ;;
  esac
done

# ---- assemble: substitute the answers into the template ----
echo
note "assembling the config"
subst scalar subject name "$(yaml_quote "$SUBJECT_NAME")"
if [ -n "$SUBJECT_DESC" ]; then subst folded subject description "$SUBJECT_DESC"; fi
if [ -n "$SEEDS" ];        then subst blocklist subject seeds "$SEEDS"; fi
if [ -n "$SCOPE_IN" ];     then subst flowlist subject in "$(flow_list "$SCOPE_IN")"; fi
if [ -n "$SCOPE_OUT" ];    then subst flowlist subject out "$(flow_list "$SCOPE_OUT")"; fi
subst scalar anchor name "$(yaml_quote "$ANCHOR_NAME")"
subst scalar anchor type "$ANCHOR_TYPE"
subst scalar anchor relationship_to_subject "$(yaml_quote "$ANCHOR_REL")"
if [ -n "$COMPETITORS" ]; then
  subst flowlist anchor competitors "$(flow_list "$COMPETITORS")"
  # Retarget the template's <competitor X> markers elsewhere (tracking.watch), so
  # the must-track list points at the real names. Missing slots keep placeholders.
  C1="$(comp_item "$COMPETITORS" 1)"
  C2="$(comp_item "$COMPETITORS" 2)"
  C3="$(comp_item "$COMPETITORS" 3)"
  CONTENT="$(cat "$DRAFT")"
  if [ -n "$C1" ]; then CONTENT="${CONTENT//<competitor A>/$(esc_dq "$C1")}"; fi
  if [ -n "$C2" ]; then CONTENT="${CONTENT//<competitor B>/$(esc_dq "$C2")}"; fi
  if [ -n "$C3" ]; then CONTENT="${CONTENT//<competitor C>/$(esc_dq "$C3")}"; fi
  printf '%s\n' "$CONTENT" > "$DRAFT.tmp"
  mv "$DRAFT.tmp" "$DRAFT"
fi
set_or_insert output email_to "$(yaml_quote "$EMAIL")"
if [ -n "$WEBHOOK" ];  then set_or_insert output webhook_url "$(yaml_quote "$WEBHOOK")"; fi
if [ -n "$INSTANCE" ]; then insert_deployment "$(yaml_quote "$INSTANCE")"; fi

# Every answer must read back exactly through the readers the agents use.
roundtrip_text  subject name "$SUBJECT_NAME"
roundtrip_text  anchor name "$ANCHOR_NAME"
roundtrip_plain anchor type "$ANCHOR_TYPE"
roundtrip_text  anchor relationship_to_subject "$ANCHOR_REL"
roundtrip_plain output email_to "$EMAIL"
if [ -n "$WEBHOOK" ];  then roundtrip_plain output webhook_url "$WEBHOOK"; fi
if [ -n "$INSTANCE" ]; then roundtrip_text deployment instance "$INSTANCE"; fi

if ! WHY="$(validate_config "$DRAFT")"; then
  die "the assembled draft failed validation (missing:$WHY)"
fi
note "draft assembled and validated"

# ---- optional claude review (fully skippable; the wizard needs no model) ----
echo
if ask_yn "Have claude review the draft and suggest improvements? (optional; one bounded call)"; then
  if run_review; then
    echo
    echo "--- suggested changes (diff against your draft) ---"
    diff -u "$DRAFT" "$SUGGEST" || true
    echo "---------------------------------------------------"
    if ask_yn "Apply these suggestions?"; then
      mv -f "$SUGGEST" "$DRAFT"
      note "suggestions applied"
    else
      rm -f "$SUGGEST"
      note "suggestions discarded - keeping your answers as-is"
    fi
  fi
fi

# ---- ship it (atomically; the only write to $CONFIG in the whole script) ----
if ! WHY="$(validate_config "$DRAFT")"; then
  die "the final draft failed validation (missing:$WHY)"
fi
mv "$DRAFT" "$CONFIG"
echo
echo "[init] wrote $CONFIG (from $TPL)"
echo "[init] next steps:"
echo "         ./bin/bootstrap.sh                     # deep research -> profile.draft.yaml"
echo "         \$EDITOR profile.draft.yaml             # review the derived blocks"
echo "         cp profile.draft.yaml profile.yaml     # approve (the quality gate)"
echo "         ./bin/monitor.sh daily                 # first run"
if ask_yn "Run ./bin/bootstrap.sh now (the deep research pass)?"; then
  echo "[init] starting bootstrap"
  exec ./bin/bootstrap.sh
fi
echo "[init] done - run ./bin/bootstrap.sh whenever you're ready"
