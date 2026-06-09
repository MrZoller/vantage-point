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

echo "== install-launchd uninstall: removes both agents =="
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
  if [ -f "$la/ai.zoller.vantagepoint.daily.plist" ] || [ -f "$la/ai.zoller.vantagepoint.weekly.plist" ]; then
    fail "uninstall removed both plists"
  else
    pass "uninstall removed both plists"
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
    sed 's#'"$co"'/bin/monitor.sh#/moved/elsewhere/bin/monitor.sh#' "$p" > "$p.tmp" && mv "$p.tmp" "$p"
  done
  ( HOME="$home" PATH="$co/stub:$PATH" bash "$co/bin/install-launchd.sh" uninstall >/dev/null 2>&1 ); rc=$?
  assert_eq "uninstall exits 0 after a move" "0" "$rc"
  if [ -f "$la/ai.zoller.vantagepoint.mover.daily.plist" ]; then fail "the marker-recorded labels are removed after a move"; else pass "the marker-recorded labels are removed after a move"; fi
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
    email_report to@example.com "$report" )
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
    email_report to@example.com "$report" )
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
}
test_email_helpers

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
test_sample_configs() {
  # shellcheck source=bin/config-lib.sh
  source "$ROOT/bin/config-lib.sh"
  local s name blk missing
  # The annotated reference config is validated alongside the samples so its example
  # values stay shell-readable and complete.
  for s in "$ROOT"/monitor-config.example.yaml "$ROOT"/samples/*.yaml; do
    [ -e "$s" ] || { fail "no sample configs found"; return; }
    name="$(basename "$s")"
    if [ -n "$(cfg_get models monitor "$s")" ];      then pass "$name: models.monitor set";     else fail "$name: models.monitor set";     fi
    if [ -n "$(cfg_get_text subject name "$s")" ];   then pass "$name: subject.name set";        else fail "$name: subject.name set";        fi
    if [ -n "$(cfg_get_text anchor name "$s")" ];    then pass "$name: anchor.name set";         else fail "$name: anchor.name set";         fi
    if [ -n "$(cfg_get relevance threshold "$s")" ]; then pass "$name: relevance.threshold set"; else fail "$name: relevance.threshold set"; fi
    missing=""
    for blk in subject anchor relevance monitoring tracking output governance; do
      grep -q "^$blk:" "$s" || missing="$missing $blk"
    done
    if [ -z "$missing" ]; then pass "$name: all top-level blocks present"; else fail "$name: missing blocks:$missing"; fi
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
  local repo="$1" lastboot="${2:-2099-01-01}" run_timeout="${3:-0}" email_to="${4:-}"
  mkdir -p "$repo/bin" "$repo/state" "$repo/kb" "$repo/stub"
  cp "$ROOT/bin/monitor.sh" "$ROOT/bin/portal.py" "$repo/bin/"; cp_libs "$repo/bin"
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
  make_fake_repo "$repo" "2099-01-01" 1800     # run_timeout_seconds = 1800 (> 0)
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
  make_fake_repo "$repo" "2099-01-01" 1800
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
  curl -s -o /dev/null "http://127.0.0.1:$port/grade?id=abc123&v=up" || true
  kill "$srv" 2>/dev/null || true
  assert_contains "a grade is recorded to feedback.jsonl" "$(cat "$repo/state/feedback.jsonl" 2>/dev/null)" '"verdict": "up"'
  assert_contains "the grade captures the item id" "$(cat "$repo/state/feedback.jsonl" 2>/dev/null)" '"id": "abc123"'
}
test_portal_server

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
      "$(grep -i '^Subject:' "$msg")" "[Vantage Point: Test Market & Co]"
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

# An isolated bootstrap.sh checkout with a stub `claude`. The stub is installed under
# the fake HOME's .npm-global/bin, which bootstrap.sh PREPENDS to PATH - so it wins
# over any real claude on the host, keeping the test hermetic (no network call).
make_fake_bootstrap_repo() {  # <repo> <home> [nomodel]
  local repo="$1" home="$2"
  mkdir -p "$repo/bin" "$repo/state" "$home/.npm-global/bin"
  cp "$ROOT/bin/bootstrap.sh" "$ROOT/bin/dedupe-feedback.py" "$repo/bin/"; cp_libs "$repo/bin"
  if [ "${3:-}" = nomodel ]; then
    printf 'version: 1\nmodels:\n  monitor: sonnet\n' > "$repo/monitor-config.yaml"
  else
    printf 'version: 1\nmodels:\n  bootstrap: opus\n' > "$repo/monitor-config.yaml"
  fi
  printf 'bootstrap prompt (test fixture)\n' > "$repo/bootstrap-prompt.md"
  # Stub claude: the research call writes the draft + a summary and records its args;
  # the editorial call (prompt names a PROFILE-DRAFT SUMMARY) edits the summary per env.
  cat > "$home/.npm-global/bin/claude" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"PROFILE-DRAFT SUMMARY"*)
    [ -n "${ED_MARKER:-}" ] && echo ran >> "$ED_MARKER"
    [ -n "${ED_EMPTY:-}" ]   && : > profile.draft.summary.md
    [ -n "${ED_REWRITE:-}" ] && printf '# edited summary\nbottom line\n' > profile.draft.summary.md
    exit "${ED_EXIT:-0}" ;;
  *)
    [ -n "${CLAUDE_ARGS:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS"
    printf 'derived: {}\n' > profile.draft.yaml
    printf '# Profile draft summary\nbottom line: test market\n' > profile.draft.summary.md
    exit 0 ;;
esac
SH
  chmod +x "$home/.npm-global/bin/claude"
  write_capture_msmtp "$home/.npm-global/bin/msmtp"
}

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

echo "== bootstrap.sh: folds in deduped calibration grades =="
test_bootstrap_feedback() {
  local repo="$TMP/bootfb" home="$TMP/boothome3" out args="$TMP/boot_args3"
  make_fake_bootstrap_repo "$repo" "$home"
  printf '%s\n' \
    '{"timestamp":"2026-06-01T00:00:00Z","id":"abc","verdict":"up"}' \
    '{"timestamp":"2026-06-02T00:00:00Z","id":"abc","verdict":"down"}' \
    '{"timestamp":"2026-06-01T00:00:00Z","id":"xyz","verdict":"up"}' > "$repo/state/feedback.jsonl"
  out="$( cd "$repo" && CLAUDE_ARGS="$args" HOME="$home" bash bin/bootstrap.sh 2>&1 )"
  assert_contains "folds in deduped calibration grades (2, not 3)" "$out" "including 2 calibration grade"
  assert_contains "passes the calibration block to claude" "$(cat "$args" 2>/dev/null)" "calibration grades"
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

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
