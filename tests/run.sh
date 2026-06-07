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

echo "== install-launchd: generates valid, path-substituted plists =="
test_install_launchd() {
  # Simulate a checkout under a path with XML-special chars (the regression that
  # broke sed templating + produced invalid XML).
  local co="$TMP/a&b<c>d/checkout"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  local home="$TMP/home"; mkdir -p "$home"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 )
  local plist="$home/Library/LaunchAgents/ai.zoller.marketmonitor.daily.plist"
  if [ ! -f "$plist" ]; then fail "install-launchd produced a daily plist"; return; fi
  pass "install-launchd produced a daily plist"
  if grep -q '__MM_ROOT__' "$plist"; then
    fail "no __MM_ROOT__ token remains"
  else
    pass "no __MM_ROOT__ token remains"
  fi
  # Valid XML AND the path decodes back to the real (special-char) dir.
  local got
  got="$(python3 - "$plist" <<'PY'
import sys, plistlib
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f)["ProgramArguments"][0])
PY
)"
  assert_eq "plist is valid XML and path round-trips" "$co/bin/monitor.sh" "$got"
}
test_install_launchd

echo "== install-launchd uninstall: removes the agents =="
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
  if [ -f "$home/Library/LaunchAgents/ai.zoller.marketmonitor.daily.plist" ]; then
    fail "uninstall removed the daily plist"
  else
    pass "uninstall removed the daily plist"
  fi
}
test_uninstall

echo "== monitor.sh: argument + review-gate behavior (no claude needed) =="
test_monitor_gates() {
  local rc out
  # Bogus mode exits 2 before doing anything.
  ( cd "$ROOT" && bash bin/monitor.sh bogus >/dev/null 2>&1 ); rc=$?
  assert_eq "rejects an invalid mode with exit 2" "2" "$rc"
  # A valid mode with no approved profile.yaml exits 1 at the review gate.
  # (The repo has no profile.yaml — it's gitignored — so this hits the gate.)
  out="$( cd "$ROOT" && bash bin/monitor.sh daily 2>&1 )"; rc=$?
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

  # ---- plain-text fallback: no renderer on PATH ----
  local pbin="$TMP/pbin"; mkdir -p "$pbin"; write_capture_msmtp "$pbin/msmtp"
  local plain="$TMP/plain.eml"
  ( set -e
    # shellcheck disable=SC2030  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$plain" PATH="$pbin:/usr/bin:/bin"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report to@example.com "$report" )
  assert_contains "fallback declares text/plain; charset=utf-8" \
    "$(cat "$plain")" "Content-Type: text/plain; charset=utf-8"

  # ---- HTML path: a stub renderer is present ----
  local hbin="$TMP/hbin"; mkdir -p "$hbin"; write_capture_msmtp "$hbin/msmtp"
  printf '#!/usr/bin/env bash\necho "<p>rendered</p>"\nexit 0\n' > "$hbin/cmark-gfm"
  chmod +x "$hbin/cmark-gfm"
  local html="$TMP/html.eml"
  ( set -e
    # shellcheck disable=SC2030,SC2031  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$html" PATH="$hbin:/usr/bin:/bin"
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

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
