#!/usr/bin/env bash
# tests/run.sh — fast, dependency-light checks for the parts of the scripts that
# don't require the `claude` CLI. Run locally with `bash tests/run.sh`; CI runs
# the same file. Each check prints PASS/FAIL; the script exits nonzero if any fail.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }
# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}
# assert_contains <name> <haystack> <needle>
assert_contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing [$3])" ;; esac
}

# Write an msmtp stub that captures the message it's piped to into $MSG_OUT (which
# the stub reads from its environment at runtime, so callers must `export` it).
write_capture_msmtp() {
  # shellcheck disable=SC2016  # $MSG_OUT is intentionally expanded at stub runtime
  printf '#!/usr/bin/env bash\ncat > "$MSG_OUT"\nexit 0\n' > "$1"
  chmod +x "$1"
}

# A stub bin dir for the install-launchd tests: no-op launchctl/plutil + a msmtp.
make_install_stubs() {
  local dir="$1"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/launchctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/plutil"
  write_capture_msmtp "$dir/msmtp"
  chmod +x "$dir/launchctl" "$dir/plutil"
}

# A minimal PATH dir containing ONLY bash, cat, and a capturing msmtp — and no
# markdown renderer, whatever the host has installed. Lets the email tests pin
# which branch (plain vs HTML) they exercise instead of depending on /usr/bin.
make_min_bin() {
  local dir="$1"
  mkdir -p "$dir"
  ln -s "$(command -v bash)" "$dir/bash"
  ln -s "$(command -v cat)" "$dir/cat"
  write_capture_msmtp "$dir/msmtp"
}

# assert_plist_ok <desc> <plist path> <expected ProgramArguments[0]>
# Asserts the generated plist exists, has no leftover token, is valid XML, and its
# program path decodes back to the expected value.
assert_plist_ok() {
  if [ ! -f "$2" ]; then fail "$1: plist exists"; return; fi
  pass "$1: plist exists"
  if grep -q '__MM_ROOT__' "$2"; then fail "$1: no __MM_ROOT__ token remains"; else pass "$1: no __MM_ROOT__ token remains"; fi
  local got
  got="$(python3 - "$2" <<'PY'
import sys, plistlib
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f)["ProgramArguments"][0])
PY
)"
  assert_eq "$1: valid XML and path round-trips" "$3" "$got"
}

echo "== install-launchd: generates valid, path-substituted plists (daily + weekly) =="
test_install_launchd() {
  # Simulate a checkout under a path with XML-special chars (the regression that
  # broke sed templating + produced invalid XML).
  local co="$TMP/a&b<c>d/checkout"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  local home="$TMP/home" rc; mkdir -p "$home"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "installer exits 0" "0" "$rc"
  local la="$home/Library/LaunchAgents"
  assert_plist_ok "daily"  "$la/ai.zoller.marketmonitor.daily.plist"  "$co/bin/monitor.sh"
  assert_plist_ok "weekly" "$la/ai.zoller.marketmonitor.weekly.plist" "$co/bin/monitor.sh"
}
test_install_launchd

echo "== install-launchd uninstall: removes both agents =="
test_uninstall() {
  local co="$TMP/uninst/checkout"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  local home="$TMP/home2"; mkdir -p "$home"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 )
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" uninstall >/dev/null 2>&1 )
  local la="$home/Library/LaunchAgents"
  if [ -f "$la/ai.zoller.marketmonitor.daily.plist" ] || [ -f "$la/ai.zoller.marketmonitor.weekly.plist" ]; then
    fail "uninstall removed both plists"
  else
    pass "uninstall removed both plists"
  fi
}
test_uninstall

echo "== monitor.sh: argument + review-gate behavior (no claude needed) =="
test_monitor_gates() {
  # Run from an ISOLATED copy with no profile.yaml, so the review gate always
  # triggers regardless of whether the developer approved one in the real
  # checkout — otherwise this test could fall through and spend a real claude run.
  local rc out repo="$TMP/gaterepo"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/monitor.sh" "$repo/bin/"
  # Bogus mode exits 2 before touching the filesystem.
  ( bash "$repo/bin/monitor.sh" bogus >/dev/null 2>&1 ); rc=$?
  assert_eq "rejects an invalid mode with exit 2" "2" "$rc"
  # Valid mode, but this copy has no profile.yaml -> exits 1 at the review gate.
  out="$( bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "refuses to run without an approved profile (exit 1)" "1" "$rc"
  assert_contains "review-gate message mentions profile.yaml" "$out" "profile.yaml"
}
test_monitor_gates

