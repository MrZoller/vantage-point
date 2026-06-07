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

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
