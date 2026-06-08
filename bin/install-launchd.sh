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
# collide. Leave it unset for a single deployment (labels stay un-suffixed). Renaming
# an instance (or converting a default deployment to a named one) is safe: a reinstall
# retires this checkout's previously-installed agents before installing the new labels.
#
#   ./bin/install-launchd.sh            # install / reinstall this instance's agents
#   ./bin/install-launchd.sh uninstall  # unload + remove this checkout's agents
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

# XML-escape the checkout path once (used both to write plists and to recognize the
# agents that belong to THIS checkout). Escape & first so it isn't double-escaped.
ROOT_XML="$ROOT"
ROOT_XML="${ROOT_XML//&/&amp;}"
ROOT_XML="${ROOT_XML//</&lt;}"
ROOT_XML="${ROOT_XML//>/&gt;}"
PROG_LINE="<string>$ROOT_XML/bin/monitor.sh</string>"   # ProgramArguments[0] in our plists

command -v launchctl >/dev/null 2>&1 || {
  echo "launchctl not found - launchd is macOS-only. On Linux use cron (see README)." >&2
  exit 1
}

# Optional per-instance namespace from the config (so multiple clones coexist).
# Slugify to a safe label segment: lowercase, non-[a-z0-9-] -> '-', trim dashes.
INSTANCE_RAW=""
[ -f "$ROOT/monitor-config.yaml" ] && INSTANCE_RAW="$(cfg_get_text deployment instance "$ROOT/monitor-config.yaml")"
INSTANCE="$(printf '%s' "$INSTANCE_RAW" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//')"
# A configured-but-unusable name must NOT silently become the default deployment.
if [ -n "$INSTANCE_RAW" ] && [ -z "$INSTANCE" ]; then
  echo "deployment.instance ('$INSTANCE_RAW') has no usable [a-z0-9-] characters - pick an ASCII slug" >&2
  exit 1
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

# Labels of every installed agent whose plist runs THIS checkout's monitor.sh
# (identified by the baked-in path), one per line. Lets us retire our own stale
# agents after a rename without ever touching a sibling instance (different checkout).
our_installed_labels() {
  local f base
  for f in "$LA_DIR"/ai.zoller.vantagepoint.*.plist; do
    [ -e "$f" ] || continue
    grep -qF "$PROG_LINE" "$f" || continue
    base="$(basename "$f")"
    printf '%s\n' "${base%.plist}"
  done
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
  # Remove every agent that runs this checkout (covers a since-renamed instance too).
  our_installed_labels | while IFS= read -r label; do
    remove_label "$label"
    echo "[install-launchd] removed $label"
  done
  # Safety net (e.g. a hand-edited plist path-match missed): the current labels.
  for label in "${LABELS[@]}"; do
    if [ -f "$LA_DIR/$label.plist" ]; then remove_label "$label"; echo "[install-launchd] removed $label"; fi
  done
}

if [ "${1:-}" = "uninstall" ]; then
  uninstall
  exit 0
fi

mkdir -p "$LA_DIR" "$ROOT/state"

# Retire any of OUR previously-installed agents whose label we're NOT about to
# (re)install - i.e. after renaming deployment.instance, or converting a default
# deployment to a named one. Scoped by checkout path, so siblings are untouched.
our_installed_labels | while IFS= read -r label; do
  case " ${LABELS[*]} " in *" $label "*) continue ;; esac
  remove_label "$label"
  echo "[install-launchd] retired stale agent $label (relabelled this checkout)"
done

# Iterate modes (template filenames are fixed); the label is namespaced per instance.
for mode in daily weekly; do
  label="$PREFIX.$mode"
  src="$ROOT/launchd/ai.zoller.vantagepoint.$mode.plist"
  dst="$LA_DIR/$label.plist"
  [ -f "$src" ] || { echo "missing template $src" >&2; exit 1; }

  template="$(cat "$src")"
  template="${template//__VP_ROOT__/$ROOT_XML}"
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