echo "== email helpers: plain-text fallback and HTML multipart =="
test_email_helpers() {
  # Extract just the email helper functions from monitor.sh (between the markers
  # added for exactly this purpose) so we can unit-test them without claude.
  local funcs="$TMP/emailfuncs.sh"
  awk '/^# ---- email helpers ----/{f=1} /^# Promote this run.s output/{f=0} f' \
    "$ROOT/bin/monitor.sh" > "$funcs"
  if grep -q 'email_report()' "$funcs"; then
    pass "extracted email helpers from monitor.sh"
  else
    fail "extracted email helpers from monitor.sh"; return
  fi

  local report="$TMP/report.md"
  printf '# Daily — 1 item\n\n* item with a bare url https://example.com/x\n' > "$report"

  # ---- plain-text fallback: PATH has NO renderer (deterministic, host-independent) ----
  local pbin="$TMP/pbin"; make_min_bin "$pbin"
  local plain="$TMP/plain.eml"
  ( set -e
    # shellcheck disable=SC2030  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$plain" PATH="$pbin"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report to@example.com "$report" )
  local ptype
  ptype="$(python3 - "$plain" <<'PY'
import sys, email
print(email.message_from_file(open(sys.argv[1])).get_content_type())
PY
)"
  assert_eq "fallback sends a single text/plain message (not multipart)" "text/plain" "$ptype"

  # ---- HTML path: a stub renderer is the only one on PATH ----
  local hbin="$TMP/hbin"; make_min_bin "$hbin"
  printf '#!/usr/bin/env bash\necho "<p>rendered</p>"\nexit 0\n' > "$hbin/cmark-gfm"
  chmod +x "$hbin/cmark-gfm"
  local html="$TMP/html.eml"
  ( set -e
    # shellcheck disable=SC2030,SC2031  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$html" PATH="$hbin"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report to@example.com "$report" )
  # Validate it parses as a real multipart/alternative with text + html parts.
  local kinds
  kinds="$(python3 - "$html" <<'PY'
import sys, email
m = email.message_from_file(open(sys.argv[1]))
parts = [p.get_content_type() for p in m.walk() if p.get_content_maintype() != "multipart"]
print(m.get_content_type(), ",".join(sorted(parts)))
PY
)"
  assert_eq "HTML email is multipart/alternative with text+html parts" \
    "multipart/alternative text/html,text/plain" "$kinds"
}
test_email_helpers

echo "== cfg_get_text: parses human-readable subject.name (quotes, escapes, #) =="
test_cfg_get_text() {
  local fns="$TMP/cfgfns.sh" cfg="$TMP/c.yaml"
  awk '/^# ---- config readers ----/{f=1} /^# ---- end config readers ----/{f=0} f' \
    "$ROOT/bin/monitor.sh" > "$fns"
  # shellcheck disable=SC1090
  source "$fns"
  printf 'subject:\n  name: "Mechanical & microbrand wristwatches"\n' > "$cfg"
  assert_eq "double-quoted: spaces + &" "Mechanical & microbrand wristwatches" "$(cfg_get_text subject name "$cfg")"
  printf 'subject:\n  name: Plain Name   # c\n' > "$cfg"
  assert_eq "unquoted: trailing comment stripped" "Plain Name" "$(cfg_get_text subject name "$cfg")"
  printf 'subject:\n  name: C# developer tools\n' > "$cfg"
  assert_eq "unquoted: literal # kept" "C# developer tools" "$(cfg_get_text subject name "$cfg")"
  cat > "$cfg" <<'YAML'
subject:
  name: 'Bob''s Watches'
YAML
  assert_eq "single-quoted: doubled-quote escape" "Bob's Watches" "$(cfg_get_text subject name "$cfg")"
  cat > "$cfg" <<'YAML'
subject:
  name: "Bob \"Sig\" Watches"
YAML
  assert_eq "double-quoted: internal escaped quotes" 'Bob "Sig" Watches' "$(cfg_get_text subject name "$cfg")"
}
test_cfg_get_text

echo "== encode_header: RFC 2047-encodes non-ASCII, passes ASCII through =="
test_encode_header() {
  local fns="$TMP/ehfns.sh"
  awk '/^# ---- email helpers ----/{f=1} /^# Promote this run.s output/{f=0} f' \
    "$ROOT/bin/monitor.sh" > "$fns"
  # shellcheck disable=SC1090
  source "$fns"
  assert_eq "ASCII passes through unchanged" "[market-monitor: Plain] daily" "$(encode_header "[market-monitor: Plain] daily")"
  assert_contains "non-ASCII becomes an RFC 2047 encoded-word" "$(encode_header "Café")" "=?UTF-8?B?"
}
test_encode_header

