#!/usr/bin/env bash
# install-launchd.sh [uninstall] - (re)install the daily + weekly + refresh launchd
# agents WITHOUT editing anything tracked in the repo.
#
# It generates the real plists from the launchd/*.plist templates into
# ~/Library/LaunchAgents, substituting this checkout's absolute path for __VP_ROOT__
# and the agent label for __VP_LABEL__, then loads them. The committed templates are
# never touched, so a fresh clone stays clean and `git status` never shows local edits.
#
# The refresh agent runs `bootstrap.sh --if-stale` daily: a no-op unless the approved
# profile is past governance.profile_refresh_days, so a forgotten refresh can't quietly
# rot a profile (set profile_refresh_days blank/0 to turn it off entirely). Daily because
# a coarser poll cannot honour the window it checks - see the plist template.
#
# Multiple instances on one machine: give each checkout a distinct
# `deployment.instance` in its monitor-config.yaml and the agent labels/filenames are
# namespaced (ai.zoller.vantagepoint.<instance>.{daily,weekly,refresh}) so clones don't
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
# ProgramArguments[0] in our plists - monitor.sh for daily/weekly, bootstrap.sh for
# refresh - so ownership is matched on the checkout's bin/ prefix, not one script name.
# Only ProgramArguments carries a bin/ path (the log paths are under state/), so this
# stays as specific as the full-line match it replaced.
PROG_PREFIX="<string>$ROOT_XML/bin/"

command -v launchctl >/dev/null 2>&1 || {
  echo "launchctl not found - launchd is macOS-only. On Linux use cron (see README)." >&2
  exit 1
}

# Optional per-instance namespace from the config (so multiple clones coexist).
# Slugify to a safe label segment: lowercase, non-[a-z0-9-] -> '-', trim dashes.
INSTANCE_RAW=""
[ -f "$ROOT/monitor-config.yaml" ] && INSTANCE_RAW="$(cfg_get_text deployment instance "$ROOT/monitor-config.yaml")"
INSTANCE="$(printf '%s' "$INSTANCE_RAW" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//')"
if [ -n "$INSTANCE" ]; then
  PREFIX="ai.zoller.vantagepoint.$INSTANCE"
else
  PREFIX="ai.zoller.vantagepoint"
fi
LABELS=("$PREFIX.daily" "$PREFIX.weekly" "$PREFIX.refresh")

# Hour for the DAILY refresh check, staggered per instance. The check itself is free;
# what must not collide is the deep-research bootstrap it can start, which is the most
# expensive thing this repo runs. Clones bootstrapped on the same day cross their refresh
# windows on the same day, so they need separating in TIME, not by date. Hashing the label
# gives each checkout a stable hour (identical on every reinstall) with nothing to
# configure. 1-5, so every bucket lands before the 06:30 daily sweep.
REFRESH_HOUR=$(( $(printf '%s' "$PREFIX.refresh" | cksum | awk '{print $1}') % 5 + 1 ))

# A configured-but-unusable name must NOT silently become the default deployment.
# Checked up front (before any LaunchAgents mutation) so a bad name can't leave the
# checkout unscheduled - but only when installing; uninstall is path/marker-based and
# must still work with a since-broken name.
if [ "${1:-}" != "uninstall" ] && [ -n "$INSTANCE_RAW" ] && [ -z "$INSTANCE" ]; then
  echo "deployment.instance ('$INSTANCE_RAW') has no usable [a-z0-9-] characters - pick an ASCII slug" >&2
  exit 1
fi

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
    grep -qF "$PROG_PREFIX" "$f" || continue
    base="$(basename "$f")"
    printf '%s\n' "${base%.plist}"
  done
}

# Is label $1 OURS? Yes if its plist runs this checkout, OR runs a checkout path that
# no longer exists (THIS checkout was moved). No if it points at a different, still
# present checkout - i.e. a sibling instance (possibly made by copying a checkout, so
# its recorded marker is not authoritative for us).
label_is_ours() {
  local plist="$LA_DIR/$1.plist" prog
  [ -f "$plist" ] || return 1
  grep -qF "$PROG_PREFIX" "$plist" && return 0
  prog="$(sed -n 's#^[[:space:]]*<string>\(.*/bin/[^/<]*\.sh\)</string>[[:space:]]*$#\1#p' "$plist" | head -1)"
  # The path is XML-escaped in the plist; decode it (amp last) before the -e test, or a
  # sibling whose path has &/</> would look "gone" and defeat the hijack guard.
  prog="${prog//&lt;/<}"; prog="${prog//&gt;/>}"; prog="${prog//&amp;/&}"
  [ -n "$prog" ] && [ ! -e "$prog" ]   # our old location is gone -> we moved here
}

