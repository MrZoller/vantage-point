#!/usr/bin/env bash
# install-launchd.sh [uninstall] — (re)install the daily + weekly launchd agents
# WITHOUT editing anything tracked in the repo.
#
# It generates the real plists from the launchd/*.plist templates into
# ~/Library/LaunchAgents, substituting this checkout's absolute path for the
# __MM_ROOT__ token, then loads them. The committed templates are never touched,
# so a fresh clone stays clean and `git status` never shows local plist edits.
#
#   ./bin/install-launchd.sh            # install / reinstall both agents
#   ./bin/install-launchd.sh uninstall  # unload + remove both agents
set -euo pipefail

# Make ${var//pat/repl} a strictly literal replace on every bash. Bash 5.2
# otherwise treats '&' in the replacement as the matched text (patsub_replacement),
# which would corrupt a checkout path containing '&'. No-op on bash < 5.2.
shopt -u patsub_replacement 2>/dev/null || true

# Project root = parent of this script's bin/ dir. This is what gets baked into
# the generated plists, so the schedules always point at THIS checkout.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LA_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
LABELS=(ai.zoller.marketmonitor.daily ai.zoller.marketmonitor.weekly)

command -v launchctl >/dev/null 2>&1 || {
  echo "launchctl not found — launchd is macOS-only. On Linux use cron (see README)." >&2
  exit 1
}

uninstall() {
  for label in "${LABELS[@]}"; do
    launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
    rm -f "$LA_DIR/$label.plist"
    echo "[install-launchd] removed $label"
  done
}

if [ "${1:-}" = "uninstall" ]; then
  uninstall
  exit 0
fi

mkdir -p "$LA_DIR" "$ROOT/state"
for label in "${LABELS[@]}"; do
  src="$ROOT/launchd/$label.plist"
  dst="$LA_DIR/$label.plist"
  [ -f "$src" ] || { echo "missing template $src" >&2; exit 1; }

  # XML-escape the path before injecting it, so a checkout path containing &, <
  # or > still produces a valid plist (otherwise launchd installs a broken agent).
  # Escape & first, or it would re-escape the & in the entities added afterwards.
  root_xml="$ROOT"
  root_xml="${root_xml//&/&amp;}"
  root_xml="${root_xml//</&lt;}"
  root_xml="${root_xml//>/&gt;}"
  template="$(cat "$src")"
  printf '%s\n' "${template//__MM_ROOT__/$root_xml}" > "$dst"

  # Catch a malformed plist before launchd does (no-op if plutil is absent).
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$dst" >/dev/null || { echo "generated $dst is not valid plist" >&2; exit 1; }
  fi

  # Reload idempotently: unload an existing copy (ignore "not loaded"), then load.
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$dst"
  echo "[install-launchd] installed $label -> $dst"
done

echo "[install-launchd] done. Kick a run now to confirm wiring:"
echo "  launchctl kickstart -k $DOMAIN/ai.zoller.marketmonitor.daily"