# Build an isolated, runnable monitor.sh checkout that needs no real claude: minimal
# config/profile/prompt + a stub `claude` that records its invocation and prints a
# JSON envelope without writing a report (so the run ends "nothing material").
make_fake_repo() {
  local repo="$1" lastboot="${2:-2099-01-01}" run_timeout="${3:-0}" email_to="${4:-}"
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb" "$repo/stub"
  cp "$ROOT/bin/monitor.sh" "$ROOT/bin/dashboard.sh" "$repo/bin/"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  monitor: sonnet
  deepdive: opus
subject:
  name: "Test Market & Co"
monitoring:
  run_timeout_seconds: $run_timeout
  state_max_lines: 5
  deepdive_threshold: 0.85
  deepdive_max_items: 5
tracking:
  observations_max_lines: 5
governance:
  profile_refresh_days: 30
output:
  email_to: "$email_to"
YAML
  cat > "$repo/profile.yaml" <<YAML
subject:
  derived:
    last_bootstrapped: $lastboot
anchor:
  derived:
    last_bootstrapped: $lastboot
YAML
  printf 'monitor prompt (test fixture)\n' > "$repo/monitor-prompt.md"
  printf 'deep-dive prompt (test fixture) DEEPDIVE_FIXTURE\n' > "$repo/deepdive-prompt.md"
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_RAN:-}" ] && : > "$CLAUDE_RAN"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  write_capture_msmtp "$repo/stub/msmtp"
}

# Mirror monitor.sh's proc_start so tests can forge a matching/non-matching owner token.
proc_start() {
  ps -o lstart= -p "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//'
}

echo "== monitor.sh: skips when a live lock is held =="
test_lock_skip() {
  local repo="$TMP/lockrepo" out rc
  make_fake_repo "$repo"
  mkdir -p "$repo/state/.lock"
  # A live, matching owner token (this test process). monitor must see it active.
  printf '%s %s\n' "$$" "$(proc_start "$$")" > "$repo/state/.lock/owner"
  local marker="$repo/claude_ran"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_RAN="$marker" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "skip exits 0" "0" "$rc"
  assert_contains "prints 'in progress — skipping'" "$out" "in progress — skipping"
  if [ -f "$marker" ]; then fail "claude was NOT invoked while locked"; else pass "claude was NOT invoked while locked"; fi
}
test_lock_skip

echo "== monitor.sh: a recycled PID (same pid, different start time) is reclaimed =="
test_lock_reused_pid() {
  local repo="$TMP/reusedpidrepo" out rc
  make_fake_repo "$repo"
  mkdir -p "$repo/state/.lock"
  # Live pid (this process) but a start time that does NOT match: simulates the
  # original owner dying and its PID being reused by an unrelated process.
  printf '%s %s\n' "$$" "Thu Jan  1 00:00:00 2000" > "$repo/state/.lock/owner"
  local marker="$repo/claude_ran"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_RAN="$marker" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "exits 0" "0" "$rc"
  assert_contains "reclaims a recycled-PID lock" "$out" "reclaiming stale lock"
  if [ -f "$marker" ]; then pass "claude ran after reclaiming recycled-PID lock"; else fail "claude ran after reclaiming recycled-PID lock"; fi
}
test_lock_reused_pid

