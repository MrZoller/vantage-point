#!/usr/bin/env bash
# install-launchd.sh [uninstall] - (re)install the daily + weekly launchd agents
# WITHOUT editing anything tracked in the repo.
#
# It generates the real plists from the launchd/*.plist templates into
# ~/Library/LaunchAgents, substituting this checkout's absolute path for __VP_ROOT__
# and the agent label for __VP_LABEL__, then loads them. The committed templates are
# never touched, so a fresh clone stays clean and `git status` never shows local edits.
#
# Multiple instances on one machine: give each checkout a distinct
# `deployment.instance` in its monitor-config.yaml and the agent labels/filenames are
# namespaced (ai.zoller.vantagepoint.<instance>.{daily,weekly}) so clones don't
# collide. Leave it unset for a single deployment (labels stay un-suffixed).
#
#   ./bin/install-launchd.sh            # install / reinstall this instance's agents
#   ./bin/install-launchd.sh uninstall  # unload + remove this instance's agents
set -euo pipefail

# Make ${var//pat/repl} a strictly literal replace on every bash. Bash 5.2
# otherwise treats '&' in the replacement as the matched text (patsub_replacement),
# which would corrupt a checkout path containing '&'. No-op on bash < 5.2.
shopt -u patsub_replacement 2>/dev/null || true

# Project root = parent of this script's bin/ dir. This is what gets baked into
# the generated plists, so the schedules always point at THIS checkout.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/config-lib.sh
. "$ROOT/bin/config-lib.sh"
LA_DIR="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"

command -v launchctl >/dev/null 2>&1 || {
  echo "launchctl not found - launchd is macOS-only. On Linux use cron (see README)." >&2
  exit 1
}

# Optional per-instance namespace from the config (so multiple clones coexist).
# Slugify to a safe label segment: lowercase, non-[a-z0-9-] -> '-', trim dashes.
INSTANCE=""
if [ -f "$ROOT/monitor-config.yaml" ]; then
  INSTANCE="$(cfg_get_text deployment instance "$ROOT/monitor-config.yaml")"
  INSTANCE="$(printf '%s' "$INSTANCE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//')"
fi
if [ -n "$INSTANCE" ]; then
  PREFIX="ai.zoller.vantagepoint.$INSTANCE"
else
  PREFIX="ai.zoller.vantagepoint"
fi
LABELS=("$PREFIX.daily" "$PREFIX.weekly")

remove_label() {  # bootout (ignore "not loaded") + delete the plist
  launchctl bootout "$DOMAIN/$1" 2>/dev/null || true
  rm -f "$LA_DIR/$1.plist"
}

# Retire pre-rename (market-monitor) agents so they can't fire alongside the renamed
# ones. Only for the DEFAULT (un-suffixed) instance - those legacy agents belong to
# the original single deployment, not to a named instance.
if [ -z "$INSTANCE" ]; then
  for label in ai.zoller.marketmonitor.daily ai.zoller.marketmonitor.weekly; do
    if [ -f "$LA_DIR/$label.plist" ]; then
      remove_label "$label"
      echo "[install-launchd] retired legacy agent $label"
    fi
  done
fi

uninstall() {
  for label in "${LABELS[@]}"; do
    remove_label "$label"
    echo "[install-launchd] removed $label"
  done
}

if [ "${1:-}" = "uninstall" ]; then
  uninstall
  exit 0
fi

mkdir -p "$LA_DIR" "$ROOT/state"
# Iterate modes (template filenames are fixed); the label is namespaced per instance.
for mode in daily weekly; do
  label="$PREFIX.$mode"
  src="$ROOT/launchd/ai.zoller.vantagepoint.$mode.plist"
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
  template="${template//__VP_ROOT__/$root_xml}"
  template="${template//__VP_LABEL__/$label}"   # label is slug-safe; no XML escaping needed
  printf '%s\n' "$template" > "$dst"

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
echo "  launchctl kickstart -k $DOMAIN/$PREFIX.daily"
