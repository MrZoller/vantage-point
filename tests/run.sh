#!/usr/bin/env bash
# tests/run.sh - fast, dependency-light checks for the parts of the scripts that
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
# assert_not_contains <name> <haystack> <needle>
assert_not_contains() {
  case "$2" in *"$3"*) fail "$1 (unexpectedly found [$3])" ;; *) pass "$1" ;; esac
}

# Write an msmtp stub that captures the message it's piped to into $MSG_OUT (which
# the stub reads from its environment at runtime, so callers must `export` it). It
# also records its recipient args (one per line) to $MSG_OUT.rcpt, so tests can assert
# the envelope recipients reach msmtp's command line.
write_capture_msmtp() {
  # shellcheck disable=SC2016  # $MSG_OUT is intentionally expanded at stub runtime
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$MSG_OUT.rcpt"\ncat > "$MSG_OUT"\nexit 0\n' > "$1"
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

# A minimal PATH dir containing ONLY bash, cat, and a capturing msmtp - and no
# markdown renderer, whatever the host has installed. Lets the email tests pin
# which branch (plain vs HTML) they exercise instead of depending on /usr/bin.
make_min_bin() {
  local dir="$1"
  mkdir -p "$dir"
  ln -s "$(command -v bash)" "$dir/bash"
  ln -s "$(command -v cat)" "$dir/cat"
  write_capture_msmtp "$dir/msmtp"
}

# Copy the shared libs that monitor.sh / bootstrap.sh source into a test repo's bin/.
cp_libs() { cp "$ROOT/bin/config-lib.sh" "$ROOT/bin/email-lib.sh" "$1"; }

# assert_plist_ok <desc> <plist path> <expected ProgramArguments[0]>
# Asserts the generated plist exists, has no leftover token, is valid XML, and its
# program path decodes back to the expected value.
assert_plist_ok() {
  if [ ! -f "$2" ]; then fail "$1: plist exists"; return; fi
  pass "$1: plist exists"
  if grep -q '__VP_ROOT__' "$2"; then fail "$1: no __VP_ROOT__ token remains"; else pass "$1: no __VP_ROOT__ token remains"; fi
  if grep -q '__VP_LABEL__' "$2"; then fail "$1: no __VP_LABEL__ token remains"; else pass "$1: no __VP_LABEL__ token remains"; fi
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
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  local home="$TMP/home" rc; mkdir -p "$home"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "installer exits 0" "0" "$rc"
  local la="$home/Library/LaunchAgents"
  assert_plist_ok "daily"  "$la/ai.zoller.vantagepoint.daily.plist"  "$co/bin/monitor.sh"
  assert_plist_ok "weekly" "$la/ai.zoller.vantagepoint.weekly.plist" "$co/bin/monitor.sh"
}
test_install_launchd

echo "== install-launchd uninstall: removes all three agents =="
test_uninstall() {
  local co="$TMP/uninst/checkout"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  local home="$TMP/home2"; mkdir -p "$home"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 )
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" uninstall >/dev/null 2>&1 )
  local la="$home/Library/LaunchAgents"
  if [ -f "$la/ai.zoller.vantagepoint.daily.plist" ] || [ -f "$la/ai.zoller.vantagepoint.weekly.plist" ] \
     || [ -f "$la/ai.zoller.vantagepoint.refresh.plist" ]; then
    fail "uninstall removed all three plists"
  else
    pass "uninstall removed all three plists"
  fi
}
test_uninstall

echo "== install-launchd: retires pre-rename (market-monitor) agents =="
test_install_retires_legacy() {
  local co="$TMP/legacy/checkout"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  local home="$TMP/legacyhome" la
  la="$home/Library/LaunchAgents"
  mkdir -p "$la"
  printf 'old daily plist\n'  > "$la/ai.zoller.marketmonitor.daily.plist"   # pre-rename agent
  printf 'old weekly plist\n' > "$la/ai.zoller.marketmonitor.weekly.plist"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 )
  if [ -f "$la/ai.zoller.marketmonitor.daily.plist" ] || [ -f "$la/ai.zoller.marketmonitor.weekly.plist" ]; then
    fail "legacy market-monitor agents removed"
  else
    pass "legacy market-monitor agents removed"
  fi
  if [ -f "$la/ai.zoller.vantagepoint.daily.plist" ]; then pass "new agent installed"; else fail "new agent installed"; fi
}
test_install_retires_legacy