echo "== monitor.sh: reclaims stale lock, prunes state, warns on stale profile =="
test_full_run() {
  local repo="$TMP/runrepo" out rc
  make_fake_repo "$repo" "2000-01-01"                 # old profile -> staleness warning
  seq 1 20 | sed 's/^/{"n":/; s/$/}/' > "$repo/state/seen.jsonl"          # > state_max_lines (5)
  seq 1 20 | sed 's/^/{"o":/; s/$/}/' > "$repo/state/observations.jsonl"  # > observations_max_lines (5)
  mkdir -p "$repo/state/.lock"
  printf '%s %s\n' "2147483646" "x" > "$repo/state/.lock/owner"    # a pid that isn't running -> stale
  local marker="$repo/claude_ran"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_RAN="$marker" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  assert_contains "reclaims the stale lock" "$out" "reclaiming stale lock"
  assert_contains "prunes oversized state" "$out" "pruned state/seen.jsonl"
  assert_contains "prunes oversized observations" "$out" "pruned state/observations.jsonl"
  assert_contains "warns on stale profile" "$out" "profile is"
  if [ -f "$marker" ]; then pass "claude ran after reclaiming the lock"; else fail "claude ran after reclaiming the lock"; fi
  local n; n="$(wc -l < "$repo/state/seen.jsonl" | tr -d ' ')"
  assert_eq "seen.jsonl pruned to state_max_lines" "5" "$n"
  local o; o="$(wc -l < "$repo/state/observations.jsonl" | tr -d ' ')"
  assert_eq "observations.jsonl pruned to observations_max_lines" "5" "$o"
  if [ -f "$repo/kb/index.html" ]; then pass "dashboard refreshed (kb/index.html)"; else fail "dashboard refreshed (kb/index.html)"; fi
  if [ -d "$repo/state/.lock" ]; then fail "lock released on exit"; else pass "lock released on exit"; fi
}
test_full_run

# A stub claude that, on the triage call, writes a report + a deep-dive queue with a
# high-scoring item, and on the deep-dive call (prompt contains DEEPDIVE_FIXTURE)
# records that it ran. Used by the two-pass tests.
write_twopass_stub() {  # $1 = repo
  cat > "$1/stub/claude" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *DEEPDIVE_FIXTURE*)                       # the deep-dive pass
    [ -n "${DD_MARKER:-}" ] && echo "ran" >> "$DD_MARKER"
    [ -n "${DD_WRITE_OBS:-}" ] && printf '{"junk":"from-deepdive"}\n' >> state/observations.jsonl
    [ -n "${DD_EMPTY:-}" ] && : > "kb/.$(date +%F).daily.partial.md"   # simulate emptying the report
    printf '{"num_turns":2,"total_cost_usd":0.0}\n'; exit "${DD_EXIT:-0}" ;;
  *)                                        # the triage pass
    printf '# report\n* item\n' > "kb/.$(date +%F).daily.partial.md"
    printf '{"url":"u","title":"t","signal":"opportunity","score":0.9,"so_what":"x"}\n' \
      > "state/.deepdive.daily.queue.jsonl"
    printf '{"num_turns":1,"total_cost_usd":0.0}\n'; exit 0 ;;
esac
SH
  chmod +x "$1/stub/claude"
}