# The plist's baked-in path stops matching if the checkout is MOVED, and the label
# changes if deployment.instance is RENAMED - so also record what we installed in a
# per-checkout marker (it travels with the checkout, surviving a rename). Cleanup uses
# the union of both signals, but each marker label is validated as ours first, so a
# copied checkout's inherited marker can't make us tear down a live sibling.
MARKER="$ROOT/state/.launchd-labels"
installed_labels() {
  { our_installed_labels
    if [ -f "$MARKER" ]; then
      while IFS= read -r l; do
        [ -n "$l" ] && label_is_ours "$l" && printf '%s\n' "$l"
        true   # keep the loop body's exit 0 under set -e
      done < "$MARKER"
    fi
    true       # keep the group's exit 0 (marker may be absent) for set -e/pipefail
  } | sort -u
}

# Retire pre-rename (market-monitor) agents so they can't fire alongside the renamed
# ones. Matched by label: these predate instances entirely, so only one such set ever
# exists on a machine - retiring it isn't instance-specific. Defined as a function so
# it runs only AFTER the collision preflight (a rejected install must mutate nothing).
retire_legacy_agents() {
  local label
  for label in ai.zoller.marketmonitor.daily ai.zoller.marketmonitor.weekly; do
    if [ -f "$LA_DIR/$label.plist" ]; then
      remove_label "$label"
      echo "[install-launchd] retired legacy agent $label"
    fi
  done
}

# Uninstall removes ALL of this checkout's agents (by baked-in path AND the recorded
# marker), so it works after a move or rename, and even if the name is now invalid.
# It also retires any legacy agents (no collision concern on the uninstall path).
uninstall() {
  retire_legacy_agents
  installed_labels | while IFS= read -r label; do
    [ -n "$label" ] || continue
    remove_label "$label"
    echo "[install-launchd] removed $label"
  done
  rm -f "$MARKER"
}

if [ "${1:-}" = "uninstall" ]; then
  uninstall
  exit 0
fi

mkdir -p "$LA_DIR" "$ROOT/state"

# Refuse to hijack a label that already belongs to a DIFFERENT live checkout (e.g. two
# clones whose deployment.instance slugify to the same value). Labels must be unique.
# This is the FIRST thing on the install path: nothing below mutates LaunchAgents until
# the install is known to be valid, so a rejected install leaves every schedule intact.
for label in "${LABELS[@]}"; do
  if [ -f "$LA_DIR/$label.plist" ] && ! label_is_ours "$label"; then
    echo "[install-launchd] label $label already belongs to a different checkout - set a unique deployment.instance" >&2
    exit 1
  fi
done

# Past the preflight: now it's safe to mutate. Retire legacy agents, then any of OUR
# previously-installed agents whose label we're NOT about to (re)install - i.e. after
# renaming deployment.instance (or moving the checkout, via the marker). Scoped to this
# checkout, so sibling instances are untouched.
retire_legacy_agents
installed_labels | while IFS= read -r label; do
  [ -n "$label" ] || continue
  case " ${LABELS[*]} " in *" $label "*) continue ;; esac
  remove_label "$label"
  echo "[install-launchd] retired stale agent $label (relabelled/moved this checkout)"
done

# Iterate modes (template filenames are fixed); the label is namespaced per instance.
for mode in daily weekly refresh; do
  label="$PREFIX.$mode"
  src="$ROOT/launchd/ai.zoller.vantagepoint.$mode.plist"
  dst="$LA_DIR/$label.plist"
  [ -f "$src" ] || { echo "missing template $src" >&2; exit 1; }

  template="$(cat "$src")"
  template="${template//__VP_ROOT__/$ROOT_XML}"
  template="${template//__VP_LABEL__/$label}"   # label is slug-safe; no XML escaping needed
  template="${template//__VP_REFRESH_HOUR__/$REFRESH_HOUR}"   # refresh template only; a no-op elsewhere
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

# Record what we installed so a later uninstall/rename/move can find these labels
# even if the path or instance name no longer matches.
printf '%s\n' "${LABELS[@]}" > "$MARKER"

echo "[install-launchd] profile refresh: daily at 0$REFRESH_HOUR:00 (a no-op unless the profile is past governance.profile_refresh_days)"
echo "[install-launchd] done. Kick a run now to confirm wiring:"
echo "  launchctl kickstart -k $DOMAIN/$PREFIX.daily"