echo "== install-launchd: namespaces agents by deployment.instance (multi-instance) =="
test_install_instance() {
  local home="$TMP/multihome" la; la="$home/Library/LaunchAgents"; mkdir -p "$home" "$la"
  # A pre-rename legacy agent present on this machine - must be retired even though
  # we're installing a NAMED instance (not just the default).
  printf 'old daily\n' > "$la/ai.zoller.marketmonitor.daily.plist"
  # Instance A: an uppercase/spaced name to exercise slugification -> "ai-models".
  local a="$TMP/inst-a/checkout"
  mkdir -p "$a/bin" "$a/launchd" "$a/stub"
  cp "$ROOT/bin/install-launchd.sh" "$a/bin/"; cp_libs "$a/bin"
  cp "$ROOT"/launchd/*.plist "$a/launchd/"
  chmod +x "$a/bin/install-launchd.sh"
  make_install_stubs "$a/stub"
  printf 'version: 1\ndeployment:\n  instance: "AI Models"\n' > "$a/monitor-config.yaml"
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  assert_plist_ok "instance daily"  "$la/ai.zoller.vantagepoint.ai-models.daily.plist"  "$a/bin/monitor.sh"
  assert_plist_ok "instance weekly" "$la/ai.zoller.vantagepoint.ai-models.weekly.plist" "$a/bin/monitor.sh"
  if [ -f "$la/ai.zoller.marketmonitor.daily.plist" ]; then fail "legacy agent retired even under a named instance"; else pass "legacy agent retired even under a named instance"; fi
  assert_contains "label is namespaced by the slugified instance" \
    "$(cat "$la/ai.zoller.vantagepoint.ai-models.daily.plist")" "<string>ai.zoller.vantagepoint.ai-models.daily</string>"
  if [ -f "$la/ai.zoller.vantagepoint.daily.plist" ]; then fail "a named instance does not install the un-suffixed agent"; else pass "a named instance does not install the un-suffixed agent"; fi

  # Instance B coexists in the same LaunchAgents dir.
  local b="$TMP/inst-b/checkout"
  mkdir -p "$b/bin" "$b/launchd" "$b/stub"
  cp "$ROOT/bin/install-launchd.sh" "$b/bin/"; cp_libs "$b/bin"
  cp "$ROOT"/launchd/*.plist "$b/launchd/"
  chmod +x "$b/bin/install-launchd.sh"
  make_install_stubs "$b/stub"
  printf 'version: 1\ndeployment:\n  instance: watches\n' > "$b/monitor-config.yaml"
  ( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" >/dev/null 2>&1 )
  if [ -f "$la/ai.zoller.vantagepoint.ai-models.daily.plist" ] && [ -f "$la/ai.zoller.vantagepoint.watches.daily.plist" ]; then
    pass "two instances coexist in LaunchAgents"
  else
    fail "two instances coexist in LaunchAgents"
  fi
  # Uninstalling B touches only its own labels.
  ( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" uninstall >/dev/null 2>&1 )
  if [ -f "$la/ai.zoller.vantagepoint.watches.daily.plist" ]; then fail "uninstall removes only its own instance"; else pass "uninstall removes only its own instance"; fi
  if [ -f "$la/ai.zoller.vantagepoint.ai-models.daily.plist" ]; then pass "the other instance survives a sibling uninstall"; else fail "the other instance survives a sibling uninstall"; fi

  # Renaming A's instance (same checkout) retires the old labels instead of leaving
  # them to double-fire alongside the new ones.
  printf 'version: 1\ndeployment:\n  instance: frontier\n' > "$a/monitor-config.yaml"
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  if [ -f "$la/ai.zoller.vantagepoint.frontier.daily.plist" ]; then pass "rename installs the new labels"; else fail "rename installs the new labels"; fi
  if [ -f "$la/ai.zoller.vantagepoint.ai-models.daily.plist" ]; then fail "rename retires this checkout's old labels"; else pass "rename retires this checkout's old labels"; fi
}
test_install_instance

echo "== install-launchd: rejects an instance name that slugifies to empty =="
test_install_instance_invalid() {
  local co="$TMP/inst-bad/checkout" home="$TMP/badhome" rc out
  mkdir -p "$co/bin" "$co/launchd" "$co/stub" "$home"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  printf 'version: 1\ndeployment:\n  instance: "!!!"\n' > "$co/monitor-config.yaml"   # slugifies to ""
  out="$( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" 2>&1 )"; rc=$?
  assert_eq "exits non-zero on an unusable instance name" "1" "$rc"
  assert_contains "explains the name is unusable" "$out" "no usable"
  if [ -f "$home/Library/LaunchAgents/ai.zoller.vantagepoint.daily.plist" ]; then
    fail "does not silently fall back to the default agent"
  else
    pass "does not silently fall back to the default agent"
  fi
}
test_install_instance_invalid

echo "== install-launchd: uninstall works even if the instance name is later broken =="
test_install_uninstall_broken() {
  local co="$TMP/inst-brk/checkout" home="$TMP/brkhome" la rc
  la="$home/Library/LaunchAgents"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub" "$home"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  printf 'version: 1\ndeployment:\n  instance: brand-x\n' > "$co/monitor-config.yaml"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 )
  if [ -f "$la/ai.zoller.vantagepoint.brand-x.daily.plist" ]; then pass "instance installed"; else fail "instance installed"; fi
  # Operator breaks the instance name, then tries to uninstall - it must still work.
  printf 'version: 1\ndeployment:\n  instance: "!!!"\n' > "$co/monitor-config.yaml"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" uninstall >/dev/null 2>&1 ); rc=$?
  assert_eq "uninstall exits 0 despite a now-invalid instance name" "0" "$rc"
  if [ -f "$la/ai.zoller.vantagepoint.brand-x.daily.plist" ]; then fail "uninstall removed this checkout's agents anyway"; else pass "uninstall removed this checkout's agents anyway"; fi
}
test_install_uninstall_broken

echo "== install-launchd: uninstall still finds agents after the checkout moves =="
test_install_cleanup_after_move() {
  local co="$TMP/inst-move/checkout" home="$TMP/movehome" la rc p
  la="$home/Library/LaunchAgents"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub" "$home"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  printf 'version: 1\ndeployment:\n  instance: mover\n' > "$co/monitor-config.yaml"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 )
  # Simulate a checkout move: rewrite the baked-in path so the path signal no longer
  # matches; only the recorded marker (state/.launchd-labels) can now find the labels.
  for p in "$la"/ai.zoller.vantagepoint.mover.*.plist; do
    [ -e "$p" ] || continue
    sed 's#'"$co"'/bin/#/moved/elsewhere/bin/#' "$p" > "$p.tmp" && mv "$p.tmp" "$p"
  done
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" uninstall >/dev/null 2>&1 ); rc=$?
  assert_eq "uninstall exits 0 after a move" "0" "$rc"
  if [ -f "$la/ai.zoller.vantagepoint.mover.daily.plist" ] || [ -f "$la/ai.zoller.vantagepoint.mover.refresh.plist" ]; then
    fail "the marker-recorded labels are removed after a move"
  else
    pass "the marker-recorded labels are removed after a move"
  fi
}
test_install_cleanup_after_move

echo "== install-launchd: refuses to hijack a label owned by another checkout =="
test_install_rejects_collision() {
  local home="$TMP/colhome" la co a b rc out
  la="$home/Library/LaunchAgents"; mkdir -p "$home"
  a="$TMP/col-a/checkout"; b="$TMP/col-b/checkout"
  for co in "$a" "$b"; do
    mkdir -p "$co/bin" "$co/launchd" "$co/stub"
    cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
    cp "$ROOT"/launchd/*.plist "$co/launchd/"
    printf '#!/usr/bin/env bash\n' > "$co/bin/monitor.sh"   # so the agent reads as "live"
    chmod +x "$co/bin/install-launchd.sh"
    make_install_stubs "$co/stub"
  done
  printf 'version: 1\ndeployment:\n  instance: "AI Models"\n' > "$a/monitor-config.yaml"   # -> ai-models
  printf 'version: 1\ndeployment:\n  instance: "AI_Models"\n' > "$b/monitor-config.yaml"   # also -> ai-models
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  out="$( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" 2>&1 )"; rc=$?
  assert_eq "a colliding-slug second checkout exits non-zero" "1" "$rc"
  assert_contains "explains the label collision" "$out" "already belongs to a different checkout"
  assert_contains "the first checkout's agent is left intact" "$(cat "$la/ai.zoller.vantagepoint.ai-models.daily.plist")" "$a/bin/monitor.sh"
}
test_install_rejects_collision

echo "== install-launchd: a copied checkout's stale marker doesn't remove a sibling =="
test_install_copied_marker() {
  local home="$TMP/cphome" la co a b
  la="$home/Library/LaunchAgents"; mkdir -p "$home"
  a="$TMP/cp-a/checkout"; b="$TMP/cp-b/checkout"
  for co in "$a" "$b"; do
    mkdir -p "$co/bin" "$co/launchd" "$co/stub" "$co/state"
    cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
    cp "$ROOT"/launchd/*.plist "$co/launchd/"
    printf '#!/usr/bin/env bash\n' > "$co/bin/monitor.sh"
    chmod +x "$co/bin/install-launchd.sh"
    make_install_stubs "$co/stub"
  done
  printf 'version: 1\ndeployment:\n  instance: ai-models\n' > "$a/monitor-config.yaml"
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  # Simulate `cp -r` of an installed checkout: B inherits A's marker, then is renamed.
  cp "$a/state/.launchd-labels" "$b/state/.launchd-labels"
  printf 'version: 1\ndeployment:\n  instance: devtools\n' > "$b/monitor-config.yaml"
  ( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" >/dev/null 2>&1 )
  if [ -f "$la/ai.zoller.vantagepoint.ai-models.daily.plist" ]; then pass "the original sibling's agent survives the copy's install"; else fail "the original sibling's agent survives the copy's install"; fi
  if [ -f "$la/ai.zoller.vantagepoint.devtools.daily.plist" ]; then pass "the copied checkout installs its own agent"; else fail "the copied checkout installs its own agent"; fi
}
test_install_copied_marker

# Read one field out of a generated plist for the refresh-agent tests: "args" joins
# ProgramArguments with spaces; anything else names a StartCalendarInterval key.
plist_field() {  # <plist> <args|Day|Hour|Minute>
  python3 - "$1" "$2" <<'PY'
import sys, plistlib
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
key = sys.argv[2]
print(" ".join(d["ProgramArguments"]) if key == "args" else d["StartCalendarInterval"].get(key, ""))
PY
}

echo "== install-launchd: installs a monthly, self-gating profile-refresh agent =="
test_install_refresh_agent() {
  local co="$TMP/refresh/checkout" home="$TMP/refreshhome" la hour minute plist
  la="$home/Library/LaunchAgents"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub" "$home"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  local out
  out="$( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" 2>/dev/null )"
  plist="$la/ai.zoller.vantagepoint.refresh.plist"
  # Installed by DEFAULT, alongside daily/weekly: an opt-in refresh agent is one an
  # operator forgets to opt into, which is the whole failure being fixed.
  assert_plist_ok "refresh" "$plist" "$co/bin/bootstrap.sh"
  assert_eq "the refresh agent runs bootstrap.sh behind its staleness gate" \
    "$co/bin/bootstrap.sh --if-stale" "$(plist_field "$plist" args)"
  if grep -q '__VP_REFRESH_HOUR__' "$plist"; then fail "refresh: no __VP_REFRESH_HOUR__ token remains"; else pass "refresh: no __VP_REFRESH_HOUR__ token remains"; fi
  if grep -q '__VP_REFRESH_MINUTE__' "$plist"; then fail "refresh: no __VP_REFRESH_MINUTE__ token remains"; else pass "refresh: no __VP_REFRESH_MINUTE__ token remains"; fi
  # DAILY: no Day key at all. A monthly poll cannot honour the window it checks - with
  # profile_refresh_days=30, a profile refreshed on the 1st is 28d old at the next monthly
  # check, is skipped, and reaches ~59d by the one after. The gate is free; polling is not
  # the expensive part.
  assert_eq "polls daily - no day-of-month pinning" "" "$(plist_field "$plist" Day)"
  assert_eq "and no weekday pinning either" "" "$(plist_field "$plist" Weekday)"
  hour="$(plist_field "$plist" Hour)"
  minute="$(plist_field "$plist" Minute)"
  # Every bucket must land before the 06:30 daily sweep.
  if [ "$hour" -ge 1 ] && [ "$hour" -le 5 ]; then
    pass "fires overnight, ahead of the 06:30 sweep (got 0$hour:$minute)"
  else
    fail "fires overnight, ahead of the 06:30 sweep (got $hour)"
  fi
  # Range/type check only: a reverted literal 0 would pass this. The stagger test below
  # is what actually guards the widening.
  if [ -n "$minute" ] && [ "$minute" -ge 0 ] && [ "$minute" -le 59 ]; then
    pass "the minute is a hashed value in range (got $minute)"
  else
    fail "the minute is a hashed value in range (got '$minute')"
  fi
  # The operator's readback must name the slot that was ACTUALLY installed. This drifted
  # once already: the minute was threaded through the plist but the status line kept
  # printing ":00", so an install reported a time it had not scheduled.
  local want
  want="$(printf 'daily at %02d:%02d' "$hour" "$minute")"
  case "$out" in
    *"$want"*) pass "the status line names the installed slot ($want)" ;;
    *)         fail "the status line names the installed slot (want '$want', got: $(printf '%s' "$out" | grep -i 'profile refresh' || echo '<no such line>'))" ;;
  esac
}
test_install_refresh_agent

echo "== install-launchd: the refresh slot is stable per checkout, staggered across instances =="
test_install_refresh_day_stagger() {
  local home="$TMP/staggerhome" la a b slot_a slot_a2 slot_b hour_a hour_b
  la="$home/Library/LaunchAgents"; mkdir -p "$home"
  a="$TMP/stag-a/checkout"; b="$TMP/stag-b/checkout"
  local co
  for co in "$a" "$b"; do
    mkdir -p "$co/bin" "$co/launchd" "$co/stub"
    cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
    cp "$ROOT"/launchd/*.plist "$co/launchd/"
    chmod +x "$co/bin/install-launchd.sh"
    make_install_stubs "$co/stub"
  done
  # These two are a REAL collision, not a hypothetical: under the original hour-only
  # hash both live deployments landed on 01:00. They are the regression this test
  # exists for, so do not swap them for a pair that happens to differ by hour.
  printf 'version: 1\ndeployment:\n  instance: ai-conferences\n' > "$a/monitor-config.yaml"
  printf 'version: 1\ndeployment:\n  instance: defense-primes\n' > "$b/monitor-config.yaml"
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  hour_a="$(plist_field "$la/ai.zoller.vantagepoint.ai-conferences.refresh.plist" Hour)"
  slot_a="$hour_a:$(plist_field "$la/ai.zoller.vantagepoint.ai-conferences.refresh.plist" Minute)"
  # Reinstalling must not move the slot around: it is derived from the label, not the clock.
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  # Re-read BOTH fields. Reusing $hour_a here would compare the hour to itself and
  # quietly check only the minute - the drift this assertion exists to catch.
  slot_a2="$(plist_field "$la/ai.zoller.vantagepoint.ai-conferences.refresh.plist" Hour)"
  slot_a2="$slot_a2:$(plist_field "$la/ai.zoller.vantagepoint.ai-conferences.refresh.plist" Minute)"
  assert_eq "a reinstall keeps the same refresh slot" "$slot_a" "$slot_a2"
  ( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" >/dev/null 2>&1 )
  hour_b="$(plist_field "$la/ai.zoller.vantagepoint.defense-primes.refresh.plist" Hour)"
  slot_b="$hour_b:$(plist_field "$la/ai.zoller.vantagepoint.defense-primes.refresh.plist" Minute)"
  # Same hour is the POINT here: it is what makes this a regression test rather than a
  # coincidence. If the hash ever moves these two apart by hour the test still passes,
  # but it stops guarding the minute widening - so assert the shared hour loudly.
  assert_eq "the pair still shares an hour (so the minute is what separates them)" "$hour_a" "$hour_b"
  # Clones bootstrapped on the same day cross their windows on the same day, so what has
  # to differ is the TIME - a deep-research bootstrap is the most expensive thing here and
  # several must not start at once.
  if [ "$slot_a" != "$slot_b" ]; then
    pass "two instances that share an hour still land on different minutes ($slot_a vs $slot_b)"
  else
    fail "two instances that share an hour still land on different minutes (both $slot_a)"
  fi
}
test_install_refresh_day_stagger

echo "== install-launchd: deployment.refresh_time pins the slot the hash would pick =="
test_install_refresh_time_override() {
  local co="$TMP/rtime/checkout" home="$TMP/rtimehome" la plist rc before
  la="$home/Library/LaunchAgents"; mkdir -p "$home"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  # Zero-padded on purpose: "08" must be read as decimal, not rejected as bad octal.
  printf 'version: 1\ndeployment:\n  instance: pinned\n  refresh_time: "08:05"\n' > "$co/monitor-config.yaml"
  local out
  out="$( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" 2>/dev/null )"
  plist="$la/ai.zoller.vantagepoint.pinned.refresh.plist"
  assert_eq "an explicit refresh_time sets the hour" "8" "$(plist_field "$plist" Hour)"
  assert_eq "an explicit refresh_time sets the minute" "5" "$(plist_field "$plist" Minute)"
  # Zero-padded readback of the pinned value - an operator who pinned a slot to dodge a
  # collision has to be able to READ BACK the slot they pinned.
  case "$out" in
    *"daily at 08:05"*) pass "the status line names the pinned slot (08:05)" ;;
    *)                  fail "the status line names the pinned slot (got: $(printf '%s' "$out" | grep -i 'profile refresh' || echo '<no such line>'))" ;;
  esac
  # A two-digit hour must not come out as "012:45" - the old hard-coded leading zero.
  printf 'version: 1\ndeployment:\n  instance: pinned2\n  refresh_time: "12:45"\n' > "$co/monitor-config.yaml"
  out="$( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" 2>/dev/null )"
  case "$out" in
    *"daily at 12:45"*) pass "a two-digit hour is not zero-prefixed (12:45)" ;;
    *)                  fail "a two-digit hour is not zero-prefixed (got: $(printf '%s' "$out" | grep -i 'profile refresh' || echo '<no such line>'))" ;;
  esac
  # Put the pinned instance back so the rejection loop below tests what it says it does.
  printf 'version: 1\ndeployment:\n  instance: pinned\n  refresh_time: "08:05"\n' > "$co/monitor-config.yaml"
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 )

  # A bad value must fail loudly BEFORE touching LaunchAgents - a silently-ignored
  # typo would put the instance back on the hashed slot it was pinned away from.
  before="$(cat "$plist")"
  local bad
  for bad in "0830" "24:00" "01:60" "aa:bb" "1:2:3" "01:" "18446744073709551617:30"; do
    printf 'version: 1\ndeployment:\n  instance: pinned\n  refresh_time: "%s"\n' "$bad" > "$co/monitor-config.yaml"
    rc=0
    ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 ) || rc=$?
    if [ "$rc" -ne 0 ]; then
      pass "rejects refresh_time '$bad' (exit $rc)"
    else
      fail "rejects refresh_time '$bad' (exited 0)"
    fi
  done
  assert_eq "a rejected refresh_time leaves the installed plist untouched" "$before" "$(cat "$plist")"

  # ...but uninstall must still work with a config that install would reject, or a
  # since-broken value would strand the agents with no way to remove them.
  rc=0
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" uninstall >/dev/null 2>&1 ) || rc=$?
  assert_eq "uninstall still works with an invalid refresh_time" "0" "$rc"
  if [ -f "$plist" ]; then fail "uninstall removed the refresh agent"; else pass "uninstall removed the refresh agent"; fi
}
test_install_refresh_time_override

echo "== install-launchd: rejects a broken instance name before mutating LaunchAgents =="
test_install_broken_keeps_legacy() {
  local co="$TMP/inst-brk2/checkout" home="$TMP/brk2home" la rc
  la="$home/Library/LaunchAgents"
  mkdir -p "$co/bin" "$co/launchd" "$co/stub" "$la"
  cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
  cp "$ROOT"/launchd/*.plist "$co/launchd/"
  chmod +x "$co/bin/install-launchd.sh"
  make_install_stubs "$co/stub"
  printf 'old daily\n' > "$la/ai.zoller.marketmonitor.daily.plist"   # a legacy agent present
  printf 'version: 1\ndeployment:\n  instance: "!!!"\n' > "$co/monitor-config.yaml"   # slugifies to ""
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "install rejects the broken name" "1" "$rc"
  if [ -f "$la/ai.zoller.marketmonitor.daily.plist" ]; then pass "legacy agent NOT deleted when the install is rejected"; else fail "legacy agent NOT deleted when the install is rejected"; fi
}
test_install_broken_keeps_legacy

echo "== install-launchd: collision guard decodes a sibling path with XML-special chars =="
test_install_collision_escaped_path() {
  local home="$TMP/eschome" la co a b rc out
  la="$home/Library/LaunchAgents"; mkdir -p "$home"
  a="$TMP/esc-a&x/checkout"; b="$TMP/esc-b/checkout"
  for co in "$a" "$b"; do
    mkdir -p "$co/bin" "$co/launchd" "$co/stub"
    cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
    cp "$ROOT"/launchd/*.plist "$co/launchd/"
    printf '#!/usr/bin/env bash\n' > "$co/bin/monitor.sh"   # so the sibling reads as "live"
    chmod +x "$co/bin/install-launchd.sh"
    make_install_stubs "$co/stub"
  done
  printf 'version: 1\ndeployment:\n  instance: shared\n' > "$a/monitor-config.yaml"
  printf 'version: 1\ndeployment:\n  instance: shared\n' > "$b/monitor-config.yaml"
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  out="$( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" 2>&1 )"; rc=$?
  assert_eq "second checkout is rejected (sibling path has &)" "1" "$rc"
  assert_contains "the original (& path) agent is left intact" "$(cat "$la/ai.zoller.vantagepoint.shared.daily.plist")" "esc-a&amp;x/checkout/bin/monitor.sh"
}
test_install_collision_escaped_path

echo "== install-launchd: a colliding rename is rejected without dropping the old schedule =="
test_install_rename_collision_preserves() {
  local home="$TMP/rcphome" la co a b rc
  la="$home/Library/LaunchAgents"; mkdir -p "$home"
  a="$TMP/rcp-a/checkout"; b="$TMP/rcp-b/checkout"
  for co in "$a" "$b"; do
    mkdir -p "$co/bin" "$co/launchd" "$co/stub"
    cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
    cp "$ROOT"/launchd/*.plist "$co/launchd/"
    printf '#!/usr/bin/env bash\n' > "$co/bin/monitor.sh"
    chmod +x "$co/bin/install-launchd.sh"
    make_install_stubs "$co/stub"
  done
  printf 'version: 1\ndeployment:\n  instance: alpha\n' > "$a/monitor-config.yaml"
  printf 'version: 1\ndeployment:\n  instance: beta\n'  > "$b/monitor-config.yaml"
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 )
  ( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" >/dev/null 2>&1 )
  # Rename A to beta (collides with the live B) and reinstall A.
  printf 'version: 1\ndeployment:\n  instance: beta\n' > "$a/monitor-config.yaml"
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "the colliding rename is rejected" "1" "$rc"
  if [ -f "$la/ai.zoller.vantagepoint.alpha.daily.plist" ]; then pass "A's existing schedule is preserved on a rejected rename"; else fail "A's existing schedule is preserved on a rejected rename"; fi
}
test_install_rename_collision_preserves

echo "== install-launchd: a rejected colliding install retires nothing (legacy intact) =="
test_install_collision_keeps_legacy() {
  local home="$TMP/clhome" la co a b rc
  la="$home/Library/LaunchAgents"; mkdir -p "$home" "$la"
  a="$TMP/cl-a/checkout"; b="$TMP/cl-b/checkout"
  for co in "$a" "$b"; do
    mkdir -p "$co/bin" "$co/launchd" "$co/stub"
    cp "$ROOT/bin/install-launchd.sh" "$co/bin/"; cp_libs "$co/bin"
    cp "$ROOT"/launchd/*.plist "$co/launchd/"
    printf '#!/usr/bin/env bash\n' > "$co/bin/monitor.sh"
    chmod +x "$co/bin/install-launchd.sh"
    make_install_stubs "$co/stub"
  done
  printf 'version: 1\ndeployment:\n  instance: beta\n' > "$b/monitor-config.yaml"
  ( HOME="$home" PATH="$b/stub:$PATH" bash "$b/bin/install-launchd.sh" >/dev/null 2>&1 )   # B owns "beta"
  printf 'old daily\n' > "$la/ai.zoller.marketmonitor.daily.plist"                          # a legacy agent present
  printf 'version: 1\ndeployment:\n  instance: beta\n' > "$a/monitor-config.yaml"           # A collides with B
  ( HOME="$home" PATH="$a/stub:$PATH" bash "$a/bin/install-launchd.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "the colliding install is rejected" "1" "$rc"
  if [ -f "$la/ai.zoller.marketmonitor.daily.plist" ]; then pass "legacy agent left intact (collision preflight ran first)"; else fail "legacy agent left intact (collision preflight ran first)"; fi
}
test_install_collision_keeps_legacy

echo "== monitor.sh: argument + review-gate behavior (no claude needed) =="
test_monitor_gates() {
  # Run from an ISOLATED copy with no profile.yaml, so the review gate always
  # triggers regardless of whether the developer approved one in the real
  # checkout - otherwise this test could fall through and spend a real claude run.
  local rc out repo="$TMP/gaterepo"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/monitor.sh" "$repo/bin/"; cp_libs "$repo/bin"
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
  # email_report lives in monitor.sh and delegates to the shared sender in
  # bin/email-lib.sh; extract the wrapper and source the lib alongside it.
  local funcs="$TMP/emailfuncs.sh"
  awk '/^# ---- email delivery ----/{f=1} /^# Promote this run.s output/{f=0} f' \
    "$ROOT/bin/monitor.sh" > "$funcs"
  if grep -q 'email_report()' "$funcs"; then
    pass "extracted email_report from monitor.sh"
  else
    fail "extracted email_report from monitor.sh"; return
  fi

  local report="$TMP/report.md"
  printf '# Daily - 1 item\n\n* item with a bare url https://example.com/x\n' > "$report"

  # ---- plain-text fallback: PATH has NO renderer (deterministic, host-independent) ----
  local pbin="$TMP/pbin"; make_min_bin "$pbin"
  local plain_eml="$TMP/plain.eml"
  ( set -e
    # shellcheck disable=SC2030  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$plain_eml" PATH="$pbin"
    # shellcheck source=bin/email-lib.sh
    source "$ROOT/bin/email-lib.sh"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report "$report" to@example.com )
  local ptype
  ptype="$(python3 - "$plain_eml" <<'PY'
import sys, email
print(email.message_from_file(open(sys.argv[1])).get_content_type())
PY
)"
  assert_eq "fallback sends a single text/plain message (not multipart)" "text/plain" "$ptype"

  # ---- HTML path: a stub renderer is the only one on PATH ----
  local hbin="$TMP/hbin"; make_min_bin "$hbin"
  printf '#!/usr/bin/env bash\necho "<p>rendered</p>"\nexit 0\n' > "$hbin/cmark-gfm"
  chmod +x "$hbin/cmark-gfm"
  local html_eml="$TMP/html.eml"
  ( set -e
    # shellcheck disable=SC2030,SC2031  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$html_eml" PATH="$hbin"
    # shellcheck source=bin/email-lib.sh
    source "$ROOT/bin/email-lib.sh"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report "$report" to@example.com )
  # Validate it parses as a real multipart/alternative with text + html parts.
  local kinds
  kinds="$(python3 - "$html_eml" <<'PY'
import sys, email
m = email.message_from_file(open(sys.argv[1]))
parts = [p.get_content_type() for p in m.walk() if p.get_content_maintype() != "multipart"]
print(m.get_content_type(), ",".join(sorted(parts)))
PY
)"
  assert_eq "HTML email is multipart/alternative with text+html parts" \
    "multipart/alternative text/html,text/plain" "$kinds"
  # The template chrome (header title, briefing subtitle, hidden preheader, footer)
  # is built in pure bash, so it must land even on this minimal PATH.
  local doc; doc="$(cat "$html_eml")"
  assert_contains "HTML header carries a title (subject fallback)" "$doc" 'class="title">Market intelligence'
  assert_contains "HTML header carries the briefing subtitle" "$doc" 'Daily briefing - 2026-01-01'
  assert_contains "HTML includes a hidden inbox preheader" "$doc" 'class="preheader"'
  assert_contains "HTML includes the footer" "$doc" 'Generated by Vantage Point'
  # Outlook (Word engine) only honors table bgcolor + inline styles, not the <style>
  # card/background. Assert the table-based chrome that keeps it from rendering as a
  # grey page with a missing white card / missing body margins.
  assert_contains "page background uses a table bgcolor (Outlook-safe)" "$doc" 'bgcolor="#eef1f5"'
  assert_contains "white card uses a table bgcolor (Outlook-safe)" "$doc" 'bgcolor="#ffffff"'
  assert_contains "card sits in a padded gutter cell (body margin)" "$doc" 'class="gutter" style="padding:24px 16px;"'
  assert_contains "body cell carries inline padding (Outlook-safe margin)" "$doc" 'padding:6px 32px 22px'
  assert_contains "card width is pinned for Outlook via mso conditional" "$doc" '[if mso]><table role="presentation" width="640"'
}
test_email_helpers

echo "== email: output.email_images embeds the logo as a CID inline image =="
test_email_logo() {
  local funcs="$TMP/emaillogofuncs.sh"
  awk '/^# ---- email delivery ----/{f=1} /^# Promote this run.s output/{f=0} f' \
    "$ROOT/bin/monitor.sh" > "$funcs"
  local report="$TMP/logoreport.md"
  printf '# Daily - 1 item\n\n* something\n' > "$report"
  # Min PATH plus base64 (to encode the image) and an HTML renderer stub.
  local lbin="$TMP/lbin"; make_min_bin "$lbin"
  ln -s "$(command -v base64)" "$lbin/base64"
  printf '#!/usr/bin/env bash\necho "<p>rendered</p>"\nexit 0\n' > "$lbin/cmark-gfm"
  chmod +x "$lbin/cmark-gfm"
  # The real logo asset, located via LOGO_ASSET (the monitor sets this from $ROOT).
  local logo="$TMP/logo-email.png"
  cp "$ROOT/assets/logo-email.png" "$logo"

  # ---- images ON: multipart/related, text+html+png, header references the cid ----
  local on_eml="$TMP/logo_on.eml"
  ( set -e
    # shellcheck disable=SC2030,SC2031  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$on_eml" PATH="$lbin" LOGO_ASSET="$logo" EMAIL_IMAGES=1
    # shellcheck source=bin/email-lib.sh
    source "$ROOT/bin/email-lib.sh"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report "$report" to@example.com )
  local struct
  struct="$(python3 - "$on_eml" <<'PY'
import sys, email
m = email.message_from_file(open(sys.argv[1]))
parts = sorted(p.get_content_type() for p in m.walk() if p.get_content_maintype() != "multipart")
imgs = [p for p in m.walk() if p.get_content_type() == "image/png"]
print(m.get_content_type(), ",".join(parts), imgs[0].get("Content-ID") if imgs else "")
PY
)"
  assert_eq "images on -> multipart/related wrapping text+html+png with a Content-ID" \
    "multipart/related image/png,text/html,text/plain <vp-logo@vantagepoint>" "$struct"
  assert_contains "HTML header references the logo via cid:" "$(cat "$on_eml")" 'src="cid:vp-logo@vantagepoint"'

  # ---- images OFF (default): plain multipart/alternative, no image, no cid ----
  local off_eml="$TMP/logo_off.eml"
  ( set -e
    # shellcheck disable=SC2030,SC2031  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$off_eml" PATH="$lbin" LOGO_ASSET="$logo"
    # shellcheck source=bin/email-lib.sh
    source "$ROOT/bin/email-lib.sh"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report "$report" to@example.com )
  assert_eq "images off -> stays multipart/alternative (no image)" "multipart/alternative" \
    "$(python3 -c 'import sys,email;print(email.message_from_file(open(sys.argv[1])).get_content_type())' "$off_eml")"
  assert_not_contains "no cid reference when images are off" "$(cat "$off_eml")" "cid:"

  # ---- fail-safe: images ON but the asset is missing -> degrade cleanly, no crash ----
  local miss_eml="$TMP/logo_miss.eml"
  ( set -e
    # shellcheck disable=SC2030,SC2031  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$miss_eml" PATH="$lbin" LOGO_ASSET="$TMP/nope.png" EMAIL_IMAGES=1
    # shellcheck source=bin/email-lib.sh
    source "$ROOT/bin/email-lib.sh"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report "$report" to@example.com )
  assert_eq "missing asset degrades to multipart/alternative (fail-safe)" "multipart/alternative" \
    "$(python3 -c 'import sys,email;print(email.message_from_file(open(sys.argv[1])).get_content_type())' "$miss_eml")"
}
test_email_logo

echo "== cfg_get: an absent key returns 0, an unreadable FILE does not =="
test_cfg_get_io_failure() {
  # These two must stay distinguishable. A reader that swallows I/O errors lets a run
  # continue with an empty config - no delivery settings, no rubric - while still writing
  # state, which is worse than stopping. A caller that genuinely wants tolerance (the
  # --if-stale profile read in bootstrap.sh) opts in with `|| true` at the call site.
  local dir="$TMP/cfgio" rc
  mkdir -p "$dir"
  printf 'subject:\n  name: present\n' > "$dir/ok.yaml"
  ( set -e; . "$ROOT/bin/config-lib.sh"; v="$(cfg_get subject nosuchkey "$dir/ok.yaml")"; [ -z "$v" ] ) ; rc=$?
  assert_eq "an absent key in a readable file returns 0" "0" "$rc"
  ( set -e; . "$ROOT/bin/config-lib.sh"; cfg_get subject name "$dir/nope.yaml" >/dev/null 2>&1 ) ; rc=$?
  if [ "$rc" -ne 0 ]; then pass "a missing file propagates a failure"; else fail "a missing file propagates a failure"; fi
  if [ "$(id -u)" != 0 ]; then
    printf 'subject:\n  name: hidden\n' > "$dir/locked.yaml"; chmod 000 "$dir/locked.yaml"
    ( set -e; . "$ROOT/bin/config-lib.sh"; cfg_get subject name "$dir/locked.yaml" >/dev/null 2>&1 ) ; rc=$?
    chmod 644 "$dir/locked.yaml"
    if [ "$rc" -ne 0 ]; then pass "an unreadable file propagates a failure"; else fail "an unreadable file propagates a failure"; fi
    # ...and the opt-in form is what makes that survivable where it is wanted.
    ( set -e; . "$ROOT/bin/config-lib.sh"; chmod 000 "$dir/locked.yaml"; v="$(cfg_get subject name "$dir/locked.yaml" 2>/dev/null || true)"; [ -z "$v" ] ) ; rc=$?
    chmod 644 "$dir/locked.yaml"
    assert_eq "|| true at the call site makes it tolerant on purpose" "0" "$rc"
  fi
}
test_cfg_get_io_failure

echo "== cfg_get_bool: truthy parsing + default =="
test_cfg_get_bool() {
  # shellcheck source=bin/config-lib.sh
  source "$ROOT/bin/config-lib.sh"
  local cfg="$TMP/bool.yaml"
  printf 'output:\n  email_images: true\n' > "$cfg"
  assert_eq "true -> 1" "1" "$(cfg_get_bool output email_images 0 "$cfg")"
  printf 'output:\n  email_images: FALSE\n' > "$cfg"
  assert_eq "FALSE -> empty (even with default on)" "" "$(cfg_get_bool output email_images 1 "$cfg")"
  printf 'output:\n  email_images: yes\n' > "$cfg"
  assert_eq "yes -> 1" "1" "$(cfg_get_bool output email_images 0 "$cfg")"
  printf 'output:\n  email_to: ""\n' > "$cfg"
  assert_eq "absent -> default off" "" "$(cfg_get_bool output email_images 0 "$cfg")"
  assert_eq "absent -> default on" "1" "$(cfg_get_bool output email_images 1 "$cfg")"
}
test_cfg_get_bool

echo "== cfg_get_list / email: output.email_to accepts a list and reaches every recipient =="
test_email_multi() {
  # shellcheck source=bin/config-lib.sh
  source "$ROOT/bin/config-lib.sh"

  # ---- cfg_get_list parses every shape, one item per line ----
  local cfg="$TMP/multi.yaml"
  printf 'output:\n  email_to:\n    - a@x.com\n    - b@y.com   # a trailing comment\n  webhook_url: ""\n' > "$cfg"
  assert_eq "block list -> newline-joined items" "a@x.com
b@y.com" "$(cfg_get_list output email_to "$cfg")"

  printf 'output:\n  email_to: "a@x.com, b@y.com"\n  webhook_url: ""\n' > "$cfg"
  assert_eq "comma-joined scalar -> split into items" "a@x.com
b@y.com" "$(cfg_get_list output email_to "$cfg")"

  printf 'output:\n  email_to: solo@x.com\n  webhook_url: ""\n' > "$cfg"
  assert_eq "bare scalar -> a single item (back-compat)" "solo@x.com" \
    "$(cfg_get_list output email_to "$cfg")"

  printf 'output:\n  email_to: [a@x.com, b@y.com]\n' > "$cfg"
  assert_eq "inline flow list -> split into items" "a@x.com
b@y.com" "$(cfg_get_list output email_to "$cfg")"

  printf 'output:\n  email_to: ""\n  webhook_url: ""\n' > "$cfg"
  assert_eq "blank scalar -> no items" "" "$(cfg_get_list output email_to "$cfg")"

  # ---- email_report sends one private message per recipient (no shared To:/Cc) ----
  local funcs="$TMP/emailfuncs2.sh"
  awk '/^# ---- email delivery ----/{f=1} /^# Promote this run.s output/{f=0} f' \
    "$ROOT/bin/monitor.sh" > "$funcs"
  local report="$TMP/report2.md"
  printf '# Daily - 1 item\n\n* something\n' > "$report"
  # A counting msmtp stub: every invocation appends its recipient args to .rcpt and
  # writes the piped message to a per-call file ($MSG_OUT.1, .2, ...), so the test can
  # confirm each recipient got its own separate message.
  local mbin="$TMP/mbin"; mkdir -p "$mbin"
  ln -s "$(command -v bash)" "$mbin/bash"
  ln -s "$(command -v cat)" "$mbin/cat"
  cat > "$mbin/msmtp" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$MSG_OUT.n" 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s' "$n" > "$MSG_OUT.n"
printf '%s\n' "$@" >> "$MSG_OUT.rcpt"
cat > "$MSG_OUT.$n"
exit 0
STUB
  chmod +x "$mbin/msmtp"
  local eml="$TMP/multi.eml"; rm -f "$eml".*
  ( set -e
    # shellcheck disable=SC2030,SC2031  # subshell-local env is intentional (isolation)
    export MODE=daily TODAY=2026-01-01 MSG_OUT="$eml" PATH="$mbin"
    # shellcheck source=bin/email-lib.sh
    source "$ROOT/bin/email-lib.sh"
    # shellcheck disable=SC1090
    source "$funcs"
    email_report "$report" a@x.com b@y.com )
  # Two separate msmtp calls, one per recipient (each its own envelope address).
  assert_eq "each recipient is sent in its own msmtp envelope" "a@x.com
b@y.com" "$(cat "$eml.rcpt")"
  assert_eq "two distinct messages were sent" "2" "$(cat "$eml.n")"
  # Each message's To: header carries only that one recipient - not the other.
  local to1 to2
  to1="$(python3 -c 'import sys,email; print(email.message_from_file(open(sys.argv[1]))["To"])' "$eml.1")"
  to2="$(python3 -c 'import sys,email; print(email.message_from_file(open(sys.argv[1]))["To"])' "$eml.2")"
  assert_eq "first message To: is only the first recipient" "a@x.com" "$to1"
  assert_eq "second message To: is only the second recipient" "b@y.com" "$to2"
  # And neither recipient can see the other anywhere in their copy.
  assert_not_contains "first recipient's copy hides the second address" "$(cat "$eml.1")" "b@y.com"
  assert_not_contains "second recipient's copy hides the first address" "$(cat "$eml.2")" "a@x.com"
}
test_email_multi

echo "== cfg_get_text: parses human-readable subject.name (quotes, escapes, #) =="
test_cfg_get_text() {
  local cfg="$TMP/c.yaml"
  # shellcheck source=bin/config-lib.sh
  source "$ROOT/bin/config-lib.sh"
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

echo "== samples: the example + each sample config is structurally valid (shell-readable) =="
# assert_config_structure <label> <file> - the structural checks every shippable
# config must pass; also applied to the config bin/init.sh emits.
assert_config_structure() {
  local name="$1" s="$2" blk missing
  # shellcheck source=bin/config-lib.sh
  source "$ROOT/bin/config-lib.sh"
  if [ -n "$(cfg_get models monitor "$s")" ];      then pass "$name: models.monitor set";     else fail "$name: models.monitor set";     fi
  if [ -n "$(cfg_get_text subject name "$s")" ];   then pass "$name: subject.name set";        else fail "$name: subject.name set";        fi
  if [ -n "$(cfg_get_text anchor name "$s")" ];    then pass "$name: anchor.name set";         else fail "$name: anchor.name set";         fi
  if [ -n "$(cfg_get relevance threshold "$s")" ]; then pass "$name: relevance.threshold set"; else fail "$name: relevance.threshold set"; fi
  missing=""
  for blk in budgets subject anchor relevance monitoring tracking output governance; do
    grep -q "^$blk:" "$s" || missing="$missing $blk"
  done
  if [ -z "$missing" ]; then pass "$name: all top-level blocks present"; else fail "$name: missing blocks:$missing"; fi
}
test_sample_configs() {
  # shellcheck source=bin/config-lib.sh
  source "$ROOT/bin/config-lib.sh"
  local s name
  # The annotated reference config is validated alongside the samples so its example
  # values stay shell-readable and complete.
  for s in "$ROOT"/monitor-config.example.yaml "$ROOT"/samples/*.yaml; do
    [ -e "$s" ] || { fail "no sample configs found"; return; }
    name="$(basename "$s")"
    assert_config_structure "$name" "$s"
    # models.init ships commented out (the init review inherits models.bootstrap).
    if [ -z "$(cfg_get models init "$s")" ] && grep -q '# init:' "$s"; then
      pass "$name: models.init present but commented"
    else
      fail "$name: models.init present but commented"
    fi
  done
}
test_sample_configs

echo "== _esc: escapes &, <, > correctly (even under bash 5.2 patsub_replacement) =="
test_esc() {
  # shellcheck source=bin/email-lib.sh
  source "$ROOT/bin/email-lib.sh"
  # Without disabling patsub_replacement this would mangle < / > to <lt; / >gt;.
  assert_eq "escapes angle brackets and ampersand" "&lt;b&gt; &amp; &lt;/b&gt;" "$(_esc '<b> & </b>')"
}
test_esc

echo "== encode_header: RFC 2047-encodes non-ASCII, passes ASCII through =="
test_encode_header() {
  # shellcheck source=bin/email-lib.sh
  source "$ROOT/bin/email-lib.sh"
  # Build the non-ASCII needle from bytes at runtime (keeps this file pure ASCII): "Cafe" + U+00E9.
  local cafe; cafe="Caf$(printf '\303\251')"
  assert_eq "ASCII passes through unchanged" "[Vantage Point: Plain] daily" "$(encode_header "[Vantage Point: Plain] daily")"
  assert_contains "non-ASCII becomes an RFC 2047 encoded-word" "$(encode_header "$cafe")" "=?UTF-8?B?"

  # Regression: detection must NOT depend on an external grep. On a PATH with no grep
  # (but with base64/tr for the encode branch), a non-ASCII subject must still be
  # encoded and an ASCII one must pass through - proving raw UTF-8 can't slip into a
  # header just because grep is missing from a minimal launchd-style PATH.
  local nbin="$TMP/nogrep"; mkdir -p "$nbin"
  local t; for t in bash cat base64 tr; do ln -s "$(command -v "$t")" "$nbin/$t"; done
  local enc asc
  enc="$( PATH="$nbin" bash -c 'set -e; . "$1"; encode_header "$2"' _ "$ROOT/bin/email-lib.sh" "$cafe" )"
  asc="$( PATH="$nbin" bash -c 'set -e; . "$1"; encode_header "$2"' _ "$ROOT/bin/email-lib.sh" "plain ascii" )"
  assert_contains "non-ASCII is encoded even with no grep on PATH" "$enc" "=?UTF-8?B?"
  assert_eq "ASCII passes through even with no grep on PATH" "plain ascii" "$asc"
}
test_encode_header

# Build an isolated, runnable monitor.sh checkout that needs no real claude: minimal
# config/profile/prompt + a stub `claude` that records its invocation and prints a
# JSON envelope without writing a report (so the run ends "nothing material").
make_fake_repo() {
  # Default "fresh" = TODAY, not a far-future date. A future last_bootstrapped yields a
  # negative age, and until that was fixed a negative age read as "inside the window" -
  # so 2099 worked here only by relying on the bug. Now it warns, as it should.
  local repo="$1" lastboot="${2:-$(date +%F)}" run_timeout="${3:-0}" email_to="${4:-}"
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb" "$repo/stub"
  cp "$ROOT/bin/monitor.sh" "$ROOT/bin/portal.py" "$ROOT/bin/dedupe-feedback.py" \
     "$ROOT/bin/webhook.py" "$ROOT/bin/fetch.py" "$ROOT/bin/horizon.py" \
     "$ROOT/bin/cadence.py" "$repo/bin/"
  cp_libs "$repo/bin"
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
  printf 'editor prompt (test fixture) EDITOR_FIXTURE\n' > "$repo/editor-prompt.md"
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
  assert_contains "prints 'in progress - skipping'" "$out" "in progress - skipping"
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
  # The fixture claude writes no report, so this is the "silence is correct" path:
  # the core ethos must be positively asserted, not just exercised.
  assert_contains "prints the silence message on a quiet day" "$out" "nothing material"
  if [ -f "$repo/kb/$(date +%F).daily.md" ]; then fail "no report written on a quiet day"; else pass "no report written on a quiet day"; fi
  if [ -f "$repo/kb/.$(date +%F).daily.partial.md" ]; then fail "empty scratch file cleaned up"; else pass "empty scratch file cleaned up"; fi
  if [ -f "$repo/kb/index.html" ]; then pass "portal snapshot refreshed (kb/index.html)"; else fail "portal snapshot refreshed (kb/index.html)"; fi
  if [ -d "$repo/state/.lock" ]; then fail "lock released on exit"; else pass "lock released on exit"; fi
}
test_full_run

echo "== monitor.sh: wraps the claude run in timeout when run_timeout_seconds > 0 =="
test_run_timeout_wrap() {
  local repo="$TMP/torepo" out rc marker="$TMP/timeout_used"
  make_fake_repo "$repo" "$(date +%F)" 1800     # run_timeout_seconds = 1800 (> 0)
  # A stub `timeout` (first on PATH) that records it was used, then runs the wrapped cmd.
  cat > "$repo/stub/timeout" <<'SH'
#!/usr/bin/env bash
echo used >> "$TIMEOUT_USED"
shift          # drop the duration argument
exec "$@"
SH
  chmod +x "$repo/stub/timeout"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( TIMEOUT_USED="$marker" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "wrapped run exits 0" "0" "$rc"
  if [ -f "$marker" ]; then pass "the claude run is wrapped in timeout"; else fail "the claude run is wrapped in timeout"; fi
}
test_run_timeout_wrap

echo "== monitor.sh: a wall-clock timeout fails the run and cleanup surfaces it =="
test_run_timeout_expiry() {
  local repo="$TMP/toexprepo" out rc
  make_fake_repo "$repo" "$(date +%F)" 1800
  # A stub `timeout` that simulates expiry: exit 124 (timeout's convention) without claude.
  printf '#!/usr/bin/env bash\nexit 124\n' > "$repo/stub/timeout"
  chmod +x "$repo/stub/timeout"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  if [ "$rc" -ne 0 ]; then pass "a timed-out run exits nonzero"; else fail "a timed-out run exits nonzero"; fi
  assert_contains "cleanup surfaces the failure" "$out" "run FAILED"
  if [ -d "$repo/state/.lock" ]; then fail "lock released after a timeout"; else pass "lock released after a timeout"; fi
}
test_run_timeout_expiry

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

# A stub claude for the editorial-pass tests: triage writes a report; the editor call
# (its prompt contains EDITOR_FIXTURE) records that it ran and, per env, rewrites /
# empties / fails. The config swaps models.deepdive -> models.editor so only the
# editor second pass is in play.
write_editor_stub() {  # $1 = repo
  cat > "$1/stub/claude" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *EDITOR_FIXTURE*)                          # the editorial pass
    [ -n "${ED_MARKER:-}" ] && echo ran >> "$ED_MARKER"
    [ -n "${ED_EMPTY:-}" ]   && : > "kb/.$(date +%F).daily.partial.md"
    [ -n "${ED_REWRITE:-}" ] && printf '# edited\n* curated item\n' > "kb/.$(date +%F).daily.partial.md"
    printf '{"num_turns":2,"total_cost_usd":0.0}\n'; exit "${ED_EXIT:-0}" ;;
  *)                                         # the triage pass
    printf '# report\n* item\n' > "kb/.$(date +%F).daily.partial.md"
    printf '{"num_turns":1,"total_cost_usd":0.0}\n'; exit 0 ;;
esac
SH
  chmod +x "$1/stub/claude"
}

# Swap the fixture config's deepdive model for an editor model (portable: pure s///,
# no newline insertion), so the editor pass is enabled and deep-dive is not.
enable_editor() { sed 's/^  deepdive: opus$/  editor: opus/' "$1/monitor-config.yaml" > "$1/c.tmp" && mv "$1/c.tmp" "$1/monitor-config.yaml"; }

echo "== monitor.sh: editorial pass runs on the report when models.editor is set =="
test_editor_enabled() {
  local repo="$TMP/edrepo" out rc ed="$TMP/ed_ran"
  make_fake_repo "$repo"
  enable_editor "$repo"
  write_editor_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( ED_MARKER="$ed" ED_REWRITE=1 HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  if [ -f "$ed" ]; then pass "editorial pass was invoked"; else fail "editorial pass was invoked"; fi
  assert_contains "logs the editor pass to runs.log" "$(cat "$repo/state/runs.log" 2>/dev/null)" '"pass":"editor"'
  if [ -s "$repo/kb/$(date +%F).daily.md" ]; then pass "edited report is delivered"; else fail "edited report is delivered"; fi
  assert_contains "the delivered report is the edited one" "$(cat "$repo/kb/$(date +%F).daily.md" 2>/dev/null)" "curated item"
}
test_editor_enabled

echo "== monitor.sh: no editorial pass when models.editor is unset =="
test_editor_disabled() {
  local repo="$TMP/edoffrepo" out rc ed="$TMP/ed_ran_off"
  make_fake_repo "$repo"
  # Remove deepdive too, so neither second pass runs; editor stays unset.
  sed '/^  deepdive: opus$/d' "$repo/monitor-config.yaml" > "$repo/c.tmp" && mv "$repo/c.tmp" "$repo/monitor-config.yaml"
  write_editor_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( ED_MARKER="$ed" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  if [ -f "$ed" ]; then fail "editorial pass NOT invoked when disabled"; else pass "editorial pass NOT invoked when disabled"; fi
}
test_editor_disabled

echo "== monitor.sh: a failed editorial pass keeps the unedited report =="
test_editor_failure() {
  local repo="$TMP/edfailrepo" out rc
  make_fake_repo "$repo"
  enable_editor "$repo"
  write_editor_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( ED_EXIT=1 ED_REWRITE=1 HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run still exits 0 despite editor failure" "0" "$rc"
  assert_contains "warns that the editorial pass failed" "$out" "editorial pass failed"
  assert_contains "the unedited report is delivered" "$(cat "$repo/kb/$(date +%F).daily.md" 2>/dev/null)" "* item"
}
test_editor_failure

echo "== monitor.sh: an editorial pass that empties the report keeps the unedited one =="
test_editor_empty() {
  local repo="$TMP/edemptyrepo" out rc
  make_fake_repo "$repo"
  enable_editor "$repo"
  write_editor_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( ED_EMPTY=1 HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  assert_contains "warns it kept the unedited report" "$out" "kept the unedited report"
  if [ -s "$repo/kb/$(date +%F).daily.md" ]; then pass "non-empty report delivered" ; else fail "non-empty report delivered"; fi
}
test_editor_empty

# A stub claude that appends one line per call to $ARGS_LOG - "<pass> --max-turns <n>"
# (the prompt itself is multi-line, so the full argv can't be line-indexed) - while
# still driving all three passes: triage writes a report + a high-scoring deep-dive
# queue entry; the deep-dive/editor calls just succeed.
write_arglog_stub() {  # $1 = repo
  cat > "$1/stub/claude" <<'SH'
#!/usr/bin/env bash
pass=triage
case "$*" in *DEEPDIVE_FIXTURE*) pass=deepdive ;; *EDITOR_FIXTURE*) pass=editor ;; esac
if [ -n "${ARGS_LOG:-}" ]; then
  turns=""
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" = "--max-turns" ] && turns="${args[i+1]:-}"
  done
  printf '%s --max-turns %s\n' "$pass" "$turns" >> "$ARGS_LOG"
fi
if [ "$pass" = triage ]; then
  printf '# report\n* item\n' > "kb/.$(date +%F).daily.partial.md"
  printf '{"url":"u","title":"t","signal":"opportunity","score":0.9,"so_what":"x"}\n' \
    > "state/.deepdive.daily.queue.jsonl"
  printf '{"num_turns":1,"total_cost_usd":0.0}\n'
else
  printf '{"num_turns":2,"total_cost_usd":0.0}\n'
fi
exit 0
SH
  chmod +x "$1/stub/claude"
}

echo "== monitor.sh: budgets.*_max_turns drives --max-turns per pass =="
test_budget_turns() {
  local repo="$TMP/budgetrepo" out rc argslog="$TMP/budget_args"
  make_fake_repo "$repo"
  # All three passes on, each with a distinct configured turn cap.
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  monitor: sonnet
  deepdive: opus
  editor: opus
budgets:
  monitor_max_turns: 33
  deepdive_max_turns: 22
  editor_max_turns: 11
YAML
  write_arglog_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( ARGS_LOG="$argslog" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  local calls; calls="$(cat "$argslog" 2>/dev/null)"
  assert_contains "triage gets budgets.monitor_max_turns"     "$calls" "triage --max-turns 33"
  assert_contains "deep-dive gets budgets.deepdive_max_turns" "$calls" "deepdive --max-turns 22"
  assert_contains "editor gets budgets.editor_max_turns"      "$calls" "editor --max-turns 11"
}
test_budget_turns

echo "== monitor.sh: absent or invalid budgets fall back to the default turn caps =="
test_budget_turn_defaults() {
  local repo="$TMP/budgetdefrepo" argslog="$TMP/budget_def_args"
  make_fake_repo "$repo"                       # fixture config has no budgets block
  write_arglog_stub "$repo"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  ( ARGS_LOG="$argslog" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
    bash "$repo/bin/monitor.sh" daily >/dev/null 2>&1 )
  assert_contains "no budgets block -> triage default --max-turns 40" \
    "$(cat "$argslog" 2>/dev/null)" "triage --max-turns 40"
  printf 'budgets:\n  monitor_max_turns: nope\n  deepdive_max_turns: 0\n' >> "$repo/monitor-config.yaml"
  : > "$argslog"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  ( ARGS_LOG="$argslog" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
    bash "$repo/bin/monitor.sh" daily >/dev/null 2>&1 )
  local calls; calls="$(cat "$argslog" 2>/dev/null)"
  assert_contains "non-numeric monitor_max_turns -> default 40" "$calls" "triage --max-turns 40"
  assert_contains "zero deepdive_max_turns -> default 40"       "$calls" "deepdive --max-turns 40"
}
test_budget_turn_defaults

echo "== monitor.sh: budgets.monthly_cost_usd warns when crossed, never skips the run =="
test_budget_monthly_warning() {
  local repo="$TMP/budgetwarn" out rc
  make_fake_repo "$repo"
  printf 'budgets:\n  monthly_cost_usd: 1.50\n' >> "$repo/monitor-config.yaml"
  printf '{"timestamp":"%s","mode":"daily","pass":"triage","cost_usd":2.0}\n' \
    "$(date -u +%FT%TZ)" > "$repo/state/runs.log"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "an over-budget run still exits 0" "0" "$rc"
  assert_contains "warns when the 30-day spend crosses the cap" "$out" "budgets.monthly_cost_usd"
  assert_contains "the warning carries the estimate caveat" "$out" "API-equivalent estimate"
  local n; n="$(printf '%s\n' "$out" | grep -c 'budgets.monthly_cost_usd' || true)"
  assert_eq "warns once per run, not on both checks" "1" "$n"
  # Spend outside the 30-day window doesn't count toward the cap.
  printf '{"timestamp":"2000-01-01T00:00:00Z","mode":"daily","pass":"triage","cost_usd":99}\n' \
    > "$repo/state/runs.log"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  case "$out" in
    *budgets.monthly_cost_usd*) fail "old spend outside the window doesn't warn" ;;
    *) pass "old spend outside the window doesn't warn" ;;
  esac
}
test_budget_monthly_warning

echo "== monitor.sh: the run that crosses the cap warns at its own end =="
test_budget_crossing_run() {
  local repo="$TMP/budgetcross" out rc
  make_fake_repo "$repo"
  printf 'budgets:\n  monthly_cost_usd: 1.50\n' >> "$repo/monitor-config.yaml"
  # No prior spend, so the pre-run check is quiet; this run's own logged cost
  # crosses the cap, and the end-of-run re-check must catch it.
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
printf '{"num_turns":1,"total_cost_usd":2.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "crossing run exits 0" "0" "$rc"
  assert_contains "the crossing run itself warns" "$out" "budgets.monthly_cost_usd"
}
test_budget_crossing_run

echo "== monitor.sh: no budget warning when under the cap or the cap is off =="
test_budget_monthly_off() {
  local repo="$TMP/budgetoff" out
  make_fake_repo "$repo"
  printf '{"timestamp":"%s","mode":"daily","pass":"triage","cost_usd":2.0}\n' \
    "$(date -u +%FT%TZ)" > "$repo/state/runs.log"
  # Default config: no budgets block at all -> cap off.
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  case "$out" in
    *budgets.monthly_cost_usd*) fail "no warning when the cap is unset" ;;
    *) pass "no warning when the cap is unset" ;;
  esac
  printf 'budgets:\n  monthly_cost_usd: 100\n' >> "$repo/monitor-config.yaml"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  case "$out" in
    *budgets.monthly_cost_usd*) fail "no warning while under the cap" ;;
    *) pass "no warning while under the cap" ;;
  esac
}
test_budget_monthly_off

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

echo "== portal.py --export: renders entities, sparklines, events, report links =="
test_portal_export() {
  local repo="$TMP/portalrepo" html
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  {
    printf '{"timestamp":"2026-05-01T07:00:00Z","entity":"Tudor BB58","metric":"secondary_price_usd","value":3650,"unit":"USD","source":"u"}\n'
    printf 'THIS IS A MALFORMED / TRUNCATED LINE {oops\n'   # must not blank the snapshot
    printf '{"timestamp":"2026-06-01T07:00:00Z","entity":"Tudor BB58","metric":"secondary_price_usd","value":3200,"unit":"USD","source":"u"}\n'
    printf '{"timestamp":"2026-06-06T07:00:00Z","entity":"Tudor BB58","metric":"event","event_type":"leak","value":"new GMT teased","source":"u"}\n'
    printf '{"timestamp":"2026-06-05T07:00:00Z","entity":"Tudor BB58","metric":"event","event_type":"leak","value":"X <b>raw</b> & co","source":"u"}\n'
  } > "$repo/state/observations.jsonl"
  printf 'r\n' > "$repo/kb/2026-06-06.daily.md"
  # A surfaced item dated today so the Activity visuals render in the static export.
  printf '{"id":"i1","date":"%s","signal":"opportunity","title":"x","url":"https://x"}\n' \
    "$(date -u +%F)" > "$repo/state/seen.jsonl"
  ( cd "$repo" && python3 bin/portal.py --export >/dev/null )
  html="$repo/kb/index.html"
  if [ ! -f "$html" ]; then fail "portal wrote kb/index.html"; return; fi
  pass "portal wrote kb/index.html"
  assert_contains "lists the tracked entity (despite a malformed line)" "$(cat "$html")" "Tudor BB58"
  assert_contains "renders a sparkline cell" "$(cat "$html")" 'class="spark"'
  assert_contains "export includes the Activity visuals" "$(cat "$html")" "Activity"
  assert_contains "export embeds an inline SVG (no JS, CSP-safe)" "$(cat "$html")" "<svg"
  assert_contains "topbar carries the inline brand logo" "$(cat "$html")" 'class="brand-mark"'
  assert_contains "event detail falls back to value when note is absent" "$(cat "$html")" "new GMT teased"
  assert_contains "HTML-escapes injected text" "$(cat "$html")" "X &lt;b&gt;raw&lt;/b&gt; &amp; co"
  case "$(cat "$html")" in
    *"<b>raw</b>"*) fail "no raw unescaped markup leaks into the snapshot" ;;
    *) pass "no raw unescaped markup leaks into the snapshot" ;;
  esac
  assert_contains "links a recent report" "$(cat "$html")" "2026-06-06.daily.md"
  python3 - "$html" <<'PY'
import sys, html.parser
class P(html.parser.HTMLParser): pass
P().feed(open(sys.argv[1]).read())
PY
  assert_eq "kb/index.html parses as HTML" "0" "$?"
}
test_portal_export

echo "== demo-bundle.sh: packages the portal runtime + live data into a portable folder =="
test_demo_bundle() {
  local repo="$TMP/demorepo" out="$TMP/demoout"
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/portal.py" "$ROOT/bin/portal.sh" "$ROOT/bin/cadence.py" \
     "$ROOT/bin/config-lib.sh" "$ROOT/bin/demo-bundle.sh" "$repo/bin/"
  printf 'subject:\n  name: Acme Corp\noutput:\n  webhook_url: https://x/h\n' > "$repo/monitor-config.yaml"
  printf 'subject:\n  name: Acme Corp\n' > "$repo/profile.yaml"
  printf '{"timestamp":"2026-06-01T07:00:00Z","entity":"Acme","metric":"event","event_type":"x","value":"hi","source":"u"}\n' \
    > "$repo/state/observations.jsonl"
  printf 'r\n' > "$repo/kb/2026-06-06.daily.md"
  ( cd "$repo" && bash bin/demo-bundle.sh --out "$out" --tar >/dev/null 2>&1 )
  # The portal runtime travels with the bundle (portal.py is required; cadence.py is the
  # one sibling it loads by path).
  for f in bin/portal.py bin/portal.sh bin/cadence.py; do
    if [ -f "$out/$f" ]; then pass "bundle ships $f"; else fail "bundle ships $f"; fi
  done
  # Live data is copied verbatim (we bundle everything as-is, no redaction).
  if [ -f "$out/monitor-config.yaml" ]; then pass "bundle ships monitor-config.yaml"; else fail "bundle ships monitor-config.yaml"; fi
  if [ -f "$out/profile.yaml" ]; then pass "bundle ships profile.yaml"; else fail "bundle ships profile.yaml"; fi
  if [ -f "$out/state/observations.jsonl" ]; then pass "bundle ships state/"; else fail "bundle ships state/"; fi
  if [ -f "$out/kb/2026-06-06.daily.md" ]; then pass "bundle ships kb/ reports"; else fail "bundle ships kb/ reports"; fi
  # A one-command launcher and an orientation note land at the bundle root.
  if [ -x "$out/start-demo.sh" ]; then pass "bundle has an executable start-demo.sh"; else fail "bundle has an executable start-demo.sh"; fi
  if [ -f "$out/START-HERE.md" ]; then pass "bundle has START-HERE.md"; else fail "bundle has START-HERE.md"; fi
  # --tar writes a carryable archive alongside the folder.
  if [ -f "$out.tar.gz" ]; then pass "--tar writes a tarball"; else fail "--tar writes a tarball"; fi
  # The bundle is self-serving: the portal renders the bundled data on its own.
  ( cd "$out" && python3 bin/portal.py --export >/dev/null 2>&1 )
  if [ -f "$out/kb/index.html" ]; then
    pass "bundled portal renders its data (kb/index.html)"
    assert_contains "bundle render names the tracked entity" "$(cat "$out/kb/index.html")" "Acme"
  else
    fail "bundled portal renders its data (kb/index.html)"
  fi
  # Without --force, an existing destination is refused (a bundle is cheap to rebuild,
  # but clobbering the wrong folder is not).
  local err
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out "$out" 2>&1 1>/dev/null )" || true
  assert_contains "refuses to overwrite without --force" "$err" "already exists"
  # --force replaces it cleanly.
  if ( cd "$repo" && bash bin/demo-bundle.sh --out "$out" --force >/dev/null 2>&1 ); then
    pass "--force overwrites an existing bundle"
  else
    fail "--force overwrites an existing bundle"
  fi
  # An empty source still produces a (warned) startable bundle rather than crashing.
  local bare="$TMP/demobare" bareout="$TMP/demobareout"
  mkdir -p "$bare/bin"
  cp "$ROOT/bin/portal.py" "$ROOT/bin/portal.sh" "$ROOT/bin/cadence.py" \
     "$ROOT/bin/demo-bundle.sh" "$bare/bin/"
  if ( cd "$bare" && bash bin/demo-bundle.sh --out "$bareout" >/dev/null 2>&1 ); then
    pass "bundles with no data without crashing"
  else
    fail "bundles with no data without crashing"
  fi
  # Safety: --force must never aim rm -rf at the repo itself, an ancestor, or an
  # arbitrary important directory. A canary file in the repo proves nothing got deleted.
  printf 'canary\n' > "$repo/CANARY"
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out . --force 2>&1 1>/dev/null )" || true
  assert_contains "refuses --out . (the repo itself)" "$err" "refusing"
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out .. --force 2>&1 1>/dev/null )" || true
  assert_contains "refuses --out .. (an ancestor of the repo)" "$err" "ancestor"
  if [ -f "$repo/CANARY" ] && [ -f "$repo/bin/demo-bundle.sh" ]; then
    pass "refused --force left the repo untouched"
  else
    fail "refused --force left the repo untouched"
  fi
  # --force won't nuke a populated directory it didn't create (no START-HERE.md).
  local stranger="$TMP/demostranger"
  mkdir -p "$stranger"; printf 'precious\n' > "$stranger/keep.txt"
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out "$stranger" --force 2>&1 1>/dev/null )" || true
  assert_contains "refuses --force on a populated non-bundle dir" "$err" "not a previous demo bundle"
  if [ -f "$stranger/keep.txt" ]; then pass "stranger dir left intact"; else fail "stranger dir left intact"; fi
  # --force on an existing regular file is refused (a bundle is a folder) -- so a stray
  # '--out profile.yaml --force' can't delete the live profile.
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out profile.yaml --force 2>&1 1>/dev/null )" || true
  assert_contains "refuses --force on an existing non-directory" "$err" "non-directory"
  if [ -f "$repo/profile.yaml" ]; then pass "live profile.yaml left intact"; else fail "live profile.yaml left intact"; fi
  # A destination inside a copied tree (state/, kb/) is refused before cp recurses into
  # itself and strands a half-built bundle in the live data.
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out state/demo 2>&1 1>/dev/null )" || true
  assert_contains "refuses --out inside state/" "$err" "inside the state/ tree"
  if [ ! -e "$repo/state/demo" ]; then pass "no bundle stranded under state/"; else fail "no bundle stranded under state/"; fi
  # A custom monitoring.state_file outside state/ is copied into the bundle and the demo
  # config repointed at it (so the off-machine portal never reaches back to live state).
  local sfrepo="$TMP/demosf" sfout="$TMP/demosfout"
  mkdir -p "$sfrepo/bin" "$sfrepo/state" "$sfrepo/var"
  cp "$ROOT/bin/portal.py" "$ROOT/bin/portal.sh" "$ROOT/bin/cadence.py" \
     "$ROOT/bin/config-lib.sh" "$ROOT/bin/demo-bundle.sh" "$sfrepo/bin/"
  printf 'monitoring:\n  state_file: var/dedup.jsonl\nsubject:\n  name: Acme\n' > "$sfrepo/monitor-config.yaml"
  printf '{"id":"i1","date":"2026-06-06","signal":"opportunity","title":"x","url":"https://x"}\n' \
    > "$sfrepo/var/dedup.jsonl"
  ( cd "$sfrepo" && bash bin/demo-bundle.sh --out "$sfout" >/dev/null 2>&1 )
  if [ -f "$sfout/state/dedup.jsonl" ]; then pass "bundles the out-of-tree state_file under state/"; else fail "bundles the out-of-tree state_file under state/"; fi
  assert_contains "repoints the demo config at the bundled state_file" \
    "$(cat "$sfout/monitor-config.yaml" 2>/dev/null)" "state_file: state/dedup.jsonl"
  # A real bundle carries the .vp-demo-bundle sentinel; --force keys off that, not a
  # generic START-HERE.md, so an unrelated docs folder that merely has its own
  # START-HERE.md is not clobbered.
  if [ -f "$out/.vp-demo-bundle" ]; then pass "bundle carries the .vp-demo-bundle sentinel"; else fail "bundle carries the .vp-demo-bundle sentinel"; fi
  local docsdir="$TMP/demodocs"
  mkdir -p "$docsdir"; printf '# getting started\n' > "$docsdir/START-HERE.md"; printf 'keep\n' > "$docsdir/other.txt"
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out "$docsdir" --force 2>&1 1>/dev/null )" || true
  assert_contains "refuses --force on a non-bundle dir that only has START-HERE.md" "$err" "not a previous demo bundle"
  if [ -f "$docsdir/other.txt" ]; then pass "generic START-HERE.md dir left intact"; else fail "generic START-HERE.md dir left intact"; fi
  # --tar treats <out>.tar.gz as an output artifact: it won't clobber an existing one
  # without --force (test with the folder absent so the folder guard doesn't mask it).
  local tdir="$TMP/demotar"
  ( cd "$repo"; bash bin/demo-bundle.sh --out "$tdir" --tar >/dev/null 2>&1 )
  rm -rf "$tdir"                                   # keep $tdir.tar.gz, drop the folder
  err="$( cd "$repo"; bash bin/demo-bundle.sh --out "$tdir" --tar 2>&1 1>/dev/null )" || true
  assert_contains "refuses --tar when the tarball already exists" "$err" ".tar.gz already exists"
  if ( cd "$repo"; bash bin/demo-bundle.sh --out "$tdir" --tar --force >/dev/null 2>&1 ); then
    pass "--force lets --tar overwrite an existing tarball"
  else
    fail "--force lets --tar overwrite an existing tarball"
  fi
  # An out-of-tree state_file whose basename collides with a real bundled file (grades)
  # is namespaced, not overwritten -- the bundled feedback.jsonl keeps its grades.
  local colrepo="$TMP/democol" colout="$TMP/democolout"
  mkdir -p "$colrepo/bin" "$colrepo/state" "$colrepo/var"
  cp "$ROOT/bin/portal.py" "$ROOT/bin/portal.sh" "$ROOT/bin/cadence.py" \
     "$ROOT/bin/config-lib.sh" "$ROOT/bin/demo-bundle.sh" "$colrepo/bin/"
  printf 'monitoring:\n  state_file: var/feedback.jsonl\nsubject:\n  name: Acme\n' > "$colrepo/monitor-config.yaml"
  printf 'REAL_GRADES\n' > "$colrepo/state/feedback.jsonl"
  printf 'DEDUP_LOG\n' > "$colrepo/var/feedback.jsonl"
  ( cd "$colrepo" && bash bin/demo-bundle.sh --out "$colout" >/dev/null 2>&1 )
  assert_eq "basename collision preserves the bundled grades file" "REAL_GRADES" "$(cat "$colout/state/feedback.jsonl" 2>/dev/null)"
  if [ -f "$colout/state/statefile-feedback.jsonl" ]; then pass "colliding state_file is namespaced"; else fail "colliding state_file is namespaced"; fi
  assert_contains "config repointed at the namespaced state_file" \
    "$(cat "$colout/monitor-config.yaml" 2>/dev/null)" "state_file: state/statefile-feedback.jsonl"
  # A symlinked file inside state/ is dereferenced into real data, so the off-site bundle
  # is self-contained (and never points back at the original machine's live state).
  local symrepo="$TMP/demosym" symout="$TMP/demosymout" ext="$TMP/demoext.jsonl"
  mkdir -p "$symrepo/bin" "$symrepo/state"
  cp "$ROOT/bin/portal.py" "$ROOT/bin/portal.sh" "$ROOT/bin/cadence.py" \
     "$ROOT/bin/config-lib.sh" "$ROOT/bin/demo-bundle.sh" "$symrepo/bin/"
  printf 'subject:\n  name: Acme\n' > "$symrepo/monitor-config.yaml"
  printf 'EXTERNAL_OBS\n' > "$ext"
  ln -s "$ext" "$symrepo/state/observations.jsonl"
  ( cd "$symrepo" && bash bin/demo-bundle.sh --out "$symout" >/dev/null 2>&1 )
  if [ -f "$symout/state/observations.jsonl" ] && [ ! -L "$symout/state/observations.jsonl" ]; then
    pass "symlinked state file is dereferenced into a real file"
  else
    fail "symlinked state file is dereferenced into a real file"
  fi
  assert_eq "dereferenced content matches the link target" "EXTERNAL_OBS" "$(cat "$symout/state/observations.jsonl" 2>/dev/null)"
}
test_demo_bundle

echo "== portal.sh: argument handling =="
test_portal_args() {
  local repo="$TMP/portalargs" rc
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/portal.sh" "$ROOT/bin/portal.py" "$repo/bin/"
  ( cd "$repo" && bash bin/portal.sh --help >/dev/null 2>&1 ); rc=$?
  assert_eq "--help exits 0" "0" "$rc"
  ( cd "$repo" && bash bin/portal.sh --port abc >/dev/null 2>&1 ); rc=$?
  assert_eq "--port with a non-numeric value exits 2" "2" "$rc"
  ( cd "$repo" && bash bin/portal.sh --bogus >/dev/null 2>&1 ); rc=$?
  assert_eq "an unknown argument exits 2" "2" "$rc"
  # --export writes kb/index.html without starting a server.
  mkdir -p "$repo/kb" "$repo/state"
  ( cd "$repo" && bash bin/portal.sh --export >/dev/null 2>&1 ); rc=$?
  assert_eq "--export exits 0" "0" "$rc"
  if [ -f "$repo/kb/index.html" ]; then pass "--export wrote kb/index.html"; else fail "--export wrote kb/index.html"; fi
}
test_portal_args

echo "== portal.py: serves overview/reports/review/profile/config + records grades =="
test_portal_server() {
  if ! command -v curl >/dev/null 2>&1; then pass "portal server (skipped: no curl)"; return; fi
  local repo="$TMP/psrvrepo" port=8791 page
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  printf 'version: 1\nsubject:\n  name: "Test Market & Co"\noutput:\n  email_to: ""\n' \
    > "$repo/monitor-config.yaml"
  printf 'subject:\n  name: "Watches"\n  derived:\n    last_bootstrapped: 2026-06-01\n' \
    > "$repo/profile.yaml"
  # A human-readable summary alongside the YAML -> the profile view renders it like the
  # bootstrap email (the YAML stays reachable at ?raw=1).
  printf '# Profile summary\n\n> **Bottom line:** a collector of mechanical watches.\n\n## Interests\n- in-house movements\n' \
    > "$repo/profile.summary.md"
  # The report body carries a raw <script> to prove it can't become live markup when
  # served (escaped by the fallback; raw_html disabled in pandoc; omitted by cmark).
  printf '# Daily\n\n> **Bottom line:** corroborated\n\n## Opportunities\n- **Item** matters [src](https://x) <script>alert(1)</script>\n' \
    > "$repo/kb/2026-06-06.daily.md"
  {
    printf '{"id":"abc123","title":"Tudor GMT leak","signal":"opportunity","score":0.9,"so_what":"matters","url":"https://x"}\n'
    printf 'MALFORMED LINE {oops\n'                          # must not break the listing
    printf 'null\n'                                          # valid JSON, non-object -> must be skipped
    printf '{"id":"evil","title":"XSS attempt","signal":"opportunity","score":0.5,"url":"javascript:alert(1)"}\n'
  } > "$repo/state/seen.jsonl"
  ( cd "$repo" && exec python3 bin/portal.py "$port" >/dev/null 2>&1 ) &
  local srv=$!
  page="$(curl -s --retry 8 --retry-delay 1 --retry-connrefused "http://127.0.0.1:$port/review" || true)"
  assert_contains "review lists a surfaced item (skips the malformed line)" "$page" "Tudor GMT leak"
  assert_contains "each surfaced item carries a scroll anchor" "$page" 'class="item" id="item-0"'
  assert_contains "renders a safe http(s) source link" "$page" 'href="https://x"'
  case "$page" in
    *'href="javascript'*) fail "drops a javascript: url instead of linking it" ;;
    *) pass "drops a javascript: url instead of linking it" ;;
  esac
  local list_html; list_html="$(curl -s "http://127.0.0.1:$port/reports" || true)"
  assert_contains "reports list links to the report file" "$list_html" "/reports?f=2026-06-06.daily.md"
  assert_contains "reports list shows a friendly date label (not the .md filename)" "$list_html" ">2026-06-06</a>"
  assert_contains "reports list offers a 'Save all as PDF' link" "$list_html" "/reports?print=1"
  local report_html; report_html="$(curl -s "http://127.0.0.1:$port/reports?f=2026-06-06.daily.md" || true)"
  assert_contains "a report renders its body" "$report_html" "Bottom line"
  assert_contains "the report page sets a PDF-friendly title" "$report_html" "<title>Vantage Point — Daily briefing 2026-06-06</title>"
  assert_contains "pages ship a print stylesheet for Save-as-PDF" "$report_html" "@media print"
  local print_html; print_html="$(curl -s "http://127.0.0.1:$port/reports?print=1" || true)"
  assert_contains "the print-all view renders the report body" "$print_html" "Bottom line"
  assert_contains "the print-all view marks reports for page breaks" "$print_html" "printreport"
  case "$report_html" in
    *"<script>alert(1)</script>"*) fail "raw <script> in a report is not served as live markup" ;;
    *) pass "raw <script> in a report is not served as live markup" ;;
  esac
  assert_contains "responses carry a script-blocking CSP header" \
    "$(curl -s -D - -o /dev/null "http://127.0.0.1:$port/reports?f=2026-06-06.daily.md" || true)" \
    "Content-Security-Policy: default-src 'none'"
  assert_contains "a bogus report name is rejected (no path traversal)" \
    "$(curl -s "http://127.0.0.1:$port/reports?f=../monitor-config.yaml" || true)" "Report not found"
  assert_contains "config view is read-only and renders the config" \
    "$(curl -s "http://127.0.0.1:$port/config" || true)" "Test Market &amp; Co"
  local profile_html; profile_html="$(curl -s "http://127.0.0.1:$port/profile" || true)"
  assert_contains "profile view renders the formatted summary like the email" "$profile_html" "Bottom line"
  assert_contains "the summary view links to the raw YAML" "$profile_html" "/profile?raw=1"
  assert_contains "the profile YAML is reachable at ?raw=1" \
    "$(curl -s "http://127.0.0.1:$port/profile?raw=1" || true)" "last_bootstrapped"
  # The grade redirects back to the graded row (not the page top), so the portal
  # doesn't jump to the top after every thumb.
  assert_contains "a grade redirects back to its row, not the page top" \
    "$(curl -s -D - -o /dev/null "http://127.0.0.1:$port/grade?id=abc123&v=up" || true)" \
    "Location: /review#item-1"
  kill "$srv" 2>/dev/null || true
  assert_contains "a grade is recorded to feedback.jsonl" "$(cat "$repo/state/feedback.jsonl" 2>/dev/null)" '"verdict": "up"'
  assert_contains "the grade captures the item id" "$(cat "$repo/state/feedback.jsonl" 2>/dev/null)" '"id": "abc123"'
}
test_portal_server

echo "== portal.py: missed-signal reports record a 'missed' verdict (recall loop) =="
test_portal_missed() {
  if ! command -v curl >/dev/null 2>&1; then pass "portal missed signals (skipped: no curl)"; return; fi
  local repo="$TMP/pmissrepo" port=8798 page fb
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  printf 'version: 1\n' > "$repo/monitor-config.yaml"
  ( cd "$repo" && exec python3 bin/portal.py "$port" >/dev/null 2>&1 ) &
  local srv=$!
  page="$(curl -s --retry 8 --retry-delay 1 --retry-connrefused "http://127.0.0.1:$port/review" || true)"
  assert_contains "review offers the missed-signal form" "$page" 'action="/missed"'
  curl -s -o /dev/null "http://127.0.0.1:$port/missed?url=https%3A%2F%2Fex.com%2Fmissed-item&note=big%20launch" || true
  fb="$(cat "$repo/state/feedback.jsonl" 2>/dev/null)"
  assert_contains "a report records verdict missed" "$fb" '"verdict": "missed"'
  assert_contains "the report carries the url" "$fb" 'https://ex.com/missed-item'
  assert_contains "the report carries the note" "$fb" 'big launch'
  # Same URL re-reported -> same id, so dedupe-feedback collapses to one row.
  curl -s -o /dev/null "http://127.0.0.1:$port/missed?url=https%3A%2F%2Fex.com%2Fmissed-item" || true
  assert_eq "re-reporting a URL reuses its stable id" "1" \
    "$(python3 "$ROOT/bin/dedupe-feedback.py" "$repo/state/feedback.jsonl" | grep -c .)"
  # A non-http(s) URL is rejected, not recorded.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/missed?url=javascript%3Aalert(1)" || true)"
  assert_eq "a non-http(s) url is rejected with 400" "400" "$code"
  case "$(cat "$repo/state/feedback.jsonl")" in
    *javascript*) fail "a rejected url is not recorded" ;;
    *) pass "a rejected url is not recorded" ;;
  esac
  page="$(curl -s "http://127.0.0.1:$port/review" || true)"
  assert_contains "review lists the recorded miss" "$page" "ex.com/missed-item"
  page="$(curl -s "http://127.0.0.1:$port/" || true)"
  assert_contains "calibration card counts reported misses" "$page" "missed signal"
  kill "$srv" 2>/dev/null || true
}
test_portal_missed

echo "== portal.py: the draft view leads with a live diff vs the approved profile =="
test_portal_draft_diff() {
  local repo="$TMP/pdiff" out py="$TMP/pdiff.py"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  printf 'relevance:\n  threshold: 0.6\n  old_line: kept\n' > "$repo/profile.yaml"
  # The draft raises the threshold and carries a raw <script> to prove the diff
  # rendering escapes rather than serves it.
  printf 'relevance:\n  threshold: 0.7\n  note: "<script>alert(1)</script>"\n' > "$repo/profile.draft.yaml"
  cat > "$py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
page = m.profile_inner({"draft": ["1"]})
print("CARD", "What changed vs the approved profile" in page)
print("MINUS", '<span class="dr">-  threshold: 0.6</span>' in page)
print("PLUS", '<span class="da">+  threshold: 0.7</span>' in page)
print("ESCAPED", "<script>alert(1)</script>" not in page)
approved = m.profile_inner({})
print("BANNER", "View the draft and what changed" in approved)
os.remove(m.PROFILE_DRAFT)
print("NO_DRAFT_CARD", "What changed" not in m.profile_inner({}))
PY
  out="$(python3 "$py" "$repo/bin/portal.py")"
  assert_contains "draft view shows the what-changed card" "$out" "CARD True"
  assert_contains "removed lines are tinted" "$out" "MINUS True"
  assert_contains "added lines are tinted" "$out" "PLUS True"
  assert_contains "diff content is escaped, not served as markup" "$out" "ESCAPED True"
  assert_contains "approved view's banner points at the diff" "$out" "BANNER True"
  assert_contains "no card without a pending draft" "$out" "NO_DRAFT_CARD True"
}
test_portal_draft_diff

echo "== portal.py: the draft view shows the rubric backtest card when present =="
test_portal_backtest_card() {
  local repo="$TMP/pbt" out py="$TMP/pbt.py"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  printf 'relevance:\n  threshold: 0.6\n' > "$repo/profile.yaml"
  printf 'relevance:\n  threshold: 0.6\n  rubric: refreshed\n' > "$repo/profile.draft.yaml"
  printf '## Backtest vs your grades\n\nagrees with your verdict: 41 / 47\n\n**Would now drop** (score fell below threshold 0.60):\n\n- [a1b2c3d4] Competitor B ships orchestration  0.82 -> 0.41\n' \
    > "$repo/profile.draft.backtest.md"
  cat > "$py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
page = m.profile_inner({"draft": ["1"]})
print("CARD", "Backtest vs your grades" in page)
print("DROP", "Would now drop" in page)
print("MTIME", "backtested" in page)
# Not shown on the approved view, and gone once the artifact is removed.
print("NOT_ON_APPROVED", "Backtest vs your grades" not in m.profile_inner({}))
os.remove(m.PROFILE_DRAFT_BACKTEST)
print("ABSENT", "Backtest vs your grades" not in m.profile_inner({"draft": ["1"]}))
PY
  out="$(python3 "$py" "$repo/bin/portal.py")"
  assert_contains "draft view renders the backtest card" "$out" "CARD True"
  assert_contains "the would-drop regression list is shown" "$out" "DROP True"
  assert_contains "the card stamps its backtest date" "$out" "MTIME True"
  assert_contains "the approved view omits the backtest" "$out" "NOT_ON_APPROVED True"
  assert_contains "no card once the artifact is gone" "$out" "ABSENT True"
}
test_portal_backtest_card

echo "== portal.py: the light-markdown fallback renders a GFM table (watchlist) =="
test_portal_light_table() {
  # Exercise the no-renderer path directly so it's deterministic regardless of whether
  # the host has pandoc/cmark installed.
  local out
  out="$(python3 - "$ROOT/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
md = "| Entity | Latest |\n|--------|--------|\n| Tudor BB58 | $3,200 |\n"
print(m._light_md(md))
PY
)"
  assert_contains "renders a table element" "$out" "<table>"
  assert_contains "renders a header cell" "$out" "<th>Entity</th>"
  assert_contains "renders a body cell" "$out" "<td>Tudor BB58</td>"
  case "$out" in
    *"|"*) fail "no raw table pipes leak through" ;;
    *) pass "no raw table pipes leak through" ;;
  esac
}
test_portal_light_table

echo "== portal.py: the light-markdown fallback renders emphasis without leaking marks =="
test_portal_light_emphasis() {
  # The no-renderer path must turn *, _, ** and __ into <em>/<strong> instead of
  # leaking the literal marks -- while leaving snake_case identifiers and the contents
  # of `code spans` untouched (the GFM intra-word / code rules).
  local out
  out="$(python3 - "$ROOT/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m._light_md("This is _italic_ and *also* and __bold__ and **strong**."))
print(m._light_md("A snake_case_name and `config_lib.sh` stay literal."))
# Two short bold spans on one line must stay separate (not over-match into one).
print(m._light_md("**A** and **B**"))
# A link whose URL contains emphasis-like marks must keep its destination intact,
# while emphasis still applies to the link text.
print(m._light_md("[**x**](https://example.com/_id_/*p*)"))
# A code span inside a link label must survive (nested placeholder restore).
print(m._light_md("see [`config_lib.sh`](https://example.com)"))
PY
)"
  assert_contains "underscore emphasis becomes <em>" "$out" "<em>italic</em>"
  assert_contains "single-asterisk emphasis becomes <em>" "$out" "<em>also</em>"
  assert_contains "double-underscore becomes <strong>" "$out" "<strong>bold</strong>"
  assert_contains "double-asterisk becomes <strong>" "$out" "<strong>strong</strong>"
  assert_contains "snake_case is not italicised" "$out" "snake_case_name"
  assert_contains "underscores inside a code span stay literal" "$out" "<code>config_lib.sh</code>"
  assert_contains "two short bold spans stay separate" "$out" "<strong>A</strong> and <strong>B</strong>"
  assert_contains "a URL with emphasis marks keeps its destination" "$out" 'href="https://example.com/_id_/*p*"'
  assert_contains "emphasis still applies to the link text" "$out" "<strong>x</strong></a>"
  assert_contains "a code span inside a link label survives" "$out" '<a href="https://example.com"><code>config_lib.sh</code></a>'
  case "$out" in
    *"_italic_"*|*"__bold__"*) fail "no raw emphasis marks leak through" ;;
    *) pass "no raw emphasis marks leak through" ;;
  esac
}
test_portal_light_emphasis

echo "== portal.py: data layer is robust to NaN / null-ts / multi-pass runs.log =="
test_portal_data_robustness() {
  local repo="$TMP/pdr" out day
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  {
    printf '{"timestamp":"2026-06-01T00:00:00Z","entity":"E","metric":"m","value":10,"unit":"x"}\n'
    printf '{"timestamp":"2026-06-02T00:00:00Z","entity":"E","metric":"m","value":20,"unit":"x"}\n'
    printf '{"timestamp":null,"entity":"E","metric":"m","value":99999,"unit":"x"}\n'                  # null ts must not win
    printf '{"timestamp":"2026-06-03T00:00:00Z","entity":"E","metric":"m","value":NaN,"unit":"x"}\n'  # non-finite skipped
    printf '{"timestamp":"2026-06-04T00:00:00Z","entity":["bad"],"metric":"m","value":5}\n'           # non-scalar entity skipped
    printf '{"timestamp":"2026-06-04T00:00:00Z","entity":"E","metric":{"x":1},"value":5}\n'           # non-scalar metric skipped
  } > "$repo/state/observations.jsonl"
  # Two passes of ONE monitor invocation, stamped independently (distinct timestamps),
  # both inside the 30-day window (stamped "today" so the window check is deterministic).
  day="$(date -u +%Y-%m-%dT%H:%M)"
  {
    printf '{"timestamp":"%s:01Z","mode":"daily","pass":"triage","cost_usd":0.02}\n' "$day"
    printf '{"timestamp":"%s:02Z","mode":"daily","pass":"deepdive","cost_usd":0.30}\n' "$day"
  } > "$repo/state/runs.log"
  out="$(python3 - "$repo/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows = m.tracked_entities()
print("LATEST", rows[0]["latest"])
print("ASOF", rows[0]["as_of"])
print("SPARK_OK", bool(m.spark(rows[0]["series"])))
runs, cost, _ = m.run_stats()
print("RUNS", runs)
print("COST", round(cost, 2))
PY
)"
  assert_contains "a null-timestamp row does not become the latest value" "$out" "LATEST 20"
  assert_contains "as_of comes from a real timestamp, not None" "$out" "ASOF 2026-06-02"
  assert_contains "a non-finite (NaN) value can't crash the sparkline" "$out" "SPARK_OK True"
  assert_contains "multi-pass invocation counts as one run" "$out" "RUNS 1"
  assert_contains "cost still sums across every pass" "$out" "COST 0.32"
  assert_contains "a non-scalar entity/metric row can't crash the page" "$out" "LATEST 20"
}
test_portal_data_robustness

echo "== portal.py: fallback links preserve query strings; stale summary isn't preferred =="
test_portal_fallback_links_and_freshness() {
  local repo="$TMP/pflf" out
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  printf 'subject:\n  name: x\n' > "$repo/profile.yaml"
  printf '# summary\n' > "$repo/profile.summary.md"
  touch -t 202001010000 "$repo/profile.summary.md"   # digest OLDER than the profile
  touch -t 202601010000 "$repo/profile.yaml"
  out="$(python3 - "$repo/bin/portal.py" <<'PY'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# Fallback markdown must not double-escape a query-string '&' in the href.
print(m._light_md("see [src](https://example.com/p?a=1&b=2)"))
print("STALE", m._summary_is_current(m.PROFILE_SUMMARY, m.PROFILE))
os.utime(m.PROFILE_SUMMARY, (time.time(), time.time()))    # now at least as fresh
print("FRESH", m._summary_is_current(m.PROFILE_SUMMARY, m.PROFILE))
PY
)"
  assert_contains "a query-string link keeps a single &amp; in the href" "$out" 'href="https://example.com/p?a=1&amp;b=2"'
  case "$out" in
    *"&amp;amp;"*) fail "no double-escaped &amp;amp; in a fallback link" ;;
    *) pass "no double-escaped &amp;amp; in a fallback link" ;;
  esac
  assert_contains "a digest older than the profile is treated as stale" "$out" "STALE False"
  assert_contains "a digest at least as fresh as the profile is used" "$out" "FRESH True"
}
test_portal_fallback_links_and_freshness

echo "== portal.py: activity calendar + signal-mix render inline SVG from seen.jsonl =="
test_portal_activity_visuals() {
  local repo="$TMP/pav" out py="$TMP/pav.py"
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  # Write the probe to a file (statement-level heredoc) rather than piping it through a
  # heredoc inside $( ): bash 3.2's $() parser miscounts the parens in this script and
  # closes the substitution early. Running a plain `python3 file` inside $() is safe.
  cat > "$py" <<'PY'
import importlib.util, json, os, sys
from datetime import datetime, timezone, timedelta
root = os.path.dirname(os.path.dirname(sys.argv[1]))
today = datetime.now(timezone.utc).date()
def r(days_ago, sig, n):
    return {"id": "%s%d" % (sig, days_ago), "date": (today - timedelta(days=days_ago)).isoformat(),
            "signal": sig, "title": "t", "url": "https://x"}
rows = [r(0, "opportunity", 1), r(0, "threat", 1), r(1, "shift", 1), r(8, "opportunity", 1)]
rows += [{"id": "d", "date": today.isoformat(), "signal": "dropped", "title": "d"},  # excluded
         {"id": "nd", "signal": "opportunity", "title": "no date"},                  # skipped
         {"id": "bd", "date": "not-a-date", "signal": "threat", "title": "bad"},      # skipped
         {"id": "ns", "date": (today - timedelta(days=2)).isoformat(),               # non-scalar
          "signal": ["weird"], "title": "malformed signal"}]                         # must not crash
with open(os.path.join(root, "state", "seen.jsonl"), "w") as f:
    for row in rows:
        f.write(json.dumps(row) + "\n")
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cal, mix = m.activity_calendar(), m.signal_mix()
print("CAL_SVG", cal.count("<svg"))                              # also proves the non-scalar row didn't crash
print("CAL_TODAY", ("%s: 2 items" % today.isoformat()) in cal)   # dropped item excluded -> 2 not 3
print("MIX_SVG", mix.count("<svg"))
print("MIX_THREAT", m.SIG_COLORS["threat"] in mix)
# Only an out-of-window dated item -> nothing visible -> both cards omitted.
with open(os.path.join(root, "state", "seen.jsonl"), "w") as f:
    f.write(json.dumps({"id": "old", "date": (today - timedelta(days=300)).isoformat(),
                        "signal": "opportunity", "title": "x"}) + "\n")
print("OOW_CAL", repr(m.activity_calendar()))
open(os.path.join(root, "state", "seen.jsonl"), "w").close()     # empty -> visuals omitted
print("EMPTY_CAL", repr(m.activity_calendar()))
print("EMPTY_MIX", repr(m.signal_mix()))
PY
  out="$(python3 "$py" "$repo/bin/portal.py")"
  assert_contains "calendar renders one inline SVG (and a non-scalar signal didn't crash it)" "$out" "CAL_SVG 1"
  assert_contains "calendar counts surfaced items per day (drops the 'dropped' item)" "$out" "CAL_TODAY True"
  assert_contains "signal mix renders one inline SVG" "$out" "MIX_SVG 1"
  assert_contains "signal mix includes the threat color" "$out" "MIX_THREAT True"
  assert_contains "calendar is omitted when all dated items fall outside the window" "$out" "OOW_CAL ''"
  assert_contains "calendar is omitted when there are no dated items" "$out" "EMPTY_CAL ''"
  assert_contains "signal mix is omitted when there are no dated items" "$out" "EMPTY_MIX ''"
}
test_portal_activity_visuals

echo "== portal.py: calibration card computes precision / coverage / source hit rates =="
test_portal_calibration() {
  local repo="$TMP/pcal" out py="$TMP/pcal.py"
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  # File-based probe (not a heredoc inside $()): bash 3.2's $() parser chokes on that.
  cat > "$py" <<'PY'
import importlib.util, json, os, sys
from datetime import datetime, timezone, timedelta
root = os.path.dirname(os.path.dirname(sys.argv[1]))
today = datetime.now(timezone.utc).date()
d0, d1 = today.isoformat(), (today - timedelta(days=1)).isoformat()
old = (today - timedelta(days=60)).isoformat()
seen = [
    {"id": "g1", "date": d0, "signal": "opportunity", "title": "good", "source": "alpha.com", "url": "https://a"},
    {"id": "g2", "date": d1, "signal": "threat", "title": "good2", "source": "alpha.com", "url": "https://a2"},
    {"id": "b1", "date": d1, "signal": "shift", "title": "bad", "source": "beta.com", "url": "https://b"},
    {"id": "u1", "date": d0, "signal": "shift", "title": "ungraded", "source": "beta.com", "url": "https://b2"},
    {"id": "dr", "date": d0, "signal": "dropped", "title": "dropped", "source": "alpha.com"},
    {"id": "oo", "date": old, "signal": "threat", "title": "out of window", "source": "alpha.com", "url": "https://a3"},
]
with open(os.path.join(root, "state", "seen.jsonl"), "w") as f:
    for r in seen:
        f.write(json.dumps(r) + "\n")
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fb = [
    {"timestamp": "2020-01-01T00:00:00Z", "id": "g1", "verdict": "down"},  # regraded below
    {"timestamp": now, "id": "g1", "verdict": "up"},
    {"timestamp": now, "id": "g2", "verdict": "up"},
    {"timestamp": now, "id": "b1", "verdict": "down"},
    {"timestamp": now, "id": "pruned1", "verdict": "down"},  # item pruned from seen.jsonl
]
with open(os.path.join(root, "state", "feedback.jsonl"), "w") as f:
    for r in fb:
        f.write(json.dumps(r) + "\n")
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
n, ups, downs = m.calibration_stats()
print("N30", n)
print("UPS", ups)
print("DOWNS", downs)
card = m.calibration_card()
print("PRECISION_LINE", "50% precision" in card and "(2 up of 4 graded)" in card)
print("COVERAGE_LINE", "80% coverage" in card)
print("CHART_SVG", card.count("<svg"))
print("ALPHA_RATE", "100% (2/2)" in card)
print("BETA_RATE", "0% (0/1)" in card)
open(os.path.join(root, "state", "feedback.jsonl"), "w").close()
print("EMPTY_CARD", repr(m.calibration_card()))
PY
  out="$(python3 "$py" "$repo/bin/portal.py")"
  assert_contains "30d denominator includes a graded-but-pruned item" "$out" "N30 5"
  assert_contains "a regrade counts its newest verdict (up)" "$out" "UPS 2"
  assert_contains "a pruned item's grade still counts (by grade timestamp)" "$out" "DOWNS 2"
  assert_contains "precision is over graded items only (2/4 = 50%)" "$out" "PRECISION_LINE True"
  assert_contains "coverage keeps the headline honest (4/5 graded)" "$out" "COVERAGE_LINE True"
  assert_contains "renders the weekly precision SVG" "$out" "CHART_SVG 1"
  assert_contains "per-source hit rate: alpha.com 100%" "$out" "ALPHA_RATE True"
  assert_contains "per-source hit rate: beta.com 0%" "$out" "BETA_RATE True"
  assert_contains "card is omitted until the first grade exists" "$out" "EMPTY_CARD ''"
}
test_portal_calibration

echo "== portal.py: feed health card flags failing and stale feeds =="
test_portal_feed_health() {
  local repo="$TMP/pfh" out py="$TMP/pfh.py"
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  cat > "$py" <<'PY'
import importlib.util, json, os, sys
from datetime import datetime, timedelta, timezone
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("NO_FILE", repr(m.feed_health_card()))
now = datetime.now(timezone.utc)
fresh = now.strftime("%Y-%m-%dT%H:%M:%SZ")
old = (now - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
health = {
    "https://ok.example/feed":    {"last_ok": fresh, "consecutive_failures": 0, "last_entry": fresh},
    "https://quiet.example/feed": {"last_ok": fresh, "consecutive_failures": 0, "last_entry": old},
    "https://dead.example/feed":  {"last_ok": "", "consecutive_failures": 4,
                                   "last_entry": "", "last_error": fresh, "error": "boom"},
    "https://junk.example/feed":  "not-a-dict",
}
with open(m.FEEDHEALTH, "w") as f:
    json.dump(health, f)
rows = m.feed_health_rows()
print("ORDER", "|".join(r["feed"].split("//")[1].split(".")[0] for r in rows))
card = m.feed_health_card()
print("FAILING", "failing (4 runs)" in card)
print("STALE", "stale (no new entries since" in card)
print("SUMMARY", "2 of 3 feeds need attention" in card)
PY
  out="$(python3 "$py" "$repo/bin/portal.py")"
  assert_contains "card omitted with no health file" "$out" "NO_FILE ''"
  assert_contains "problems sort first (failing, stale, ok)" "$out" "ORDER dead|quiet|ok"
  assert_contains "a failing feed is flagged with its streak" "$out" "FAILING True"
  assert_contains "a 200-but-silent feed is flagged stale" "$out" "STALE True"
  assert_contains "the summary counts feeds needing attention" "$out" "SUMMARY True"
}
test_portal_feed_health

echo "== portal.py: entity dossiers join observations + tagged/legacy items =="
test_portal_entities() {
  local repo="$TMP/pent" out py="$TMP/pent.py" port=8795 page
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  {
    printf '{"timestamp":"2026-05-01T07:00:00Z","entity":"Tudor BB58","metric":"secondary_price_usd","value":3650,"unit":"USD","source":"u"}\n'
    printf '{"timestamp":"2026-06-01T07:00:00Z","entity":"Tudor BB58","metric":"secondary_price_usd","value":3200,"unit":"USD","source":"u"}\n'
    printf '{"timestamp":"2026-06-06T07:00:00Z","entity":"Tudor BB58","metric":"event","event_type":"leak","value":"new GMT teased","source":"u"}\n'
    printf '{"timestamp":"2026-06-02T07:00:00Z","entity":"Pelagos 39","metric":"new_listings","value":4,"source":"u"}\n'
    printf '{"timestamp":"2026-06-02T07:00:00Z","entity":"AI","metric":"mention_count","value":5,"source":"u"}\n'
  } > "$repo/state/observations.jsonl"
  {
    # Tagged with the entity (the new `entities` field)...
    printf '{"id":"t1","date":"2026-06-06","signal":"threat","title":"Price cut announced","entities":["Tudor BB58"],"so_what":"undercuts","url":"https://a","source":"alpha.com"}\n'
    # ...a pre-tagging record that only NAMES it (case-insensitive fallback)...
    printf '{"id":"t2","date":"2026-06-01","signal":"opportunity","title":"TUDOR bb58 supply gap","url":"https://b","source":"beta.com"}\n'
    # ...an unrelated item and a dropped-but-tagged item: both excluded.
    printf '{"id":"x1","date":"2026-06-06","signal":"shift","title":"Other news","url":"https://c","source":"c.com"}\n'
    printf '{"id":"x2","date":"2026-06-06","signal":"dropped","title":"noise","entities":["Tudor BB58"],"score":0.2}\n'
    # Short-entity ("AI") fallback: whole-token match only -- "Prepaid" must not hit.
    printf '{"id":"a1","date":"2026-06-06","signal":"shift","title":"AI regulation looms","url":"https://d","source":"d.com"}\n'
    printf '{"id":"a2","date":"2026-06-06","signal":"shift","title":"Prepaid plans rejigged","url":"https://e","source":"e.com"}\n'
  } > "$repo/state/seen.jsonl"
  cat > "$py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ents = {r["name"]: r for r in m.all_entities()}
print("NAMES", "|".join(sorted(ents)))
print("OBS", ents["Tudor BB58"]["observations"])
print("ITEMS", ents["Tudor BB58"]["items"])         # tagged + legacy-named, like the dossier
print("ITEMS_AI", ents["AI"]["items"])              # whole-token: a1 only, not "Prepaid"
print("LAST", ents["Tudor BB58"]["last"])
ids = [i["id"] for i in m.entity_items("Tudor BB58")]
print("MATCHED", "|".join(sorted(ids)))             # t1 (tagged) + t2 (named), no x1/x2
print("EVENTS", len(m.entity_events("Tudor BB58")))
print("MATCHED_AI", "|".join(sorted(i["id"] for i in m.entity_items("AI"))))
PY
  out="$(python3 "$py" "$repo/bin/portal.py")"
  assert_contains "entities come from observations AND item tags" "$out" "NAMES AI|Pelagos 39|Tudor BB58"
  assert_contains "observation count" "$out" "OBS 3"
  assert_contains "index item count matches the dossier (tagged + legacy-named)" "$out" "ITEMS 2"
  assert_contains "index legacy match is whole-token too" "$out" "ITEMS_AI 1"
  assert_contains "last activity is the newest of obs/items" "$out" "LAST 2026-06-06"
  assert_contains "dossier matches tagged + legacy named items only" "$out" "MATCHED t1|t2"
  assert_contains "event timeline is entity-scoped" "$out" "EVENTS 1"
  assert_contains "a short entity matches whole tokens only (no 'Prepaid' for 'AI')" "$out" "MATCHED_AI a1"

  if ! command -v curl >/dev/null 2>&1; then pass "entity pages (skipped: no curl)"; return; fi
  ( cd "$repo" && exec python3 bin/portal.py "$port" >/dev/null 2>&1 ) &
  local srv=$!
  page="$(curl -s --retry 8 --retry-delay 1 --retry-connrefused "http://127.0.0.1:$port/entities" || true)"
  assert_contains "entities index lists the entity" "$page" "Tudor BB58"
  assert_contains "entities index links the dossier" "$page" '/entity?e=Tudor%20BB58'
  page="$(curl -s "http://127.0.0.1:$port/entity?e=Tudor%20BB58" || true)"
  assert_contains "dossier shows the metric series" "$page" "secondary_price_usd"
  assert_contains "dossier shows the event timeline" "$page" "new GMT teased"
  assert_contains "dossier lists a tagged surfaced item" "$page" "Price cut announced"
  assert_contains "dossier lists a legacy item that names the entity" "$page" "supply gap"
  page="$(curl -s "http://127.0.0.1:$port/entity?e=Nope" || true)"
  assert_contains "an unknown entity 404s gracefully" "$page" "Entity not found"
  page="$(curl -s "http://127.0.0.1:$port/" || true)"
  assert_contains "overview links a tracked entity to its dossier" "$page" '/entity?e=Tudor%20BB58'
  kill "$srv" 2>/dev/null || true
}
test_portal_entities

echo "== monitor.sh: an absolute state_file is named to Claude verbatim (no .// prefix) =="
test_state_file_absolute() {
  local repo="$TMP/absrepo" out abs="$TMP/abs-seen.jsonl" args="$TMP/abs_args"
  make_fake_repo "$repo"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  monitor: sonnet
monitoring:
  run_timeout_seconds: 0
  state_max_lines: 5
  state_file: $abs
tracking:
  observations_max_lines: 5
governance:
  profile_refresh_days: 30
output:
  email_to: ""
YAML
  # A stub claude that records the prompt it was handed, so we can inspect the path ref.
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  assert_contains "prompt names the absolute path verbatim" "$(cat "$args" 2>/dev/null)" "Your dedup/state file is $abs."
  case "$(cat "$args" 2>/dev/null)" in
    *".//"*) fail "no doubled .// prefix on an absolute state_file" ;;
    *) pass "no doubled .// prefix on an absolute state_file" ;;
  esac
  if [ -f "$abs" ]; then pass "absolute state_file is created"; else fail "absolute state_file is created"; fi
}
test_state_file_absolute

echo "== portal.py: review honors monitoring.state_file =="
test_feedback_state_file() {
  local repo="$TMP/fbstate" out
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  printf 'monitoring:\n  state_file: ./state/custom-seen.jsonl   # relocated dedup file\n' \
    > "$repo/monitor-config.yaml"
  printf '{"id":"c1","title":"Custom-path item","signal":"opportunity","score":0.8,"url":"https://z"}\n' \
    > "$repo/state/custom-seen.jsonl"
  # Import the server module (no HTTP needed) so SEEN resolves against the repo's config.
  out="$(python3 - "$repo/bin/portal.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fb", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("SEEN_BASENAME", os.path.basename(m.SEEN))
print("TITLES", "|".join(i.get("title", "") for i in m.recent_items()))
PY
)"
  assert_contains "resolves SEEN to the configured state_file" "$out" "SEEN_BASENAME custom-seen.jsonl"
  assert_contains "review UI reads items from the configured state_file" "$out" "Custom-path item"
}
test_feedback_state_file

echo "== dedupe-feedback.py: latest verdict per id wins BY TIMESTAMP (used by bootstrap) =="
test_feedback_dedupe() {
  local fb="$TMP/fb.jsonl" out
  # The latest grade ('down', 2026-06-02) is placed BEFORE the older one on purpose, so
  # this fails if dedup ever falls back to "last line in the file wins" (append order).
  printf '%s\n' \
    '{"timestamp":"2026-06-02T00:00:00Z","id":"abc","verdict":"down"}' \
    'MALFORMED {oops' \
    'null' \
    '{"timestamp":null,"id":"abc","verdict":"up"}' \
    '{"timestamp":"2026-06-01T00:00:00Z","id":"xyz","verdict":"up"}' > "$fb"
  local rc
  out="$(python3 "$ROOT/bin/dedupe-feedback.py" "$fb")"; rc=$?
  assert_eq "exits 0 even with a non-string (null) timestamp" "0" "$rc"
  assert_eq "regraded + valid ids collapse to one row each (bad/null lines skipped)" "2" "$(printf '%s\n' "$out" | grep -c .)"
  assert_contains "the regraded id keeps its newest-timestamp verdict" "$out" '"id": "abc", "verdict": "down"'
  assert_eq "the stale up verdict for abc is dropped (only xyz is up)" "1" "$(printf '%s\n' "$out" | grep -c '"verdict": "up"')"
}
test_feedback_dedupe

echo "== dedupe-feedback.py: --since/--max scope the live-calibration window =="
test_feedback_window() {
  local fb="$TMP/fbwin.jsonl" out
  printf '%s\n' \
    '{"timestamp":"2026-05-01T00:00:00Z","id":"old","verdict":"down"}' \
    '{"timestamp":"2026-06-02T00:00:00Z","id":"a","verdict":"up"}' \
    '{"timestamp":"2026-06-03T00:00:00Z","id":"b","verdict":"down"}' \
    '{"timestamp":"2026-06-04T00:00:00Z","id":"c","verdict":"up"}' > "$fb"
  out="$(python3 "$ROOT/bin/dedupe-feedback.py" "$fb" --since 2026-06-01)"
  assert_eq "--since keeps only post-cutoff grades" "3" "$(printf '%s\n' "$out" | grep -c .)"
  case "$out" in
    *'"old"'*) fail "--since excludes the pre-cutoff grade" ;;
    *) pass "--since excludes the pre-cutoff grade" ;;
  esac
  # Grades from the cutoff DAY itself are kept (ISO ts > bare date, lexically).
  assert_contains "a grade on the cutoff day survives --since" \
    "$(python3 "$ROOT/bin/dedupe-feedback.py" "$fb" --since 2026-06-02)" '"a"'
  out="$(python3 "$ROOT/bin/dedupe-feedback.py" "$fb" --since 2026-06-01 --max 2)"
  assert_eq "--max keeps only the newest N" "2" "$(printf '%s\n' "$out" | grep -c .)"
  case "$out" in
    *'"a"'*) fail "--max drops the oldest in-window grade" ;;
    *) pass "--max drops the oldest in-window grade" ;;
  esac
  # Chronological output: the older in-window grade (b) precedes the newest (c).
  assert_contains "--max output is chronological (oldest first)" \
    "$(printf '%s' "$out" | head -1)" '"id": "b"'
}
test_feedback_window

echo "== monitor.sh: injects post-bootstrap grades as live calibration =="
test_live_calibration() {
  local repo="$TMP/livecal" out args="$TMP/livecal_args"
  make_fake_repo "$repo" "2026-01-01"          # profile vintage = the grade cutoff
  # A stub claude that records the prompt it was handed.
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  printf '%s\n' \
    '{"timestamp":"2025-12-01T00:00:00Z","id":"pre","verdict":"down","title":"absorbed-by-bootstrap"}' \
    '{"timestamp":"2026-02-01T00:00:00Z","id":"post","verdict":"down","title":"fresh-thumbs-down"}' \
    '{"timestamp":"2026-02-02T00:00:00Z","id":"miss1","verdict":"missed","url":"https://ex.com/fresh-missed-signal"}' \
    > "$repo/state/feedback.jsonl"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  assert_contains "announces the live-calibration injection" "$out" "live calibration: applying 2 recent grade"
  assert_contains "prompt carries the grades block" "$(cat "$args" 2>/dev/null)" "RECENT OPERATOR GRADES"
  assert_contains "the post-bootstrap grade is injected" "$(cat "$args" 2>/dev/null)" "fresh-thumbs-down"
  assert_contains "a missed-signal report is injected too" "$(cat "$args" 2>/dev/null)" "fresh-missed-signal"
  assert_contains "the block explains the missed verdict" "$(cat "$args" 2>/dev/null)" "missed = a relevant item"
  case "$(cat "$args" 2>/dev/null)" in
    *absorbed-by-bootstrap*) fail "a pre-bootstrap grade is excluded (already in the rubric)" ;;
    *) pass "a pre-bootstrap grade is excluded (already in the rubric)" ;;
  esac

  # relevance.recent_grades: 0 switches the injection off entirely.
  local args2="$TMP/livecal_args2"
  printf 'relevance:\n  recent_grades: 0\n' >> "$repo/monitor-config.yaml"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args2" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  case "$(cat "$args2" 2>/dev/null)" in
    *"RECENT OPERATOR GRADES"*) fail "recent_grades: 0 disables the injection" ;;
    *) pass "recent_grades: 0 disables the injection" ;;
  esac
}
test_live_calibration

echo "== portal.py: latest_verdicts picks the newest timestamp, not file order =="
test_feedback_latest_verdict() {
  local repo="$TMP/fbverdict" out
  mkdir -p "$repo/bin" "$repo/state"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  # Newest grade ('down') appears first; append-order would wrongly return 'up'. The
  # null-timestamp row must not crash the comparison (it sorts earliest).
  printf '%s\n' \
    '{"timestamp":"2026-06-02T00:00:00Z","id":"abc","verdict":"down"}' \
    '{"timestamp":null,"id":"abc","verdict":"up"}' \
    '{"timestamp":"2026-06-01T00:00:00Z","id":"abc","verdict":"up"}' > "$repo/state/feedback.jsonl"
  out="$(python3 - "$repo/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fb", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("VERDICT", m.latest_verdicts().get("abc"))
PY
)"
  assert_contains "returns the newest-timestamp verdict" "$out" "VERDICT down"
}
test_feedback_latest_verdict

echo "== monitor.sh: email Subject names the monitored subject =="
test_email_subject() {
  local repo="$TMP/subjrepo" out rc msg="$TMP/subj.eml"
  make_fake_repo "$repo" "$(date +%F)" 0 "me@example.com"   # email enabled; subject.name set
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
      "$(grep -i '^Subject:' "$msg")" "[Vantage Point: Test Market & Co]"
  else
    fail "an email was sent"
  fi
}
test_email_subject

# A capturing webhook server: appends each POST body to the file in $2 and responds
# 200. serve_forever (killed by the test) so a port-open probe connection can't
# consume the one real request.
# A static file server for the feed fixtures. Replaces `python3 -m http.server`, which
# goes through the same reverse-DNS server_bind() described in _Quiet below.
write_static_httpd() {  # <script-path>
  cat > "$1" <<'PY'
import sys, socketserver
from http.server import SimpleHTTPRequestHandler, HTTPServer
class _Quiet(HTTPServer):
    # See the capture server: skip the socket.getfqdn() call in server_bind, so a stalled
    # resolver cannot leave us bound-but-not-listening.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]
class H(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=sys.argv[1], **k)
    def log_message(self, *a):
        pass
_Quiet(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
}

write_capture_httpd() {  # <script-path>
  cat > "$1" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
import socketserver
class _Quiet(HTTPServer):
    # http.server's server_bind() calls socket.getfqdn() - a REVERSE DNS lookup - between
    # bind() and listen(). Where that resolver stalls, the socket sits BOUND BUT NOT
    # LISTENING, which is precisely what the macOS runner reported: server process alive,
    # no output, curl timing out, and netstat showing 127.0.0.1.<port> in state CLOSED
    # rather than LISTEN. Nothing here needs a hostname, so skip the lookup.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        with open(sys.argv[2], "ab") as f:
            f.write(self.rfile.read(n) + b"\n")
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *args):
        pass
_Quiet(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
}

# wait_port <port> [server-log] [server-pid]
# Wait for something to listen on 127.0.0.1:<port>, then report.
#
# Polls from ONE python process instead of spawning a fresh one per iteration. The old
# form spawned 25, which on the macOS runner is the difference between a nominal 5s budget
# and a ~12s wall clock, and piles interpreter startups onto the machine that is already
# the bottleneck.
#
# Built on what the previous commit's diagnostics reported from the macOS leg, identically
# for all 7 failures: the server pid was still ALIVE, its log was EMPTY (no traceback),
# lsof showed nothing bound on the port, and the last connect status was 35 - EWOULDBLOCK,
# i.e. the probe TIMED OUT rather than being refused (61, which is what nothing-listening
# gives locally). A live, silent, not-yet-bound server means the budget ran out before the
# server finished starting - so stop spending that budget on interpreter startups, and
# allow more of it.
#
# It still explains itself on failure, and now also when it succeeds LATE, so a runner
# drifting back toward the limit is visible before it goes red again.
WAIT_PORT_BUDGET="${WAIT_PORT_BUDGET:-30}"
wait_port() {
  local out rc secs
  out="$(python3 - "$1" "$WAIT_PORT_BUDGET" <<'PY'
import errno, os, socket, sys, time
port, budget = int(sys.argv[1]), float(sys.argv[2])
start = time.monotonic()
last = "none"
while True:
    left = budget - (time.monotonic() - start)
    if left <= 0:
        break
    s = socket.socket()
    # Generous PER-ATTEMPT timeout, not a short one. errno 35 (EWOULDBLOCK) means the
    # connect was still in progress when we gave up; nothing-listening answers 61
    # (ECONNREFUSED) immediately instead. The macOS runner returned 35 on every attempt
    # for 30s under a 0.5s per-attempt limit while curl - which imposes no such limit -
    # fetched pages from servers started the same way. So a slow-completing loopback
    # connect was being read as "not up yet" on every single poll.
    s.settimeout(min(5.0, left))
    rc = s.connect_ex(("127.0.0.1", port))
    s.close()
    if rc == 0:
        print("ok %.2f" % (time.monotonic() - start))
        sys.exit(0)
    last = rc
    time.sleep(0.1)
# Render the status symbolically: the numbers differ per platform (ECONNREFUSED is 61 on
# macOS, 111 on Linux), so a fixed legend would misdiagnose the very failure this prints.
name = errno.errorcode.get(last, "?") if isinstance(last, int) else "?"
desc = os.strerror(last) if isinstance(last, int) else ""
print("timeout %.2f last=%s (%s: %s)" % (time.monotonic() - start, last, name, desc))
sys.exit(1)
PY
)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    secs="${out#ok }"
    # Quiet under 2s; louder above, because silence is how this drifted to red unnoticed.
    case "$secs" in
      0.*|1.*) : ;;
      *) printf '    wait_port: 127.0.0.1:%s took %ss to accept (budget %ss)\n' \
           "$1" "$secs" "$WAIT_PORT_BUDGET" >&2 ;;
    esac
    return 0
  fi
  {
    printf '    wait_port: gave up on 127.0.0.1:%s (%s)\n' "$1" "$out"
    printf '    wait_port: ECONNREFUSED=nothing listening; ETIMEDOUT/EWOULDBLOCK=bound but not accepting\n'
    if [ -n "${3:-}" ]; then
      if kill -0 "$3" 2>/dev/null; then
        printf '    wait_port: server pid %s is still alive (started, but never bound)\n' "$3"
      else
        printf '    wait_port: server pid %s is GONE (it exited instead of serving)\n' "$3"
      fi
    fi
    if [ -n "${2:-}" ] && [ -s "$2" ]; then
      printf '    wait_port: server output follows --\n'
      sed 's/^/      /' "$2"
    elif [ -n "${2:-}" ]; then
      printf '    wait_port: server produced no output (log %s is empty)\n' "$2"
    fi
    if command -v lsof >/dev/null 2>&1; then
      printf '    wait_port: lsof for port %s --\n' "$1"
      lsof -nP -iTCP:"$1" 2>/dev/null | sed 's/^/      /' || true
    fi
    # lsof can come back empty without privileges, so ask the kernel a second way.
    if command -v netstat >/dev/null 2>&1; then
      printf '    wait_port: netstat rows for port %s --\n' "$1"
      netstat -an 2>/dev/null | grep -E "[.:]$1[[:space:]]" | sed 's/^/      /' || true
    fi
    # THE decisive one. The portal tests reach their server on this same runner, in this
    # same port range, bound the same way (portal.py binds 127.0.0.1 too) - they just wait
    # with curl instead of a socket probe, and they pass. So this asks the only question
    # left: is the SERVER unreachable, or is this PROBE broken? If curl gets bytes where
    # connect_ex timed out for 30s, the probe is the bug and the servers were never at
    # fault.
    if command -v curl >/dev/null 2>&1; then
      printf '    wait_port: curl cross-check --\n'
      curl -s -m 5 -o /dev/null -w '      curl exit ok, http=%{http_code}, connect=%{time_connect}s\n' \
        "http://127.0.0.1:$1/" 2>&1 || printf '      curl also failed (exit %s)\n' "$?"
    fi
  } >&2
  return 1
}

echo "== webhook.py: posts one polyglot JSON payload (Slack text / Discord content) =="
test_webhook_py() {
  local srv="$TMP/caphttpd.py" body="$TMP/wh_body.json" probe="$TMP/wh_probe.py" out rc port=8793
  write_capture_httpd "$srv"
  local slog="$TMP/srv.cap.$port.log"
  python3 "$srv" "$port" "$body" > "$slog" 2>&1 &
  local pid=$!
  if ! wait_port "$port" "$slog" "$pid"; then fail "capture server came up"; kill "$pid" 2>/dev/null; return; fi
  printf '# Daily\n\n- **Item** matters\n' | \
    python3 "$ROOT/bin/webhook.py" "http://127.0.0.1:$port/hook" "[VP: Test] daily 2026-06-09" daily 2026-06-09
  rc=$?
  kill "$pid" 2>/dev/null || true
  assert_eq "exits 0 on a 2xx response" "0" "$rc"
  cat > "$probe" <<'PY'
import json, sys
payload = json.loads(open(sys.argv[1]).read().strip())
print("HEADING_LEADS_TEXT", payload["text"].startswith("[VP: Test] daily 2026-06-09"))
print("MD_INTACT", payload["report_markdown"].startswith("# Daily"))
print("MODE", payload["mode"], "DATE", payload["date"])
print("CONTENT_EQ_TEXT", payload["content"] == payload["text"])  # short report: no truncation
PY
  out="$(python3 "$probe" "$body")"
  assert_contains "Slack text leads with the heading" "$out" "HEADING_LEADS_TEXT True"
  assert_contains "report_markdown carries the untouched body" "$out" "MD_INTACT True"
  assert_contains "metadata keys are present" "$out" "MODE daily DATE 2026-06-09"
  assert_contains "short reports are not truncated" "$out" "CONTENT_EQ_TEXT True"

  # Discord-limit truncation, computed without a server.
  cat > "$probe" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wh", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p = m.build_payload("h", "daily", "2026-06-09", "x" * 5000)
print("CONTENT_FITS_DISCORD", len(p["content"]) <= 2000)
print("CONTENT_MARKED", p["content"].endswith("... (truncated)"))
print("TEXT_FULL", len(p["text"]) > 5000 - 1)
PY
  out="$(python3 "$probe" "$ROOT/bin/webhook.py")"
  assert_contains "content fits Discord's 2000-char limit" "$out" "CONTENT_FITS_DISCORD True"
  assert_contains "truncation is marked" "$out" "CONTENT_MARKED True"
  assert_contains "text/report_markdown stay untruncated" "$out" "TEXT_FULL True"

  # Failure modes: unreachable URL -> 1; non-http scheme -> 2. Both print to stderr.
  printf 'r\n' | python3 "$ROOT/bin/webhook.py" "http://127.0.0.1:1/hook" h daily 2026-06-09 2>/dev/null
  assert_eq "an unreachable webhook exits 1" "1" "$?"
  printf 'r\n' | python3 "$ROOT/bin/webhook.py" "file:///etc/passwd" h daily 2026-06-09 2>/dev/null
  assert_eq "a non-http(s) scheme is rejected with exit 2" "2" "$?"
}
test_webhook_py

echo "== monitor.sh: posts the report to output.webhook_url; a failed post can't fail the run =="
test_monitor_webhook() {
  local repo="$TMP/whrepo" out rc srv="$TMP/caphttpd2.py" body="$TMP/wh_mon.json" port=8794
  make_fake_repo "$repo"
  # cfg_get re-enters a repeated top-level block, so appending a second output:
  # block is a valid way to set webhook_url on the fixture config.
  printf 'output:\n  webhook_url: "http://127.0.0.1:%s/hook"\n' "$port" >> "$repo/monitor-config.yaml"
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
printf 'webhook report body\n' > "kb/.$(date +%F).daily.partial.md"
printf '{"num_turns":1}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  write_capture_httpd "$srv"
  local slog="$TMP/srv.cap.$port.log"
  python3 "$srv" "$port" "$body" > "$slog" 2>&1 &
  local pid=$!
  if ! wait_port "$port" "$slog" "$pid"; then fail "capture server came up"; kill "$pid" 2>/dev/null; return; fi
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" bash "$repo/bin/monitor.sh" daily 2>&1 )"; rc=$?
  kill "$pid" 2>/dev/null || true
  assert_eq "run exits 0" "0" "$rc"
  assert_contains "announces the webhook post" "$out" "posted report to webhook"
  assert_contains "the posted payload carries the report" "$(cat "$body" 2>/dev/null)" "webhook report body"
  assert_contains "the heading names the monitored subject" "$(cat "$body" 2>/dev/null)" "[Vantage Point: Test Market & Co] daily"

  # Unreachable webhook: the run must still succeed and keep the report.
  local repo2="$TMP/whrepo2"
  make_fake_repo "$repo2"
  printf 'output:\n  webhook_url: "http://127.0.0.1:1/hook"\n' >> "$repo2/monitor-config.yaml"
  cp "$repo/stub/claude" "$repo2/stub/claude"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo2/stub:$PATH" bash "$repo2/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "a failed webhook post still exits 0" "0" "$rc"
  assert_contains "warns that the webhook post failed" "$out" "webhook post failed"
  if [ -s "$repo2/kb/$(date +%F).daily.md" ]; then pass "report survives a failed webhook post"; else fail "report survives a failed webhook post"; fi
}
test_monitor_webhook

# Write RSS/Atom/broken feed fixtures (dates relative to now) into the dir in $1.
write_feed_fixtures() {  # <dir>
  python3 - "$1" <<'PY'
import os, sys
from datetime import datetime, timedelta, timezone
from email.utils import format_datetime
d = sys.argv[1]
now = datetime.now(timezone.utc)
fresh, old = format_datetime(now - timedelta(hours=2)), format_datetime(now - timedelta(hours=200))
# The NEWEST entry (30 min ago) carries a -10:00 offset: if fetch.py formatted its
# wall-clock time with a Z suffix it would sort ~10h old instead of first.
offset = format_datetime((now - timedelta(minutes=30)).astimezone(timezone(timedelta(hours=-10))))
rel = format_datetime(now - timedelta(hours=3))
rss = ('<?xml version="1.0"?>\n<rss version="2.0"><channel><title>R</title>\n'
       '<item><title>Fresh RSS story</title><link>https://ex.com/fresh</link>'
       '<pubDate>%s</pubDate></item>\n'
       '<item><title>Offset story</title><link>https://ex.com/offset</link>'
       '<pubDate>%s</pubDate></item>\n'
       '<item><title>Relative link story</title><link>/rel/post</link>'
       '<pubDate>%s</pubDate></item>\n'
       '<item><title>Guid only story</title><guid>https://ex.com/guid-only</guid>'
       '<pubDate>%s</pubDate></item>\n'
       '<item><title>Opaque guid story</title><guid isPermaLink="false">opaque-1</guid>'
       '<pubDate>%s</pubDate></item>\n'
       '<item><title>Stale RSS story</title><link>https://ex.com/stale</link>'
       '<pubDate>%s</pubDate></item>\n'
       '<item><title>Already seen story</title><link>https://ex.com/seen</link>'
       '<pubDate>%s</pubDate></item>\n'
       '<item><title>Undated story</title><link>https://ex.com/undated</link></item>\n'
       '</channel></rss>\n') % (fresh, offset, rel, rel, rel, old, fresh)
atom = ('<?xml version="1.0"?>\n<feed xmlns="http://www.w3.org/2005/Atom"><title>A</title>\n'
        '<entry><title>Fresh Atom entry</title>'
        '<link rel="alternate" href="https://ax.com/entry"/>'
        '<updated>%s</updated></entry>\n</feed>\n'
        % (now - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"))
with open(os.path.join(d, "rss.xml"), "w") as f:
    f.write(rss)
with open(os.path.join(d, "atom.xml"), "w") as f:
    f.write(atom)
with open(os.path.join(d, "bad.xml"), "w") as f:
    f.write("not xml at all {")
PY
}

echo "== fetch.py: deterministic feed sweep (window, dedup, cap, broken feeds) =="
test_fetch_py() {
  local dir="$TMP/feeds" out err rc port=8796
  mkdir -p "$dir"
  write_feed_fixtures "$dir"
  local slog="$TMP/srv.feed.$port.log"
  write_static_httpd "$TMP/statichttpd.py"
  python3 "$TMP/statichttpd.py" "$dir" "$port" > "$slog" 2>&1 &
  local srv=$!
  if ! wait_port "$port" "$slog" "$srv"; then fail "feed server came up"; kill "$srv" 2>/dev/null; return; fi
  cat > "$TMP/feeds-profile.yaml" <<YAML
subject:
  derived:
    feeds:
      - http://127.0.0.1:$port/rss.xml
      - http://127.0.0.1:$port/atom.xml
      - http://127.0.0.1:$port/bad.xml
      - http://127.0.0.1:1/dead.xml
YAML
  printf '{"url":"https://ex.com/seen","id":"s1"}\n' > "$TMP/feeds-seen.jsonl"
  err="$TMP/fetch.err"
  python3 "$ROOT/bin/fetch.py" --hours 30 --max 10 \
    --seen "$TMP/feeds-seen.jsonl" --out "$TMP/cand.jsonl" \
    "$TMP/feeds-profile.yaml" 2> "$err"; rc=$?
  assert_eq "exits 0 despite broken + unreachable feeds" "0" "$rc"
  out="$(cat "$TMP/cand.jsonl" 2>/dev/null)"
  assert_contains "keeps a fresh RSS item" "$out" "Fresh RSS story"
  assert_contains "keeps a fresh Atom item" "$out" "Fresh Atom entry"
  assert_contains "keeps an undated item (can't be proven stale)" "$out" "Undated story"
  case "$out" in *"Stale RSS story"*) fail "drops an item older than the window" ;; *) pass "drops an item older than the window" ;; esac
  case "$out" in *"/seen"*) fail "drops an item already in the seen file" ;; *) pass "drops an item already in the seen file" ;; esac
  # The -10:00-offset entry is the newest item: only a UTC-normalized published
  # value sorts it first (wall-clock-with-Z would bury it ~10h down the list).
  assert_contains "newest candidate first despite a timezone offset" \
    "$(head -1 "$TMP/cand.jsonl")" "Offset story"
  assert_contains "a relative entry link is resolved against the feed URL" \
    "$out" "\"url\": \"http://127.0.0.1:$port/rel/post\""
  assert_contains "a permalink <guid> stands in for a missing <link>" "$out" "https://ex.com/guid-only"
  case "$out" in *"Opaque guid story"*) fail "a non-permalink guid item is skipped" ;; *) pass "a non-permalink guid item is skipped" ;; esac
  assert_contains "candidates carry the link host as source" "$out" '"source": "ex.com"'
  assert_contains "stats line counts candidates and feeds" "$(cat "$err")" "6 candidate(s) from 4 feed(s)"
  assert_contains "stats line counts failed feeds" "$(cat "$err")" "2 feed(s) failed"
  # An inline YAML list (`feeds: [url]`) must work too -- not silently parse as none.
  printf 'subject:\n  derived:\n    feeds: [http://127.0.0.1:%s/rss.xml]\n' "$port" > "$TMP/inline.yaml"
  python3 "$ROOT/bin/fetch.py" --hours 30 --out "$TMP/cand-inline.jsonl" "$TMP/inline.yaml" 2>/dev/null
  assert_contains "an inline feeds list is parsed" "$(cat "$TMP/cand-inline.jsonl" 2>/dev/null)" "Fresh RSS story"
  # --max caps to the newest N (again: only correct under UTC normalization).
  python3 "$ROOT/bin/fetch.py" --hours 30 --max 1 --out "$TMP/cand1.jsonl" \
    "$TMP/feeds-profile.yaml" 2>/dev/null
  assert_eq "--max 1 keeps one candidate" "1" "$(wc -l < "$TMP/cand1.jsonl" | tr -d ' ')"
  assert_contains "--max keeps the newest (offset-normalized) candidate" \
    "$(cat "$TMP/cand1.jsonl")" "Offset story"
  kill "$srv" 2>/dev/null || true
  # No feeds configured: exit 0, no output file, a clear note.
  printf 'subject:\n  derived:\n    feeds: []\n' > "$TMP/nofeeds.yaml"
  err="$( python3 "$ROOT/bin/fetch.py" --out "$TMP/none.jsonl" "$TMP/nofeeds.yaml" 2>&1 )"; rc=$?
  assert_eq "no feeds exits 0" "0" "$rc"
  assert_contains "notes the skip" "$err" "no feeds configured"
  if [ -f "$TMP/none.jsonl" ]; then fail "writes no candidates file without feeds"; else pass "writes no candidates file without feeds"; fi
}
test_fetch_py

echo "== fetch.py: follows a 308 redirect on every python on the box =="
# urllib only learned 308 in 3.11, and 3.9's redirect_request rejects the code
# outright -- so a 308 feed verified clean under bootstrap.sh's python and then
# failed every launchd monitor run under the system one. Guards bin/fetch.py's
# _RedirectHandler; deleting either half of it must turn this red.
test_fetch_308() {
  local dir="$TMP/feeds-308" rc port=8801 srv py real seen="" slog
  mkdir -p "$dir"
  write_feed_fixtures "$dir"
  # python3 -m http.server cannot emit a 308, so serve one from a tiny handler.
  cat > "$TMP/srv308.py" <<'PYSRV'
import os, socketserver, sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class _Quiet(HTTPServer):
    # Skip the socket.getfqdn() reverse lookup http.server does between bind() and
    # listen(); a stalled resolver otherwise leaves the socket bound but not listening.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


ROOT, PORT = sys.argv[1], int(sys.argv[2])


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redir.xml":
            self.send_response(308)
            self.send_header("Location", "/rss.xml")
            self.end_headers()
            return
        try:
            body = open(os.path.join(ROOT, os.path.basename(self.path)), "rb").read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/xml")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


_Quiet(("127.0.0.1", PORT), H).serve_forever()
PYSRV
  slog="$TMP/srv.308.$port.log"
  python3 "$TMP/srv308.py" "$dir" "$port" > "$slog" 2>&1 &
  srv=$!
  if ! wait_port "$port" "$slog" "$srv"; then fail "308 server came up"; kill "$srv" 2>/dev/null; return; fi
  printf 'subject:\n  derived:\n    feeds: [http://127.0.0.1:%s/redir.xml]\n' "$port" > "$TMP/f308.yaml"
  # The suite runs on PATH's python3 (often 3.11+, where 308 works unaided), but
  # launchd runs monitor.sh under /usr/bin/python3 -- 3.9 on macOS. Only running
  # both actually covers the version that broke.
  for py in python3 /usr/bin/python3; do
    real="$(command -v "$py" 2>/dev/null)" || continue
    [ -n "$real" ] || continue
    case " $seen " in *" $real "*) continue ;; esac
    seen="$seen $real"
    rm -f "$TMP/cand308.jsonl"
    "$real" "$ROOT/bin/fetch.py" --hours 30 --out "$TMP/cand308.jsonl" "$TMP/f308.yaml" 2>/dev/null; rc=$?
    assert_eq "308 feed exits 0 ($("$real" -V 2>&1))" "0" "$rc"
    assert_contains "308 redirect is followed to the feed ($("$real" -V 2>&1))" \
      "$(cat "$TMP/cand308.jsonl" 2>/dev/null)" "Fresh RSS story"
  done
  kill "$srv" 2>/dev/null || true
  wait "$srv" 2>/dev/null || true   # reap it quietly; bash otherwise prints "Terminated"
}
test_fetch_308

echo "== fetch.py: --health tracks per-feed sweep health across runs =="
test_fetch_health() {
  local dir="$TMP/feeds-h" err rc port=8799 fh="$TMP/feedhealth.json"
  mkdir -p "$dir"
  write_feed_fixtures "$dir"
  local slog="$TMP/srv.feed.$port.log"
  write_static_httpd "$TMP/statichttpd.py"
  python3 "$TMP/statichttpd.py" "$dir" "$port" > "$slog" 2>&1 &
  local srv=$!
  if ! wait_port "$port" "$slog" "$srv"; then fail "feed server came up"; kill "$srv" 2>/dev/null; return; fi
  cat > "$TMP/health-profile.yaml" <<YAML
subject:
  derived:
    feeds:
      - http://127.0.0.1:$port/rss.xml
      - http://127.0.0.1:1/dead.xml
YAML
  printf 'corrupt {' > "$fh"   # a corrupt health file must be survivable, not fatal
  err="$TMP/fetch-h.err"
  python3 "$ROOT/bin/fetch.py" --hours 30 --health "$fh" \
    --out "$TMP/cand-h.jsonl" "$TMP/health-profile.yaml" 2> "$err"; rc=$?
  assert_eq "exits 0 over a corrupt health file" "0" "$rc"
  local probe="$TMP/health-probe.py"
  cat > "$probe" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))
ok = h[sys.argv[2]]
dead = h[sys.argv[3]]
print("OK_FAILS", ok["consecutive_failures"])
print("OK_LASTOK", bool(ok["last_ok"]))
print("OK_ENTRY", bool(ok["last_entry"]))
print("DEAD_FAILS", dead["consecutive_failures"])
print("DEAD_ERROR", bool(dead.get("error")))
print("DEAD_LASTOK", repr(dead["last_ok"]))
PY
  local out
  out="$(python3 "$probe" "$fh" "http://127.0.0.1:$port/rss.xml" "http://127.0.0.1:1/dead.xml")"
  assert_contains "a healthy feed records zero consecutive failures" "$out" "OK_FAILS 0"
  assert_contains "a healthy feed records last_ok" "$out" "OK_LASTOK True"
  assert_contains "a healthy feed records its newest entry" "$out" "OK_ENTRY True"
  assert_contains "a dead feed counts one failure" "$out" "DEAD_FAILS 1"
  assert_contains "a dead feed records its error" "$out" "DEAD_ERROR True"
  assert_contains "a never-ok feed has an empty last_ok" "$out" "DEAD_LASTOK ''"
  # Two more failing runs -> the counter accumulates and the loud warning fires.
  python3 "$ROOT/bin/fetch.py" --hours 30 --health "$fh" \
    --out "$TMP/cand-h.jsonl" "$TMP/health-profile.yaml" 2>/dev/null
  python3 "$ROOT/bin/fetch.py" --hours 30 --health "$fh" \
    --out "$TMP/cand-h.jsonl" "$TMP/health-profile.yaml" 2> "$err"
  out="$(python3 "$probe" "$fh" "http://127.0.0.1:$port/rss.xml" "http://127.0.0.1:1/dead.xml")"
  assert_contains "consecutive failures accumulate across runs" "$out" "DEAD_FAILS 3"
  assert_contains "a repeatedly-failing feed warns loudly" "$(cat "$err")" "failed 3 runs in a row"
  kill "$srv" 2>/dev/null || true
  # A feed removed from the config is dropped from the health file.
  printf 'subject:\n  derived:\n    feeds:\n      - http://127.0.0.1:1/dead.xml\n' > "$TMP/health-profile.yaml"
  python3 "$ROOT/bin/fetch.py" --hours 30 --health "$fh" \
    --out "$TMP/cand-h.jsonl" "$TMP/health-profile.yaml" 2>/dev/null
  case "$(cat "$fh")" in
    *rss.xml*) fail "an unconfigured feed is pruned from the health file" ;;
    *) pass "an unconfigured feed is pruned from the health file" ;;
  esac
  # No feeds at all -> health resets to empty (nothing to report on).
  printf 'subject:\n  derived:\n    feeds: []\n' > "$TMP/health-profile.yaml"
  python3 "$ROOT/bin/fetch.py" --health "$fh" "$TMP/health-profile.yaml" 2>/dev/null
  assert_eq "no feeds -> an empty health map" "{}" "$(tr -d ' \n' < "$fh")"
}
test_fetch_health

echo "== monitor.sh: feeds the pre-fetched candidates to triage (and cleans up) =="
test_monitor_fetch() {
  local repo="$TMP/fetchrepo" dir="$TMP/feeds2" out args="$TMP/fetch_args" port=8797
  make_fake_repo "$repo"
  mkdir -p "$dir"
  write_feed_fixtures "$dir"
  cat > "$repo/profile.yaml" <<YAML
subject:
  derived:
    last_bootstrapped: $(date +%F)
    feeds:
      - http://127.0.0.1:$port/rss.xml
anchor:
  derived:
    last_bootstrapped: $(date +%F)
YAML
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  local slog="$TMP/srv.feed.$port.log"
  write_static_httpd "$TMP/statichttpd.py"
  python3 "$TMP/statichttpd.py" "$dir" "$port" > "$slog" 2>&1 &
  local srv=$!
  if ! wait_port "$port" "$slog" "$srv"; then fail "feed server came up"; kill "$srv" 2>/dev/null; return; fi
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  kill "$srv" 2>/dev/null || true
  assert_contains "announces the feed sweep" "$out" "feed sweep:"
  assert_contains "prompt names the candidates file" "$(cat "$args" 2>/dev/null)" "PRE-FETCHED CANDIDATES"
  assert_contains "prompt points at the right path" "$(cat "$args" 2>/dev/null)" "state/.candidates.daily.jsonl"
  if [ -f "$repo/state/.candidates.daily.jsonl" ]; then fail "candidates file cleaned up after the run"; else pass "candidates file cleaned up after the run"; fi
  if [ -s "$repo/state/feedhealth.json" ]; then pass "the sweep records feed health"; else fail "the sweep records feed health"; fi

  # No feeds in the profile -> no candidates note, run unchanged.
  local repo2="$TMP/fetchrepo2" args2="$TMP/fetch_args2"
  make_fake_repo "$repo2"
  cp "$repo/stub/claude" "$repo2/stub/claude"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args2" HOME="$TMP/fakehome" PATH="$repo2/stub:$PATH" \
          bash "$repo2/bin/monitor.sh" daily 2>&1 )"
  case "$(cat "$args2" 2>/dev/null)" in
    *"PRE-FETCHED CANDIDATES"*) fail "no candidates note without feeds" ;;
    *) pass "no candidates note without feeds" ;;
  esac

  # An unreachable feed must not fail the run.
  local repo3="$TMP/fetchrepo3"
  make_fake_repo "$repo3"
  cat > "$repo3/profile.yaml" <<YAML
subject:
  derived:
    last_bootstrapped: $(date +%F)
    feeds:
      - http://127.0.0.1:1/dead.xml
anchor:
  derived:
    last_bootstrapped: $(date +%F)
YAML
  local rc
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo3/stub:$PATH" bash "$repo3/bin/monitor.sh" daily 2>&1 )"; rc=$?
  assert_eq "a dead feed can't fail the run" "0" "$rc"
}
test_monitor_fetch

echo "== monitor.sh: a gap since the last run widens the sweep window (catch-up) =="
test_monitor_catchup() {
  local repo="$TMP/catchuprepo" out args="$TMP/catchup_args"
  make_fake_repo "$repo"
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  # The last logged run is ~100h ago (99.5h, so the rounded-up gap is exactly 100):
  # a 30h daily lookback would lose ~70h of signal.
  printf '{"timestamp":"%s","mode":"daily","pass":"triage","cost_usd":0.01}\n' \
    "$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=99,minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
    > "$repo/state/runs.log"
  # A re-bootstrap logged its passes to the SAME runs.log just now. These must NOT be
  # mistaken for a sweep: the catch-up baseline is the last triage row (~100h ago), so
  # the window must still widen despite this recent bootstrap row being the newest line.
  printf '{"timestamp":"%s","mode":"bootstrap","pass":"bootstrap","cost_usd":0.5}\n' \
    "$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
    >> "$repo/state/runs.log"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  assert_contains "announces the widened window" "$out" "catch-up: last run was"
  assert_contains "the prompt carries the catch-up instruction" "$(cat "$args" 2>/dev/null)" "CATCH-UP WINDOW"
  assert_contains "a recent bootstrap row doesn't poison the sweep baseline" "$(cat "$args" 2>/dev/null)" "widened to the last 100 hours"

  # The widening is capped at catchup_max_hours EXTRA hours on top of the normal
  # window (30h daily + 48h cap = 78h) -- the cap bounds the widening, not the window.
  printf 'monitoring:\n  catchup_max_hours: 48\n' > "$repo/monitor-config.yaml.cap"
  cat "$repo/monitor-config.yaml" >> "$repo/monitor-config.yaml.cap"
  mv "$repo/monitor-config.yaml.cap" "$repo/monitor-config.yaml"
  printf '{"timestamp":"2020-01-01T00:00:00Z","mode":"daily","pass":"triage"}\n' > "$repo/state/runs.log"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  assert_contains "a huge gap is capped at window + catchup_max_hours" "$(cat "$args" 2>/dev/null)" "widened to the last 78 hours"

  # WEEKLY can catch up even though its normal window (198h) exceeds the default
  # cap (168) -- the regression where a flat cap made weekly catch-up impossible.
  printf '{"timestamp":"2020-01-01T00:00:00Z","mode":"weekly","pass":"triage"}\n' > "$repo/state/runs.log"
  sed -i.bak 's/catchup_max_hours: 48/catchup_max_hours: 168/' "$repo/monitor-config.yaml" && rm -f "$repo/monitor-config.yaml.bak"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" weekly 2>&1 )"
  assert_contains "weekly widens past its 198h window (to 198+168)" "$(cat "$args" 2>/dev/null)" "widened to the last 366 hours"

  # A recent last run (inside the window) -> no catch-up at all.
  local repo2="$TMP/catchuprepo2" args2="$TMP/catchup_args2"
  make_fake_repo "$repo2"
  cp "$repo/stub/claude" "$repo2/stub/claude"
  printf '{"timestamp":"%s","mode":"daily","pass":"triage"}\n' \
    "$(date -u +%FT%TZ)" > "$repo2/state/runs.log"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args2" HOME="$TMP/fakehome" PATH="$repo2/stub:$PATH" \
          bash "$repo2/bin/monitor.sh" daily 2>&1 )"
  case "$(cat "$args2" 2>/dev/null)" in
    *"CATCH-UP WINDOW"*) fail "no catch-up when the last run is recent" ;;
    *) pass "no catch-up when the last run is recent" ;;
  esac

  # catchup_max_hours: 0 disables the widening entirely.
  local repo3="$TMP/catchuprepo3" args3="$TMP/catchup_args3"
  make_fake_repo "$repo3"
  cp "$repo/stub/claude" "$repo3/stub/claude"
  printf 'monitoring:\n  catchup_max_hours: 0\n' >> "$repo3/monitor-config.yaml"
  printf '{"timestamp":"2020-01-01T00:00:00Z","mode":"daily","pass":"triage"}\n' > "$repo3/state/runs.log"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args3" HOME="$TMP/fakehome" PATH="$repo3/stub:$PATH" \
          bash "$repo3/bin/monitor.sh" daily 2>&1 )"
  case "$(cat "$args3" 2>/dev/null)" in
    *"CATCH-UP WINDOW"*) fail "catchup_max_hours: 0 disables catch-up" ;;
    *) pass "catchup_max_hours: 0 disables catch-up" ;;
  esac

  # A LEGACY runs.log row (predates per-pass logging -> no `pass` field) must still seed
  # the catch-up baseline: the bootstrap-exclusion filter keeps it.
  local repo4="$TMP/catchuprepo4" args4="$TMP/catchup_args4"
  make_fake_repo "$repo4"
  cp "$repo/stub/claude" "$repo4/stub/claude"
  printf '{"timestamp":"%s","mode":"daily","cost_usd":0.01}\n' \
    "$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=99,minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
    > "$repo4/state/runs.log"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args4" HOME="$TMP/fakehome" PATH="$repo4/stub:$PATH" \
          bash "$repo4/bin/monitor.sh" daily 2>&1 )"
  assert_contains "a legacy (no-pass) row still seeds the catch-up baseline" "$(cat "$args4" 2>/dev/null)" "widened to the last 100 hours"
}
test_monitor_catchup

echo "== horizon.py: latest-per-id collapse, grace by precision, due/upcoming math =="
test_horizon_py() {
  local repo="$TMP/horizonpy" h="$TMP/horizonpy/h.jsonl" due upcoming far rc
  mkdir -p "$repo"; cp "$ROOT/bin/horizon.py" "$repo/"
  # Fixed dates + a fixed --as-of so the math is deterministic regardless of the day
  # the suite runs. as-of = 2026-06-07; month grace is 7 days, year grace 30.
  printf '%s\n' \
    '{"timestamp":"2026-01-01T00:00:00Z","id":"h-slip","entity":"A","event":"GA","due":"2026-03-31","due_precision":"quarter","due_text":"Q1","status":"pending","source":"u"}' \
    '{"timestamp":"2026-02-01T00:00:00Z","id":"h-slip","entity":"A","event":"GA","due":"2026-09-30","due_precision":"quarter","due_text":"slipped to Q3","status":"pending","source":"u"}' \
    '{"timestamp":"2026-01-01T00:00:00Z","id":"h-met","entity":"B","event":"earnings","due":"2026-05-01","due_precision":"day","status":"pending","source":"u"}' \
    '{"timestamp":"2026-05-02T00:00:00Z","id":"h-met","entity":"B","event":"earnings","due":"2026-05-01","due_precision":"day","status":"met","source":"u"}' \
    '{"timestamp":"2026-01-01T00:00:00Z","id":"h-monthok","entity":"C","event":"launch","due":"2026-06-01","due_precision":"month","status":"pending","source":"u"}' \
    '{"timestamp":"2026-01-01T00:00:00Z","id":"h-monthlate","entity":"D","event":"launch","due":"2026-05-30","due_precision":"month","status":"pending","source":"u"}' \
    '{"timestamp":"2026-01-01T00:00:00Z","id":"h-bad","entity":"E","event":"thing","due":"2026-05-01","due_precision":"fortnight","status":"pending","source":"u"}' \
    '{"timestamp":"2026-01-01T00:00:00Z","id":["not","a","string"],"entity":"F","event":"oops","due":"2026-05-01","status":"pending","source":"u"}' \
    'this is not json -- a corrupt hand-edited row' \
    > "$h"
  due="$( python3 "$repo/horizon.py" due --as-of 2026-06-07 "$h" )"; rc=$?
  assert_eq "due exits 0 despite a corrupt row" "0" "$rc"
  # A non-string (non-hashable) id must be skipped, not crash the whole sweep.
  assert_contains "a non-string id is skipped without aborting" "$due" '"id": "h-monthok"'
  assert_contains "month-due +6d is due but NOT past grace" "$due" '"id": "h-monthok", '
  case "$due" in *'"id": "h-monthok"'*'"past_grace": false'*) pass "h-monthok flagged inside grace" ;; *) fail "h-monthok flagged inside grace" ;; esac
  case "$due" in *'"id": "h-monthlate"'*'"past_grace": true'*) pass "month-due +8d is past grace" ;; *) fail "month-due +8d is past grace" ;; esac
  case "$due" in *'"id": "h-bad"'*'"past_grace": true'*) pass "an unknown precision degrades to year grace" ;; *) fail "an unknown precision degrades to year grace" ;; esac
  assert_not_contains "a met expectation is suppressed (latest row wins)" "$due" "h-met"
  assert_not_contains "a not-yet-due expectation is excluded" "$due" "h-slip"

  upcoming="$( python3 "$repo/horizon.py" upcoming --as-of 2026-06-07 --days 14 "$h" )"
  assert_contains "upcoming renders a Markdown table header" "$upcoming" "| When | Entity | Expected | Status |"
  assert_contains "an in-grace due row lands in the table as 'due'" "$upcoming" "| by Jun 1 | C | launch | due |"
  assert_contains "past-grace rows go to the overdue list" "$upcoming" "Overdue / unconfirmed:"
  assert_contains "an overdue row names the entity + days past" "$upcoming" "D's launch was expected"
  # A wide window surfaces the slipped (collapsed-to-Q3) expectation as a quarter label.
  far="$( python3 "$repo/horizon.py" upcoming --as-of 2026-06-07 --days 200 "$h" )"
  assert_contains "the collapsed slip shows its new (Q3) date" "$far" "~Sep (Q3)"
  assert_not_contains "the slip's old Q1 date is gone (latest row wins)" "$far" "Q1"
  # An empty / missing log emits nothing (the caller skips the section).
  assert_eq "missing file emits nothing" "" "$( python3 "$repo/horizon.py" upcoming --as-of 2026-06-07 "$TMP/nope.jsonl" )"
}
test_horizon_py

echo "== monitor.sh: forward radar injects DUE EXPECTATIONS; daily appends no section =="
test_monitor_horizon() {
  local repo="$TMP/horizonrepo" out args="$TMP/horizon_args" past future
  make_fake_repo "$repo"
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  # A due-past-grace expectation (~40d overdue, month precision) and a future one.
  past="$(python3 -c 'from datetime import date,timedelta; print((date.today()-timedelta(days=40)).isoformat())')"
  future="$(python3 -c 'from datetime import date,timedelta; print((date.today()+timedelta(days=20)).isoformat())')"
  printf '%s\n' \
    "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"id\":\"h-past\",\"entity\":\"Competitor C\",\"event\":\"EU launch\",\"due\":\"$past\",\"due_precision\":\"month\",\"due_text\":\"by then\",\"status\":\"pending\",\"source\":\"https://z\"}" \
    "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"id\":\"h-fut\",\"entity\":\"Competitor B\",\"event\":\"Q2 earnings\",\"due\":\"$future\",\"due_precision\":\"day\",\"due_text\":\"soon\",\"status\":\"pending\",\"source\":\"https://x\"}" \
    > "$repo/state/horizon.jsonl"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  assert_contains "announces due expectations" "$out" "forward radar: 1 expectation(s) due"
  assert_contains "prompt carries the injected DUE EXPECTATIONS block" "$(cat "$args" 2>/dev/null)" "DUE EXPECTATIONS - forward radar"
  assert_contains "the past-grace row is injected" "$(cat "$args" 2>/dev/null)" "h-past"
  assert_contains "the injected row is flagged past grace" "$(cat "$args" 2>/dev/null)" '"past_grace": true'
  assert_not_contains "a not-yet-due expectation is NOT injected" "$(cat "$args" 2>/dev/null)" "h-fut"
  assert_not_contains "a daily run never appends a Coming up section" "$out" "appended the Coming up section"

  # tracking.horizon: false turns the whole feature off (no injection).
  local args2="$TMP/horizon_args2"
  printf 'tracking:\n  horizon: false\n' >> "$repo/monitor-config.yaml"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args2" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  assert_not_contains "tracking.horizon: false disables the injection" "$(cat "$args2" 2>/dev/null)" "DUE EXPECTATIONS - forward radar"
}
test_monitor_horizon

echo "== monitor.sh: weekly appends the Coming up section; a silent weekly stays silent =="
test_monitor_horizon_weekly() {
  local repo="$TMP/horizonwk" out soon report
  make_fake_repo "$repo"
  # A stub that writes a weekly report so the post-editor append path is exercised.
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
printf '# weekly report\n* item\n' > "kb/.$(date +%F).weekly.partial.md"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  soon="$(python3 -c 'from datetime import date,timedelta; print((date.today()+timedelta(days=10)).isoformat())')"
  printf '%s\n' \
    "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"id\":\"h-soon\",\"entity\":\"Competitor B\",\"event\":\"Q2 earnings\",\"due\":\"$soon\",\"due_precision\":\"day\",\"due_text\":\"in 10 days\",\"status\":\"pending\",\"source\":\"https://x\"}" \
    > "$repo/state/horizon.jsonl"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" bash "$repo/bin/monitor.sh" weekly 2>&1 )"
  report="$repo/kb/$(date +%F).weekly.md"
  assert_contains "announces the appended section" "$out" "appended the Coming up section"
  assert_contains "the weekly report carries a Coming up section" "$(cat "$report" 2>/dev/null)" "## Coming up"
  assert_contains "the section lists the upcoming expectation" "$(cat "$report" 2>/dev/null)" "Q2 earnings"

  # Silence preserved: pending expectations but an EMPTY report -> no report, no section.
  local repo2="$TMP/horizonwk2"
  make_fake_repo "$repo2"                       # default stub writes no report
  cp "$repo/state/horizon.jsonl" "$repo2/state/horizon.jsonl"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo2/stub:$PATH" bash "$repo2/bin/monitor.sh" weekly 2>&1 )"
  assert_contains "a silent weekly stays silent" "$out" "nothing material"
  assert_not_contains "no section is appended without a report" "$out" "appended the Coming up section"
  if [ -f "$repo2/kb/$(date +%F).weekly.md" ]; then fail "the radar never causes a report"; else pass "the radar never causes a report"; fi
}
test_monitor_horizon_weekly

echo "== monitor.sh: a stale profile says so in the report, not only in the log =="
test_monitor_stale_in_report() {
  local repo="$TMP/stalereport" out report msg="$TMP/stale.eml"
  make_fake_repo "$repo" "2000-01-01" 0 "me@example.com"   # far past profile_refresh_days (30)
  # A stub that writes a report, so the post-editor append path is exercised.
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
printf '# daily report\n* item\n' > "kb/.$(date +%F).daily.partial.md"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( MSG_OUT="$msg" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  report="$repo/kb/$(date +%F).daily.md"
  assert_contains "still warns in the run log" "$out" "WARNING: profile is"
  assert_contains "announces the appended notice" "$out" "appended the profile-staleness notice"
  assert_contains "the delivered report carries the notice" \
    "$(cat "$report" 2>/dev/null)" "The approved profile is stale"
  assert_contains "the notice names the configured window" \
    "$(cat "$report" 2>/dev/null)" "governance.profile_refresh_days"
  # Appending to the report FILE (not just the log) is the point: it has to reach the
  # inbox, which is the only channel anyone actually reads.
  assert_contains "the emailed report carries it too" "$(cat "$msg" 2>/dev/null)" "approved profile is stale"

  # A fresh profile adds nothing.
  local repo2="$TMP/freshreport"
  make_fake_repo "$repo2" "$(date +%F)"
  cp "$repo/stub/claude" "$repo2/stub/claude"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo2/stub:$PATH" bash "$repo2/bin/monitor.sh" daily 2>&1 )"
  assert_not_contains "a fresh profile appends nothing" "$out" "appended the profile-staleness notice"
  assert_not_contains "no notice in a fresh run's report" \
    "$(cat "$repo2/kb/$(date +%F).daily.md" 2>/dev/null)" "The approved profile is stale"

  # The same empty-date hole on the monitor side: an absent last_bootstrapped must be
  # REPORTED as unparseable, not silently read as "today" (GNU date) and so never stale.
  # Passes on macOS either way; it guards the Linux leg.
  local repo4="$TMP/staleblank"
  make_fake_repo "$repo4" "2000-01-01"
  printf 'subject:\n  derived:\n    name: no-date-here\n' > "$repo4/profile.yaml"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo4/stub:$PATH" bash "$repo4/bin/monitor.sh" daily 2>&1 )"
  assert_contains "an absent last_bootstrapped is called out, not read as fresh" \
    "$out" "couldn't parse profile last_bootstrapped"

  # A FUTURE date is the third way into the same hole: it parses, so it never reaches the
  # "couldn't parse" branch, but its negative age is never -gt the window either - so the
  # warning would silently switch off for as long as the date stays ahead of the clock.
  local repo4b="$TMP/stalefuture"
  make_fake_repo "$repo4b" "2099-06-01"
  cp "$repo/stub/claude" "$repo4b/stub/claude"   # report-writing stub; the notice rides a report
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo4b/stub:$PATH" bash "$repo4b/bin/monitor.sh" daily 2>&1 )"
  assert_contains "a future last_bootstrapped warns rather than reading as fresh" \
    "$out" "is in the future"
  assert_contains "and the notice reaches the report" \
    "$(cat "$repo4b/kb/$(date +%F).daily.md" 2>/dev/null)" "dated in the future"

  # With a COMPLETE draft pending, the profile is stale by design until a human approves.
  # Telling the operator to run bootstrap.sh there is the one instruction that destroys
  # the finished work: a manual run is ungated and its synthesis overwrites the draft.
  local repo5="$TMP/stalepending"
  make_fake_repo "$repo5" "2000-01-01"
  cp "$repo/stub/claude" "$repo5/stub/claude"
  printf 'derived: {}\n' > "$repo5/profile.draft.yaml"
  : > "$repo5/state/.draft-complete"
  touch -t 202601010000 "$repo5/profile.yaml"
  touch -t 202602010000 "$repo5/profile.draft.yaml"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo5/stub:$PATH" bash "$repo5/bin/monitor.sh" daily 2>&1 )"
  local rep5; rep5="$repo5/kb/$(date +%F).daily.md"
  assert_contains "announces the approval notice instead" "$out" "appended the pending-draft approval notice"
  assert_contains "the report asks for approval, not another bootstrap" \
    "$(cat "$rep5" 2>/dev/null)" "waiting for your approval"
  assert_contains "and spells out the approval command" \
    "$(cat "$rep5" 2>/dev/null)" "cp profile.draft.yaml profile.yaml"
  assert_not_contains "it does NOT tell the operator to re-run bootstrap" \
    "$(cat "$rep5" 2>/dev/null)" "Refresh with"
  # An INCOMPLETE draft (no marker) is debris, not pending work: back to refresh advice.
  rm -f "$repo5/state/.draft-complete" "$rep5"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo5/stub:$PATH" bash "$repo5/bin/monitor.sh" daily 2>&1 )"
  assert_contains "an unmarked draft falls back to the refresh notice" "$out" "appended the profile-staleness notice"
  # A draft TRUNCATED during the documented human-edit step must not be advertised for
  # approval either - same nonempty bar the --if-stale gate applies.
  : > "$repo5/profile.draft.yaml"
  : > "$repo5/state/.draft-complete"
  touch -t 202601010000 "$repo5/profile.yaml"
  touch -t 202602010000 "$repo5/profile.draft.yaml"
  rm -f "$rep5"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo5/stub:$PATH" bash "$repo5/bin/monitor.sh" daily 2>&1 )"
  assert_contains "an emptied draft is not advertised for approval" "$out" "appended the profile-staleness notice"
  assert_not_contains "no approval instruction for an empty draft" \
    "$(cat "$rep5" 2>/dev/null)" "waiting for your approval"

  # Silence still wins: like the forward radar, the notice rides along on a report, it
  # never causes one. (An instance that is mostly silent is covered by the monthly
  # refresh agent instead.)
  local repo3="$TMP/stalesilent"
  make_fake_repo "$repo3" "2000-01-01"        # default stub writes no report
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo3/stub:$PATH" bash "$repo3/bin/monitor.sh" daily 2>&1 )"
  assert_contains "a silent run stays silent" "$out" "nothing material"
  assert_not_contains "nothing appended without a report" "$out" "appended the profile-staleness notice"
  if [ -f "$repo3/kb/$(date +%F).daily.md" ]; then
    fail "the staleness notice never causes a report"
  else
    pass "the staleness notice never causes a report"
  fi
}
test_monitor_stale_in_report

echo "== portal.py: forward-radar Coming up card + dossier Expected list + export =="
test_portal_coming_up() {
  local repo="$TMP/pcu" out py="$TMP/pcu.py" port=8794 page
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/portal.py" "$repo/bin/"
  cat > "$py" <<'PY'
import importlib.util, json, sys
from datetime import date, timedelta
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("NO_FILE", repr(m.coming_up_card()))
today = date.today()
rows = [
  {"timestamp":"2026-01-01T00:00:00Z","id":"h-late","entity":"Competitor C","event":"EU launch","due":(today-timedelta(days=60)).isoformat(),"due_precision":"month","due_text":"by then","status":"pending","source":"https://z"},
  {"timestamp":"2026-01-01T00:00:00Z","id":"h-due","entity":"Competitor B","event":"earnings","due":(today-timedelta(days=2)).isoformat(),"due_precision":"day","status":"pending","source":"https://x"},
  {"timestamp":"2026-01-01T00:00:00Z","id":"h-soon","entity":"Vendor X","event":"GA","due":(today+timedelta(days=10)).isoformat(),"due_precision":"quarter","due_text":"Q3","status":"pending","source":"https://q"},
  {"timestamp":"2026-01-02T00:00:00Z","id":"h-old","entity":"Competitor C","event":"price cut","due":"2026-01-01","due_precision":"day","status":"met","source":"https://m"},
]
with open(m.HORIZON, "w") as f:
    for r in rows: f.write(json.dumps(r) + "\n")
print("ORDER", "|".join(r["entity"] for r in m.coming_up_rows()))
card = m.coming_up_card()
print("OVERDUE_STYLED", "st-bad" in card and "overdue" in card)
print("LINKS", "/entity?e=Competitor%20C" in card)
print("EXP", "|".join("%s:%s" % (e["event"], e["badge"]) for e in m.entity_expectations("Competitor C")))
print("INDEX", "Vendor X" in [r["name"] for r in m.all_entities()])
PY
  out="$(python3 "$py" "$repo/bin/portal.py")"
  assert_contains "card omitted with no expectations" "$out" "NO_FILE ''"
  assert_contains "overdue sorts before due before upcoming" "$out" "ORDER Competitor C|Competitor B|Vendor X"
  assert_contains "an overdue expectation is styled as a warning" "$out" "OVERDUE_STYLED True"
  assert_contains "entity names link to their dossier" "$out" "LINKS True"
  assert_contains "dossier lists the pending overdue expectation" "$out" "EU launch:overdue"
  assert_contains "dossier keeps the met history after pending" "$out" "price cut:met"
  assert_contains "a horizon-only entity reaches the index" "$out" "INDEX True"
  # The static export carries the card (Overview snapshot, no /entity route).
  ( cd "$repo" && python3 bin/portal.py --export kb/index.html >/dev/null 2>&1 )
  assert_contains "static export includes the Coming up card" "$(cat "$repo/kb/index.html" 2>/dev/null)" "Coming up"

  # Disablement: tracking.horizon: false hides the card/dossier/index even with leftover
  # state, matching the monitor (no stale Coming up card for a turned-off feature).
  printf 'tracking:\n  horizon: false\n' > "$repo/monitor-config.yaml"
  local dis
  dis="$(python3 - "$repo/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("CARD", repr(m.coming_up_card()))
print("EXP", m.entity_expectations("Competitor C"))
print("INDEX", "Vendor X" in [r["name"] for r in m.all_entities()])
PY
)"
  assert_contains "tracking.horizon: false hides the Coming up card" "$dis" "CARD ''"
  assert_contains "tracking.horizon: false hides dossier expectations" "$dis" "EXP []"
  assert_contains "a disabled radar drops its horizon-only entity from the index" "$dis" "INDEX False"
  rm -f "$repo/monitor-config.yaml"   # restore default-enabled for the live-server checks

  if ! command -v curl >/dev/null 2>&1; then pass "dossier Expected (skipped: no curl)"; return; fi
  ( cd "$repo" && exec python3 bin/portal.py "$port" >/dev/null 2>&1 ) &
  local srv=$!
  page="$(curl -s --retry 8 --retry-delay 1 --retry-connrefused "http://127.0.0.1:$port/" || true)"
  assert_contains "overview shows the Coming up card" "$page" "Coming up"
  page="$(curl -s "http://127.0.0.1:$port/entity?e=Competitor%20C" || true)"
  assert_contains "dossier shows the Expected list" "$page" "Expected"
  assert_contains "dossier shows the entity's expectation" "$page" "EU launch"
  kill "$srv" 2>/dev/null || true
}
test_portal_coming_up

echo "== cadence.py: baselines, floor, min-events, suppression + episode reset =="
test_cadence_py() {
  local repo="$TMP/cadencepy" obs="$TMP/cadencepy/obs.jsonl" flags="$TMP/cadencepy/quiet.jsonl" out rc
  mkdir -p "$repo"; cp "$ROOT/bin/cadence.py" "$repo/"
  # Fixed dates + a fixed --as-of so the math is deterministic regardless of the day
  # the suite runs. as-of = 2026-06-07.
  # A: 4 release events 21 days apart (one same-day dup), last 2026-03-05 -> median 21,
  #    silence 94 >= max(3*21, 14) -> quiet. B: 3 events, below --min-events -> never a
  #    baseline. C: daily rhythm, 10d silent -> past 3x its median but under the 14-day
  #    floor -> not quiet. D: metric (non-event) rows only -> ignored. Plus a corrupt row.
  printf '%s\n' \
    '{"timestamp":"2026-01-01T07:00:00Z","entity":"A","metric":"event","event_type":"release","value":"v1","source":"https://a/1"}' \
    '{"timestamp":"2026-01-22T07:00:00Z","entity":"A","metric":"event","event_type":"release","value":"v2","source":"https://a/2"}' \
    '{"timestamp":"2026-02-12T07:00:00Z","entity":"A","metric":"event","event_type":"release","value":"v3","source":"https://a/3"}' \
    '{"timestamp":"2026-03-05T07:00:00Z","entity":"A","metric":"event","event_type":"release","value":"v4","source":"https://a/4"}' \
    '{"timestamp":"2026-03-05T09:00:00Z","entity":"A","metric":"event","event_type":"release","value":"v4 again","source":"https://a/4b"}' \
    '{"timestamp":"2026-01-01T07:00:00Z","entity":"B","metric":"event","event_type":"hire","value":"x","source":"https://b/1"}' \
    '{"timestamp":"2026-02-01T07:00:00Z","entity":"B","metric":"event","event_type":"hire","value":"y","source":"https://b/2"}' \
    '{"timestamp":"2026-03-01T07:00:00Z","entity":"B","metric":"event","event_type":"hire","value":"z","source":"https://b/3"}' \
    '{"timestamp":"2026-05-25T07:00:00Z","entity":"C","metric":"event","event_type":"post","value":"p","source":"https://c/1"}' \
    '{"timestamp":"2026-05-26T07:00:00Z","entity":"C","metric":"event","event_type":"post","value":"p","source":"https://c/2"}' \
    '{"timestamp":"2026-05-27T07:00:00Z","entity":"C","metric":"event","event_type":"post","value":"p","source":"https://c/3"}' \
    '{"timestamp":"2026-05-28T07:00:00Z","entity":"C","metric":"event","event_type":"post","value":"p","source":"https://c/4"}' \
    '{"timestamp":"2026-06-01T07:00:00Z","entity":"D","metric":"price_usd","value":42,"source":"https://d/1"}' \
    '{"timestamp":"2026-04-20T07:00:00Z","entity":"A","metric":"event","event_type":"release","value":"unsourced leak"}' \
    '{"timestamp":"2026-01-01T07:00:00Z","entity":"E","metric":"event","event_type":"ship","value":"1"}' \
    '{"timestamp":"2026-01-22T07:00:00Z","entity":"E","metric":"event","event_type":"ship","value":"2"}' \
    '{"timestamp":"2026-02-12T07:00:00Z","entity":"E","metric":"event","event_type":"ship","value":"3"}' \
    '{"timestamp":"2026-03-05T07:00:00Z","entity":"E","metric":"event","event_type":"ship","value":"4"}' \
    'this is not json -- a corrupt hand-edited row' \
    > "$obs"
  out="$( python3 "$repo/cadence.py" quiet --as-of 2026-06-07 --factor 3 --min-events 4 "$obs" "$flags" )"; rc=$?
  assert_eq "quiet exits 0 despite a corrupt row" "0" "$rc"
  assert_contains "a long-silent entity is flagged" "$out" '"entity": "A"'
  assert_contains "same-day repeats collapse (median stays 21)" "$out" '"median_gap_days": 21'
  assert_contains "silence is counted from the last event" "$out" '"silence_days": 94'
  assert_contains "an unsourced later event does not advance last_seen" "$out" '"last_seen": "2026-03-05"'
  assert_contains "the silence/median ratio is reported" "$out" '"factor": 4.5'
  assert_contains "the last event's source rides along" "$out" '"last_source": "https://a/4b"'
  assert_not_contains "below min-events -> no baseline, never flagged" "$out" '"entity": "B"'
  assert_not_contains "a short silence under the 14-day floor is not quiet" "$out" '"entity": "C"'
  assert_not_contains "non-event metrics never form a baseline" "$out" '"entity": "D"'
  assert_not_contains "unsourced events never form a baseline" "$out" '"entity": "E"'
  # Suppression: mark the flagged silence, and the same silence stops re-alarming.
  printf '%s\n' "$out" | python3 "$repo/cadence.py" mark --as-of 2026-06-07 "$flags"
  assert_contains "mark records the flagged silence" "$(cat "$flags" 2>/dev/null)" '"entity": "A"'
  assert_eq "a marked silence is suppressed" "" "$( python3 "$repo/cadence.py" quiet --as-of 2026-06-07 --factor 3 --min-events 4 "$obs" "$flags" )"
  # Episode reset: the entity resumes (last_seen advances), goes quiet again later ->
  # the stale flag no longer matches and the NEW silence is flagged.
  printf '%s\n' '{"timestamp":"2026-03-26T07:00:00Z","entity":"A","metric":"event","event_type":"release","value":"v5","source":"https://a/5"}' >> "$obs"
  out="$( python3 "$repo/cadence.py" quiet --as-of 2026-06-07 --factor 3 --min-events 4 "$obs" "$flags" )"
  assert_contains "a resumed-then-quiet entity re-flags as a new episode" "$out" '"last_seen": "2026-03-26"'
  # Fail-safe edges: a missing observations file emits nothing.
  assert_eq "missing observations file emits nothing" "" "$( python3 "$repo/cadence.py" quiet --as-of 2026-06-07 "$TMP/nope.jsonl" )"

  # mark --report: only entities the delivered report actually names get flagged --
  # a silence the agent left out of the report must re-inject, not vanish unseen.
  local mflags="$TMP/cadencepy/markreport.jsonl" mreport="$TMP/cadencepy/report.md"
  printf '# weekly\n\n## Quiet on\n- **A** has gone dark (no release in 13 weeks)\n' > "$mreport"
  printf '%s\n' \
    '{"entity":"A","event_type":"release","last_seen":"2026-03-05"}' \
    '{"entity":"Xylo","event_type":"release","last_seen":"2026-03-01"}' \
    | python3 "$repo/cadence.py" mark --as-of 2026-06-07 --report "$mreport" "$mflags"
  assert_contains "mark --report flags the reported entity" "$(cat "$mflags" 2>/dev/null)" '"entity": "A"'
  assert_not_contains "mark --report skips entities absent from the report" "$(cat "$mflags" 2>/dev/null)" '"entity": "Xylo"'

  # compact: the flag log is bounded by rewriting to the latest row per key -- never
  # by a tail-prune, which could evict an old-but-still-active flag and re-alarm.
  local cflags="$TMP/cadencepy/compact.jsonl"
  printf '%s\n' \
    '{"timestamp":"2026-01-01T00:00:00Z","entity":"X","event_type":"release","last_seen":"2026-01-01","flagged":"2026-01-01"}' \
    '{"timestamp":"2026-02-01T00:00:00Z","entity":"Y","event_type":"hire","last_seen":"2026-01-15","flagged":"2026-02-01"}' \
    '{"timestamp":"2026-03-01T00:00:00Z","entity":"X","event_type":"release","last_seen":"2026-02-20","flagged":"2026-03-01"}' \
    > "$cflags"
  python3 "$repo/cadence.py" compact "$cflags"
  assert_eq "compact keeps one row per entity/event_type" "2" "$(wc -l < "$cflags" | tr -d ' ')"
  assert_contains "compact keeps the newest flag per key" "$(cat "$cflags")" '"last_seen": "2026-02-20"'
  assert_not_contains "compact drops superseded flags" "$(cat "$cflags")" '"2026-01-01T00:00:00Z"'
  assert_contains "compact keeps unrelated keys" "$(cat "$cflags")" '"entity": "Y"'
}
test_cadence_py

echo "== monitor.sh: quiet detection injects QUIET ENTITIES (weekly), marks, suppresses =="
test_monitor_quiet() {
  local repo="$TMP/quietrepo" out args0="$TMP/quiet_args0" args1="$TMP/quiet_args1" args2="$TMP/quiet_args2"
  make_fake_repo "$repo"
  # A stub that captures its prompt AND writes a weekly report that names Competitor Q
  # in its Quiet on section -- but NOT Competitor R -- so the report-gated mark path
  # is exercised both ways (daily runs ignore the weekly partial and stay silent).
  cat > "$repo/stub/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
printf '# weekly report\n\n## Quiet on\n- **Competitor Q** - no release in 13 weeks vs a ~3-week norm\n' \
  > "kb/.$(date +%F).weekly.partial.md"
printf '{"num_turns":1,"total_cost_usd":0.0}\n'
exit 0
SH
  chmod +x "$repo/stub/claude"
  # The fixture config prunes observations to 5 lines; this test seeds 8 (two
  # entities x 4 events), so widen the cap or the prune eats the first entity.
  sed 's/observations_max_lines: 5/observations_max_lines: 50/' "$repo/monitor-config.yaml" \
    > "$repo/monitor-config.yaml.tmp" && mv "$repo/monitor-config.yaml.tmp" "$repo/monitor-config.yaml"
  # Competitor Q and Competitor R: 4 release events 21 days apart each, the last ~90
  # days ago -> silence >= max(3*21, 14) = 63 -> both quiet. Dates are relative to
  # today so the math holds whenever the suite runs.
  python3 - "$repo/state/observations.jsonl" <<'PY'
import json, sys
from datetime import date, timedelta
today = date.today()
with open(sys.argv[1], "w") as f:
    for entity, offsets in (("Competitor Q", (153, 132, 111, 90)),
                            ("Competitor R", (152, 131, 110, 89))):
        for d in offsets:
            f.write(json.dumps({"timestamp": (today - timedelta(days=d)).isoformat() + "T07:00:00Z",
                                "entity": entity, "metric": "event",
                                "event_type": "release", "value": "release",
                                "source": "https://example.test/releases"}) + "\n")
PY
  # Daily: quiet detection is weekly-only -- no injection, no flag bookkeeping.
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args0" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" daily 2>&1 )"
  assert_not_contains "a daily run never injects QUIET ENTITIES" "$(cat "$args0" 2>/dev/null)" "QUIET ENTITIES"
  if [ -f "$repo/state/quiet.jsonl" ]; then fail "daily writes no quiet flags"; else pass "daily writes no quiet flags"; fi
  # Weekly: both silences are injected; only the one the shipped report NAMES is
  # marked -- the silence the agent left out must re-inject, not vanish unseen.
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args1" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" weekly 2>&1 )"
  assert_contains "announces the quiet entities" "$out" "quiet detection: 2 entity(ies) silent past their baseline"
  assert_contains "prompt carries the injected QUIET ENTITIES block" "$(cat "$args1" 2>/dev/null)" "QUIET ENTITIES - cadence baselines"
  assert_contains "the quiet entities are injected" "$(cat "$args1" 2>/dev/null)" "Competitor Q"
  assert_contains "the injected row carries the silence arithmetic" "$(cat "$args1" 2>/dev/null)" '"silence_days": 90'
  assert_contains "the reported silence is marked" "$(cat "$repo/state/quiet.jsonl" 2>/dev/null)" '"entity": "Competitor Q"'
  assert_not_contains "a silence absent from the report is NOT marked" "$(cat "$repo/state/quiet.jsonl" 2>/dev/null)" '"entity": "Competitor R"'
  # Weekly again: the reported silence never re-alarms; the unreported one re-injects.
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args2" HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" \
          bash "$repo/bin/monitor.sh" weekly 2>&1 )"
  assert_contains "an unreported silence re-injects next weekly" "$(cat "$args2" 2>/dev/null)" "Competitor R"
  assert_not_contains "a marked silence is not re-injected" "$(cat "$args2" 2>/dev/null)" '"entity": "Competitor Q"'

  # Silence preserved: a weekly that ships NO report must not mark the flags (they
  # were never delivered), so the silence re-injects next weekly.
  local repo2="$TMP/quietrepo2" args3="$TMP/quiet_args3"
  make_fake_repo "$repo2"                       # default stub writes no report
  sed 's/observations_max_lines: 5/observations_max_lines: 50/' "$repo2/monitor-config.yaml" \
    > "$repo2/monitor-config.yaml.tmp" && mv "$repo2/monitor-config.yaml.tmp" "$repo2/monitor-config.yaml"
  cp "$repo/state/observations.jsonl" "$repo2/state/observations.jsonl"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo2/stub:$PATH" bash "$repo2/bin/monitor.sh" weekly 2>&1 )"
  assert_contains "quiet rows are computed on the silent weekly" "$out" "quiet detection: 2"
  assert_contains "the silent weekly stays silent" "$out" "nothing material"
  if [ -f "$repo2/state/quiet.jsonl" ]; then fail "an unshipped report marks nothing"; else pass "an unshipped report marks nothing"; fi
  # Disablement: tracking.quiet: false turns the whole feature off (no computation).
  printf 'tracking:\n  quiet: false\n' >> "$repo2/monitor-config.yaml"
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( CLAUDE_ARGS="$args3" HOME="$TMP/fakehome" PATH="$repo2/stub:$PATH" \
          bash "$repo2/bin/monitor.sh" weekly 2>&1 )"
  assert_not_contains "tracking.quiet: false disables the injection" "$(cat "$args3" 2>/dev/null)" "QUIET ENTITIES"
  assert_not_contains "tracking.quiet: false disables the computation" "$out" "quiet detection:"
}
test_monitor_quiet

echo "== monitor.sh: quiet-flag log is compacted, never tail-pruned (active flags survive) =="
test_monitor_quiet_compact() {
  local repo="$TMP/quietcompact" out
  make_fake_repo "$repo"
  # Competitor Q is quiet and ALREADY flagged -- its flag row sits at the HEAD of an
  # oversized log. A line-count tail-prune would evict it and wrongly re-alarm the
  # same silence; compaction (latest row per key) must keep it suppressed.
  python3 - "$repo/state/observations.jsonl" "$repo/state/quiet.jsonl" <<'PY'
import json, sys
from datetime import date, timedelta
today = date.today()
last = None
with open(sys.argv[1], "w") as f:
    for d in (153, 132, 111, 90):
        day = (today - timedelta(days=d)).isoformat()
        last = day
        f.write(json.dumps({"timestamp": day + "T07:00:00Z", "entity": "Competitor Q",
                            "metric": "event", "event_type": "release", "value": "release",
                            "source": "https://example.test/releases"}) + "\n")
with open(sys.argv[2], "w") as f:
    f.write(json.dumps({"timestamp": "2026-01-01T00:00:00Z", "entity": "Competitor Q",
                        "event_type": "release", "last_seen": last,
                        "flagged": "2026-01-01"}) + "\n")
    for _ in range(520):
        f.write(json.dumps({"timestamp": "2026-01-02T00:00:00Z", "entity": "Other",
                            "event_type": "x", "last_seen": "2026-01-01",
                            "flagged": "2026-01-02"}) + "\n")
PY
  # shellcheck disable=SC2031  # per-command env prefix, not a lost subshell change
  out="$( HOME="$TMP/fakehome" PATH="$repo/stub:$PATH" bash "$repo/bin/monitor.sh" weekly 2>&1 )"
  assert_contains "an oversized flag log is compacted" "$out" "compacted state/quiet.jsonl"
  assert_eq "compaction keeps the latest row per key" "2" "$(wc -l < "$repo/state/quiet.jsonl" | tr -d ' ')"
  assert_contains "the still-active flag survives compaction" "$(cat "$repo/state/quiet.jsonl")" '"entity": "Competitor Q"'
  assert_not_contains "the suppressed silence stays suppressed" "$out" "quiet detection:"
}
test_monitor_quiet_compact

echo "== portal.py: dossier Cadence line shows the baseline; quiet styled; off when disabled =="
test_portal_cadence() {
  local repo="$TMP/pcad" out
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb"
  cp "$ROOT/bin/portal.py" "$ROOT/bin/cadence.py" "$repo/bin/"
  # portal.entity_cadence() measures the silence against the UTC date, so the fixture
  # has to be laid out in UTC too: built from the LOCAL date, the assertions below are
  # off by a day whenever the two disagree (any evening west of Greenwich), which is
  # invisible on the always-UTC CI runners and fails only on a developer's machine.
  python3 - "$repo/state/observations.jsonl" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
today = datetime.now(timezone.utc).date()
with open(sys.argv[1], "w") as f:
    for d in (153, 132, 111, 90):
        f.write(json.dumps({"timestamp": (today - timedelta(days=d)).isoformat() + "T07:00:00Z",
                            "entity": "Competitor Q", "metric": "event",
                            "event_type": "release", "value": "release",
                            "source": "https://q.example/releases"}) + "\n")
PY
  out="$(python3 - "$repo/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
page = m.entity_inner({"e": ["Competitor Q"]})
print("LINE", "Cadence: ~21-day release rhythm (4 on record)" in page)
print("QUIET", "90d quiet" in page and "st-bad" in page)
PY
)"
  assert_contains "dossier shows the computed Cadence line" "$out" "LINE True"
  assert_contains "a quiet entity is styled as a warning" "$out" "QUIET True"
  # Disablement: tracking.quiet: false hides the line, matching the monitor.
  printf 'tracking:\n  quiet: false\n' > "$repo/monitor-config.yaml"
  out="$(python3 - "$repo/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("CAD", m.entity_cadence("Competitor Q"))
PY
)"
  assert_contains "tracking.quiet: false hides the Cadence line" "$out" "CAD []"
  rm -f "$repo/monitor-config.yaml"
  # A standalone portal.py copy (no sibling cadence.py) degrades to no line, not a crash.
  local solo="$TMP/pcadsolo"
  mkdir -p "$solo/bin" "$solo/state" "$solo/kb"
  cp "$ROOT/bin/portal.py" "$solo/bin/"
  cp "$repo/state/observations.jsonl" "$solo/state/observations.jsonl"
  out="$(python3 - "$solo/bin/portal.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("portal", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
page = m.entity_inner({"e": ["Competitor Q"]})
print("OK", "Event timeline" in page and "Cadence:" not in page)
PY
)"
  assert_contains "a standalone portal copy degrades to no Cadence line" "$out" "OK True"
}
test_portal_cadence

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

# An isolated bootstrap.sh checkout with a stub `claude`. The stub is installed under
# the fake HOME's .npm-global/bin, which bootstrap.sh PREPENDS to PATH - so it wins
# over any real claude on the host, keeping the test hermetic (no network call).
make_fake_bootstrap_repo() {  # <repo> <home> [nomodel]
  local repo="$1" home="$2"
  mkdir -p "$repo/bin" "$repo/state" "$home/.npm-global/bin"
  cp "$ROOT/bin/bootstrap.sh" "$ROOT/bin/dedupe-feedback.py" "$ROOT/bin/backtest.py" "$repo/bin/"; cp_libs "$repo/bin"
  cp "$ROOT/backtest-prompt.md" "$repo/backtest-prompt.md"
  if [ "${3:-}" = nomodel ]; then
    printf 'version: 1\nmodels:\n  monitor: sonnet\n' > "$repo/monitor-config.yaml"
  else
    printf 'version: 1\nmodels:\n  bootstrap: opus\n' > "$repo/monitor-config.yaml"
  fi
  printf 'bootstrap prompt (test fixture)\n' > "$repo/bootstrap-prompt.md"
  # Stub claude: the research call writes the draft + a summary and records its args;
# SYNTH_EXIT drives that call's exit code, AFTER the draft is written (a failing synthesis
# is what aborts a real run, and the real agent Writes the draft before the CLI errors) and
# NO_SUMMARY suppresses the summary it writes (the "successful run, nothing to email" path),
# NO_DRAFT models claude ending its turn cleanly without ever calling Write, and
# PARTIAL_DRAFT models a Write that got cut off - nonempty, so -s cannot tell it apart;
  # the editorial call (prompt names a PROFILE-DRAFT SUMMARY) edits the summary per env;
  # the backtest call (prompt names a Backtest prompt) records its prompt and writes a
  # canned score file from $BT_JSONL (or garbage / nothing, to drive the failure paths).
  cat > "$home/.npm-global/bin/claude" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"PROFILE-DRAFT SUMMARY"*)
    [ -n "${ED_MARKER:-}" ] && echo ran >> "$ED_MARKER"
    [ -n "${ED_EMPTY:-}" ]   && : > profile.draft.summary.md
    [ -n "${ED_REWRITE:-}" ] && printf '# edited summary\nbottom line\n' > profile.draft.summary.md
    exit "${ED_EXIT:-0}" ;;
  *"Backtest prompt"*)
    [ -n "${BT_ARGS:-}" ] && printf '%s\n' "$*" > "$BT_ARGS"
    # A misbehaving/injected pass that tries to clobber the draft via a RELATIVE path:
    # with the scratch-dir isolation it can only hit its own cwd, never the repo's draft.
    [ -n "${BT_CLOBBER:-}" ] && printf 'CLOBBERED\n' > profile.draft.yaml
    [ -n "${BT_GARBAGE:-}" ] && printf 'not json at all\n@@@\n' > profile.draft.backtest.jsonl
    [ -n "${BT_JSONL:-}" ]   && printf '%s\n' "$BT_JSONL" > profile.draft.backtest.jsonl
    exit "${BT_EXIT:-0}" ;;
  *)
    [ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
    if [ "${PARTIAL_DRAFT:-}" = late ]; then
      # Truncated AFTER last_bootstrapped but before relevance.rubric - what a
      # top-to-bottom synthesis cut short actually looks like. The earlier check passed
      # this, because last_bootstrapped sits near the TOP of the schema.
      printf 'derived: {}\nsubject:\n  last_bootstrapped: 2026-01-01\n' > profile.draft.yaml
    elif [ -n "${PARTIAL_DRAFT:-}" ]; then
      printf 'derived: {}\n' > profile.draft.yaml     # cut off before last_bootstrapped
    elif [ -z "${NO_DRAFT:-}" ]; then
      printf 'derived: {}\nsubject:\n  last_bootstrapped: 2026-01-01\nrelevance:\n  rubric: test rubric\n' > profile.draft.yaml
    fi
    if [ "${SYNTH_EXIT:-0}" != 0 ]; then
      # Order matters: the real agent Writes the draft mid-session and the CLI fails
      # afterwards, so a failed run DOES leave a newer-than-profile draft behind.
      echo "stub synthesis blew up" >&2
      exit "$SYNTH_EXIT"
    fi
    [ -n "${NO_SUMMARY:-}" ] || printf '# Profile draft summary\nbottom line: test market\n' > profile.draft.summary.md
    printf '{"num_turns":1,"total_cost_usd":0.0}\n'
    exit 0 ;;
esac
SH
  chmod +x "$home/.npm-global/bin/claude"
  write_capture_msmtp "$home/.npm-global/bin/msmtp"
}

# An isolated bootstrap.sh checkout wired for the DEEP-RESEARCH pipeline (models.researcher
# set): copies the research/fetch helpers + the real plan/facet/challenge prompts, and a
# stub `claude` that branches on the prompt. The stub records facet invocations + per-facet
# start/end times (batching), honors the MAX_THINKING_TOKENS env (plan/synth/challenge), and
# can be driven to fail facets / write a garbage plan / empty the draft via env vars.
make_research_bootstrap_repo() {  # <repo> <home>
  local repo="$1" home="$2"
  mkdir -p "$repo/bin" "$repo/state" "$home/.npm-global/bin"
  cp "$ROOT/bin/bootstrap.sh" "$ROOT/bin/dedupe-feedback.py" "$ROOT/bin/backtest.py" \
     "$ROOT/bin/research.py" "$ROOT/bin/fetch.py" "$repo/bin/"; cp_libs "$repo/bin"
  cp "$ROOT/research-plan-prompt.md" "$ROOT/research-facet-prompt.md" \
     "$ROOT/research-challenge-prompt.md" "$ROOT/backtest-prompt.md" "$repo/"
  printf 'bootstrap prompt (test fixture)\n' > "$repo/bootstrap-prompt.md"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
  researcher: sonnet
budgets:
  research_parallel: 3
YAML
  cat > "$home/.npm-global/bin/claude" <<'SH'
#!/usr/bin/env bash
prompt="$*"
emit_json() { printf '{"num_turns":1,"total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":5}}\n'; }
case "$prompt" in
  *"lead researcher"*)              # PLAN pass
    [ -n "${THINK_LOG:-}" ] && printf 'plan:%s\n' "${MAX_THINKING_TOKENS:-unset}" >> "$THINK_LOG"
    [ -n "${PLAN_ARGS:-}" ] && printf '%s\n' "$*" > "$PLAN_ARGS"
    mkdir -p state/.research
    if [ -n "${PLAN_GARBAGE:-}" ]; then
      printf 'not json at all {{{\n' > state/.research/plan.json
    else
      n="${PLAN_FACETS:-2}"; i=1
      { printf '{ "facets": [\n'
        while [ "$i" -le "$n" ]; do
          sep=","; [ "$i" -eq "$n" ] && sep=""
          printf '  { "id": "facet-%s", "title": "T%s", "goal": "G%s", "questions": ["q"], "seeds": [], "deliverable": "d" }%s\n' "$i" "$i" "$i" "$sep"
          i=$((i + 1))
        done
        printf '] }\n'; } > state/.research/plan.json
    fi
    emit_json; exit 0 ;;
  *"one researcher"*)               # FACET pass
    note="$(printf '%s' "$prompt" | grep -o 'state/\.research/notes/[a-z0-9-]*\.md' | head -1)"
    fid="$(basename "$note" .md)"
    [ -n "${FACET_CALLS:-}" ] && printf '%s\n' "$fid" >> "$FACET_CALLS"
    if [ -n "${FACET_TIMES:-}" ]; then
      # python3 for a portable ms timestamp: BSD `date` (the macOS CI leg) has no %N.
      python3 -c 'import time;print(int(time.time()*1000))' > "$FACET_TIMES.$fid"
      sleep 0.4
      python3 -c 'import time;print(int(time.time()*1000))' >> "$FACET_TIMES.$fid"
    fi
    if [ "${FACET_FAIL:-}" = all ] || [ "${FACET_FAIL:-}" = "$fid" ]; then exit 1; fi
    printf '# Facet: %s\n\n## Findings\n- ok [x](https://e/%s)\n' "$fid" "$fid" > "$note"
    emit_json; exit 0 ;;
  *"drafted intelligence profile"*) # CHALLENGE pass
    [ -n "${THINK_LOG:-}" ] && printf 'challenge:%s\n' "${MAX_THINKING_TOKENS:-unset}" >> "$THINK_LOG"
    [ -n "${CH_EMPTY:-}" ] && : > profile.draft.yaml
    [ -n "${CH_TRUNC:-}" ] && printf 'derived: {}\n' > profile.draft.yaml   # nonempty, not reviewable
    [ -n "${CH_EXIT:-}" ] && exit "${CH_EXIT}"
    printf '## Challenge report\n- claim X - verdict: confirmed [src](https://e/x)\n' > profile.draft.challenge.md
    emit_json; exit 0 ;;
  *"Backtest prompt"*) exit 0 ;;
  *"PROFILE-DRAFT SUMMARY"*) exit 0 ;;
  *)                                # SYNTHESIS pass
    [ -n "${THINK_LOG:-}" ] && printf 'synth:%s\n' "${MAX_THINKING_TOKENS:-unset}" >> "$THINK_LOG"
    [ -n "${SYNTH_ARGS:-}" ] && printf '%s\n' "$prompt" > "$SYNTH_ARGS"
    printf 'derived: {}\nsubject:\n  last_bootstrapped: 2026-01-01\nrelevance:\n  rubric: test rubric\n' > profile.draft.yaml
    printf '# Profile draft summary\nbottom line: test market\n' > profile.draft.summary.md
    emit_json; exit 0 ;;
esac
SH
  chmod +x "$home/.npm-global/bin/claude"
  write_capture_msmtp "$home/.npm-global/bin/msmtp"
}

echo "== research.py: validate-plan clamps, slugifies, de-dups (bad plan -> nonzero) =="
test_research_py() {
  local d="$TMP/research"; mkdir -p "$d"
  # A plan with mixed-case/spaced ids, a colliding slug, and a no-id (title-only) facet.
  cat > "$d/plan.json" <<'JSON'
{ "facets": [
  { "id": "Sources & Feeds", "goal": "ranked sources" },
  { "id": "sources-feeds",   "goal": "dup slug" },
  { "title": "The Anchor",   "goal": "anchor set" },
  { "id": "extra-1", "goal": "g1" },
  { "id": "extra-2", "goal": "g2" }
] }
JSON
  local out
  out="$(python3 "$ROOT/bin/research.py" validate-plan --max 3 "$d/plan.json")"
  assert_eq "clamps to --max facets" "3" "$(printf '%s\n' "$out" | grep -c .)"
  assert_contains "slugifies a spaced/punctuated id" "$out" "sources-feeds	"
  assert_contains "de-dups a colliding slug" "$out" "sources-feeds-2	"
  assert_contains "derives an id from a title-only facet" "$out" "the-anchor	"
  assert_contains "carries the goal as the manifest field" "$out" "	ranked sources	"
  # Each line is id<TAB>goal<TAB>compact-json with the normalized id inside.
  assert_contains "emits the facet json with the normalized id" "$out" '"id": "sources-feeds"'
  local rc
  printf 'not json {{{\n' > "$d/bad.json"
  python3 "$ROOT/bin/research.py" validate-plan "$d/bad.json" >/dev/null 2>&1; rc=$?
  assert_eq "garbage plan exits nonzero (forces single-pass fallback)" "1" "$rc"
  printf '{ "facets": [] }\n' > "$d/empty.json"
  python3 "$ROOT/bin/research.py" validate-plan "$d/empty.json" >/dev/null 2>&1; rc=$?
  assert_eq "empty facet list exits nonzero" "1" "$rc"
  python3 "$ROOT/bin/research.py" validate-plan "$d/nope.json" >/dev/null 2>&1; rc=$?
  assert_eq "missing plan file exits nonzero" "1" "$rc"
  # A newline embedded in a goal must NOT add a stray output line (the shell protocol is
  # one facet per line) -- it's collapsed to a space.
  printf '{ "facets": [ {"id":"a","goal":"g a"}, {"id":"b","goal":"line1\\nline2"} ] }\n' > "$d/nl.json"
  out="$(python3 "$ROOT/bin/research.py" validate-plan --max 6 "$d/nl.json")"
  assert_eq "a newline in goal does not add a facet line" "2" "$(printf '%s\n' "$out" | grep -c .)"
  assert_contains "the newline in goal is collapsed to a space" "$out" "line1 line2"
}
test_research_py

echo "== fetch.py --verify: flags draft feeds that don't serve a parseable feed =="
test_fetch_verify() {
  local dir="$TMP/feeds-v" port=8795 rc
  mkdir -p "$dir"; write_feed_fixtures "$dir"
  # A well-formed XML doc that is NOT a feed (a sitemap) must be flagged, not blessed as
  # a 0-entry feed -- the root element isn't rss/rdf/feed.
  printf '<?xml version="1.0"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://e/x</loc></url></urlset>\n' \
    > "$dir/sitemap.xml"
  local slog="$TMP/srv.verify.$port.log"
  write_static_httpd "$TMP/statichttpd.py"
  python3 "$TMP/statichttpd.py" "$dir" "$port" > "$slog" 2>&1 &
  local srv=$!
  if ! wait_port "$port" "$slog" "$srv"; then fail "verify feed server came up"; kill "$srv" 2>/dev/null; return; fi
  cat > "$TMP/verify-draft.yaml" <<YAML
subject:
  derived:
    feeds:
      - http://127.0.0.1:$port/rss.xml
      - http://127.0.0.1:$port/bad.xml
      - http://127.0.0.1:$port/sitemap.xml
      - http://127.0.0.1:1/dead.xml
YAML
  python3 "$ROOT/bin/fetch.py" --verify --out "$TMP/verify.md" "$TMP/verify-draft.yaml" 2>/dev/null; rc=$?
  kill "$srv" 2>/dev/null || true
  assert_eq "verify exits 0 (an aid, never a gate)" "0" "$rc"
  local md; md="$(cat "$TMP/verify.md" 2>/dev/null)"
  assert_contains "reports the failing count" "$md" "3 of 4 draft feed(s) don't serve a parseable feed"
  assert_contains "names the unparseable feed" "$md" "bad.xml"
  assert_contains "names the unreachable feed" "$md" "dead.xml"
  assert_contains "flags a valid-XML non-feed (sitemap), not blessed as a feed" "$md" "sitemap.xml"
  assert_contains "lists the working feed with its entry count" "$md" "rss.xml"
  # No feeds in the draft -> nothing to verify, no file, exit 0.
  printf 'subject:\n  derived:\n    feeds: []\n' > "$TMP/verify-none.yaml"
  local err; err="$(python3 "$ROOT/bin/fetch.py" --verify --out "$TMP/vn.md" "$TMP/verify-none.yaml" 2>&1)"; rc=$?
  assert_eq "no draft feeds exits 0" "0" "$rc"
  assert_contains "notes there's nothing to verify" "$err" "nothing to verify"
  if [ -f "$TMP/vn.md" ]; then fail "writes no report when there are no feeds"; else pass "writes no report when there are no feeds"; fi
}
test_fetch_verify

echo "== bootstrap.sh: deep-research pipeline (plan -> parallel facets -> synthesis) =="
test_bootstrap_research_pipeline() {
  local repo="$TMP/rp" home="$TMP/rphome" synth="$TMP/rp_synth" calls="$TMP/rp_calls"
  make_research_bootstrap_repo "$repo" "$home"
  out="$( cd "$repo" && SYNTH_ARGS="$synth" FACET_CALLS="$calls" HOME="$home" \
          bash bin/bootstrap.sh 2>&1 )"
  assert_contains "announces the plan pass" "$out" "planning the investigation"
  assert_contains "announces the facets (default 2)" "$out" "2 facet(s), 3 at a time"
  assert_contains "synthesizes from the research notes" "$out" "synthesizing the draft -> profile.draft.yaml (from research notes)"
  # Both facets were researched and their notes written.
  if [ -s "$repo/state/.research/notes/facet-1.md" ] && [ -s "$repo/state/.research/notes/facet-2.md" ]; then
    pass "each facet wrote its notes file"
  else
    fail "each facet wrote its notes file"
  fi
  # The synthesis prompt names both notes files and asks for a provenance block.
  local sp; sp="$(cat "$synth" 2>/dev/null)"
  assert_contains "synthesis prompt carries the notes manifest" "$sp" "RESEARCH NOTES"
  assert_contains "synthesis prompt names facet-1's notes" "$sp" "state/.research/notes/facet-1.md"
  assert_contains "synthesis prompt names facet-2's notes" "$sp" "state/.research/notes/facet-2.md"
  assert_contains "synthesis prompt asks for a provenance block" "$sp" "How this draft was researched"
  # A facet prompt sees ONLY its own facet (mutual exclusion).
  assert_eq "exactly two facet invocations" "2" "$(grep -c . "$calls" 2>/dev/null || echo 0)"
  # Per-pass usage logged to runs.log: plan + 2 facets + synthesis.
  local log; log="$(cat "$repo/state/runs.log" 2>/dev/null)"
  assert_contains "logs the plan pass" "$log" '"pass":"research-plan"'
  assert_contains "logs a facet pass" "$log" '"pass":"research-facet:facet-1"'
  assert_contains "logs the synthesis pass" "$log" '"pass":"bootstrap"'
}
test_bootstrap_research_pipeline

echo "== bootstrap.sh: the plan pass runs unattended (can't punt to AskUserQuestion) =="
# Regression: a model sometimes treats the plan prompt as ambiguous and calls
# AskUserQuestion instead of writing plan.json; in a headless run that question is
# auto-dismissed and no plan is written -> "no usable research plan" every time. The
# plan pass must disallow that escape hatch, and the prompt must say so out loud.
test_bootstrap_plan_autonomous() {
  local repo="$TMP/rp-auto" home="$TMP/rpautohome" pargs="$TMP/rp_plan_args"
  make_research_bootstrap_repo "$repo" "$home"
  ( cd "$repo" && PLAN_ARGS="$pargs" HOME="$home" bash bin/bootstrap.sh >/dev/null 2>&1 )
  local pa; pa="$(cat "$pargs" 2>/dev/null)"
  assert_contains "the plan pass disallows AskUserQuestion" "$pa" "AskUserQuestion"
  # The flag travels with --disallowedTools (not, say, a stray mention in the prompt).
  case "$pa" in
    *--disallowedTools*AskUserQuestion*) pass "AskUserQuestion is on the disallowedTools list" ;;
    *) fail "AskUserQuestion is on the disallowedTools list" ;;
  esac
  # The prompt itself tells the headless model to act, not ask.
  assert_contains "the plan prompt says it runs unattended" \
    "$(cat "$ROOT/research-plan-prompt.md")" "autonomously"
}
test_bootstrap_plan_autonomous

echo "== every unattended claude -p pass disallows AskUserQuestion =="
# A headless pass that can ask a question hangs/aborts on a silent dismissal. Guard the
# invariant across both agents: every `claude -p` here must name AskUserQuestion in its
# --disallowedTools so the model can never block on a prompt nobody will answer.
test_no_pass_can_ask() {
  local f n_pass n_guarded
  for f in "$ROOT/bin/bootstrap.sh" "$ROOT/bin/monitor.sh"; do
    n_pass="$(grep -c -- '--disallowedTools' "$f")"
    n_guarded="$(grep -c -- '--disallowedTools "[^"]*AskUserQuestion' "$f")"
    assert_eq "$(basename "$f"): every claude -p pass disallows AskUserQuestion" \
      "$n_pass" "$n_guarded"
  done
}
test_no_pass_can_ask

echo "== bootstrap.sh: models.researcher unset -> single-pass (no plan/facets) =="
test_bootstrap_single_pass_invariance() {
  local repo="$TMP/rp-off" home="$TMP/rpoffhome" synth="$TMP/rp_off_synth" calls="$TMP/rp_off_calls"
  make_research_bootstrap_repo "$repo" "$home"
  # Drop models.researcher -> the pipeline must not run at all.
  printf 'version: 1\nmodels:\n  bootstrap: opus\n' > "$repo/monitor-config.yaml"
  out="$( cd "$repo" && SYNTH_ARGS="$synth" FACET_CALLS="$calls" HOME="$home" \
          bash bin/bootstrap.sh 2>&1 )"
  case "$out" in
    *"planning the investigation"*) fail "no plan pass when researcher unset" ;;
    *) pass "no plan pass when researcher unset" ;;
  esac
  if [ -f "$calls" ]; then fail "no facet invocations when researcher unset"; else pass "no facet invocations when researcher unset"; fi
  assert_not_contains "synthesis prompt has no notes manifest" "$(cat "$synth" 2>/dev/null)" "RESEARCH NOTES"
  if [ -d "$repo/state/.research" ]; then fail "no research scratch dir when researcher unset"; else pass "no research scratch dir when researcher unset"; fi
}
test_bootstrap_single_pass_invariance

echo "== bootstrap.sh: a failed facet gets a stub note; the run completes =="
test_bootstrap_facet_failure() {
  local repo="$TMP/rp-ff" home="$TMP/rpffhome" synth="$TMP/rp_ff_synth"
  make_research_bootstrap_repo "$repo" "$home"
  out="$( cd "$repo" && FACET_FAIL=facet-2 SYNTH_ARGS="$synth" HOME="$home" \
          bash bin/bootstrap.sh 2>&1 )"
  assert_contains "the surviving facet wrote real notes" "$(cat "$repo/state/.research/notes/facet-1.md" 2>/dev/null)" "## Findings"
  assert_contains "the failed facet gets a stub note" "$(cat "$repo/state/.research/notes/facet-2.md" 2>/dev/null)" "FACET FAILED"
  assert_contains "the manifest flags the failed facet" "$(cat "$synth" 2>/dev/null)" "FAILED (treat as unresearched)"
  assert_contains "reports partial coverage" "$out" "1/2 facet(s) produced notes"
  if [ -s "$repo/profile.draft.yaml" ]; then pass "the run still produced a draft"; else fail "the run still produced a draft"; fi
}
test_bootstrap_facet_failure

echo "== bootstrap.sh: every facet failing falls back to single-pass synthesis =="
test_bootstrap_all_facets_fail() {
  local repo="$TMP/rp-af" home="$TMP/rpafhome" synth="$TMP/rp_af_synth"
  make_research_bootstrap_repo "$repo" "$home"
  out="$( cd "$repo" && FACET_FAIL=all SYNTH_ARGS="$synth" HOME="$home" \
          bash bin/bootstrap.sh 2>&1 )"
  assert_contains "warns every facet failed" "$out" "every facet failed"
  assert_not_contains "synthesis runs with no notes manifest" "$(cat "$synth" 2>/dev/null)" "RESEARCH NOTES"
  if [ -s "$repo/profile.draft.yaml" ]; then pass "single-pass fallback still produced a draft"; else fail "single-pass fallback still produced a draft"; fi
}
test_bootstrap_all_facets_fail

echo "== bootstrap.sh: an invalid plan falls back to single-pass with a warning =="
test_bootstrap_bad_plan() {
  local repo="$TMP/rp-bp" home="$TMP/rpbphome" synth="$TMP/rp_bp_synth" calls="$TMP/rp_bp_calls"
  make_research_bootstrap_repo "$repo" "$home"
  out="$( cd "$repo" && PLAN_GARBAGE=1 SYNTH_ARGS="$synth" FACET_CALLS="$calls" HOME="$home" \
          bash bin/bootstrap.sh 2>&1 )"
  assert_contains "warns the plan was unusable" "$out" "no usable research plan"
  if [ -f "$calls" ]; then fail "no facets run on a bad plan"; else pass "no facets run on a bad plan"; fi
  assert_not_contains "synthesis has no notes manifest after a bad plan" "$(cat "$synth" 2>/dev/null)" "RESEARCH NOTES"
  if [ -s "$repo/profile.draft.yaml" ]; then pass "a bad plan still produced a draft"; else fail "a bad plan still produced a draft"; fi
}
test_bootstrap_bad_plan

echo "== bootstrap.sh: clamps the plan's facet count to budgets.research_max_facets =="
test_bootstrap_clamp() {
  local repo="$TMP/rp-cl" home="$TMP/rpclhome" calls="$TMP/rp_cl_calls"
  make_research_bootstrap_repo "$repo" "$home"
  printf 'version: 1\nmodels:\n  bootstrap: opus\n  researcher: sonnet\nbudgets:\n  research_max_facets: 4\n  research_parallel: 4\n' \
    > "$repo/monitor-config.yaml"
  ( cd "$repo" && PLAN_FACETS=8 FACET_CALLS="$calls" HOME="$home" bash bin/bootstrap.sh >/dev/null 2>&1 )
  assert_eq "an 8-facet plan with max 4 runs exactly 4" "4" "$(grep -c . "$calls" 2>/dev/null || echo 0)"
}
test_bootstrap_clamp

echo "== bootstrap.sh: facet batching never exceeds budgets.research_parallel =="
test_bootstrap_batching() {
  local repo="$TMP/rp-bt" home="$TMP/rpbthome" times="$TMP/rp_times"
  make_research_bootstrap_repo "$repo" "$home"
  printf 'version: 1\nmodels:\n  bootstrap: opus\n  researcher: sonnet\nbudgets:\n  research_parallel: 2\n' \
    > "$repo/monitor-config.yaml"
  ( cd "$repo" && PLAN_FACETS=5 FACET_TIMES="$times" HOME="$home" bash bin/bootstrap.sh >/dev/null 2>&1 )
  # Compute the max number of overlapping facet [start,end] intervals.
  local maxc
  maxc="$(python3 - "$times".* <<'PY'
import sys
events = []
for path in sys.argv[1:]:
    try:
        nums = [int(x) for x in open(path).read().split()]
    except (OSError, ValueError):
        continue
    if len(nums) >= 2:
        events.append((nums[0], 1)); events.append((nums[1], -1))
events.sort(key=lambda e: (e[0], e[1]))   # ends before starts at a tie
cur = mx = 0
for _, d in events:
    cur += d; mx = max(mx, cur)
print(mx)
PY
)"
  local nfiles; nfiles="$(set -- "$times".*; [ -e "$1" ] && echo $# || echo 0)"
  assert_eq "all 5 facets ran" "5" "$nfiles"
  if [ "${maxc:-9}" -le 2 ]; then pass "never more than research_parallel=2 facets at once (peak $maxc)"; else fail "never more than research_parallel=2 facets at once (peak $maxc)"; fi
}
test_bootstrap_batching

echo "== bootstrap.sh: --resume skips finished facets; a fresh run clears the scratch =="
test_bootstrap_resume() {
  local repo="$TMP/rp-rs" home="$TMP/rprshome" calls="$TMP/rp_rs_calls"
  make_research_bootstrap_repo "$repo" "$home"
  # Seed a finished plan, one fresh GOOD notes file, and one FAILED stub (both newer
  # than the plan): resume must keep the good one and RE-RUN the failed stub.
  mkdir -p "$repo/state/.research/notes"
  printf '{ "facets": [ { "id":"facet-1","goal":"g1" }, { "id":"facet-2","goal":"g2" } ] }\n' \
    > "$repo/state/.research/plan.json"
  sleep 1
  printf '# Facet: facet-1\n\n## Findings\n- prior [x](https://e/1)\n' > "$repo/state/.research/notes/facet-1.md"
  printf '# Facet: facet-2\n\nFACET FAILED - prior transient failure\n' > "$repo/state/.research/notes/facet-2.md"
  # A stale run-JSON from facet-1's prior (completed) attempt: resume must NOT re-log it.
  printf '{"num_turns":1,"total_cost_usd":0.99}\n' > "$repo/state/.research/facet-1.json"
  out="$( cd "$repo" && FACET_CALLS="$calls" HOME="$home" bash bin/bootstrap.sh --resume 2>&1 )"
  assert_contains "reuses the existing plan on --resume" "$out" "reusing existing plan"
  assert_contains "keeps the finished facet's notes" "$out" "facet facet-1: resume - keeping existing notes"
  assert_eq "the failed stub is re-run, the good one skipped" "facet-2" "$(cat "$calls" 2>/dev/null)"
  local rlog; rlog="$(cat "$repo/state/runs.log" 2>/dev/null)"
  assert_not_contains "a skipped facet's prior spend is NOT re-logged" "$rlog" "research-facet:facet-1"
  assert_contains "the re-run facet IS logged" "$rlog" "research-facet:facet-2"
  # A fresh (non-resume) run wipes the scratch and re-runs both.
  local calls2="$TMP/rp_rs_calls2"
  out="$( cd "$repo" && FACET_CALLS="$calls2" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_eq "a fresh run re-invokes both facets" "2" "$(grep -c . "$calls2" 2>/dev/null || echo 0)"
}
test_bootstrap_resume

echo "== bootstrap.sh: challenge pass writes a report folded into the email =="
test_bootstrap_challenge() {
  local repo="$TMP/rp-ch" home="$TMP/rpchhome" msg="$TMP/rp_ch.eml"
  make_research_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
  challenge: opus
subject:
  name: "Chal Market"
output:
  email_to: "me@example.com"
YAML
  out="$( cd "$repo" && MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "announces the challenge pass" "$out" "challenge pass on opus"
  assert_contains "writes the challenge report" "$out" "challenge report written to profile.draft.challenge.md"
  assert_contains "the email folds in the challenge report" "$(cat "$msg" 2>/dev/null)" "Challenge report"
  assert_contains "the approval hint points at the challenge" "$out" "adversarial challenge of the draft's claims: profile.draft.challenge.md"
  assert_contains "logs the challenge pass spend" "$(cat "$repo/state/runs.log" 2>/dev/null)" '"pass":"challenge"'
  # The summary (which the email + portal lead with) carries a staleness caveat, since the
  # challenge may have corrected the draft after the summary was written.
  assert_contains "the summary warns it may be stale vs the corrected draft" \
    "$(cat "$repo/profile.draft.summary.md" 2>/dev/null)" "ran after this summary was written"
  assert_contains "the emailed summary carries the staleness caveat too" \
    "$(cat "$msg" 2>/dev/null)" "ran after this summary was written"
}
test_bootstrap_challenge

echo "== bootstrap.sh: a challenge that empties the draft is non-destructive =="
test_bootstrap_challenge_failsafe() {
  local repo="$TMP/rp-cf" home="$TMP/rpcfhome" msg="$TMP/rp_cf.eml"
  make_research_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
  challenge: opus
output:
  email_to: "me@example.com"
YAML
  out="$( cd "$repo" && CH_EMPTY=1 MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "bootstrap still exits 0 when the challenge empties the draft" "0" "$rc"
  assert_contains "warns the draft was restored" "$out" "challenge pass failed/emptied the draft"
  assert_contains "the draft is restored from backup" "$(cat "$repo/profile.draft.yaml" 2>/dev/null)" "derived: {}"
  if [ -f "$repo/profile.draft.challenge.md" ]; then fail "no challenge report when the pass empties the draft"; else pass "no challenge report when the pass empties the draft"; fi
  assert_not_contains "no challenge section in the email" "$(cat "$msg" 2>/dev/null)" "Challenge report"

  # A challenge that leaves the draft NONEMPTY but not reviewable is corruption too: the
  # old -s gate accepted it and then deleted the backup, shipping the fragment as a draft.
  local repo2="$TMP/bootchaltrunc" home2="$TMP/boothomechal2" msg2="$TMP/boot_msg_chal2.eml"
  make_research_bootstrap_repo "$repo2" "$home2"     # only this stub HAS a challenge branch
  cat "$repo/monitor-config.yaml" > "$repo2/monitor-config.yaml"
  out="$( cd "$repo2" && CH_TRUNC=1 MSG_OUT="$msg2" HOME="$home2" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "warns the truncated challenge result was restored" "$out" "challenge pass failed/emptied the draft"
  assert_contains "a nonempty-but-unreviewable challenge result is restored too" \
    "$(cat "$repo2/profile.draft.yaml" 2>/dev/null)" "rubric"
}
test_bootstrap_challenge_failsafe

echo "== bootstrap.sh: budgets.thinking_tokens exports MAX_THINKING_TOKENS to the right passes =="
test_bootstrap_thinking() {
  local repo="$TMP/rp-th" home="$TMP/rpthhome" tlog="$TMP/rp_think.log"
  make_research_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
  researcher: sonnet
  challenge: opus
budgets:
  thinking_tokens: 1234
YAML
  # env -u clears any ambient MAX_THINKING_TOKENS so the stub only sees what bootstrap sets.
  ( cd "$repo" && env -u MAX_THINKING_TOKENS THINK_LOG="$tlog" HOME="$home" bash bin/bootstrap.sh >/dev/null 2>&1 )
  local tl; tl="$(cat "$tlog" 2>/dev/null)"
  assert_contains "plan pass gets MAX_THINKING_TOKENS" "$tl" "plan:1234"
  assert_contains "synthesis pass gets MAX_THINKING_TOKENS" "$tl" "synth:1234"
  assert_contains "challenge pass gets MAX_THINKING_TOKENS" "$tl" "challenge:1234"
  # thinking_tokens: 0 is the documented "CLI default" -> MUST NOT export 0 (which would
  # DISABLE thinking). With the ambient var cleared, an un-set leaves the stub at "unset".
  local repo0="$TMP/rp-th0" home0="$TMP/rpth0home" tlog0="$TMP/rp_think0.log"
  make_research_bootstrap_repo "$repo0" "$home0"
  printf 'version: 1\nmodels:\n  bootstrap: opus\nbudgets:\n  thinking_tokens: 0\n' > "$repo0/monitor-config.yaml"
  ( cd "$repo0" && env -u MAX_THINKING_TOKENS THINK_LOG="$tlog0" HOME="$home0" bash bin/bootstrap.sh >/dev/null 2>&1 )
  assert_contains "thinking_tokens: 0 does not export MAX_THINKING_TOKENS" "$(cat "$tlog0" 2>/dev/null)" "synth:unset"
}
test_bootstrap_thinking

echo "== bootstrap.sh: refuses to run without its config/prompt =="
test_bootstrap_gates() {
  local repo="$TMP/bootgate" out rc
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/bootstrap.sh" "$repo/bin/"; cp_libs "$repo/bin"
  out="$( cd "$repo" && bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "missing config exits 1" "1" "$rc"
  assert_contains "names the missing config" "$out" "monitor-config.yaml"
  printf 'version: 1\n' > "$repo/monitor-config.yaml"
  out="$( cd "$repo" && bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "missing prompt exits 1" "1" "$rc"
  assert_contains "names the missing prompt" "$out" "bootstrap-prompt.md"
}
test_bootstrap_gates

echo "== bootstrap.sh: --if-stale only runs when the approved profile is past its window =="
test_bootstrap_if_stale() {
  local repo="$TMP/ifstale" home="$TMP/ifstalehome" out rc
  make_fake_bootstrap_repo "$repo" "$home"
  printf 'governance:\n  profile_refresh_days: 30\n' >> "$repo/monitor-config.yaml"

  # Nothing approved yet: a FIRST bootstrap is a human decision, not a timer's.
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "no approved profile exits 0" "0" "$rc"
  assert_contains "skips when nothing is approved" "$out" "no approved profile.yaml yet"
  assert_not_contains "no claude call when nothing is approved" "$out" "synthesizing the draft"

  # A profile inside the window: not due.
  printf 'subject:\n  last_bootstrapped: %s\n' "$(date +%F)" > "$repo/profile.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "a fresh profile exits 0" "0" "$rc"
  assert_contains "skips a profile inside the refresh window" "$out" "0d old (<= profile_refresh_days=30)"
  assert_not_contains "no claude call for a fresh profile" "$out" "synthesizing the draft"

  # Past the window: this is the case that went unnoticed for ~70 days.
  printf 'subject:\n  last_bootstrapped: 2000-01-01\n' > "$repo/profile.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "a stale profile exits 0" "0" "$rc"
  assert_contains "explains why it is refreshing" "$out" "> profile_refresh_days=30) - refreshing"
  assert_contains "actually runs the bootstrap" "$out" "synthesizing the draft"

  # The run above left an unreviewed draft. A second one would overwrite it without
  # moving it any closer to approved - and re-spend a deep-research run to do it.
  touch -t 202601010000 "$repo/profile.yaml"
  touch -t 202602010000 "$repo/profile.draft.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "a pending draft exits 0" "0" "$rc"
  assert_contains "skips while a draft is awaiting review" "$out" "already waiting for review"
  assert_not_contains "no claude call while a draft is pending" "$out" "synthesizing the draft"

  # Approving the draft (cp draft -> profile.yaml) makes the profile the newer file,
  # so the next window crossing is free to refresh again.
  touch -t 202603010000 "$repo/profile.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "an approved draft unblocks the next refresh" "0" "$rc"
  assert_contains "refreshes once the draft is approved" "$out" "synthesizing the draft"

  # An unreadable last_bootstrapped counts as STALE. Guessing "fresh" from a date we
  # can't read reproduces exactly the silent rot the agent exists to prevent.
  printf 'subject:\n  last_bootstrapped: sometime\n' > "$repo/profile.yaml"
  rm -f "$repo/profile.draft.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_contains "an unparseable date is treated as stale" "$out" "treating it as stale"
  assert_contains "and the refresh runs" "$out" "synthesizing the draft"

  # A profile with NO last_bootstrapped at all is unreadable too - and this one only
  # bites on Linux: GNU `date -d ""` SUCCEEDS and answers "today", so the profile would
  # read as 0d old and the monthly agent would skip forever. BSD date already rejects
  # it, so this assertion passes on macOS either way; it guards the Linux CI leg and the
  # cron recipe in the README.
  rm -f "$repo/profile.draft.yaml"
  printf 'subject:\n  name: no-date-here\n' > "$repo/profile.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_contains "an absent last_bootstrapped is treated as stale" "$out" "treating it as stale"
  assert_contains "so it refreshes instead of skipping forever" "$out" "synthesizing the draft"

  # A FUTURE date parses fine but yields a NEGATIVE age, which is <= any window and so
  # reads as "fresh" - parking the refresh until that date plus the window. With a typo'd
  # year that is a multi-year outage of the exact cadence this agent enforces, and it is
  # silent: every run exits 0 saying there is nothing to do.
  rm -f "$repo/profile.draft.yaml"
  printf 'subject:\n  last_bootstrapped: 2099-06-01\n' > "$repo/profile.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "a future-dated profile exits 0" "0" "$rc"
  assert_contains "a future last_bootstrapped is called out" "$out" "is in the future"
  assert_contains "and is treated as stale, not fresh" "$out" "treating it as stale"
  assert_contains "so the refresh actually runs" "$out" "synthesizing the draft"
  assert_not_contains "it never reports a negative age as within the window" "$out" "d old (<= profile_refresh_days"

  # A draft left behind by a FAILED run must NOT read as "awaiting review". Its mtime
  # looks identical to a good draft's, so without a completion marker one bad night
  # parks the monthly agent forever - silently, since the skip exits 0 and the failure
  # trap never fires again. This is the whole cadence disabling itself.
  rm -f "$repo/profile.draft.yaml" "$repo/state/.draft-complete"
  printf 'subject:\n  last_bootstrapped: 2000-01-01\n' > "$repo/profile.yaml"
  # Backdate it: `-nt` compares whole seconds on bash 3.2, so a profile written in the
  # same second as the draft would tie and read as NOT newer, masking what this tests.
  touch -t 202601010000 "$repo/profile.yaml"
  out="$( cd "$repo" && SYNTH_EXIT=1 HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "the failing refresh exits non-zero" "1" "$rc"
  if [ -f "$repo/profile.draft.yaml" ] && [ "$repo/profile.draft.yaml" -nt "$repo/profile.yaml" ]; then
    pass "the failed run did leave a newer draft behind (the trap this guards)"
  else
    fail "the failed run did leave a newer draft behind (the trap this guards)"
  fi
  if [ -f "$repo/state/.draft-complete" ]; then fail "a failed run leaves no completion marker"; else pass "a failed run leaves no completion marker"; fi
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_not_contains "a failed run's draft is not mistaken for one awaiting review" \
    "$out" "already waiting for review"
  assert_contains "so the next refresh actually runs" "$out" "synthesizing the draft"
  if [ -f "$repo/state/.draft-complete" ]; then pass "a successful run marks the draft reviewable"; else fail "a successful run marks the draft reviewable"; fi

  # ...and with the marker in place, a COMPLETE draft does park it (the good case).
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_contains "a complete draft still parks the refresh" "$out" "already waiting for review"

  # A synthesis that exits 0 without producing a draft is a FAILED run, not a quiet one.
  # Left unchecked it would mark an absent-or-empty draft reviewable and park the monthly
  # refresh on nothing - the same wedge as above, through a clean exit instead of a crash.
  rm -f "$repo/profile.draft.yaml" "$repo/state/.draft-complete"
  printf 'subject:\n  last_bootstrapped: 2000-01-01\n' > "$repo/profile.yaml"
  touch -t 202601010000 "$repo/profile.yaml"
  out="$( cd "$repo" && NO_DRAFT=1 HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "a synthesis that writes no draft fails the run" "1" "$rc"
  assert_contains "and says why" "$out" "produced no usable profile.draft.yaml"
  if [ -f "$repo/state/.draft-complete" ]; then fail "nothing is marked reviewable"; else pass "nothing is marked reviewable"; fi
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_contains "so the next refresh still runs" "$out" "synthesizing the draft"

  # Nonempty is not the same as complete. A synthesis that exits 0 having written only a
  # truncated fragment leaves a file -s is happy with; vouching for that parks the refresh
  # on garbage exactly as an empty draft would.
  rm -f "$repo/profile.draft.yaml" "$repo/state/.draft-complete"
  printf 'subject:\n  last_bootstrapped: 2000-01-01\n' > "$repo/profile.yaml"
  touch -t 202601010000 "$repo/profile.yaml"
  out="$( cd "$repo" && PARTIAL_DRAFT=1 HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "a truncated draft fails the run" "1" "$rc"
  assert_contains "and names the missing field" "$out" "no last_bootstrapped"
  if [ -s "$repo/profile.draft.yaml" ]; then pass "the truncated draft is nonempty (what -s alone would accept)"; else fail "the truncated draft is nonempty (what -s alone would accept)"; fi
  if [ -f "$repo/state/.draft-complete" ]; then fail "a truncated draft is not marked reviewable"; else pass "a truncated draft is not marked reviewable"; fi
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_contains "so the refresh still runs next time" "$out" "synthesizing the draft"

  # ...and one truncated AFTER last_bootstrapped, which the single-field check accepted.
  rm -f "$repo/profile.draft.yaml" "$repo/state/.draft-complete"
  printf 'subject:\n  last_bootstrapped: 2000-01-01\n' > "$repo/profile.yaml"
  touch -t 202601010000 "$repo/profile.yaml"
  out="$( cd "$repo" && PARTIAL_DRAFT=late HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
  assert_eq "a draft truncated after last_bootstrapped also fails" "1" "$rc"
  assert_contains "that draft really does carry last_bootstrapped" \
    "$(cat "$repo/profile.draft.yaml" 2>/dev/null)" "last_bootstrapped"
  if [ -f "$repo/state/.draft-complete" ]; then fail "a late-truncated draft is not marked reviewable"; else pass "a late-truncated draft is not marked reviewable"; fi

  # An UNREADABLE approved profile must not kill the run before the notifier is armed:
  # cfg_get inherits awk's status, so this used to exit under set -e with no trap yet.
  if [ "$(id -u)" != 0 ]; then
    rm -f "$repo/profile.draft.yaml" "$repo/state/.draft-complete"
    printf 'subject:\n  last_bootstrapped: 2000-01-01\n' > "$repo/profile.yaml"
    chmod 000 "$repo/profile.yaml"
    out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"; rc=$?
    chmod 644 "$repo/profile.yaml"
    assert_eq "an unreadable profile does not kill the run" "0" "$rc"
    assert_contains "it is treated as stale rather than dying silently" "$out" "synthesizing the draft"
  fi

  # A previous run's leftover draft must not be adopted: an EMPTY one never parks the
  # gate, and a stale one is cleared at run start so the check means "this run wrote it".
  rm -f "$repo/state/.draft-complete"
  : > "$repo/profile.draft.yaml"
  touch -t 202602010000 "$repo/profile.draft.yaml"
  : > "$repo/state/.draft-complete"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_not_contains "an empty draft never parks the refresh" "$out" "already waiting for review"
  assert_contains "it refreshes over the empty draft" "$out" "synthesizing the draft"

  # Operator opt-out: no refresh window configured -> the agent is a permanent no-op.
  local repo2="$TMP/ifstaleoff" home2="$TMP/ifstalehome2"
  make_fake_bootstrap_repo "$repo2" "$home2"     # config has no governance block
  printf 'subject:\n  last_bootstrapped: 2000-01-01\n' > "$repo2/profile.yaml"
  out="$( cd "$repo2" && HOME="$home2" bash bin/bootstrap.sh --if-stale 2>&1 )"
  assert_contains "no refresh window configured -> permanently off" "$out" "periodic refresh is off"
  assert_not_contains "no claude call when the window is off" "$out" "synthesizing the draft"

  # A human running it by hand is never gated, however fresh the profile is.
  printf 'subject:\n  last_bootstrapped: %s\n' "$(date +%F)" > "$repo/profile.yaml"
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_not_contains "a bare run is never gated" "$out" "--if-stale"
  assert_contains "a bare run always bootstraps" "$out" "synthesizing the draft"

  # An unknown flag is still rejected rather than silently ignored.
  out="$( cd "$repo" && HOME="$home" bash bin/bootstrap.sh --nope 2>&1 )"; rc=$?
  assert_eq "an unknown flag exits 2" "2" "$rc"
  assert_contains "the usage line lists both flags" "$out" "only --resume, --if-stale"
}
test_bootstrap_if_stale

echo "== bootstrap.sh: a failed run emails a failure notice instead of dying silently =="
test_bootstrap_failure_email() {
  local repo="$TMP/bootfail" home="$TMP/boothomefail" out rc msg="$TMP/boot_fail.eml"
  make_fake_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
subject:
  name: "Test Market & Co"
output:
  email_to: "me@example.com"
YAML
  out="$( cd "$repo" && SYNTH_EXIT=7 MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "the failing exit code is preserved" "7" "$rc"
  assert_contains "says it failed, with the code" "$out" "FAILED (exit 7)"
  assert_contains "reports it emailed the notice" "$out" "emailed the failure notice"
  if [ -f "$msg" ]; then
    assert_contains "the Subject says the bootstrap failed" "$(grep -i '^Subject:' "$msg")" "bootstrap FAILED (exit 7)"
    assert_contains "the Subject names the instance" "$(grep -i '^Subject:' "$msg")" "Test Market & Co"
    # The stderr tail is the whole point: a notice with no explanation just moves the
    # silence into the inbox.
    assert_contains "the body carries the bootstrap.err tail" "$(cat "$msg")" "stub synthesis blew up"
    assert_contains "the body says the approved profile is untouched" "$(cat "$msg")" "untouched and still in use"
    assert_contains "the body gives the resume command" "$(cat "$msg")" "bootstrap.sh --resume"
  else
    fail "a failure email was sent"
  fi

  # A failure with no configured recipient must still exit correctly and not blow up
  # inside the handler.
  local repo2="$TMP/bootfailnomail" home2="$TMP/boothomefail2"
  make_fake_bootstrap_repo "$repo2" "$home2"     # config has no output.email_to
  out="$( cd "$repo2" && SYNTH_EXIT=3 HOME="$home2" bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "still exits with the failing code when nobody is configured" "3" "$rc"
  assert_contains "still says it failed" "$out" "FAILED (exit 3)"

  # The trap has to be armed before ANY mutation. A run that cannot create state/ or
  # clear the previous draft - read-only filesystem, a permissions change - dies under
  # set -e, and with the trap installed later that was another silent dead refresh.
  local repo4="$TMP/boottrapearly" home4="$TMP/boothometrap" msg4="$TMP/boot_trap.eml"
  make_fake_bootstrap_repo "$repo4" "$home4"
  cat "$repo/monitor-config.yaml" > "$repo4/monitor-config.yaml"
  rmdir "$repo4/state"
  printf 'not a directory\n' > "$repo4/state"     # so the run's `mkdir -p state` fails
  out="$( cd "$repo4" && MSG_OUT="$msg4" HOME="$home4" bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "a setup failure exits non-zero" "1" "$rc"
  assert_contains "a setup failure is reported, not silent" "$out" "FAILED (exit 1)"
  assert_contains "and still emails the notice" "$out" "emailed the failure notice"

  # A SUCCESSFUL run sends no failure notice - including the run that writes no summary,
  # which used to leave a non-zero status behind as the script's last command.
  local repo3="$TMP/bootok" home3="$TMP/boothomeok" msg3="$TMP/boot_ok.eml"
  make_fake_bootstrap_repo "$repo3" "$home3"
  cat "$repo/monitor-config.yaml" > "$repo3/monitor-config.yaml"
  out="$( cd "$repo3" && NO_SUMMARY=1 MSG_OUT="$msg3" HOME="$home3" bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "a successful run with no summary exits 0" "0" "$rc"
  assert_contains "notes there was no summary to email" "$out" "no profile.draft.summary.md written"
  assert_not_contains "no failure line on a successful run" "$out" "FAILED"
  assert_not_contains "no failure email on a successful run" "$(cat "$msg3" 2>/dev/null)" "bootstrap FAILED"
}
test_bootstrap_failure_email

echo "== bootstrap.sh: models.bootstrap drives --model (else CLI default) =="
test_bootstrap_model() {
  local repo="$TMP/bootmodel" home="$TMP/boothome" out args="$TMP/boot_args"
  make_fake_bootstrap_repo "$repo" "$home"
  out="$( cd "$repo" && CLAUDE_ARGS="$args" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "announces the configured bootstrap model" "$out" "model=opus"
  assert_contains "passes --model opus to claude" "$(cat "$args" 2>/dev/null)" "--model opus"
  local repo2="$TMP/bootnomodel" home2="$TMP/boothome2" args2="$TMP/boot_args2"
  make_fake_bootstrap_repo "$repo2" "$home2" nomodel
  out="$( cd "$repo2" && CLAUDE_ARGS="$args2" HOME="$home2" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "notes the CLI default when bootstrap model unset" "$out" "using CLI default model"
  case "$(cat "$args2" 2>/dev/null)" in
    *--model*) fail "omits --model when unset" ;;
    *) pass "omits --model when unset" ;;
  esac
}
test_bootstrap_model

echo "== bootstrap.sh: budgets.bootstrap_max_turns drives --max-turns (default 80) =="
test_bootstrap_budget_turns() {
  local repo="$TMP/bootbudget" home="$TMP/boothome7" args="$TMP/boot_budget_args"
  make_fake_bootstrap_repo "$repo" "$home"
  ( cd "$repo" && CLAUDE_ARGS="$args" HOME="$home" bash bin/bootstrap.sh >/dev/null 2>&1 )
  assert_contains "no budgets block -> research default --max-turns 80" \
    "$(cat "$args" 2>/dev/null)" "--max-turns 80"
  printf 'budgets:\n  bootstrap_max_turns: 70\n' >> "$repo/monitor-config.yaml"
  ( cd "$repo" && CLAUDE_ARGS="$args" HOME="$home" bash bin/bootstrap.sh >/dev/null 2>&1 )
  assert_contains "budgets.bootstrap_max_turns drives --max-turns" \
    "$(cat "$args" 2>/dev/null)" "--max-turns 70"
}
test_bootstrap_budget_turns

echo "== bootstrap.sh: folds in deduped calibration grades =="
test_bootstrap_feedback() {
  local repo="$TMP/bootfb" home="$TMP/boothome3" out args="$TMP/boot_args3"
  make_fake_bootstrap_repo "$repo" "$home"
  printf '%s\n' \
    '{"timestamp":"2026-06-01T00:00:00Z","id":"abc","verdict":"up"}' \
    '{"timestamp":"2026-06-02T00:00:00Z","id":"abc","verdict":"down"}' \
    '{"timestamp":"2026-06-01T00:00:00Z","id":"xyz","verdict":"up"}' \
    '{"timestamp":"2026-06-03T00:00:00Z","id":"m1","verdict":"missed","url":"https://ex.com/missed-by-monitor"}' \
    > "$repo/state/feedback.jsonl"
  out="$( cd "$repo" && CLAUDE_ARGS="$args" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "folds in deduped calibration grades (3, not 4)" "$out" "including 3 calibration grade"
  assert_contains "passes the calibration block to claude" "$(cat "$args" 2>/dev/null)" "calibration grades"
  assert_contains "a missed-signal report rides along" "$(cat "$args" 2>/dev/null)" "missed-by-monitor"
  assert_contains "the block explains the missed verdict" "$(cat "$args" 2>/dev/null)" "missed = a relevant item"
}
test_bootstrap_feedback

echo "== bootstrap.sh: emails the draft summary when output.email_to is set =="
test_bootstrap_email() {
  local repo="$TMP/bootemail" home="$TMP/boothome4" out msg="$TMP/boot_msg.eml" args="$TMP/boot_email_args"
  make_fake_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
subject:
  name: "Test Market & Co"
output:
  email_to: "me@example.com"
YAML
  out="$( cd "$repo" && CLAUDE_ARGS="$args" MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "the research prompt asks for a review summary" "$(cat "$args" 2>/dev/null)" "review summary"
  assert_contains "reports it emailed the summary" "$out" "emailed the draft summary"
  if [ -f "$msg" ]; then
    assert_contains "subject says the draft is ready for review" "$(grep -i '^Subject:' "$msg")" "profile draft ready for review"
    assert_contains "subject names the monitored subject" "$(grep -i '^Subject:' "$msg")" "Test Market & Co"
    assert_contains "body carries the local cp approval step" "$(cat "$msg")" "cp profile.draft.yaml profile.yaml"
  else
    fail "an email was sent"
  fi
}
test_bootstrap_email

echo "== bootstrap.sh: a refresh writes profile.draft.diff and emails what changed =="
test_bootstrap_refresh_diff() {
  local repo="$TMP/bootdiff" home="$TMP/boothome8" out msg="$TMP/boot_msg4.eml"
  make_fake_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
output:
  email_to: "me@example.com"
YAML
  # An approved profile that differs from the draft the stub claude writes
  # ("derived: {}") -> the refresh path must produce a reviewable diff.
  printf 'derived: {}\nstale_key: to-be-dropped\n' > "$repo/profile.yaml"
  out="$( cd "$repo" && MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "announces the refresh diff" "$out" "refresh diff written to profile.draft.diff"
  assert_contains "the diff file records the dropped line" \
    "$(cat "$repo/profile.draft.diff" 2>/dev/null)" "-stale_key: to-be-dropped"
  assert_contains "the review email carries the what-changed section" \
    "$(cat "$msg" 2>/dev/null)" "What changed vs the approved profile"
  assert_contains "the review email carries the diff body" \
    "$(cat "$msg" 2>/dev/null)" "stale_key: to-be-dropped"
  assert_contains "the final approval hint points at the diff" "$out" "what changed vs the approved profile: profile.draft.diff"

  # First bootstrap (no approved profile): no diff file, no email section.
  local repo2="$TMP/bootdiff2" home2="$TMP/boothome9" msg2="$TMP/boot_msg5.eml"
  make_fake_bootstrap_repo "$repo2" "$home2"
  cat "$repo/monitor-config.yaml" > "$repo2/monitor-config.yaml"
  ( cd "$repo2" && MSG_OUT="$msg2" HOME="$home2" bash bin/bootstrap.sh >/dev/null 2>&1 )
  if [ -f "$repo2/profile.draft.diff" ]; then fail "no diff file on a first bootstrap"; else pass "no diff file on a first bootstrap"; fi
  case "$(cat "$msg2" 2>/dev/null)" in
    *"What changed vs the approved profile"*) fail "no what-changed section on a first bootstrap" ;;
    *) pass "no what-changed section on a first bootstrap" ;;
  esac

  # An identical draft: note it, leave no empty diff file behind.
  local repo3="$TMP/bootdiff3" home3="$TMP/boothome10" out3
  make_fake_bootstrap_repo "$repo3" "$home3"
  printf 'derived: {}\nsubject:\n  last_bootstrapped: 2026-01-01\nrelevance:\n  rubric: test rubric\n' > "$repo3/profile.yaml"   # exactly what the stub drafts
  out3="$( cd "$repo3" && HOME="$home3" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "notes an identical draft" "$out3" "identical to the approved"
  if [ -f "$repo3/profile.draft.diff" ]; then fail "no diff file when draft is identical"; else pass "no diff file when draft is identical"; fi
}
test_bootstrap_refresh_diff

# Seed a feedback log with 12 up/down grades (+ a missed row that must be excluded):
# id01..id05 thumbs-up, id06..id10 thumbs-down (all agree under the canned draft scores),
# id11 a thumbs-up the draft will DROP, id12 a thumbs-down the draft will SURFACE.
seed_backtest_feedback() {  # <file>
  {
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"up","title":"Up item %d","score":0.80}\n' 1 1 1
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"up","title":"Up item %d","score":0.80}\n' 2 2 2
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"up","title":"Up item %d","score":0.80}\n' 3 3 3
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"up","title":"Up item %d","score":0.80}\n' 4 4 4
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"up","title":"Up item %d","score":0.80}\n' 5 5 5
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"down","title":"Down item %d","score":0.20}\n' 6 6 6
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"down","title":"Down item %d","score":0.20}\n' 7 7 7
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"down","title":"Down item %d","score":0.20}\n' 8 8 8
    printf '{"timestamp":"2026-06-01T00:00:0%dZ","id":"id0%d","verdict":"down","title":"Down item %d","score":0.20}\n' 9 9 9
    printf '{"timestamp":"2026-06-01T00:00:10Z","id":"id10","verdict":"down","title":"Down item 10","score":0.20}\n'
    printf '{"timestamp":"2026-06-02T00:00:00Z","id":"id11","verdict":"up","title":"Competitor ships GA","score":0.82}\n'
    printf '{"timestamp":"2026-06-02T00:00:00Z","id":"id12","verdict":"down","title":"Thought-leadership post","score":0.30}\n'
    printf '{"timestamp":"2026-06-02T00:00:00Z","id":"miss1","verdict":"missed","url":"https://ex.com/never-surfaced"}\n'
  } > "$1"
}

# Canned draft scores the backtest stub writes: id01..id10 agree with their verdict,
# id11 (was up) falls to 0.41 -> DROP, id12 (was down) rises to 0.65 -> SURFACE.
BT_CANNED_SCORES='{"id":"id01","draft_score":0.80}
{"id":"id02","draft_score":0.80}
{"id":"id03","draft_score":0.80}
{"id":"id04","draft_score":0.80}
{"id":"id05","draft_score":0.80}
{"id":"id06","draft_score":0.20}
{"id":"id07","draft_score":0.20}
{"id":"id08","draft_score":0.20}
{"id":"id09","draft_score":0.20}
{"id":"id10","draft_score":0.20}
{"id":"id11","draft_score":0.41}
{"id":"id12","draft_score":0.65}'

echo "== bootstrap.sh: a refresh backtests the draft rubric against your grades =="
test_bootstrap_backtest() {
  local repo="$TMP/bootbt" home="$TMP/boothome_bt" out msg="$TMP/boot_bt.eml" args="$TMP/boot_bt_args"
  make_fake_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
  monitor: sonnet
output:
  email_to: "me@example.com"
YAML
  # A refresh (an approved profile exists, differs from the stub's "derived: {}" draft).
  printf 'derived: {}\nold: gone\n' > "$repo/profile.yaml"
  seed_backtest_feedback "$repo/state/feedback.jsonl"
  out="$( cd "$repo" && BT_JSONL="$BT_CANNED_SCORES" BT_ARGS="$args" MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"

  assert_contains "announces the backtest pass on the monitor model" "$out" "re-scoring graded items under the draft rubric (model=sonnet)"
  assert_contains "writes the backtest report" "$out" "backtest report written to profile.draft.backtest.md"
  local md; md="$(cat "$repo/profile.draft.backtest.md" 2>/dev/null)"
  assert_contains "the report leads with the agreement section" "$md" "Backtest vs your grades"
  assert_contains "the report shows the agreement count" "$md" "agrees with your verdict:"
  assert_contains "the report shows the approved-profile baseline" "$md" "approved profile:"
  assert_contains "the report flags one would-drop thumbs-up" "$md" "would now DROP a thumbs-up:  1"
  assert_contains "the dropped item is listed under Would now drop" "$md" "[id11] Competitor ships GA"
  assert_contains "the surfaced thumbs-down is listed" "$md" "[id12] Thought-leadership post"
  assert_contains "the email folds in the backtest after the diff" "$(cat "$msg" 2>/dev/null)" "Backtest vs your grades"
  assert_contains "the final approval hint points at the backtest" "$out" "how the draft rubric scores your graded items: profile.draft.backtest.md"

  # Blindness: the prompt the scorer saw must carry the item ids but NOT the withheld
  # verdict / recorded score JSON fields.
  local prompt; prompt="$(cat "$args" 2>/dev/null)"
  assert_contains "the scoring prompt carries the item ids" "$prompt" "id11"
  case "$prompt" in
    *'"verdict"'*) fail "the scoring prompt withholds the verdict field" ;;
    *) pass "the scoring prompt withholds the verdict field" ;;
  esac
  case "$prompt" in
    *'"score":'*) fail "the scoring prompt withholds the recorded score field" ;;
    *) pass "the scoring prompt withholds the recorded score field" ;;
  esac
  # Blindness is also structural: the scoring pass gets Write only, never Read, so it
  # can't open state/feedback.jsonl to see the withheld verdicts/scores.
  assert_contains "the scoring pass is granted Write only" "$prompt" "--allowedTools Write"
  assert_contains "the scoring pass is denied Read (can't peek at feedback.jsonl)" "$prompt" "--disallowedTools Read,"
  case "$prompt" in
    *"allowedTools Read,Write"*) fail "the scoring pass does not get Read access" ;;
    *) pass "the scoring pass does not get Read access" ;;
  esac
}
test_bootstrap_backtest

echo "== bootstrap.sh: backtest skips on too few grades / when disabled =="
test_bootstrap_backtest_skips() {
  # Fewer than 10 up/down grades -> a note, no backtest files, exit 0.
  local repo="$TMP/bootbt2" home="$TMP/boothome_bt2" out
  make_fake_bootstrap_repo "$repo" "$home"
  printf 'derived: {}\nold: gone\n' > "$repo/profile.yaml"
  printf '{"timestamp":"2026-06-01T00:00:01Z","id":"a","verdict":"up","title":"t","score":0.8}\n' \
    > "$repo/state/feedback.jsonl"
  out="$( cd "$repo" && BT_JSONL="$BT_CANNED_SCORES" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "notes too few grades to backtest" "$out" "too few up/down grades to backtest"
  if [ -f "$repo/profile.draft.backtest.md" ]; then fail "no backtest md on too few grades"; else pass "no backtest md on too few grades"; fi

  # Disabled via relevance.backtest_max_items: 0 (even with plenty of grades).
  local repo2="$TMP/bootbt3" home2="$TMP/boothome_bt3" out2
  make_fake_bootstrap_repo "$repo2" "$home2"
  printf 'version: 1\nmodels:\n  bootstrap: opus\nrelevance:\n  backtest_max_items: 0\n' \
    > "$repo2/monitor-config.yaml"
  printf 'derived: {}\nold: gone\n' > "$repo2/profile.yaml"
  seed_backtest_feedback "$repo2/state/feedback.jsonl"
  out2="$( cd "$repo2" && BT_JSONL="$BT_CANNED_SCORES" HOME="$home2" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "a 0 cap disables the backtest with a note" "$out2" "too few up/down grades to backtest (or backtest disabled)"
  if [ -f "$repo2/profile.draft.backtest.md" ]; then fail "no backtest md when disabled"; else pass "no backtest md when disabled"; fi
}
test_bootstrap_backtest_skips

echo "== bootstrap.sh: a garbage / empty scoring pass is warn-only (draft survives) =="
test_bootstrap_backtest_failsafe() {
  # Stub writes invalid JSON -> render finds no scores -> WARNING, no md, exit 0, draft kept.
  local repo="$TMP/bootbt4" home="$TMP/boothome_bt4" out rc
  make_fake_bootstrap_repo "$repo" "$home"
  printf 'derived: {}\nold: gone\n' > "$repo/profile.yaml"
  seed_backtest_feedback "$repo/state/feedback.jsonl"
  out="$( cd "$repo" && BT_GARBAGE=1 HOME="$home" bash bin/bootstrap.sh 2>&1 )"; rc=$?
  assert_eq "bootstrap still exits 0 on a garbage backtest" "0" "$rc"
  assert_contains "warns the backtest was skipped" "$out" "backtest render failed"
  if [ -f "$repo/profile.draft.backtest.md" ]; then fail "no backtest md on garbage scores"; else pass "no backtest md on garbage scores"; fi
  assert_contains "the draft survives a failed backtest" "$(cat "$repo/profile.draft.yaml" 2>/dev/null)" "derived: {}"

  # Stub writes nothing (empty jsonl) -> the scoring-pass guard skips before render.
  local repo2="$TMP/bootbt5" home2="$TMP/boothome_bt5" out2
  make_fake_bootstrap_repo "$repo2" "$home2"
  printf 'derived: {}\nold: gone\n' > "$repo2/profile.yaml"
  seed_backtest_feedback "$repo2/state/feedback.jsonl"
  out2="$( cd "$repo2" && HOME="$home2" bash bin/bootstrap.sh 2>&1 )"   # BT_JSONL unset -> no file
  assert_contains "warns when the scoring pass writes nothing" "$out2" "backtest scoring pass failed/empty"
  if [ -f "$repo2/profile.draft.backtest.md" ]; then fail "no backtest md when the pass writes nothing"; else pass "no backtest md when the pass writes nothing"; fi
}
test_bootstrap_backtest_failsafe

echo "== bootstrap.sh: the scoring pass is isolated - it can't clobber the draft =="
test_bootstrap_backtest_isolation() {
  local repo="$TMP/bootbt_iso" home="$TMP/boothome_bt_iso" out
  make_fake_bootstrap_repo "$repo" "$home"
  printf 'derived: {}\nold: gone\n' > "$repo/profile.yaml"
  seed_backtest_feedback "$repo/state/feedback.jsonl"
  # The stub both writes valid scores AND tries to overwrite ./profile.draft.yaml; the
  # scratch-dir isolation must keep that write off the real draft.
  out="$( cd "$repo" && BT_JSONL="$BT_CANNED_SCORES" BT_CLOBBER=1 HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "the backtest still produces its report" "$out" "backtest report written"
  case "$(cat "$repo/profile.draft.yaml" 2>/dev/null)" in
    *CLOBBERED*) fail "the scoring pass cannot overwrite the real draft" ;;
    *) pass "the scoring pass cannot overwrite the real draft" ;;
  esac
  assert_contains "the real draft is intact" "$(cat "$repo/profile.draft.yaml" 2>/dev/null)" "derived: {}"
}
test_bootstrap_backtest_isolation

echo "== bootstrap.sh: no backtest on a first bootstrap; stale files are cleaned =="
test_bootstrap_backtest_firstrun() {
  local repo="$TMP/bootbt6" home="$TMP/boothome_bt6" out
  make_fake_bootstrap_repo "$repo" "$home"
  seed_backtest_feedback "$repo/state/feedback.jsonl"   # grades exist but no approved profile
  # Pre-create stale backtest artifacts: a first bootstrap must clean them out.
  printf 'stale\n' > "$repo/profile.draft.backtest.jsonl"
  printf 'stale report\n' > "$repo/profile.draft.backtest.md"
  out="$( cd "$repo" && BT_JSONL="$BT_CANNED_SCORES" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  if [ -f "$repo/profile.draft.backtest.md" ]; then fail "stale backtest md cleaned on a first bootstrap"; else pass "stale backtest md cleaned on a first bootstrap"; fi
  if [ -f "$repo/profile.draft.backtest.jsonl" ]; then fail "stale backtest jsonl cleaned on a first bootstrap"; else pass "stale backtest jsonl cleaned on a first bootstrap"; fi
  case "$out" in
    *backtest*scoring*|*"DROP a thumbs"*) fail "no backtest activity on a first bootstrap" ;;
    *) pass "no backtest activity on a first bootstrap" ;;
  esac
}
test_bootstrap_backtest_firstrun

echo "== backtest.py: prepare blinds the eval set and render computes agreement =="
test_backtest_py() {
  local d="$TMP/btunit"; mkdir -p "$d"
  seed_backtest_feedback "$d/feedback.jsonl"
  # prepare: missed excluded (12 rows, not 13), no verdict/score fields leak.
  local evalset; evalset="$(python3 "$ROOT/bin/dedupe-feedback.py" "$d/feedback.jsonl" \
                      | python3 "$ROOT/bin/backtest.py" prepare --max 60)"
  assert_eq "prepare keeps 12 up/down items (missed excluded)" "12" "$(printf '%s\n' "$evalset" | grep -c .)"
  case "$evalset" in
    *'"verdict"'*) fail "prepare strips the verdict" ;; *) pass "prepare strips the verdict" ;;
  esac
  case "$evalset" in
    *'"score":'*) fail "prepare strips the recorded score" ;; *) pass "prepare strips the recorded score" ;;
  esac
  # cap honored, newest-first selection: --max 11 (>= the floor) drops the single
  # oldest grade (id01) and keeps the newest (id12), emitted oldest-first.
  local capped; capped="$(python3 "$ROOT/bin/dedupe-feedback.py" "$d/feedback.jsonl" \
                    | python3 "$ROOT/bin/backtest.py" prepare --max 11)"
  assert_eq "prepare --max keeps only the newest N" "11" "$(printf '%s\n' "$capped" | grep -c .)"
  assert_contains "the newest grade is kept" "$capped" "id12"
  case "$capped" in
    *'"id01"'*) fail "the oldest grade is dropped by the cap" ;;
    *) pass "the oldest grade is dropped by the cap" ;;
  esac
  # The MIN_GRADES floor applies to the CAPPED set: 12 grades but --max 5 -> skip
  # (a 5-item agreement % would look meaningful from a sample we mean to skip).
  local small; small="$(python3 "$ROOT/bin/dedupe-feedback.py" "$d/feedback.jsonl" \
                        | python3 "$ROOT/bin/backtest.py" prepare --max 5)"
  assert_eq "a cap below the 10-grade floor emits nothing" "0" "$(printf '%s' "$small" | grep -c .)"
  # render: agreement math + the borderline tag (draft 0.57 for an up item, threshold 0.6).
  printf 'relevance:\n  threshold: 0.6\n' > "$d/draft.yaml"
  printf '%s\n' "$BT_CANNED_SCORES" | sed 's/"id11","draft_score":0.41/"id11","draft_score":0.57/' \
    > "$d/scores.jsonl"
  python3 "$ROOT/bin/backtest.py" render --draft "$d/draft.yaml" --feedback "$d/feedback.jsonl" \
    --scores "$d/scores.jsonl" --out "$d/out.md"
  local md; md="$(cat "$d/out.md")"
  assert_contains "render agrees on the 10 concordant items" "$md" "10 / 12"
  assert_contains "render tags a near-threshold flip borderline" "$md" "(borderline)"

  # Out-of-range draft scores (1.2, -0.1) are invalid model output -> counted as not
  # scored, never folded into the agreement/flip arithmetic.
  printf '%s\n' "$BT_CANNED_SCORES" \
    | sed -e 's/"id01","draft_score":0.80/"id01","draft_score":1.2/' \
          -e 's/"id06","draft_score":0.20/"id06","draft_score":-0.1/' > "$d/oor.jsonl"
  python3 "$ROOT/bin/backtest.py" render --draft "$d/draft.yaml" --approved "$d/draft.yaml" \
    --feedback "$d/feedback.jsonl" --scores "$d/oor.jsonl" --out "$d/oor.md"
  assert_contains "out-of-range scores are dropped (10 of 12 scored)" "$(cat "$d/oor.md")" "your 10 graded item"
  assert_contains "the dropped out-of-range items are counted as not scored" "$(cat "$d/oor.md")" "2 graded item(s) were not scored"

  # Baseline uses the APPROVED threshold, not the draft's: an up item recorded at 0.70
  # is correct under approved 0.6 but would look wrong under a raised draft 0.8.
  printf 'relevance:\n  threshold: 0.8\n' > "$d/draft_hi.yaml"
  printf 'relevance:\n  threshold: 0.6\n' > "$d/approved.yaml"
  printf '%s\n' \
    '{"timestamp":"2026-06-01T00:00:01Z","id":"b1","verdict":"up","title":"borderline up","score":0.70}' \
    '{"timestamp":"2026-06-01T00:00:02Z","id":"b2","verdict":"up","title":"u2","score":0.90}' \
    '{"timestamp":"2026-06-01T00:00:03Z","id":"b3","verdict":"up","title":"u3","score":0.90}' \
    '{"timestamp":"2026-06-01T00:00:04Z","id":"b4","verdict":"up","title":"u4","score":0.90}' \
    '{"timestamp":"2026-06-01T00:00:05Z","id":"b5","verdict":"up","title":"u5","score":0.90}' \
    '{"timestamp":"2026-06-01T00:00:06Z","id":"b6","verdict":"down","title":"d6","score":0.10}' \
    '{"timestamp":"2026-06-01T00:00:07Z","id":"b7","verdict":"down","title":"d7","score":0.10}' \
    '{"timestamp":"2026-06-01T00:00:08Z","id":"b8","verdict":"down","title":"d8","score":0.10}' \
    '{"timestamp":"2026-06-01T00:00:09Z","id":"b9","verdict":"down","title":"d9","score":0.10}' \
    '{"timestamp":"2026-06-01T00:00:10Z","id":"b10","verdict":"down","title":"d10","score":0.10}' \
    > "$d/fb_base.jsonl"
  printf '%s\n' \
    '{"id":"b1","draft_score":0.90}' '{"id":"b2","draft_score":0.90}' '{"id":"b3","draft_score":0.90}' \
    '{"id":"b4","draft_score":0.90}' '{"id":"b5","draft_score":0.90}' '{"id":"b6","draft_score":0.10}' \
    '{"id":"b7","draft_score":0.10}' '{"id":"b8","draft_score":0.10}' '{"id":"b9","draft_score":0.10}' \
    '{"id":"b10","draft_score":0.10}' > "$d/sc_base.jsonl"
  python3 "$ROOT/bin/backtest.py" render --draft "$d/draft_hi.yaml" --approved "$d/approved.yaml" \
    --feedback "$d/fb_base.jsonl" --scores "$d/sc_base.jsonl" --out "$d/base.md"
  assert_contains "baseline uses the approved threshold (0.70 up still agrees)" \
    "$(cat "$d/base.md")" "approved profile: 10 / 10"

  # prepare derives `source` from the URL host when a grade has no recorded source
  # (older grades predate record_grade persisting it), so the rubric isn't starved of
  # domain context. Exercise the helper directly (run from bin/ so it imports).
  local derived; derived="$(cd "$ROOT/bin" && printf '%s' '{"url":"https://www.theverge.com/a"}' \
    | python3 -c 'import sys,json,backtest; print(backtest._source(json.loads(sys.stdin.read())) or "")')"
  assert_eq "source is derived from the URL host" "theverge.com" "$derived"

  # render's universe is the prepared EVAL set, not the whole feedback log: a grade
  # capped out of the eval set must NOT be reported as "not scored".
  python3 "$ROOT/bin/dedupe-feedback.py" "$d/feedback.jsonl" \
    | python3 "$ROOT/bin/backtest.py" prepare --max 11 > "$d/eval11.jsonl"
  python3 - "$d/eval11.jsonl" "$d/sc11.jsonl" <<'PY'
import json, sys
ids = [json.loads(l)["id"] for l in open(sys.argv[1])]
with open(sys.argv[2], "w") as f:
    for i in ids:
        f.write(json.dumps({"id": i, "draft_score": 0.8}) + "\n")
PY
  python3 "$ROOT/bin/backtest.py" render --draft "$d/draft.yaml" --approved "$d/draft.yaml" \
    --feedback "$d/feedback.jsonl" --eval "$d/eval11.jsonl" --scores "$d/sc11.jsonl" --out "$d/eval.md"
  assert_contains "render counts only the 11 prepared items" "$(cat "$d/eval.md")" "your 11 graded item"
  case "$(cat "$d/eval.md")" in
    *"not scored"*) fail "capped-out grades are not reported as not scored" ;;
    *) pass "capped-out grades are not reported as not scored" ;;
  esac
}
test_backtest_py

echo "== bootstrap.sh: editorial pass polishes the summary when models.editor is set =="
test_bootstrap_editor() {
  local repo="$TMP/booted" home="$TMP/boothome5" out ed="$TMP/boot_ed" msg="$TMP/boot_msg2.eml"
  make_fake_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
  editor: opus
output:
  email_to: "me@example.com"
YAML
  out="$( cd "$repo" && ED_MARKER="$ed" ED_REWRITE=1 MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  if [ -f "$ed" ]; then pass "editorial pass invoked on the summary"; else fail "editorial pass invoked on the summary"; fi
  assert_contains "announces the editorial pass" "$out" "editorial pass on the summary"
  assert_contains "the edited summary is what gets emailed" "$(cat "$msg" 2>/dev/null)" "edited summary"
}
test_bootstrap_editor

echo "== bootstrap.sh: a failed summary edit keeps + emails the unedited summary =="
test_bootstrap_editor_failure() {
  local repo="$TMP/bootedfail" home="$TMP/boothome6" out msg="$TMP/boot_msg3.eml"
  make_fake_bootstrap_repo "$repo" "$home"
  cat > "$repo/monitor-config.yaml" <<YAML
version: 1
models:
  bootstrap: opus
  editor: opus
output:
  email_to: "me@example.com"
YAML
  out="$( cd "$repo" && ED_EXIT=1 MSG_OUT="$msg" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "warns the editorial pass failed" "$out" "editorial pass failed"
  assert_contains "still emails the unedited summary" "$(cat "$msg" 2>/dev/null)" "Profile draft summary"
}
test_bootstrap_editor_failure

# An isolated init.sh checkout: the wizard + config-lib, the example template, and
# the samples (incl. their README, which feeds the template menu). A stub `claude`
# goes under the fake HOME's .npm-global/bin, which init.sh PREPENDS to PATH - so
# the stub wins over any real claude (no network call). The stub's review behavior
# is driven by $INIT_REVIEW: ok (default) writes a suggested config that bumps
# relevance.threshold 0.6 -> 0.7; fail/empty/invalid exercise the fail-safe paths.
make_fake_init_repo() {  # <repo> <home>
  local repo="$1" home="$2"
  mkdir -p "$repo/bin" "$repo/samples" "$home/.npm-global/bin"
  cp "$ROOT/bin/init.sh" "$ROOT/bin/config-lib.sh" "$repo/bin/"
  cp "$ROOT/monitor-config.example.yaml" "$repo/"
  cp "$ROOT"/samples/*.yaml "$ROOT/samples/README.md" "$repo/samples/"
  cat > "$home/.npm-global/bin/claude" <<'SH'
#!/usr/bin/env bash
[ -n "${CLAUDE_RAN:-}" ] && : > "$CLAUDE_RAN"
[ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
case "${INIT_REVIEW:-ok}" in
  fail)    exit 1 ;;
  empty)   : > .init.suggested.yaml ;;
  invalid) printf 'not: a config\n' > .init.suggested.yaml ;;
  tamper)  # a misbehaving review: edits the DRAFT in place AND writes a suggestion
           sed 's/^  threshold: 0.6/  threshold: 0.9/' .init.draft.yaml > .init.t && mv .init.t .init.draft.yaml
           sed 's/^  threshold: 0.9/  threshold: 0.7/' .init.draft.yaml > .init.suggested.yaml ;;
  *)       sed 's/^  threshold: 0.6/  threshold: 0.7/' .init.draft.yaml > .init.suggested.yaml
           echo "- suggested raising the relevance threshold" ;;
esac
exit 0
SH
  chmod +x "$home/.npm-global/bin/claude"
}

# On the example template (which has an anchor competitors key) the wizard asks 13
# questions before the review prompt; init_blanks emits 13 blank answers (= keep
# every template value) followed by the given review/apply/bootstrap answers.
init_blanks() { printf '%s\n' '' '' '' '' '' '' '' '' '' '' '' '' '' "$@"; }

echo "== init.sh: an all-defaults run writes a valid config offline (no claude) =="
test_init_defaults() {
  local repo="$TMP/initdef" home="$TMP/inithome1" rc marker="$TMP/init_ran1"
  make_fake_init_repo "$repo" "$home"
  # EOF on every question = keep every default; the wizard must finish offline.
  ( CLAUDE_RAN="$marker" HOME="$home" bash "$repo/bin/init.sh" </dev/null >/dev/null 2>&1 ); rc=$?
  assert_eq "all-defaults run exits 0" "0" "$rc"
  if [ ! -f "$repo/monitor-config.yaml" ]; then fail "config written"; return; fi
  pass "config written"
  assert_config_structure "init defaults" "$repo/monitor-config.yaml"
  assert_eq "subject.name keeps the template's value" \
    "Enterprise AI platforms & LLM products" "$(cfg_get_text subject name "$repo/monitor-config.yaml")"
  assert_contains "template comments are preserved" \
    "$(cat "$repo/monitor-config.yaml")" "Trusted seeds"
  assert_contains "empty derived: blocks survive untouched" \
    "$(cat "$repo/monitor-config.yaml")" "key_players: []"
  if [ -f "$marker" ]; then fail "claude is NOT invoked when the review is skipped"; else pass "claude is NOT invoked when the review is skipped"; fi
  if ls "$repo"/.init.* >/dev/null 2>&1; then fail "no temp drafts left behind"; else pass "no temp drafts left behind"; fi
}
test_init_defaults

echo "== init.sh: refuses to overwrite an existing config unless --force =="
test_init_overwrite_guard() {
  local repo="$TMP/initguard" home="$TMP/inithome2" rc out
  make_fake_init_repo "$repo" "$home"
  printf 'sentinel: 1\n' > "$repo/monitor-config.yaml"
  out="$( HOME="$home" bash "$repo/bin/init.sh" </dev/null 2>&1 )"; rc=$?
  assert_eq "refuses with exit 1" "1" "$rc"
  assert_contains "names the --force escape hatch" "$out" "--force"
  assert_eq "existing config left untouched" "sentinel: 1" "$(cat "$repo/monitor-config.yaml")"
  ( HOME="$home" bash "$repo/bin/init.sh" --force </dev/null >/dev/null 2>&1 ); rc=$?
  assert_eq "--force run exits 0" "0" "$rc"
  assert_contains "--force overwrites the old config" \
    "$(cat "$repo/monitor-config.yaml")" "Enterprise AI platforms"
  ( HOME="$home" bash "$repo/bin/init.sh" --bogus </dev/null >/dev/null 2>&1 ); rc=$?
  assert_eq "an unknown argument exits 2" "2" "$rc"
  ( HOME="$home" bash "$repo/bin/init.sh" --help </dev/null >/dev/null 2>&1 ); rc=$?
  assert_eq "--help exits 0" "0" "$rc"
}
test_init_overwrite_guard

echo "== init.sh: answers with & / ' / \" / # round-trip through the cfg readers =="
test_init_quoting() {
  local repo="$TMP/initquote" home="$TMP/inithome3" rc out cfg
  make_fake_init_repo "$repo" "$home"
  out="$( printf '%s\n' \
      '1' \
      'R&D "skunk" works'\'' #1' \
      'Tracks Bob'\''s market & "niche" #1 stuff' \
      'notaurl' \
      'https://ex.example/a?b=1&c=2' \
      '' \
      'pricing & "packaging", C# tools' \
      "job postings, vendor's \"fluff\"" \
      "Bob's Watches & Co" \
      'Individual' \
      'buyer & builder' \
      "Acme \"A\" & Co, O'Brien #2" \
      'nope' \
      'me@example.com' \
      'ftp://bad' \
      'https://hooks.example.com/h?t=1' \
      'AI Models' \
      'n' \
      'n' \
    | HOME="$home" bash "$repo/bin/init.sh" 2>&1 )"; rc=$?
  assert_eq "run exits 0" "0" "$rc"
  cfg="$repo/monitor-config.yaml"
  if [ ! -f "$cfg" ]; then fail "config written"; return; fi
  assert_config_structure "init quoting" "$cfg"
  # Exactly what was typed must read back through the readers the agents use.
  assert_eq "subject.name round-trips (& \" ' #)" 'R&D "skunk" works'\'' #1' "$(cfg_get_text subject name "$cfg")"
  assert_eq "anchor.name round-trips (')" "Bob's Watches & Co" "$(cfg_get_text anchor name "$cfg")"
  assert_eq "anchor.type is normalized to lowercase" "individual" "$(cfg_get anchor type "$cfg")"
  assert_eq "relationship_to_subject round-trips (&)" "buyer & builder" "$(cfg_get_text anchor relationship_to_subject "$cfg")"
  assert_eq "output.email_to set (after one re-prompt)" "me@example.com" "$(cfg_get output email_to "$cfg")"
  assert_eq "output.webhook_url set (after rejecting ftp://)" "https://hooks.example.com/h?t=1" "$(cfg_get output webhook_url "$cfg")"
  assert_eq "deployment.instance round-trips with a space" "AI Models" "$(cfg_get_text deployment instance "$cfg")"
  assert_contains "rejects a non-URL seed with a note" "$out" "not an http(s) URL"
  assert_contains "the valid seed lands in the seeds list" "$(cat "$cfg")" "- https://ex.example/a?b=1&c=2"
  case "$(cat "$cfg")" in
    *notaurl*) fail "the rejected seed stays out of the config" ;;
    *) pass "the rejected seed stays out of the config" ;;
  esac
  assert_contains "scope in is a quoted flow list" "$(cat "$cfg")" 'in: ["pricing & \"packaging\"", "C# tools"]'
  assert_contains "scope out is a quoted flow list" "$(cat "$cfg")" 'out: ["job postings", "vendor'\''s \"fluff\""]'
  assert_contains "competitors are quoted" "$(cat "$cfg")" 'competitors: ["Acme \"A\" & Co", "O'\''Brien #2"]'
  assert_contains "tracking.watch placeholder retargeted to competitor 1" \
    "$(cat "$cfg")" 'entity: "Acme \"A\" & Co"'
  assert_contains "derived blocks still empty after substitution" "$(cat "$cfg")" "news_sources: []"
}
test_init_quoting

echo "== init.sh: builds from a sample; skips the competitors question when absent =="
test_init_samples() {
  local repo="$TMP/initsample" home="$TMP/inithome4" rc cfg
  make_fake_init_repo "$repo" "$home"
  # Menu order: 1 example, then the samples/README.md table order (2 ai-frontier,
  # 3 devtools, 4 oss, 5 policy). devtools has a competitors key -> 13 questions.
  ( printf '%s\n' '3' '' '' '' '' '' '' '' '' 'X CLI, Y IDE' '' '' '' 'n' 'n' \
    | HOME="$home" bash "$repo/bin/init.sh" >/dev/null 2>&1 ); rc=$?
  assert_eq "devtools sample run exits 0" "0" "$rc"
  cfg="$repo/monitor-config.yaml"
  assert_eq "subject.name comes from the chosen sample" \
    "AI coding assistants & developer tools" "$(cfg_get_text subject name "$cfg")"
  assert_contains "competitors substituted" "$(cat "$cfg")" 'competitors: ["X CLI", "Y IDE"]'
  assert_contains "watch placeholder A retargeted" "$(cat "$cfg")" 'entity: "X CLI"'
  assert_contains "watch placeholder B retargeted" "$(cat "$cfg")" 'entity: "Y IDE"'
  # oss-dependency-watch has NO competitors key -> 12 questions; if the wizard asked
  # anyway, the answer stream would desync and the email would land in the wrong slot.
  ( printf '%s\n' '4' '' '' '' '' '' '' '' '' 'me@x.example' 'https://hooks.example/h' '' 'n' 'n' \
    | HOME="$home" bash "$repo/bin/init.sh" --force >/dev/null 2>&1 ); rc=$?
  assert_eq "oss sample run exits 0" "0" "$rc"
  assert_eq "competitors question skipped (email lands in its slot)" \
    "me@x.example" "$(cfg_get output email_to "$cfg")"
  assert_eq "webhook_url inserted into a sample that lacks the key" \
    "https://hooks.example/h" "$(cfg_get output webhook_url "$cfg")"
  assert_config_structure "init oss sample" "$cfg"
}
test_init_samples

echo "== init.sh: review suggestions apply only on yes; failures never lose the draft =="
test_init_review() {
  local repo="$TMP/initreview" home="$TMP/inithome5" rc out args="$TMP/init_args"
  make_fake_init_repo "$repo" "$home"
  # Accepted: review y, apply y -> the stub's threshold bump lands in the config.
  out="$( init_blanks y y n | CLAUDE_ARGS="$args" HOME="$home" bash "$repo/bin/init.sh" 2>&1 )"; rc=$?
  assert_eq "accepted-review run exits 0" "0" "$rc"
  assert_eq "approved suggestion is applied" "0.7" "$(cfg_get relevance threshold "$repo/monitor-config.yaml")"
  assert_contains "shows the suggestions as a diff" "$out" "threshold: 0.7"
  # Model resolution: models.init is commented in the template -> bootstrap model.
  assert_contains "notes the models.init fallback" "$out" "models.init not set"
  assert_contains "review runs on the bootstrap model" "$(cat "$args" 2>/dev/null)" "--model opus"
  assert_contains "budgets.init_max_turns drives --max-turns" "$(cat "$args" 2>/dev/null)" "--max-turns 15"
  # Rejected: review y, apply n -> the draft ships as answered.
  ( init_blanks y n n | HOME="$home" bash "$repo/bin/init.sh" --force >/dev/null 2>&1 ); rc=$?
  assert_eq "rejected-review run exits 0" "0" "$rc"
  assert_eq "rejected suggestion is NOT applied" "0.6" "$(cfg_get relevance threshold "$repo/monitor-config.yaml")"
  # Failed / empty / invalid review: warn and keep the assembled config intact.
  local mode
  for mode in fail empty invalid; do
    out="$( init_blanks y n | INIT_REVIEW="$mode" HOME="$home" bash "$repo/bin/init.sh" --force 2>&1 )"; rc=$?
    assert_eq "a $mode review still exits 0" "0" "$rc"
    assert_contains "a $mode review warns and keeps the draft" "$out" "keeping your draft"
    assert_eq "config still written after a $mode review" \
      "0.6" "$(cfg_get relevance threshold "$repo/monitor-config.yaml")"
  done
  # A review agent that edits the draft IN PLACE (it has Write access) must not be
  # able to bypass the apply-on-yes gate: rejecting ships the operator's untampered
  # draft, and accepting applies only the suggestion file.
  ( init_blanks y n n | INIT_REVIEW=tamper HOME="$home" bash "$repo/bin/init.sh" --force >/dev/null 2>&1 ); rc=$?
  assert_eq "tampering-review run exits 0" "0" "$rc"
  assert_eq "a direct draft edit is reverted when suggestions are rejected" \
    "0.6" "$(cfg_get relevance threshold "$repo/monitor-config.yaml")"
  ( init_blanks y y n | INIT_REVIEW=tamper HOME="$home" bash "$repo/bin/init.sh" --force >/dev/null 2>&1 )
  assert_eq "accepting applies the suggestion file, not the draft edit" \
    "0.7" "$(cfg_get relevance threshold "$repo/monitor-config.yaml")"
  if ls "$repo"/.init.* >/dev/null 2>&1; then fail "no suggestion/draft files left behind"; else pass "no suggestion/draft files left behind"; fi
}
test_init_review

echo "== init.sh: models.init drives the review model when set (else CLI default) =="
test_init_review_model() {
  local repo="$TMP/initmodel" home="$TMP/inithome6" out args="$TMP/init_args2"
  make_fake_init_repo "$repo" "$home"
  # Activate models.init in the template (portable sed: pure s///, reusing the
  # commented deepdive line's slot inside the models block).
  sed 's/^  # deepdive: opus.*/  init: custominit/' "$repo/monitor-config.example.yaml" \
    > "$repo/c.tmp" && mv "$repo/c.tmp" "$repo/monitor-config.example.yaml"
  out="$( init_blanks y n n | CLAUDE_ARGS="$args" HOME="$home" bash "$repo/bin/init.sh" 2>&1 )"
  assert_contains "models.init drives --model" "$(cat "$args" 2>/dev/null)" "--model custominit"
  case "$out" in
    *"models.init not set"*) fail "no fallback note when models.init is set" ;;
    *) pass "no fallback note when models.init is set" ;;
  esac
  # Neither models.init nor models.bootstrap -> CLI default, with a note.
  local repo2="$TMP/initmodel2" home2="$TMP/inithome7" args2="$TMP/init_args3"
  make_fake_init_repo "$repo2" "$home2"
  sed '/^  bootstrap: opus/d' "$repo2/monitor-config.example.yaml" \
    > "$repo2/c.tmp" && mv "$repo2/c.tmp" "$repo2/monitor-config.example.yaml"
  out="$( init_blanks y n n | CLAUDE_ARGS="$args2" HOME="$home2" bash "$repo2/bin/init.sh" 2>&1 )"
  assert_contains "notes the CLI-default fallback" "$out" "using CLI default model"
  case "$(cat "$args2" 2>/dev/null)" in
    *--model*) fail "omits --model when no model is configured" ;;
    *) pass "omits --model when no model is configured" ;;
  esac
}
test_init_review_model

echo "== init.sh: offers bootstrap at the end but never auto-runs it =="
test_init_bootstrap_offer() {
  local repo="$TMP/initboot" home="$TMP/inithome8" out
  make_fake_init_repo "$repo" "$home"
  printf '#!/usr/bin/env bash\necho BOOTSTRAP_STUB_RAN\n' > "$repo/bin/bootstrap.sh"
  chmod +x "$repo/bin/bootstrap.sh"
  out="$( init_blanks n n | HOME="$home" bash "$repo/bin/init.sh" 2>&1 )"
  case "$out" in
    *BOOTSTRAP_STUB_RAN*) fail "bootstrap NOT run when declined" ;;
    *) pass "bootstrap NOT run when declined" ;;
  esac
  assert_contains "prints the bootstrap next step instead" "$out" "./bin/bootstrap.sh"
  out="$( init_blanks n y | HOME="$home" bash "$repo/bin/init.sh" --force 2>&1 )"
  assert_contains "an explicit yes runs bootstrap" "$out" "BOOTSTRAP_STUB_RAN"
}
test_init_bootstrap_offer

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