echo "== monitor.sh: deep-dive pass runs on queued high-scorers when models.deepdive is set =="
test_deepdive_enabled() {
  local repo="$TMP/ddrepo" out rc dd="$TMP/dd_ran"
  make_fake_repo "$repo"                    # config has models.deepdive: opus
  write_twopass_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( DD_MARKER="$dd" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  if [ -f "$dd" ]; then pass "deep-dive pass was invoked"; else fail "deep-dive pass was invoked"; fi
  assert_contains "logs the deep-dive pass to runs.log" "$(cat "$repo/state/runs.log" 2>/dev/null)" '"pass":"deepdive"'
  if [ -f "$repo/state/.deepdive.daily.queue.jsonl" ]; then fail "deep-dive queue cleaned up"; else pass "deep-dive queue cleaned up"; fi
}
test_deepdive_enabled

echo "== monitor.sh: no deep-dive pass when models.deepdive is unset =="
test_deepdive_disabled() {
  local repo="$TMP/ddoffrepo" out rc dd="$TMP/dd_ran_off"
  make_fake_repo "$repo"
  sed -i.bak '/^  deepdive: opus$/d' "$repo/monitor-config.yaml" && rm -f "$repo/monitor-config.yaml.bak"
  write_twopass_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( DD_MARKER="$dd" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  if [ -f "$dd" ]; then fail "deep-dive pass NOT invoked when disabled"; else pass "deep-dive pass NOT invoked when disabled"; fi
}
test_deepdive_disabled

echo "== monitor.sh: a failed deep-dive keeps the triage report =="
test_deepdive_failure() {
  local repo="$TMP/ddfailrepo" out rc
  make_fake_repo "$repo"
  write_twopass_stub "$repo"
  # deep-dive appends a junk observation, then fails -> both report and observations restored
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( DD_EXIT=1 DD_WRITE_OBS=1 HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run still exits 0 despite deep-dive failure" "0" "$rc"
  assert_contains "warns that the deep-dive failed" "$out" "deep-dive failed"
  if [ -f "$repo/kb/$(date +%F).daily.md" ]; then pass "triage report still promoted"; else fail "triage report still promoted"; fi
  if grep -q from-deepdive "$repo/state/observations.jsonl"; then fail "failed deep-dive's observations rolled back"; else pass "failed deep-dive's observations rolled back"; fi
}
test_deepdive_failure

echo "== monitor.sh: a deep-dive that empties the report restores the triage report =="
test_deepdive_empty() {
  local repo="$TMP/ddemptyrepo" out rc
  make_fake_repo "$repo"
  write_twopass_stub "$repo"
  # deep-dive exits 0 but empties the report -> triage report must be restored
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( DD_EMPTY=1 HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  assert_contains "warns it restored the triage report" "$out" "restored the triage report"
  if [ -s "$repo/kb/$(date +%F).daily.md" ]; then pass "non-empty triage report promoted"; else fail "non-empty triage report promoted"; fi
}
test_deepdive_empty

echo "== usage.sh: a deep-dive pass doesn't inflate the run count =="
test_usage_passes() {
  local repo="$TMP/usagepass" out now
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/usage.sh" "$repo/bin/"
  now="$(date -u +%FT%TZ)"
  {
    printf '{"timestamp":"%s","mode":"daily","pass":"triage","num_turns":10,"cost_usd":0.02}\n' "$now"
    printf '{"timestamp":"%s","mode":"daily","pass":"deepdive","num_turns":20,"cost_usd":0.30}\n' "$now"
  } > "$repo/state/runs.log"
  out="$( bash "$repo/bin/usage.sh" 30 2>&1 )"
  assert_contains "one invocation = one run (not two)" "$out" "runs:    1"
  assert_contains "cost sums across both passes" "$out" "cost:    \$0.32"
  assert_contains "shows the pass breakdown" "$out" "deepdive=1, triage=1"
}
test_usage_passes

echo "== dashboard.sh: renders entities, sparklines, events, report links =="
test_dashboard() {
  local repo="$TMP/dashrepo" html
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/dashboard.sh" "$repo/bin/"
  {
    printf '{"timestamp":"2026-05-01T07:00:00Z","entity":"Tudor BB58","metric":"secondary_price_usd","value":3650,"unit":"USD","source":"u"}\n'
    printf 'THIS IS A MALFORMED / TRUNCATED LINE {oops\n'   # must not blank the dashboard
    printf '{"timestamp":"2026-06-01T07:00:00Z","entity":"Tudor BB58","metric":"secondary_price_usd","value":3200,"unit":"USD","source":"u"}\n'
    printf '{"timestamp":"2026-06-06T07:00:00Z","entity":"Tudor BB58","metric":"event","event_type":"leak","value":"new GMT teased","source":"u"}\n'
  } > "$repo/state/observations.jsonl"
  printf 'r\n' > "$repo/kb/2026-06-06.daily.md"
  ( cd "$repo" && bash bin/dashboard.sh >/dev/null )
  html="$repo/kb/index.html"
  if [ ! -f "$html" ]; then fail "dashboard wrote kb/index.html"; return; fi
  pass "dashboard wrote kb/index.html"
  assert_contains "lists the tracked entity (despite a malformed line)" "$(cat "$html")" "Tudor BB58"
  assert_contains "renders a sparkline cell" "$(cat "$html")" 'class="spark"'
  assert_contains "event detail falls back to value when note is absent" "$(cat "$html")" "new GMT teased"
  assert_contains "links a recent report" "$(cat "$html")" "2026-06-06.daily.md"
  python3 - "$html" <<'PY'
import sys, html.parser
class P(html.parser.HTMLParser): pass
P().feed(open(sys.argv[1]).read())
PY
  assert_eq "kb/index.html parses as HTML" "0" "$?"
}
test_dashboard

echo "== dashboard.sh: --serve argument handling =="
test_dashboard_args() {
  local repo="$TMP/dashargs" rc
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/dashboard.sh" "$repo/bin/"
  ( cd "$repo" && bash bin/dashboard.sh --help >/dev/null 2>&1 ); rc=$?
  assert_eq "--help exits 0" "0" "$rc"
  ( cd "$repo" && bash bin/dashboard.sh --serve abc >/dev/null 2>&1 ); rc=$?
  assert_eq "--serve with a non-numeric port exits 2" "2" "$rc"
  ( cd "$repo" && bash bin/dashboard.sh --bogus >/dev/null 2>&1 ); rc=$?
  assert_eq "an unknown argument exits 2" "2" "$rc"
}
test_dashboard_args

echo "== review.sh: argument handling =="
test_review_args() {
  local repo="$TMP/revargs" rc
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/review.sh" "$repo/bin/"
  ( cd "$repo" && bash bin/review.sh --help >/dev/null 2>&1 ); rc=$?
  assert_eq "--help exits 0" "0" "$rc"
  ( cd "$repo" && bash bin/review.sh --port abc >/dev/null 2>&1 ); rc=$?
  assert_eq "--port with a non-numeric value exits 2" "2" "$rc"
}
test_review_args

echo "== feedback-server.py: serves items and records grades =="
test_feedback_server() {
  if ! command -v curl >/dev/null 2>&1; then pass "feedback server (skipped: no curl)"; return; fi
  local repo="$TMP/fbrepo" port=8791 home_page
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/feedback-server.py" "$repo/bin/"
  {
    printf '{"id":"abc123","title":"Tudor GMT leak","signal":"opportunity","score":0.9,"so_what":"matters","url":"https://x"}\n'
    printf 'MALFORMED LINE {oops\n'                          # must not break the listing
    printf '{"id":"def456","title":"Pelagos restock","signal":"shift","score":0.7,"url":"https://y"}\n'
  } > "$repo/state/seen.jsonl"
  ( exec python3 "$repo/bin/feedback-server.py" "$port" >/dev/null 2>&1 ) &
  local srv=$!
  home_page="$(curl -s --retry 8 --retry-delay 1 --retry-connrefused "http://127.0.0.1:$port/" || true)"
  curl -s "http://127.0.0.1:$port/grade?id=abc123&v=up" >/dev/null || true
  kill "$srv" 2>/dev/null || true
  assert_contains "review page lists a surfaced item (skips the malformed line)" "$home_page" "Tudor GMT leak"
  assert_contains "a grade is recorded to feedback.jsonl" "$(cat "$repo/state/feedback.jsonl" 2>/dev/null)" '"verdict": "up"'
  assert_contains "the grade captures the item id" "$(cat "$repo/state/feedback.jsonl" 2>/dev/null)" '"id": "abc123"'
}
test_feedback_server

echo "== monitor.sh: email Subject names the monitored subject =="
test_email_subject() {
  local repo="$TMP/subjrepo" out rc msg="$TMP/subj.eml"
  make_fake_repo "$repo" "2099-01-01" 0 "me@example.com"   # email enabled; subject.name set
  # A stub claude that writes a report, so the email actually sends.
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
printf 'report body\n' > "kb/.$(date +%F).daily.partial.md"
printf '{"num_turns":1}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( MSG_OUT="$msg" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  if [ -f "$msg" ]; then
    assert_contains "Subject names the monitored subject (spaces + & preserved)" \
      "$(grep -i '^Subject:' "$msg")" "[market-monitor: Test Market & Co]"
  else
    fail "an email was sent"
  fi
}
test_email_subject

echo "== usage.sh: rolls up runs.log within the window =="
test_usage() {
  local repo="$TMP/usagerepo" out now
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/usage.sh" "$repo/bin/"
  now="$(date -u +%FT%TZ)"
  {
    printf '{"timestamp":"%s","mode":"daily","num_turns":10,"cost_usd":0.02}\n' "$now"
    printf '{"timestamp":"%s","mode":"weekly","num_turns":30,"cost_usd":0.10}\n' "$now"
    printf '{"timestamp":"2000-01-01T00:00:00Z","mode":"daily","num_turns":99,"cost_usd":9.99}\n'
  } > "$repo/state/runs.log"
  out="$( bash "$repo/bin/usage.sh" 30 2>&1 )"
  assert_contains "counts only in-window runs" "$out" "runs:    2"
  assert_contains "sums turns in window (40, not 139)" "$out" "turns:   40"
}
test_usage

echo "== usage.sh: an empty window reports zeros without erroring =="
test_usage_empty() {
  local repo="$TMP/usageemptyrepo" out rc
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/usage.sh" "$repo/bin/"
  # Only an out-of-window run exists, so the 30-day window is empty.
  printf '{"timestamp":"2000-01-01T00:00:00Z","mode":"daily","num_turns":99,"cost_usd":9.99}\n' \
    > "$repo/state/runs.log"
  out="$( bash "$repo/bin/usage.sh" 30 2>&1 )"; rc=$?
  assert_eq "exits 0 on an empty window" "0" "$rc"
  assert_contains "reports zero runs" "$out" "runs:    0"
  assert_contains "reports zero cost (no jq null error)" "$out" "cost:    \$0"
}
test_usage_empty

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
